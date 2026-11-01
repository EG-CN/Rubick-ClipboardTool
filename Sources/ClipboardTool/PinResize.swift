import AppKit

/// Geometry in global AppKit coordinates: the opposite corner/edge stays fixed.
enum PinResizeEdge: CaseIterable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    var horizontal: CGFloat {
        switch self { case .left, .topLeft, .bottomLeft: return -1; case .right, .topRight, .bottomRight: return 1; default: return 0 }
    }
    var vertical: CGFloat {
        switch self { case .top, .topLeft, .topRight: return 1; case .bottom, .bottomLeft, .bottomRight: return -1; default: return 0 }
    }
    static func hit(_ point: CGPoint, size: CGSize) -> Self? {
        let margin: CGFloat = 8
        guard CGRect(origin: .zero, size: size).contains(point) else { return nil }
        if point.x <= 16 && point.y <= 16 { return .bottomLeft }
        if point.x >= size.width - 16 && point.y <= 16 { return .bottomRight }
        if point.x <= 16 && point.y >= size.height - 16 { return .topLeft }
        if point.x >= size.width - 16 && point.y >= size.height - 16 { return .topRight }
        let left = point.x <= margin, right = point.x >= size.width - margin
        let bottom = point.y <= margin, top = point.y >= size.height - margin
        if top && left { return .topLeft }; if top && right { return .topRight }
        if bottom && left { return .bottomLeft }; if bottom && right { return .bottomRight }
        if left { return .left }; if right { return .right }
        if top { return .top }; if bottom { return .bottom }
        return nil
    }
    func resized(_ frame: CGRect, delta: CGPoint, zoom: CGFloat) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return frame }
        let w = frame.width, h = frame.height
        let proposed: CGFloat
        if horizontal != 0 && vertical != 0 {
            proposed = ((w + horizontal * delta.x) * w + (h + vertical * delta.y) * h) / (w * w + h * h)
        } else if horizontal != 0 { proposed = 1 + horizontal * delta.x / w }
        else { proposed = 1 + vertical * delta.y / h }
        let minimum = max(0.1 / max(zoom, 0.001), min(1, max(48 / w, 48 / h)))
        let scale = min(max(proposed, minimum), max(minimum, 6 / max(zoom, 0.001)))
        let width = w * scale, height = h * scale
        let x = horizontal < 0 ? frame.maxX - width : (horizontal == 0 ? frame.midX - width / 2 : frame.minX)
        let y = vertical < 0 ? frame.maxY - height : (vertical == 0 ? frame.midY - height / 2 : frame.minY)
        return CGRect(x: x, y: y, width: width, height: height)
    }
    var cursor: NSCursor {
        if horizontal == 0 { return .resizeUpDown }
        if vertical == 0 { return .resizeLeftRight }
        // Public custom cursors also work on the project's macOS 14 baseline.
        return horizontal == vertical ? Self.risingCursor : Self.fallingCursor
    }
    private static let risingCursor = diagonal(rising: true)
    private static let fallingCursor = diagonal(rising: false)
    private static func diagonal(rising: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let p = NSBezierPath()
            if rising {
                p.move(to: CGPoint(x: 5, y: 5)); p.line(to: CGPoint(x: 19, y: 19))
                p.move(to: CGPoint(x: 5, y: 11)); p.line(to: CGPoint(x: 5, y: 5)); p.line(to: CGPoint(x: 11, y: 5))
                p.move(to: CGPoint(x: 13, y: 19)); p.line(to: CGPoint(x: 19, y: 19)); p.line(to: CGPoint(x: 19, y: 13))
            } else {
                p.move(to: CGPoint(x: 5, y: 19)); p.line(to: CGPoint(x: 19, y: 5))
                p.move(to: CGPoint(x: 5, y: 13)); p.line(to: CGPoint(x: 5, y: 19)); p.line(to: CGPoint(x: 11, y: 19))
                p.move(to: CGPoint(x: 13, y: 5)); p.line(to: CGPoint(x: 19, y: 5)); p.line(to: CGPoint(x: 19, y: 11))
            }
            p.lineJoinStyle = .round; p.lineCapStyle = .round
            NSColor.white.setStroke(); p.lineWidth = 4; p.stroke()
            NSColor.black.setStroke(); p.lineWidth = 1.6; p.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 12, y: 12))
    }
}

