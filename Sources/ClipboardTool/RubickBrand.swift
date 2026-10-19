import AppKit
import SwiftUI

/// One line emblem shared by the menu bar, settings and packaged app icon.
enum RubickBrand {
    static func image(size: CGFloat, appIcon: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.scale(by: size / 100)
            transform.concat()
            if appIcon {
                NSColor(srgbRed: 0.10, green: 0.38, blue: 0.27, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 90, height: 90), xRadius: 21, yRadius: 21).fill()
            }
            // Hood peak, turned shoulders and a sharp lower hem; no enclosing shield.
            let hood = NSBezierPath()
            hood.move(to: NSPoint(x: 50, y: 85))
            hood.curve(to: NSPoint(x: 23, y: 51), controlPoint1: NSPoint(x: 39, y: 78), controlPoint2: NSPoint(x: 25, y: 62))
            hood.line(to: NSPoint(x: 18, y: 25))
            hood.line(to: NSPoint(x: 34, y: 30))
            hood.line(to: NSPoint(x: 50, y: 16))
            hood.line(to: NSPoint(x: 66, y: 30))
            hood.line(to: NSPoint(x: 82, y: 25))
            hood.line(to: NSPoint(x: 77, y: 51))
            hood.curve(to: NSPoint(x: 50, y: 85), controlPoint1: NSPoint(x: 75, y: 62), controlPoint2: NSPoint(x: 61, y: 78))
            hood.lineWidth = 5
            hood.lineJoinStyle = .round
            hood.lineCapStyle = .round
            (appIcon ? NSColor(srgbRed: 0.80, green: 0.97, blue: 0.81, alpha: 1) : NSColor.black).setStroke()
            hood.stroke()
            let face = NSBezierPath()
            face.move(to: NSPoint(x: 33, y: 53))
            face.line(to: NSPoint(x: 50, y: 64))
            face.line(to: NSPoint(x: 67, y: 53))
            face.move(to: NSPoint(x: 35, y: 44))
            face.line(to: NSPoint(x: 42, y: 41))
            face.move(to: NSPoint(x: 58, y: 41))
            face.line(to: NSPoint(x: 65, y: 44))
            face.lineWidth = 4.5
            face.lineCapStyle = .round
            face.lineJoinStyle = .round
            face.stroke()
            return true
        }
        image.isTemplate = !appIcon
        image.accessibilityDescription = "拉比克兜帽"
        return image
    }
}

struct RubickEmblem: View {
    var size: CGFloat = 28
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(nsImage: RubickBrand.image(size: max(size * 2, 64)))
            .resizable().frame(width: size, height: size)
            .foregroundStyle(RubickTheme.primary(scheme))
            .accessibilityLabel("拉比克")
    }
}

/// A real behind-window material, so the desktop remains visible through settings.
struct SettingsBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
