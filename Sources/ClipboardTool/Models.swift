import Foundation
import AppKit
import Combine

// MARK: - 剪贴板条目模型

enum ItemKind: String, Codable {
    case text
    case image
    case file
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    var id: String
    var kind: ItemKind
    var text: String?
    var imageFile: String?
    var timestamp: Date
    var pinned: Bool
    /// kind == .file 时的源文件路径
    var filePath: String?
    /// 用户标签（右键标记；nil = 未标记）
    var tag: String?
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
    /// 缩略图缓存（列表/Dock 渲染专用，按目标尺寸降采样，不持全尺寸解码图）
    private let thumbCache = NSCache<NSString, NSImage>()
    /// 持久化串行队列：JSON 编码+写盘离开主线程（历史越大越卡的根因之三）
    private let saveQueue = DispatchQueue(label: "clipboardtool.save", qos: .utility)
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
        imageCache.totalCostLimit = 128 * 1024 * 1024   // 全尺寸解码图也要有内存上限
        thumbCache.countLimit = 300
        thumbCache.totalCostLimit = 48 * 1024 * 1024
        load()
        sweepOrphanImages()
    }

    /// 启动清扫孤儿 PNG：历史版本的 trim/remove 只动索引不删文件，images/ 会无限累积
    private func sweepOrphanImages() {
        let referenced = Set(items.compactMap { $0.imageFile })
        let dir = imagesDir
        DispatchQueue.global(qos: .utility).async {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let cutoff = Date().addingTimeInterval(-60)
            for f in files where f.pathExtension.lowercased() == "png" && !referenced.contains(f.lastPathComponent) {
                // 跳过 60s 内的新文件：入册是"先写文件后插索引"，刚写的图不是孤儿
                let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if mtime < cutoff { try? FileManager.default.removeItem(at: f) }
            }
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: jsonURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else { return }
        items = decoded
    }

    /// 异步持久化：快照后入串行队列，主线程只做一次数组拷贝
    func save() {
        let snapshot = items
        let url = jsonURL
        saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 同步落盘（测试与关键路径用）
    func saveNow() {
        saveQueue.sync { }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }

    // MARK: 写入（带去重 + 上限裁剪 + 持久化）

    func addText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 全文入库：截断只允许发生在展示层——入库截断会让粘贴静默丢数据
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
        imageCache.setObject(img, forKey: f as NSString, cost: img.costEstimate)
        return img
    }

    /// 渲染用缩略图：从磁盘直接降采样到目标像素（不整图解码，内存占用差一个量级）
    func thumbnail(for item: ClipboardItem, maxPixel: CGFloat) -> NSImage? {
        guard let f = item.imageFile else { return nil }
        let key = "\(f)#\(Int(maxPixel))" as NSString
        if let hit = thumbCache.object(forKey: key) { return hit }
        let url = imagesDir.appendingPathComponent(f)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return imageFor(item) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return imageFor(item)
        }
        let img = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        thumbCache.setObject(img, forKey: key, cost: img.costEstimate)
        return img
    }

    private func deleteImageFile(_ name: String?) {
        guard let name else { return }
        imageCache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name))
    }

    /// 文件条目（Finder ⌘C 等 fileURL 来源），按路径去重
    func addFile(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if let idx = items.firstIndex(where: { $0.kind == .file && $0.filePath == path }) {
            var t = items.remove(at: idx)
            t.timestamp = Date()
            items.insert(t, at: 0)
        } else {
            items.insert(ClipboardItem(id: UUID().uuidString, kind: .file, text: nil, imageFile: nil,
                                       timestamp: Date(), pinned: false, filePath: path, tag: nil), at: 0)
        }
        trim()
        save()
        notify()
    }

    /// 设置/移除用户标签
    func setTag(_ tag: String?, id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].tag = tag
        save()
        notify()
    }

    func remove(_ id: String, keepingFile: Bool = false) {
        let file = items.first { $0.id == id }?.imageFile
        items.removeAll { $0.id == id }
        if !keepingFile { deleteImageFile(file) }
        save()
        notify()
    }

    func clear() {
        let files = items.compactMap { $0.imageFile }
        items.removeAll()
        files.forEach { deleteImageFile($0) }
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
        guard items.count > limit else { return }
        for d in items.dropFirst(limit) { deleteImageFile(d.imageFile) }
        items = Array(items.prefix(limit))
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

    /// 粗略解码内存占用（字节），供 NSCache totalCostLimit 计费
    var costEstimate: Int {
        if let cg = cgImage() { return max(cg.bytesPerRow * cg.height, 1) }
        return Int(max(size.width, 1) * max(size.height, 1) * 4)
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
