import AppKit
import SwiftUI
import Testing
@testable import ClipboardTool

@Suite(.serialized)
@MainActor
struct PinResizeTests {
    @Test func allEdgesKeepAspectAndOppositeAnchor() {
        let original = CGRect(x: -900, y: 250, width: 400, height: 240)
        for edge in PinResizeEdge.allCases {
            let delta = CGPoint(x: edge.horizontal * 80, y: edge.vertical * 48)
            let frame = edge.resized(original, delta: delta, zoom: 1)
            #expect(abs(frame.width / frame.height - original.width / original.height) < 0.001)
            #expect(frame.width > original.width)
            if edge.horizontal < 0 { #expect(frame.maxX == original.maxX) }
            if edge.horizontal > 0 { #expect(frame.minX == original.minX) }
            if edge.vertical < 0 { #expect(frame.maxY == original.maxY) }
            if edge.vertical > 0 { #expect(frame.minY == original.minY) }
            if edge.horizontal == 0 { #expect(frame.midX == original.midX) }
            if edge.vertical == 0 { #expect(frame.midY == original.midY) }
        }
    }
    @Test func extremeDragCannotInvertOrExplodeSize() {
        let original = CGRect(x: 0, y: 0, width: 400, height: 240)
        let small = PinResizeEdge.right.resized(original, delta: CGPoint(x: -4000, y: 0), zoom: 1)
        #expect(small.width >= 48 && small.height >= 48)
        let large = PinResizeEdge.topRight.resized(original, delta: CGPoint(x: 40000, y: 40000), zoom: 1)
        #expect(large.width <= original.width * 6)
        #expect(large.height <= original.height * 6)
    }
    @Test func edgeDragDeliversResizeWithoutMovingWholeWindow() throws {
        _ = NSApplication.shared
        let original = CGRect(x: 100, y: 100, width: 400, height: 240)
        let panel = NSPanel(contentRect: original, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let host = PinResizeOverlay(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
        host.frame = CGRect(origin: .zero, size: original.size)
        panel.contentView = host
        host.canResize = { true }; host.currentZoom = { 1 }
        var resized: CGRect?, zoom: CGFloat?
        host.onResize = { frame, scale in resized = frame; zoom = scale }
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 399, y: 120), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: 479, y: 120), modifierFlags: [], timestamp: 0.1, windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        host.mouseDown(with: down); host.mouseDragged(with: drag)
        let frame = try #require(resized)
        #expect(frame.minX == original.minX)
        #expect(abs(frame.width - 480) < 0.01)
        #expect(abs(frame.height - 288) < 0.01)
        #expect(zoom == 1.2)
    }
    @Test func realPinnedWindowKeepsEdgeResizeAfterSwiftUILayout() throws {
        _ = NSApplication.shared
        let image = NSImage(size: CGSize(width: 600, height: 360), flipped: false) { rect in
            NSColor.systemGreen.setFill(); rect.fill(); return true
        }
        let panel = PinController.shared.pin(image: image)
        defer { PinController.shared.close(panel); Toast.shared.hide() }
        panel.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let surface = try #require(panel.contentView)
        let overlay = try #require(surface.subviews.compactMap { $0 as? PinResizeOverlay }.first)
        let old = panel.frame
        let edge = CGPoint(x: old.width - 2, y: old.height / 2)
        #expect(surface.hitTest(edge) === overlay)
        #expect(surface.hitTest(CGPoint(x: old.width / 2, y: old.height / 2)) !== overlay)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: edge, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: edge.x + 60, y: edge.y), modifierFlags: [], timestamp: 0.1, windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        overlay.mouseDown(with: down); overlay.mouseDragged(with: drag)
        let immediate = panel.frame
        #expect(abs(immediate.width - old.width - 60) < 0.01)
        #expect(abs(immediate.height - immediate.width * old.height / old.width) <= 1.0, "old=\(old), resized=\(immediate)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(abs(panel.frame.width - immediate.width) < 0.01)
        #expect(abs(panel.frame.minX - old.minX) < 0.01)
        #expect(abs(overlay.frame.width - panel.frame.width) < 0.01)
    }
    @Test func centerPassesThroughAndEdgesReachNativeOverlay() {
        _ = NSApplication.shared
        let size = CGSize(width: 400, height: 240)
        #expect(PinResizeEdge.hit(CGPoint(x: 200, y: 120), size: size) == nil)
        #expect(PinResizeEdge.hit(CGPoint(x: 2, y: 120), size: size) == .left)
        #expect(PinResizeEdge.hit(CGPoint(x: 399, y: 239), size: size) == .topRight)
        let host = PinResizeOverlay(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
        host.frame = CGRect(origin: .zero, size: size); host.canResize = { true }
        #expect(host.hitTest(CGPoint(x: 2, y: 120)) === host)
        let surface = NSView(frame: host.frame)
        let content = NSHostingView(rootView: Color.red.frame(width: 400, height: 240))
        content.frame = surface.bounds; surface.addSubview(content)
        surface.addSubview(host)
        #expect(surface.hitTest(CGPoint(x: 2, y: 120)) === host)
        #expect(surface.hitTest(CGPoint(x: 200, y: 120)) !== host)
        host.canResize = { false }
        // OCR mode is checked by the same gate used for routing edge events.
        #expect(host.hitTest(CGPoint(x: 2, y: 120)) == nil)
        #expect(host.hitTest(CGPoint(x: 200, y: 120)) == nil)
    }
}
