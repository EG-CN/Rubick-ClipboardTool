import XCTest
import AppKit
import Carbon.HIToolbox
@testable import ClipboardTool

// MARK: - HistoryStore 核心逻辑测试（去重 / 上限裁剪 / 持久化 / 清空）

final class HistoryStoreTests: XCTestCase {

    private func makeStore() -> HistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbt-tests-" + UUID().uuidString, isDirectory: true)
        let store = HistoryStore(baseDir: dir)
        store.limit = 50 // 归一化（避免测试间 UserDefaults 污染）
        return store
    }

    func testTextDedupeMovesToTop() {
        let s = makeStore()
        s.addText("aaa")
        s.addText("bbb")
        s.addText("aaa")
        XCTAssertEqual(s.items.count, 2)
        XCTAssertEqual(s.items.first?.text, "aaa")
    }

    func testLimitTrimKeepsNewest() {
        let s = makeStore()
        s.limit = 3
        for i in 1...5 { s.addText("t\(i)") }
        XCTAssertEqual(s.items.count, 3)
        XCTAssertEqual(s.items.first?.text, "t5")
        XCTAssertEqual(s.items.last?.text, "t3")
    }

    func testPersistenceRoundTrip() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbt-persist-" + UUID().uuidString, isDirectory: true)
        let s1 = HistoryStore(baseDir: dir)
        s1.limit = 50
        s1.addText("hello 世界")
        s1.saveNow()   // save() 已异步化，测试显式同步落盘
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path))
        let s2 = HistoryStore(baseDir: dir)
        XCTAssertEqual(s2.items.count, 1)
        XCTAssertEqual(s2.items.first?.text, "hello 世界")
    }

    func testClearRemovesAll() {
        let s = makeStore()
        s.addText("a")
        s.addText("b")
        s.clear()
        XCTAssertTrue(s.items.isEmpty)
    }
}

// MARK: - 面板内快捷键匹配测试

final class PanelKeyConfigTests: XCTestCase {

    private func makeEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags = [], chars: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: flags,
                         timestamp: 0,
                         windowNumber: 0,
                         context: nil,
                         characters: chars,
                         charactersIgnoringModifiers: chars,
                         isARepeat: false,
                         keyCode: keyCode)!
    }

    func testDefaultsPresent() {
        let cfg = PanelKeyConfig()
        XCTAssertEqual(cfg.keys.count, 10)   // 9 原有 + ⌘F 聚焦搜索
        XCTAssertEqual(cfg.keys[.searchFocus]?.display, "⌘F")
        XCTAssertEqual(cfg.keys[.navUp]?.display, "↑")
        XCTAssertEqual(cfg.keys[.paste]?.display, "↵")
        XCTAssertTrue(cfg.hintText().contains("选择"))
        XCTAssertTrue(cfg.hintText().contains("快选"))
    }

    func testArrowKeyMatching() {
        let cfg = PanelKeyConfig()
        let up = makeEvent(keyCode: UInt16(kVK_UpArrow), chars: "↑")
        let down = makeEvent(keyCode: UInt16(kVK_DownArrow), chars: "↓")
        XCTAssertTrue(cfg.matches(.navUp, event: up))
        XCTAssertFalse(cfg.matches(.navDown, event: up))
        XCTAssertTrue(cfg.matches(.navDown, event: down))
    }

    func testQuickSelectMatching() {
        let cfg = PanelKeyConfig()
        let cmd1 = makeEvent(keyCode: UInt16(kVK_ANSI_1), flags: [.command], chars: "1")
        let cmd7 = makeEvent(keyCode: UInt16(kVK_ANSI_7), flags: [.command], chars: "7")
        let cmd9 = makeEvent(keyCode: UInt16(kVK_ANSI_9), flags: [.command], chars: "9")
        let bare1 = makeEvent(keyCode: UInt16(kVK_ANSI_1), chars: "1")
        XCTAssertTrue(cfg.matches(.quick, event: cmd1))
        XCTAssertEqual(cfg.quickDigit(cmd7), 7)   // 键码 26（非连续排列）
        XCTAssertEqual(cfg.quickDigit(cmd9), 9)   // 键码 25
        XCTAssertFalse(cfg.matches(.quick, event: bare1))
    }
}

// MARK: - 快捷键显示串测试

final class ComboDisplayTests: XCTestCase {

    func testGlobalComboDisplay() {
        // macOS 惯例：⌃⌥⇧⌘ 顺序
        XCTAssertEqual(comboDisplay(modifiers: UInt32(cmdKey | shiftKey),
                                    keyCode: UInt16(kVK_ANSI_V), characters: "v"), "⇧⌘V")
        XCTAssertEqual(comboDisplay(modifiers: UInt32(cmdKey),
                                    keyCode: UInt16(kVK_ANSI_Comma), characters: ","), "⌘,")
    }

    func testSpecialKeysDisplay() {
        XCTAssertEqual(comboDisplay(modifiers: 0, keyCode: UInt16(kVK_UpArrow), characters: nil), "↑")
        XCTAssertEqual(comboDisplay(modifiers: 0, keyCode: UInt16(kVK_Return), characters: nil), "↵")
        XCTAssertEqual(comboDisplay(modifiers: 0, keyCode: UInt16(kVK_Escape), characters: nil), "⎋")
    }
}

// MARK: - G5 压测与 G2 文件/标签

final class StressAndFileKindTests: XCTestCase {

