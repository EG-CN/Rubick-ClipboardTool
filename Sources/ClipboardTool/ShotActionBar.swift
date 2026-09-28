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
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 232, height: 56),
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
        var p = NSPoint(x: m.x + 14, y: m.y - 64)
        if let screen = screenContaining(m) {
            let vis = screen.visibleFrame
            p.x = min(max(p.x, vis.minX + 8), vis.maxX - 240)
            p.y = min(max(p.y, vis.minY + 8), vis.maxY - 64)
        }
        return p
    }
}

struct ShotActionView: View {
    let image: NSImage
    let onPin: () -> Void
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            Text("已复制")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
            Button("钉图", action: onPin)
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(RubickTheme.primary(scheme))
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 232, height: 56)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RubickTheme.hairline(scheme), lineWidth: 0.5))
    }
}
