import AppKit
import SwiftUI

// MARK: - Toast 轻提示（非激活、不抢焦点、自动消失）

final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var timer: Timer?

    private init() {}

    func show(_ text: String) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 34),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            panel = p
        }
        guard let p = panel else { return }
        let host = NSHostingView(rootView: ToastView(text: text))
        let size = host.fittingSize
        p.setContentSize(size)
        p.contentView = host
        position(p)
        p.orderFrontRegardless()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            self?.panel?.orderOut(nil)
        }
    }

    private func position(_ p: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: vis.midX - size.width / 2, y: vis.minY + 44))
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.78)))
    }
}
