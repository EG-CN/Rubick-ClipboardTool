import AppKit
import SwiftUI

// MARK: - 图片划选 OCR 窗口（历史图片入口，功能清单 12.2.2）
// 打开图片 → 十字拖拽划选区域 → Vision 本地识别 → 结果面板；Esc 取消

final class ImageOCRController {
    static let shared = ImageOCRController()

    private var panel: NSPanel?
    private var keyMonitor: Any?

    private init() {}

    func show(image: NSImage) {
        let view = OCRSelectView(image: image) { [weak self] rectInPoints in
            guard let self = self else { return }
            self.hide()
            self.run(image: image, rectInPoints: rectInPoints)
        }
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                            styleMask: [.titled, .fullSizeContentView, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = "识别文字 — 拖拽划选区域，Esc 取消"
            p.titleVisibility = .visible
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: view)
            panel = p
        } else {
            panel?.title = "识别文字 — 拖拽划选区域，Esc 取消"
            panel?.contentView = NSHostingView(rootView: view)
        }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        panel?.orderOut(nil)
        removeKeyMonitor()
    }

    private func run(image: NSImage, rectInPoints: CGRect?) {
        // NSImage 尺寸为点（pt）；OCRService 使用 CGImage 像素坐标
        guard let cg = image.cgImage() else {
            Toast.shared.show("无法读取图片")
            return
        }
        let pixelScale = CGFloat(cg.width) / max(image.size.width, 1)
        let rectInPixels: CGRect?
        if let r = rectInPoints {
            rectInPixels = CGRect(x: r.minX * pixelScale, y: r.minY * pixelScale,
                                  width: r.width * pixelScale, height: r.height * pixelScale)
        } else {
            rectInPixels = nil
        }
        Toast.shared.show("正在识别文字…")
        OCRService.shared.recognize(image: image, rect: rectInPixels) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let r):
                    guard !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        Toast.shared.show("该区域未识别到文字")
                        return
                    }
                    TextResultPanel.shared.show(kind: .ocr, source: "", result: r.text)
                case .failure(let err):
                    Toast.shared.show("识别失败：\(err.localizedDescription)")
                }
            }
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - 划选视图

struct OCRSelectView: View {
    let image: NSImage
    /// rectInPoints：NSImage 点坐标（原点左上）；nil = 未划选（整图识别）
    let onDone: (CGRect?) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let fit = fitSize(in: geo.size)
            let origin = CGPoint(x: (geo.size.width - fit.width) / 2,
                                 y: (geo.size.height - fit.height) / 2)
            ZStack {
                RubickTheme.darkBackground.opacity(0.4)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: fit.width, height: fit.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
                if let sel = selectionRect(in: geo.size) {
                    Rectangle()
                        .strokeBorder(RubickTheme.emeraldBright, lineWidth: 1.5)
                        .background(Rectangle().fill(RubickTheme.emerald.opacity(0.14)))
                        .frame(width: sel.width, height: sel.height)
                        .position(x: sel.midX, y: sel.midY)
                }
                Text("拖拽划选要识别的区域（点一下 = 识别整图，Esc 取消）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.5)))
                    .position(x: geo.size.width / 2, y: geo.size.height - 18)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragStart = dragStart ?? v.startLocation
                        dragCurrent = v.location
                    }
                    .onEnded { v in
                        dragCurrent = v.location
                        let viewSel = selectionRect(in: geo.size)
                        dragStart = nil
                        dragCurrent = nil
                        guard let vr = viewSel else {
                            onDone(nil)   // 未拖动 → 整图
                            return
                        }
                        // 限制在图片范围内，并换算为图片点坐标
                        let clamped = vr.intersection(CGRect(origin: origin, size: fit))
                        guard clamped.width >= 4, clamped.height >= 4 else {
                            onDone(nil)
                            return
                        }
                        let scale = fit.width / max(image.size.width, 1)
                        onDone(CGRect(x: (clamped.minX - origin.x) / scale,
                                      y: (clamped.minY - origin.y) / scale,
                                      width: clamped.width / scale,
                                      height: clamped.height / scale))
                    }
            )
        }
    }

    private func fitSize(in container: CGSize) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return container }
        let s = min(container.width / image.size.width, container.height / image.size.height)
        return CGSize(width: image.size.width * s, height: image.size.height * s)
    }

    private func selectionRect(in container: CGSize) -> CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
