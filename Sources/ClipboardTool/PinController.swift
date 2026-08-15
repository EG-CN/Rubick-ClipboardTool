import AppKit
import SwiftUI

// MARK: - 钉图：桌面置顶贴图（拖拽 / 滚轮缩放 / 双击取消 · Stitch 发光卡片风格）

final class PinController {
    static let shared = PinController()

    private(set) var pins: [NSPanel] = []

    private init() {}

    @discardableResult
    func pin(image: NSImage, at origin: NSPoint? = nil) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let model = PinModel()
        var view = PinImageView(image: image, model: model) { [weak panel] in
            if let panel = panel { PinController.shared.close(panel) }
        }
        let host = ZoomHostingView(rootView: view)

        host.onScroll = { delta in
            let factor = delta > 0 ? 1.05 : 0.95
            model.zoom = min(max(model.zoom * factor, 0.1), 6.0)
        }

        // 缩放后同步调整窗口尺寸（保持左上角位置稳定）
        view.onResize = { size in
            let dy = size.height - panel.frame.height
            panel.setContentSize(size)
            var f = panel.frame
            f.origin.y -= dy
            if f.origin.y < 40 { f.origin.y = 40 }
            panel.setFrame(f, display: true)
        }

        panel.contentView = host
        panel.setFrameOrigin(origin ?? defaultOrigin())
        panel.orderFrontRegardless()
        pins.append(panel)
        return panel
    }

    func close(_ panel: NSPanel) {
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        pins.removeAll { $0 === panel }
        if wasVisible { Toast.shared.show("已取消钉图") }
    }

    func unpinAll() {
        pins.forEach { $0.orderOut(nil) }
        pins.removeAll()
    }

    private func defaultOrigin() -> NSPoint {
        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            let offset = CGFloat(pins.count) * 28
            return NSPoint(x: vis.midX - 200 + offset, y: vis.midY - 140 - offset)
        }
        return NSPoint(x: 200, y: 200)
    }
}

final class PinModel: ObservableObject {
    @Published var zoom: CGFloat = 1.0
}

/// 捕获 scrollWheel 的 NSHostingView 子类
final class ZoomHostingView<Content: View>: NSHostingView<Content> {
    var onScroll: ((CGFloat) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }
}

struct PinImageView: View {
    let image: NSImage
    @ObservedObject var model: PinModel
    let onClose: () -> Void
    var onResize: ((CGSize) -> Void)?

    @State private var fitScale: CGFloat = 1
    @State private var hovering = false
    @State private var ocrMode = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // 奥术紫氛围光
            Circle()
                .fill(RubickTheme.arcanePurple.opacity(hovering ? 0.22 : 0.12))
                .blur(radius: 30)
                .frame(width: 280, height: 280)
                .animation(.easeOut(duration: 0.3), value: hovering)

            VStack(spacing: 0) {
                // 卡片头：状态点 + 片段 + 图钉
                HStack(spacing: 6) {
                    Circle()
                        .fill(RubickTheme.emerald)
                        .frame(width: 8, height: 8)
                        .shadow(color: RubickTheme.emerald.opacity(0.7), radius: 2)
                    Text("片段")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.5)
                        .textCase(.uppercase)
                        .foregroundStyle(RubickTheme.muted(scheme))
                    Spacer()
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(RubickTheme.emerald)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)

                Divider().opacity(0.4)

                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: image.size.width * fitScale * model.zoom,
                               height: image.size.height * fitScale * model.zoom)
                    if ocrMode {
                        OCRPinOverlay { rect in
                            ocrMode = false
                            runPinOCR(rect)
                        } onExit: {
                            ocrMode = false
                        }
                    }
                }
                .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.92 : 0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(hovering ? RubickTheme.primary(scheme) : Color.primary.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: hovering
                    ? RubickTheme.emerald.opacity(0.35)
                    : Color.black.opacity(0.35), radius: hovering ? 10 : 12, y: 5)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onClose() }
            .contextMenu {
                Button("识别文字…") { ocrMode = true }
                Button("复制图片") { writeImageToPasteboard(image) }
                Button("另存为 PNG…") { saveImageAsPng(image) }
                Divider()
                Button("关闭贴图", role: .destructive) { onClose() }
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    VStack(spacing: 4) {
                        hoverAction("doc.on.doc", help: "回响至剪贴板") {
                            writeImageToPasteboard(image)
                            Toast.shared.show("已复制图片")
                        }
                        hoverAction("square.and.arrow.down", help: "存入魔典") {
                            saveImageAsPng(image)
                        }
                        hoverAction("pin.slash", help: "取消钉图") {
                            onClose()
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .padding(6)
                    .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .onAppear {
                fitScale = min(420 / image.size.width, 300 / image.size.height)
                onResize?(contentSize())
            }
            .onChange(of: model.zoom) { _ in
                onResize?(contentSize())
            }
        }
        .padding(24)
        .animation(.easeOut(duration: 0.2), value: hovering)
    }

    /// 钉图 OCR：显示坐标 → 图片点坐标 → 像素坐标 → Vision 识别（功能清单 12.2.1）
    private func runPinOCR(_ displayRect: CGRect?) {
        guard let cg = image.cgImage() else {
            Toast.shared.show("无法读取图片")
            return
        }
        let displayScale = max(fitScale * model.zoom, 0.001)
        let pixelScale = CGFloat(cg.width) / max(image.size.width, 1)
        let rectInPixels: CGRect?
        if let r = displayRect {
            let inPoints = CGRect(x: r.minX / displayScale, y: r.minY / displayScale,
                                  width: r.width / displayScale, height: r.height / displayScale)
            rectInPixels = CGRect(x: inPoints.minX * pixelScale, y: inPoints.minY * pixelScale,
                                  width: inPoints.width * pixelScale, height: inPoints.height * pixelScale)
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

    private func hoverAction(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
                .foregroundStyle(RubickTheme.onSurface(scheme))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func contentSize() -> CGSize {
        let header: CGFloat = 28
        let padding: CGFloat = 48   // 卡片外边距（含氛围光空间）
        let inner: CGFloat = 20     // 图片内边距
        let imgW = image.size.width * fitScale * model.zoom
        let imgH = image.size.height * fitScale * model.zoom
        return CGSize(width: max(imgW, 120) + inner + padding,
                      height: imgH + header + inner + padding)
    }
}

// MARK: - 钉图 OCR 划选覆盖层

struct OCRPinOverlay: View {
    let onDone: (CGRect?) -> Void
    let onExit: () -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
            if let sel = selectionRect {
                Rectangle()
                    .strokeBorder(RubickTheme.emeraldBright, lineWidth: 1.5)
                    .background(Rectangle().fill(RubickTheme.emerald.opacity(0.15)))
                    .frame(width: sel.width, height: sel.height)
                    .position(x: sel.midX, y: sel.midY)
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: onExit) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))
                    .help("退出识别")
                    .padding(6)
                }
                Spacer()
                Text("拖拽划选 · 点一下识别整图")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(.bottom, 6)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    start = start ?? v.startLocation
                    current = v.location
                }
                .onEnded { _ in
                    let sel = selectionRect
                    start = nil
                    current = nil
                    if let s = sel, s.width >= 4, s.height >= 4 {
                        onDone(s)
                    } else {
                        onDone(nil)   // 单击 = 整图识别
                    }
                }
        )
    }

    private var selectionRect: CGRect? {
        guard let a = start, let b = current else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
