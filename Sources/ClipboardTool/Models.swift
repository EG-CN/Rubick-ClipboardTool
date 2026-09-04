import Foundation
import AppKit
import Combine

// MARK: - 剪贴板条目模型

enum ItemKind: String, Codable {
    case text
    case image
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    var id: String
    var kind: ItemKind
    var text: String?
    var imageFile: String?
    var timestamp: Date
    var pinned: Bool
}

// MARK: - 通知

extension Notification.Name {
    static let clipboardHistoryChanged = Notification.Name("clipboardHistoryChanged")
    static let panelSelectionChanged = Notification.Name("panelSelectionChanged")
    static let panelShown = Notification.Name("panelShown")
}

// MARK: - 历史存储（JSON 索引 + images/ 存 PNG）

/// 历史数据落盘于 ~/Library/Application Support/ClipboardTool/
/// v0.1 骨架用 JSON 索引 + PNG 文件；后续可平滑迁移到 SQLite 索引（功能清单 7.2）
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published var items: [ClipboardItem] = []
    var limit: Int = UserDefaults.standard.object(forKey: "historyLimit") as? Int ?? 50 {
        didSet {
            UserDefaults.standard.set(limit, forKey: "historyLimit")
            trim()
            save()
            notify()
        }
    }

    let baseDir: URL
    let imagesDir: URL
    private let jsonURL: URL

    /// 图片内存缓存：面板列表每帧都会取缩略图，不能每次都读盘（卡顿根因之一）
    private let imageCache = NSCache<NSString, NSImage>()
    /// 剪贴板图片入册串行队列：PNG 编码/磁盘比对/写文件全部离开主线程（卡顿根因之二）
    private let ingestQueue = DispatchQueue(label: "clipboardtool.ingest", qos: .userInitiated)

    /// baseDir 传 nil 时使用默认 Application Support 目录；测试可注入临时目录
    init(baseDir: URL? = nil) {
        let fm = FileManager.default
        if let baseDir = baseDir {
            self.baseDir = baseDir
            imagesDir = baseDir.appendingPathComponent("images", isDirectory: true)
            jsonURL = baseDir.appendingPathComponent("history.json")
        } else {
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDir = support.appendingPathComponent("ClipboardTool", isDirectory: true)
            imagesDir = self.baseDir.appendingPathComponent("images", isDirectory: true)
            jsonURL = self.baseDir.appendingPathComponent("history.json")
        }
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        imageCache.countLimit = 200
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: jsonURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else { return }
        items = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }

    // MARK: 写入（带去重 + 上限裁剪 + 持久化）

    func addText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 全量去重：任何位置出现相同文字 → 置顶并更新时间（与原型一致）
        if let idx = items.firstIndex(where: { $0.kind == .text && $0.text == trimmed }) {
            var t = items.remove(at: idx)
            t.timestamp = Date()
            items.insert(t, at: 0)
        } else {
            items.insert(ClipboardItem(id: UUID().uuidString, kind: .text, text: trimmed,
                                       imageFile: nil, timestamp: Date(), pinned: false), at: 0)
        }
        trim()
        save()
        notify()
    }

    func addImage(_ image: NSImage) {
        // cgImage 提取与队列外状态捕获轻量，留主线程；PNG 编码走后台（截图管线入口）
        let prev = imageFileOfFirstImageItem()
        let cg = image.cgImage()
        ingestQueue.async { [weak self] in
            guard let self, let cg else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            self.compareAndStore(png, prev: prev)
        }
    }

    /// 监听器入口：剪贴板里已是 PNG 字节时零编码直写入册
    func addImageData(_ data: Data) {
        let prev = imageFileOfFirstImageItem()
        ingestQueue.async { [weak self] in
            self?.compareAndStore(data, prev: prev)
        }
    }

    /// 主线程取最近一条图片的文件名（避免后台线程读 @Published）
    private func imageFileOfFirstImageItem() -> (id: String, file: String)? {
        guard let first = items.first, first.kind == .image, let f = first.imageFile else { return nil }
        return (first.id, f)
    }

    /// 后台（串行 FIFO）：字节级去重比对 + 落盘，然后回主线程更新索引
    private func compareAndStore(_ png: Data, prev: (id: String, file: String)?) {
        if let prev,
           let existing = try? Data(contentsOf: imagesDir.appendingPathComponent(prev.file)),
           existing == png {
            DispatchQueue.main.async { [weak self] in self?.applyDedupe(id: prev.id) }
        } else {
            let name = UUID().uuidString + ".png"
            try? png.write(to: imagesDir.appendingPathComponent(name), options: .atomic)
            DispatchQueue.main.async { [weak self] in self?.applyNewFile(name) }
        }
    }

    private func applyDedupe(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var t = items.remove(at: idx)
        t.timestamp = Date()
        items.insert(t, at: 0)
        trim()
        save()
        notify()
    }

    private func applyNewFile(_ name: String) {
        items.insert(ClipboardItem(id: UUID().uuidString, kind: .image, text: nil,
                                   imageFile: name, timestamp: Date(), pinned: false), at: 0)
        trim()
        save()
        notify()
    }

    func imageFor(_ item: ClipboardItem) -> NSImage? {
        guard let f = item.imageFile else { return nil }
        if let hit = imageCache.object(forKey: f as NSString) { return hit }
        guard let img = NSImage(contentsOf: imagesDir.appendingPathComponent(f)) else { return nil }
        imageCache.setObject(img, forKey: f as NSString)
        return img
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
        notify()
    }

    func clear() {
        items.removeAll()
        save()
        notify()
    }

    /// 点击条目后置顶（更新使用时间）
    func touch(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        var t = item
        t.timestamp = Date()
        items.insert(t, at: 0)
        save()
        notify()
    }

    private func trim() {
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
    }
}

// MARK: - NSImage → PNG

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - 相对时间

func timeAgo(_ date: Date) -> String {
    let s = Date().timeIntervalSince(date)
    if s < 60 { return "刚刚" }
    if s < 3600 { return "\(Int(s / 60)) 分钟前" }
    if s < 86400 { return "\(Int(s / 3600)) 小时前" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "M月d日 HH:mm"
    return f.string(from: date)
}
