import AppKit
import SwiftUI

// MARK: - Toast 轻提示（非激活、不抢焦点、自动消失）

final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var timer: Timer?

    private init() {}

    /// duration：结果类提示 1.8s；失败/引导类请用 showImportant（5s，长文案读得完）
    func show(_ text: String, duration: TimeInterval = 1.8) {
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
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.panel?.orderOut(nil)
        }
    }

    /// 失败/引导类提示：5 秒，保证长文案读得完
    func showImportant(_ text: String) {
        show(text, duration: 5)
    }

    /// 立即收起（截图/捕获前调用：Toast 是屏幕浮层，会被全屏截图拍进成图）
    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func position(_ p: NSPanel) {
        // 出现在鼠标所在屏（键盘焦点屏在多屏下会提示错位），并钳制在屏内
        guard let screen = screenContaining(NSEvent.mouseLocation) else { return }
        let vis = screen.visibleFrame
        let size = p.frame.size
        let x = max(vis.minX, min(vis.midX - size.width / 2, vis.maxX - size.width))
        let y = max(min(vis.minY + 44, vis.maxY - size.height - 8), vis.minY + 8)
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.78)))
    }
}
