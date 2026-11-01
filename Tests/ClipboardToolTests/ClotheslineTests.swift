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
    @Test func variableWidthPagesNeverLoseOrDuplicateItems() {
        let sizes = (0..<51).map { CGSize(width: $0 % 2 == 0 ? 164 : 320, height: 250) }
        for width: CGFloat in [640, 1512, 2560] {
            let pages = ClotheslineLayout.pages(sizes: sizes, width: width)
            #expect(pages.flatMap { Array($0) } == Array(sizes.indices))
            for page in pages {
                let used = page.reduce(CGFloat(0)) { $0 + sizes[$1].width } + CGFloat(max(0, page.count - 1)) * 18
                #expect(used <= width - 32)
            }
        }
        #expect(ClotheslineLayout.pages(sizes: [], width: 1512).isEmpty)
    }
    @Test func polaroidShapesFollowContent() {
        let landscape = ClotheslineLayout.cardSize(image: CGSize(width: 1920, height: 1080), text: nil)
        let portrait = ClotheslineLayout.cardSize(image: CGSize(width: 1080, height: 1920), text: nil)
        #expect(landscape.width > portrait.width)
        #expect(landscape.height < portrait.height)
        let short = ClotheslineLayout.cardSize(image: nil, text: "收到")
        let long = ClotheslineLayout.cardSize(image: nil, text: String(repeating: "长文字\n", count: 500))
        #expect(short.height < long.height)
        #expect(long.height <= 274)
        #expect(ClotheslineLayout.cardSize(image: CGSize(width: 0, height: 0), text: nil).height.isFinite)
    }
    @Test func movedAnchorRestoresAndExpansionStaysInsideScreen() {
        let screen = CGRect(x: -2560, y: -200, width: 2560, height: 1440)
        let visible = screen.insetBy(dx: 0, dy: 30)
        for anchor in [CGPoint(x: 0, y: 0), CGPoint(x: 0.4, y: 0.5), CGPoint(x: 1, y: 1)] {
            let tab = ClotheslineLayout.frame(screen: screen, visible: visible, expanded: false, anchor: anchor)
            let open = ClotheslineLayout.frame(screen: screen, visible: visible, expanded: true, anchor: anchor)
            #expect(visible.contains(tab) && visible.contains(open))
            #expect(open.width == visible.width - 32)
            if anchor.x == 0.4 { #expect(abs(tab.minX - (visible.minX + 0.4 * visible.width)) < 0.01) }
        }
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
    @Test func deleteAndUndoRestoresIdentityOrderAndFullText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(baseDir: root)
        store.addText("第一条\n带换行"); store.addText("第二条")
        let original = store.items
        let undo = try #require(store.removeUndoable(original[1].id))
        #expect(store.items.count == 1)
        undo()
        #expect(store.items == original)
        undo()
        #expect(store.items.count == 2)
        store.saveNow()
    }
    @Test func undoDoesNotDuplicateContentCopiedAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(baseDir: root)
        store.addText("相同内容")
        let undo = try #require(store.removeUndoable(store.items[0].id))
        store.addText("相同内容"); undo()
        #expect(store.items.count == 1)
        store.saveNow()
    }
    @Test func undoRestoresDeletedImageBytesAndMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(baseDir: root)
        let image = NSImage(size: CGSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let bytes = try #require(image.pngData())
        let file = store.imagesDir.appendingPathComponent("undo.png")
        try bytes.write(to: file)
        let item = ClipboardItem(id: UUID().uuidString, kind: .image, imageFile: "undo.png", timestamp: Date(), pinned: false, contentHash: "undo-image", metaWidth: 4, metaHeight: 4)
        store.items = [item]
        let undo = try #require(store.removeUndoable(item.id))
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        undo()
        #expect(store.items == [item])
        #expect(try Data(contentsOf: file) == bytes)
        #expect(store.imageFor(item) != nil)
        store.saveNow()
    }
    @Test func invocationRestoresHiddenStaleExpandedState() {
        #expect(ClotheslineLayout.expandsOnInvocation(hidden: true, visible: false, expanded: true))
        #expect(ClotheslineLayout.expandsOnInvocation(hidden: false, visible: false, expanded: true))
        #expect(ClotheslineLayout.expandsOnInvocation(hidden: false, visible: true, expanded: false))
        #expect(!ClotheslineLayout.expandsOnInvocation(hidden: false, visible: true, expanded: true))
    }
    @Test func originalPreferencesRemainCompatible() {
        #expect(ClipboardPresentation(rawValue: "panel") == .native)
        #expect(ClipboardPresentation(rawValue: "dock") == .dock)
        #expect(ClipboardPresentation(rawValue: "clothesline") == .clothesline)
    }
}
