import AppKit
import Testing
@testable import ClipboardTool

@Suite(.serialized)
@MainActor
struct ClotheslineTests {
    @Test func panelDoesNotStealTypingFocus() {
        _ = NSApplication.shared
        let panel = ClotheslinePanel(contentRect: .init(x: 0, y: 0, width: 980, height: 224), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }
    @Test func usesEachDisplaysOwnCoordinatesAndAvoidsMenuBar() {
        for screen in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -2560, y: -300, width: 2560, height: 1440), CGRect(x: 200, y: 982, width: 1080, height: 1920)] {
            let visible = CGRect(x: screen.minX, y: screen.minY + 40, width: screen.width, height: screen.height - 78)
            for expanded in [false, true] {
                let frame = ClotheslineLayout.frame(screen: screen, visible: visible, expanded: expanded)
                #expect(visible.contains(frame))
                #expect(frame.maxY < visible.maxY)
                #expect(frame.maxX == visible.maxX - 16)
                if !expanded { #expect(frame.width == 72) }
            }
        }
    }
    @Test func paginationReachesLastItemAndRecoversAfterDeletion() {
        #expect(ClotheslineLayout.pageStart(48, count: 50, capacity: 6) == 48)
        #expect(ClotheslineLayout.pageStart(54, count: 50, capacity: 6) == 48)
        #expect(ClotheslineLayout.pageStart(48, count: 3, capacity: 6) == 0)
        #expect(ClotheslineLayout.pageStart(48, count: 0, capacity: 6) == 0)
    }
    @Test func noPasteIntoButtonOrUnknownFocus() {
        #expect(!ClotheslineLayout.isEditable(role: "AXButton", valueSettable: false, explicitlyEditable: false))
        #expect(!ClotheslineLayout.isEditable(role: nil, valueSettable: false, explicitlyEditable: false))
        #expect(ClotheslineLayout.isEditable(role: "AXTextArea", valueSettable: false, explicitlyEditable: false))
        #expect(ClotheslineLayout.isEditable(role: "AXGroup", valueSettable: false, explicitlyEditable: true))
    }
    @Test func sharedHistoryFiltersFilesWithoutDroppingFullText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(baseDir: root)
        let text = "第一行\n  缩进正文\n" + String(repeating: "原文内容", count: 500)
        store.addText(text); store.addText("第二条"); store.addText(text)
        let shown = ClotheslineLayout.items(store.items)
        #expect(shown.count == 2)
        #expect(shown.first?.text == text)
        store.saveNow()
    }
    @Test func originalPreferencesRemainCompatible() {
        #expect(ClipboardPresentation(rawValue: "panel") == .native)
        #expect(ClipboardPresentation(rawValue: "dock") == .dock)
        #expect(ClipboardPresentation(rawValue: "clothesline") == .clothesline)
    }
}
