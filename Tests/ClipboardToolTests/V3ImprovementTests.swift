import XCTest
import AppKit
@testable import ClipboardTool

// MARK: - v3 改造测试：图片缓存 / 异步图片入册 / 新全局快捷键 / 即打即搜过滤

final class V3ImprovementTests: XCTestCase {

    private func makeStore() -> HistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbt-v3-" + UUID().uuidString, isDirectory: true)
        let store = HistoryStore(baseDir: dir)
        store.limit = 50
        return store
    }

    private func makeTestPNGData(size: CGSize = CGSize(width: 8, height: 8), color: NSColor = .red) -> Data? {
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return img.pngData()
    }

    /// 主线程 runloop 自旋，等待后台队列 + 主队列两级跳转完成
    private func waitUntil(timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: 图片缓存：两次 imageFor 命中同一实例（不再每次读盘）

    func testImageForReturnsCachedInstance() throws {
        let s = makeStore()
        guard let png = makeTestPNGData() else { return XCTFail("生成测试 PNG 失败") }
        let name = "cached-\(UUID().uuidString).png"
        try png.write(to: s.imagesDir.appendingPathComponent(name))
        let item = ClipboardItem(id: UUID().uuidString, kind: .image, text: nil,
                                 imageFile: name, timestamp: Date(), pinned: false)
        s.items.append(item)
        guard let first = s.imageFor(item) else { return XCTFail("首次读取失败") }
        let second = s.imageFor(item)
        XCTAssertTrue(first === second, "第二次读取应命中缓存（同一实例）")
    }

    // MARK: 异步入册：PNG 字节直写 → 索引落盘

    func testAddImageDataCreatesItem() {
        let s = makeStore()
        guard let png = makeTestPNGData(color: .blue) else { return XCTFail("生成测试 PNG 失败") }
        s.addImageData(png)
        waitUntil { s.items.count == 1 }
        XCTAssertEqual(s.items.count, 1)
        XCTAssertEqual(s.items.first?.kind, .image)
        XCTAssertNotNil(s.items.first?.imageFile)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: s.imagesDir.appendingPathComponent(s.items.first!.imageFile!).path))
        waitUntil { s.imageFor(s.items.first!) != nil }
        XCTAssertNotNil(s.imageFor(s.items.first!))
    }

    // MARK: 异步入册去重：同一 PNG 两次入册仍只有一条（置顶刷新时间）

    func testAddImageDataDedupes() {
        let s = makeStore()
        guard let png = makeTestPNGData(color: .green) else { return XCTFail("生成测试 PNG 失败") }
        s.addImageData(png)
        waitUntil { s.items.count == 1 }
        let firstTimestamp = s.items.first?.timestamp
        Thread.sleep(forTimeInterval: 0.05)
        s.addImageData(png)
        waitUntil { [weak s] in s?.items.first?.timestamp != firstTimestamp }
        XCTAssertEqual(s.items.count, 1, "相同图片应去重")
    }

    // MARK: 即打即搜：搜索词只匹配文本条目；图片条目在搜索态被过滤

    func testSearchMatchesTextOnly() {
        let state = PanelState()
        state.searchText = "  hello  "
        let text = ClipboardItem(id: "1", kind: .text, text: "say Hello World",
                                 imageFile: nil, timestamp: Date(), pinned: false)
        let image = ClipboardItem(id: "2", kind: .image, text: nil,
                                  imageFile: "x.png", timestamp: Date(), pinned: false)
        XCTAssertTrue(state.matches(text), "搜索应大小写不敏感且去除首尾空白")
        XCTAssertFalse(state.matches(image), "搜索态不匹配图片条目")
    }

    // MARK: 新全局快捷键位

    func testGlobalHotkeyActionsCount() {
        XCTAssertEqual(HotkeyManager.Action.allCases.count, 6, "原有 4 个 + 钉贴图 + 划图取字")
    }

    func testNewActionLabels() {
        XCTAssertTrue(actionLabel(.pinClipboard).contains("钉剪贴板"))
        XCTAssertTrue(actionLabel(.dragOCR).contains("取字"))
    }
}
