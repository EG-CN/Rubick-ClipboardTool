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
    @Test func ropePanelCentersOnEachDisplayAndStaysInsideVisibleArea() {
        for screen in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -2560, y: -300, width: 2560, height: 1440), CGRect(x: 200, y: 982, width: 1080, height: 1920)] {
            let visible = CGRect(x: screen.minX, y: screen.minY + 40, width: screen.width, height: screen.height - 78)
            let frame = ClotheslineLayout.frame(screen: screen, visible: visible, expanded: true)
            #expect(visible.contains(frame))
            #expect(frame.maxY < visible.maxY)
            #expect(frame.midX == visible.midX)
            #expect(frame.width == min(1080, max(560, visible.width * 0.62)))
        }
    }
    @Test func continuousRailKeepsOrderAndClampsScrollOffset() {
        let sizes = (0..<51).map { CGSize(width: $0 % 2 == 0 ? 164 : 320, height: 250) }
        let content = ClotheslineLayout.railWidth(widths: sizes.map(\.width))
        #expect(content > 0)
        for offset in [CGFloat(0), content / 2, content * 2] {
            let frames = ClotheslineLayout.railFrames(sizes: sizes, offset: offset, boundsWidth: 937)
            #expect(frames.count == sizes.count)
            #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.minX < $1.minX })
            // 越界滚动被夹紧：两端重复调用结果一致。
            let clamped = ClotheslineLayout.railFrames(sizes: sizes, offset: offset, boundsWidth: 937)
            #expect(frames == clamped)
        }
        let atEnd = ClotheslineLayout.railFrames(sizes: sizes, offset: content, boundsWidth: 937)
        #expect((atEnd.last?.maxX ?? 0) <= 938)
        #expect(ClotheslineLayout.railWidth(widths: []) == 0)
    }
    @Test func ropeCardsFollowSagAndNeverExceedPanelHeight() {
        let sizes = (0..<9).map { _ in CGSize(width: 220, height: 250) }
        let frames = ClotheslineLayout.railFrames(sizes: sizes, offset: 0, boundsWidth: 800)
        for frame in frames {
            #expect(frame.minY >= 54 && frame.minY <= 67)
            #expect(frame.height <= 250)
        }
        let tallest = ClotheslineLayout.cardSize(image: nil, text: String(repeating: "长文字\n", count: 500))
        #expect(tallest.height <= 274)
    }
    @Test func railFramesHandlesOversizedCardAndEdgeOffsets() {
        // 单卡比面板更宽：frame 仍完整返回，滚动被夹紧后卡片尾部保持可见。
        let oversized = [CGSize(width: 1200, height: 250)]
        let clamped = ClotheslineLayout.railFrames(sizes: oversized, offset: 10_000, boundsWidth: 800)
        #expect(clamped.count == 1)
        #expect(clamped[0].width == 1200)
        #expect(clamped[0].maxX > 0 && clamped[0].maxX <= 800)
        let atStart = ClotheslineLayout.railFrames(sizes: oversized, offset: 0, boundsWidth: 800)
        #expect(atStart.count == 1 && atStart[0].minX >= 0)
        // 空内容返回空数组；负偏移等同 0。
        #expect(ClotheslineLayout.railFrames(sizes: [], offset: 50, boundsWidth: 800).isEmpty)
        #expect(ClotheslineLayout.railFrames(sizes: oversized, offset: -40, boundsWidth: 800) == atStart)
    }
    @Test func railFramesScrollTranslatesXWithoutVerticalParallax() {
        // 卡片跟随绳滚动：offset 变化只平移 x，y 只取决于卡片在绳上的位置。
        let sizes = (0..<10).map { _ in CGSize(width: 200, height: 250) }
        let content = ClotheslineLayout.railWidth(widths: sizes.map(\.width))
        let delta: CGFloat = 120
        #expect(content - 800 >= delta) // 两次偏移都落在夹紧范围内
        let start = ClotheslineLayout.railFrames(sizes: sizes, offset: 0, boundsWidth: 800)
        let scrolled = ClotheslineLayout.railFrames(sizes: sizes, offset: delta, boundsWidth: 800)
        #expect(start.count == sizes.count && scrolled.count == sizes.count)
        for (before, after) in zip(start, scrolled) {
            #expect(after.minY == before.minY)
            #expect(after.minX == before.minX - delta)
        }
    }
    @Test func emptyingHistoryCollapsesExpandedRopeButNonEmptyReloadKeepsIt() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(baseDir: root)
        let view = ClotheslineView(frame: CGRect(x: 0, y: 0, width: 980, height: 224), store: store)
        #expect(view.capacity == 0)
        store.addText("第一条"); store.addText("第二条")
        view.reload()
        #expect(view.capacity == 2)
        view.expanded = true
        view.interaction.showManually(true)
        #expect(view.interaction.isOpen)
        // 非空 reload 不误收：只剩一条时绳子保持垂下。
        store.removeUndoable(store.items[0].id)
        view.reload()
        #expect(view.capacity == 1)
        #expect(view.interaction.isOpen)
        // 取空自动收绳：expanded 状态下历史清空后绳子自己收走。
        store.removeUndoable(store.items[0].id)
        view.reload()
        #expect(view.capacity == 0)
        #expect(!view.interaction.isOpen)
        store.saveNow()
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
    @Test func originalPreferencesRemainCompatible() {
        #expect(ClipboardPresentation(rawValue: "panel") == .native)
        #expect(ClipboardPresentation(rawValue: "dock") == .dock)
        #expect(ClipboardPresentation(rawValue: "clothesline") == .clothesline)
    }
}
