import AppKit
import Testing
@testable import ClipboardTool

@Suite(.serialized)
@MainActor
struct InlineMagnifierTests {
    private func image(background: NSColor, patch: CGRect, color: NSColor) throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        background.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: 300, height: 200)).fill()
        color.setFill(); NSBezierPath(rect: patch).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: CGSize(width: 300, height: 200))
        image.addRepresentation(bitmap)
        return image
    }

    private func pixel(_ image: NSImage, x: Int, y: Int) throws -> NSColor {
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        return try #require(bitmap.colorAt(x: x, y: bitmap.pixelsHigh - y - 1)?.usingColorSpace(.deviceRGB))
    }

    @Test func exportActuallyDoublesTheSourcePatch() throws {
        let source = try image(background: .blue, patch: CGRect(x: 140, y: 90, width: 20, height: 20), color: .red)
        let lens = InlineMagnifier(rect: CGRect(x: 100, y: 50, width: 100, height: 100), color: 0)
        let state = InlineSnapshot(selection: CGRect(origin: .zero, size: source.size), marks: [.magnifier(lens)])
        let before = try pixel(source, x: 132, y: 100)
        let rendered = try #require(InlineScreenshotRenderer.render(image: source, state: state))
        let after = try pixel(rendered, x: 132, y: 100)
        #expect(before.blueComponent > 0.9)
        #expect(after.redComponent > 0.9)
        #expect(after.blueComponent < 0.1)
        // Farther out, inside the same circle, the source remains blue.
        let outsidePatch = try pixel(rendered, x: 120, y: 100)
        #expect(outsidePatch.blueComponent > 0.9)
    }

    @Test func movingMagnifierKeepsIdentityAndUndoRedoRestoresSnapshots() {
        let document = InlineScreenshotDocument(size: CGSize(width: 300, height: 200))
        document.setSelection(CGRect(x: 0, y: 0, width: 300, height: 200))
        let empty = document.state
        let lens = InlineMagnifier(rect: CGRect(x: 100, y: 50, width: 100, height: 100), color: 1)
        document.state.marks.append(.magnifier(lens))
        document.checkpoint(empty)
        let created = document.state
        document.moveMark(id: lens.id, from: created, delta: CGPoint(x: 20, y: -10))
        document.checkpoint(created)
        guard case .magnifier(let moved) = document.state.marks[0] else { Issue.record("missing magnifier"); return }
        #expect(moved.id == lens.id)
        #expect(moved.rect == CGRect(x: 120, y: 40, width: 100, height: 100))
        let movedState = document.state
        document.undo(); #expect(document.state == created)
        document.undo(); #expect(document.state == empty)
        document.redo(); #expect(document.state == created)
        document.redo(); #expect(document.state == movedState)
    }

    @Test func magnificationKeepsLaterRedactionOverTheSourcePatch() throws {
        let source = try image(background: .blue, patch: CGRect(x: 140, y: 90, width: 20, height: 20), color: .red)
        let lens = InlineMagnifier(rect: CGRect(x: 100, y: 50, width: 100, height: 100), color: 0)
        var redaction = Annotation(tool: .highlight)
        redaction.rect = CGRect(x: 140.0 / 300, y: 90.0 / 200, width: 20.0 / 300, height: 20.0 / 200)
        redaction.displaySize = source.size
        redaction.colorIndex = 4
        redaction.fillOpacity = 1
        let state = InlineSnapshot(selection: CGRect(origin: .zero, size: source.size),
                                   marks: [.magnifier(lens), .drawing(redaction)])
        let rendered = try #require(InlineScreenshotRenderer.render(image: source, state: state))
        // This point only lies inside the enlarged patch, outside the redaction's
        // original bounds. It must not reveal the red pixels hidden by that mask.
        let masked = try pixel(rendered, x: 132, y: 100)
        #expect(masked.redComponent < 0.1)
        #expect(masked.greenComponent < 0.1)
        #expect(masked.blueComponent < 0.1)
    }

    @Test(arguments: [true, false])
    func sourceSamplingStaysInsideSelectionNearEitherEdge(left: Bool) throws {
        let selection = CGRect(x: 100, y: 0, width: 150, height: 200)
        let source = try image(background: .red, patch: selection, color: .blue)
        // The lens center is beyond the crop. Without source clamping, its visible
        // part would pull red pixels from outside the user's selected screenshot.
        let lens = InlineMagnifier(rect: CGRect(x: left ? 30 : 220, y: 50, width: 100, height: 100), color: 0)
        let rendered = try #require(InlineScreenshotRenderer.render(image: source,
            state: InlineSnapshot(selection: selection, marks: [.magnifier(lens)])))
        let color = try pixel(rendered, x: left ? 5 : 145, y: 100)
        #expect(color.blueComponent > 0.9)
        #expect(color.redComponent < 0.1)
    }
}
