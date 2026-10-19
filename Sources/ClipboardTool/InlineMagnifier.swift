import AppKit

struct InlineMagnifier: Equatable {
    let id = UUID()
    var rect: CGRect
    var color: Int
    var zoom: CGFloat = 2

    func draw(image: NSImage, selection: CGRect, overlays: [InlineMark] = []) {
        guard rect.width > 0, rect.height > 0 else { return }
        let allowed = selection.intersection(CGRect(origin: .zero, size: image.size))
        guard !allowed.isEmpty else { return }
        let size = CGSize(width: min(rect.width / zoom, allowed.width), height: min(rect.height / zoom, allowed.height))
        let source = CGRect(x: min(max(rect.midX-size.width/2, allowed.minX), allowed.maxX-size.width),
                            y: min(max(rect.midY-size.height/2, allowed.minY), allowed.maxY-size.height),
                            width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: rect).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        if let context = NSGraphicsContext.current?.cgContext {
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width/source.width, y: rect.height/source.height)
            context.translateBy(x: -source.minX, y: -source.minY)
            image.draw(in: CGRect(origin: .zero, size: image.size))
            InlineScreenshotRenderer.drawMarks(overlays, image: image, selection: selection)
        }
        NSGraphicsContext.restoreGraphicsState()
        AnnotationController.palette[color].setStroke()
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3; border.stroke()
    }
}
