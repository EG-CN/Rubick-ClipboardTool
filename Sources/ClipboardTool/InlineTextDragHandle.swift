import AppKit

final class InlineTextDragHandle: NSView {
    var onBegin: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        ("⠿" as NSString).draw(at: CGPoint(x: 7, y: 0), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white])
    }
    override func mouseDown(with event: NSEvent) { NSCursor.closedHand.push(); onBegin?(event.locationInWindow) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow) }
    override func mouseUp(with event: NSEvent) { NSCursor.pop() }
}