    /// 500 条混合历史的完整性 + 文件清理 + 重载一致性（G5 压测）
    func testStress500MixedItems() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbt-stress-" + UUID().uuidString, isDirectory: true)
        let store = HistoryStore(baseDir: dir)
        store.limit = 500
        for i in 0..<480 {
            store.addText("条目-\(i)-" + String(repeating: "魔法内容", count: 60))
        }
        for i in 0..<20 {
            let img = NSImage(size: NSSize(width: 80, height: 80))
            img.lockFocus()
            NSColor(calibratedHue: CGFloat(i) / 20, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 80, height: 80)).fill()
            img.unlockFocus()
            store.addImage(img)
        }
        // 等待异步入册（ingest 串行队列）
        let deadline = Date().addingTimeInterval(15)
        while store.items.count < 500 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(store.items.count, 500)
        store.saveNow()
        let s2 = HistoryStore(baseDir: dir)
        XCTAssertEqual(s2.items.count, 500)
        // 清空后 images/ 不应残留文件（trim/clear 文件清理路径）
        s2.clear()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("images").path)) ?? []
        XCTAssertEqual(leftover.count, 0, "清空后图片目录应无残留，实际: \(leftover)")
    }

    /// 文件 kind + 标签筛选（G2）
    func testFileKindAndTagFilter() {
        let ps = PanelState()
        let f = ClipboardItem(id: "f1", kind: .file, text: nil, imageFile: nil,
                              timestamp: Date(), pinned: false, filePath: "/tmp/报告.pdf", tag: "重要")
        ps.searchText = ""
        ps.filter = .file
        XCTAssertTrue(ps.matches(f))
        ps.filter = .text
        XCTAssertFalse(ps.matches(f))
        ps.tagFilter = "重要"
        XCTAssertTrue(ps.matches(f), "标签筛选优先于类型筛选")
        ps.tagFilter = "工作"
        XCTAssertFalse(ps.matches(f))
        ps.tagFilter = nil
        ps.filter = .all
        ps.searchText = "报告"
        XCTAssertTrue(ps.matches(f), "文件名可搜索")
        ps.searchText = "不存在"
        XCTAssertFalse(ps.matches(f))
    }

    /// 文件条目持久化往返（新字段的 Codable 兼容）
    func testFileItemPersistenceRoundTrip() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbt-file-" + UUID().uuidString, isDirectory: true)
        let s1 = HistoryStore(baseDir: dir)
        s1.addFile("/tmp/不存在的路径.pdf")
        XCTAssertEqual(s1.items.count, 0, "不存在的文件不入册")
        let real = dir.appendingPathComponent("sample.txt")
        try? "数据".write(to: real, atomically: true, encoding: .utf8)
        s1.addFile(real.path)
        s1.setTag("工作", id: s1.items.first!.id)
        s1.saveNow()
        let s2 = HistoryStore(baseDir: dir)
        XCTAssertEqual(s2.items.count, 1)
        XCTAssertEqual(s2.items.first?.kind, .file)
        XCTAssertEqual(s2.items.first?.tag, "工作")
        XCTAssertEqual(s2.items.first?.filePath, real.path)
        // 相同路径再复制 → 去重置顶
        s2.addFile(real.path)
        XCTAssertEqual(s2.items.count, 1)
    }
}

/// 长截图拼接引擎方向锁（行对齐 P0 回归）
final class StitchEngineTests: XCTestCase {

    /// 每行单一灰度的条纹图，row 从顶部数
    private func makeStriped(shift: Int) -> CGImage {
        let w = 100, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for row in 0..<h {
            let v = UInt8(truncatingIfNeeded: (row + shift) * 2)
            ctx.setFillColor(CGColor(gray: CGFloat(v) / 255.0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: CGFloat(h - 1 - row), width: CGFloat(w), height: 1))
        }
        return ctx.makeImage()!
    }

    func testScrollOffsetDirection() {
        // next = 内容上移 37 行（= 向下滚动 37 行）→ 应返回 37
        let prev = StitchEngine.Sampler(image: makeStriped(shift: 0))!
        let next = StitchEngine.Sampler(image: makeStriped(shift: 37))!
        XCTAssertEqual(StitchEngine.scrollOffset(prev: prev, next: next, maxSearch: 100), 37)
    }

    func testScrollOffsetZeroWhenIdentical() {
        let prev = StitchEngine.Sampler(image: makeStriped(shift: 0))!
        let next = StitchEngine.Sampler(image: makeStriped(shift: 0))!
        XCTAssertEqual(StitchEngine.scrollOffset(prev: prev, next: next, maxSearch: 100), 0)
    }

    func testScrollOffsetAnchorSkipsTopStickyBar() {
        // 顶部 40 行吸顶条内容随滚动"不变"，锚行应避开顶部仍对齐
        let prevBase = makeStriped(shift: 0)
        let nextBase = makeStriped(shift: 45)
        let ctxP = CGContext(data: nil, width: 100, height: 300, bitsPerComponent: 8, bytesPerRow: 100 * 4,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctxP.draw(prevBase, in: CGRect(x: 0, y: 0, width: 100, height: 300))
        ctxP.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctxP.fill(CGRect(x: 0, y: 260, width: 100, height: 40))   // 顶部 40 行（CG 上部）
        let pImg = ctxP.makeImage()!
        let ctxN = CGContext(data: nil, width: 100, height: 300, bitsPerComponent: 8, bytesPerRow: 100 * 4,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctxN.draw(nextBase, in: CGRect(x: 0, y: 0, width: 100, height: 300))
        ctxN.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctxN.fill(CGRect(x: 0, y: 260, width: 100, height: 40))
        let nImg = ctxN.makeImage()!
        let prev = StitchEngine.Sampler(image: pImg)!
        let next = StitchEngine.Sampler(image: nImg)!
        XCTAssertEqual(StitchEngine.scrollOffset(prev: prev, next: next, maxSearch: 100), 45)
    }
}
