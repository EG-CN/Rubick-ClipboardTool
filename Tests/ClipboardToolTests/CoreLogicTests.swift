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
        XCTAssertEqual(cfg.keys.count, 7)
        XCTAssertEqual(cfg.keys[.navUp]?.display, "↑")
        XCTAssertEqual(cfg.keys[.paste]?.display, "↵")
        XCTAssertTrue(cfg.hintText().contains("选择"))
        XCTAssertTrue(cfg.hintText().contains("快速选择"))
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
