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
        // 边框样式（用户可选，默认无边框）：0 无边框（中性细边，非彩色）·1 白 ·2 黑 ·3 跟随标注色
        switch UserDefaults.standard.object(forKey: "magnifier.ring") as? Int ?? 0 {
        case 1:
            NSColor.white.setStroke()
            let border = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)); border.lineWidth = 2.5; border.stroke()
        case 2:
            NSColor.black.setStroke()
            let border = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)); border.lineWidth = 2.5; border.stroke()
        case 3:
            AnnotationController.palette[color].setStroke()
            let border = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)); border.lineWidth = 3; border.stroke()
        default:
            // 无彩色边框：中性深+白双细线，浅色/深色背景都能读出边缘
            NSColor.black.withAlphaComponent(0.3).setStroke()
            let outer = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)); outer.lineWidth = 1.5; outer.stroke()
            NSColor.white.withAlphaComponent(0.55).setStroke()
            let inner = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)); inner.lineWidth = 1; inner.stroke()
        }
    }
}