/// A native sibling above the SwiftUI host owns only the edge hit regions.
/// This avoids SwiftUI gesture recognizers/cursor updates swallowing resize input.
final class PinResizeOverlay: NSView {
    var canResize: (() -> Bool)?
    var currentZoom: (() -> CGFloat)?
    var onResize: ((CGRect, CGFloat) -> Void)?
    private var session: (edge: PinResizeEdge, frame: CGRect, mouse: CGPoint, zoom: CGFloat)?
    private var tracking: NSTrackingArea?
    private var hovering = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard canResize?() == true else { return nil }
        return PinResizeEdge.hit(convert(point, from: superview), size: bounds.size) == nil ? nil : self
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard canResize?() == true else { return }
        let w = bounds.width, h = bounds.height
        addCursorRect(CGRect(x: 0, y: 8, width: 8, height: max(0, h - 16)), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: w - 8, y: 8, width: 8, height: max(0, h - 16)), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: 8, y: 0, width: max(0, w - 16), height: 8), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: 8, y: h - 8, width: max(0, w - 16), height: 8), cursor: .resizeUpDown)
        for (point, edge) in [(CGPoint(x: 0, y: 0), PinResizeEdge.bottomLeft), (CGPoint(x: w - 16, y: 0), .bottomRight), (CGPoint(x: 0, y: h - 16), .topLeft), (CGPoint(x: w - 16, y: h - 16), .topRight)] {
            addCursorRect(CGRect(origin: point, size: CGSize(width: 16, height: 16)), cursor: edge.cursor)
        }
    }
    override func cursorUpdate(with event: NSEvent) {
        guard canResize?() == true else { return }
        if let edge = PinResizeEdge.hit(convert(event.locationInWindow, from: nil), size: bounds.size) { edge.cursor.set() }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; cursorUpdate(with: event) }
    override func mouseMoved(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; if session == nil { NSCursor.arrow.set() } }
    override func mouseDown(with event: NSEvent) {
        guard let window, canResize?() == true, let edge = PinResizeEdge.hit(convert(event.locationInWindow, from: nil), size: bounds.size) else { return }
        session = (edge, window.frame, window.convertPoint(toScreen: event.locationInWindow), currentZoom?() ?? 1)
        edge.cursor.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let session, let window else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        let frame = session.edge.resized(session.frame, delta: CGPoint(x: mouse.x - session.mouse.x, y: mouse.y - session.mouse.y), zoom: session.zoom)
        onResize?(frame, session.zoom * frame.width / session.frame.width)
        session.edge.cursor.set()
    }
    override func mouseUp(with event: NSEvent) { session = nil; cursorUpdate(with: event); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering, canResize?() == true else { return }
        let path = NSBezierPath()
        for (x, y, dx, dy) in [(CGFloat(3), CGFloat(3), CGFloat(1), CGFloat(1)), (bounds.maxX - 3, 3, -1, 1), (3, bounds.maxY - 3, 1, -1), (bounds.maxX - 3, bounds.maxY - 3, -1, -1)] {
            path.move(to: CGPoint(x: x + dx * 11, y: y)); path.line(to: CGPoint(x: x, y: y)); path.line(to: CGPoint(x: x, y: y + dy * 11))
        }
        path.lineJoinStyle = .round; path.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke(); path.lineWidth = 3; path.stroke()
        NSColor(calibratedRed: 0.14, green: 0.52, blue: 0.36, alpha: 1).setStroke(); path.lineWidth = 1.3; path.stroke()
    }
}
