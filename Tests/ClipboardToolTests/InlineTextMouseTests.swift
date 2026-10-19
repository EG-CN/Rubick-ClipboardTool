import AppKit
import Testing
@testable import ClipboardTool

@Suite(.serialized)
@MainActor
struct InlineTextMouseTests {
    private func fixture(numbered: Bool) -> (NSWindow, InlineScreenshotCanvas, UUID, CGPoint) {
        _ = NSApplication.shared
        let size = CGSize(width: 600, height: 400)
        let document = InlineScreenshotDocument(size: size)
        document.setSelection(CGRect(x: 20, y: 20, width: 560, height: 360))
        let id = document.appendNote(at: CGPoint(x: 180, y: 220), numbered: numbered, fontSize: 18, color: 1)
        document.updateNote(id: id, text: "原有说明文字")
        let canvas = InlineScreenshotCanvas(image: NSImage(size: size), union: CGRect(origin: .zero, size: size),
                                            windows: [], document: document)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        guard case .note(let note) = document.state.marks[0] else { fatalError("fixture note missing") }
        let body = InlineScreenshotRenderer.layout(note, selection: document.state.selection!).body
        return (window, canvas, id, CGPoint(x: body.midX, y: body.midY))
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, canvas: InlineScreenshotCanvas) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                                       timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func click(_ point: CGPoint, canvas: InlineScreenshotCanvas) throws {
        canvas.mouseDown(with: try event(.leftMouseDown, at: point, canvas: canvas))
        canvas.mouseUp(with: try event(.leftMouseUp, at: point, canvas: canvas))
    }

    @Test(arguments: [false, true])
    func singleClickBodyStartsEditingAndBlankClickCommits(numbered: Bool) throws {
        let (window, canvas, id, bodyPoint) = fixture(numbered: numbered)
        defer { window.close() }
        try click(bodyPoint, canvas: canvas)
        let scroll = try #require(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        let editor = try #require(scroll.documentView as? NSTextView)
        #expect(editor.string == "原有说明文字")
        #expect(!scroll.drawsBackground)
        #expect(!editor.drawsBackground)
        editor.string = "修改后的正文\n第二行"
        try click(CGPoint(x: 500, y: 80), canvas: canvas)
        #expect(canvas.subviews.compactMap { $0 as? NSScrollView }.isEmpty)
        let mark = try #require(canvas.document.state.marks.first { $0.id == id })
        guard case .note(let note) = mark else { Issue.record("missing note"); return }
        #expect(note.text == "修改后的正文\n第二行")
        #expect(canvas.document.state.marks.count == 1)
    }

    @Test(arguments: [false, true])
    func draggingBodyMovesTheWholeNoteWithoutOpeningEditor(numbered: Bool) throws {
        let (window, canvas, id, bodyPoint) = fixture(numbered: numbered)
        defer { window.close() }
        let before = canvas.document.state
        let destination = CGPoint(x: bodyPoint.x + 30, y: bodyPoint.y + 20)
        canvas.mouseDown(with: try event(.leftMouseDown, at: bodyPoint, canvas: canvas))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: destination, canvas: canvas))
        canvas.mouseUp(with: try event(.leftMouseUp, at: destination, canvas: canvas))
        #expect(canvas.subviews.compactMap { $0 as? NSScrollView }.isEmpty)
        let mark = try #require(canvas.document.state.marks.first { $0.id == id })
        guard case .note(let note) = mark else { Issue.record("missing note"); return }
        #expect(note.anchor == CGPoint(x: 210, y: 240))
        #expect(note.text == "原有说明文字")
        canvas.document.undo()
        #expect(canvas.document.state == before)
    }

    @Test func editorDragHandleMovesTextWhileKeepingInputOpen() throws {
        let (window, canvas, id, bodyPoint) = fixture(numbered: false)
        defer { window.close() }
        let before = canvas.document.state
        try click(bodyPoint, canvas: canvas)
        let handle = try #require(canvas.subviews.compactMap { $0 as? InlineTextDragHandle }.first)
        let scroll = try #require(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        let editor = try #require(scroll.documentView as? NSTextView)
        editor.string = "拖动后保留正文"
        let start = CGPoint(x: handle.frame.midX, y: handle.frame.midY)
        let destination = CGPoint(x: start.x + 30, y: start.y + 20)
        handle.mouseDown(with: try event(.leftMouseDown, at: start, canvas: canvas))
        handle.mouseDragged(with: try event(.leftMouseDragged, at: destination, canvas: canvas))
        handle.mouseUp(with: try event(.leftMouseUp, at: destination, canvas: canvas))
        #expect(scroll.superview === canvas)
        let mark = try #require(canvas.document.state.marks.first { $0.id == id })
        guard case .note(let moved) = mark else { Issue.record("missing note"); return }
        #expect(moved.anchor == CGPoint(x: 210, y: 240))
        try click(CGPoint(x: 500, y: 80), canvas: canvas)
        #expect(canvas.subviews.compactMap { $0 as? NSScrollView }.isEmpty)
        guard case .note(let committed) = canvas.document.state.marks[0] else { Issue.record("missing note"); return }
        #expect(committed.text == "拖动后保留正文")
        #expect(committed.anchor == moved.anchor)
        canvas.document.undo()
        #expect(canvas.document.state == before)
    }
}
