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

                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: image.size.width * fitScale * model.zoom,
                           height: image.size.height * fitScale * model.zoom)
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
