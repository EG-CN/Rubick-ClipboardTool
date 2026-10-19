import AppKit
import Testing
@testable import ClipboardTool

@Suite(.serialized)
@MainActor
struct InlineFirstClickTests {
    @Test(arguments: [CGPoint(x: 0, y: 0), CGPoint(x: -213, y: 956)])
    func firstClickAcceptsAndSelectsFrontWindow(screenOrigin: CGPoint) throws {
        _ = NSApplication.shared
        let size = CGSize(width: 600, height: 400)
        let front = CGRect(x: 60, y: 50, width: 300, height: 250)
        let back = CGRect(x: 10, y: 10, width: 500, height: 350)
        let canvas = InlineScreenshotCanvas(image: NSImage(size: size), union: CGRect(origin: screenOrigin, size: size), windows: [front, back].map { $0.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y) })
        let window = NSWindow(contentRect: CGRect(origin: screenOrigin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        #expect(!window.isKeyWindow)
        #expect(canvas.acceptsFirstMouse(for: nil))
        let point = canvas.convert(CGPoint(x: 100, y: 100), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseDown { canvas.mouseDown(with: event) }
            else { canvas.mouseUp(with: event) }
        }
        #expect(canvas.document.state.selection == front)
        canvas.updateTrackingAreas()
        #expect(canvas.trackingAreas.contains { $0.options.contains(.activeAlways) })
    }
}
