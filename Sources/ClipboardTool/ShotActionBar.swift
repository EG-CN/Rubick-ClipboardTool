import AppKit
import SwiftUI

// MARK: - 截图后的操作条（「已复制并存入历史」+ 一键钉图，功能清单 3.5）

final class ShotActionBar {
    static let shared = ShotActionBar()

    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var currentImage: NSImage?

    private init() {}

    func show(image: NSImage) {
        currentImage = image
        let view = ShotActionView(
            image: image,
            onPin: { [weak self] in
                guard let self = self, let img = self.currentImage else { return }
                PinController.shared.pin(image: img, at: NSEvent.mouseLocation)
                Toast.shared.show("已钉在桌面 · 双击贴图取消")
                self.hide()
            },
            onClose: { [weak self] in self?.hide() }
        )
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 86),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.hidesOnDeactivate = false
            panel = p
        }
        panel?.contentView = NSHostingView(rootView: view)
        panel?.setFrameOrigin(positionNearMouse())
        panel?.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        hideTimer?.invalidate()
        hideTimer = nil
        currentImage = nil
    }

    private func positionNearMouse() -> NSPoint {
        let m = NSEvent.mouseLocation
        var p = NSPoint(x: m.x + 14, y: m.y - 86)
        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            p.x = min(max(p.x, vis.minX + 8), vis.maxX - 308)
            p.y = min(max(p.y, vis.minY + 8), vis.maxY - 94)
        }
        return p
    }
}

struct ShotActionView: View {
    let image: NSImage
    let onPin: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 7) {
                Text("已复制并存入历史")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 6) {
                    Button(action: onPin) {
                        Label("钉图", systemImage: "pin.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(RubickTheme.emerald)
                    Button("关闭", action: onClose)
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 300, height: 86)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.black.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(RubickTheme.emerald.opacity(0.35), lineWidth: 0.5))
        .shadow(color: RubickTheme.emerald.opacity(0.2), radius: 8)
    }
}
