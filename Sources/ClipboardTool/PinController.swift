import AppKit
import SwiftUI

// MARK: - 钉图：桌面置顶贴图（拖拽 / 滚轮缩放 / 双击取消 · Stitch 发光卡片风格）

final class PinController {
    static let shared = PinController()

    private(set) var pins: [NSPanel] = []
    /// 贴图窗 → 模型（⌥半透明 / ⌘C 复制按光标所在贴图生效）
    private var modelsByPanel: [NSPanel: PinModel] = [:]
    private var interactionMonitors: [Any] = []

    private init() {}

    /// ⌥ 按住=光标下贴图临时半透明；⌘C=复制光标下贴图内容。
    /// 用全局监听：贴图是非激活面板、从不持有键盘焦点。
    private func ensureInteractionMonitors() {
        guard interactionMonitors.isEmpty else { return }
        interactionMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .mouseMoved]) { [weak self] _ in
            self?.updateTranslucency()
        })
        interactionMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "c" else { return }
            let m = NSEvent.mouseLocation
            guard let entry = self?.modelsByPanel.first(where: { $0.key.frame.contains(m) }) else { return }
            if let img = entry.value.currentImage {
                copyImageToClipboardSuppressingMonitor(img)
                Toast.shared.show("已复制贴图内容")
            }
        })
    }

    private func updateTranslucency() {
        let m = NSEvent.mouseLocation
        let opt = NSEvent.modifierFlags.contains(.option)
        for (panel, model) in modelsByPanel where panel.isVisible {
            model.translucent = opt && panel.frame.contains(m)
        }
    }

    @discardableResult
    func pin(image: NSImage, at origin: NSPoint? = nil) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 拖动由 SwiftUI DragGesture 驱动（见 PinImageView）：内容手势让 AppKit 的
        // movableByWindowBackground 对整窗判定不可拖（历史形同虚设），关掉避免双重驱动
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let model = PinModel()
        // 尺寸同步回调必须挂在 model（class，引用共享）上：直接给 view（struct）赋值
        // 会在 ZoomHostingView 拷贝后失效，窗口将永远停在初始 460×340（透明死区吞点击）
        model.onResize = { [weak panel] size in
            guard let panel = panel else { return }
            let old = panel.frame
            let dy = size.height - old.height
            var f = CGRect(origin: old.origin, size: size)
            f.origin.y -= dy
            // 以光标为锚点缩放（PixPin 式）：光标下的内容点保持静止
            let m = NSEvent.mouseLocation
            if old.width > 0, old.height > 0, old.insetBy(dx: -2, dy: -2).contains(m) {
                let fx = (m.x - old.minX) / old.width
                let fy = (m.y - old.minY) / old.height
                f.origin.x = m.x - fx * f.width
                f.origin.y = m.y - fy * f.height
            }
            // 大尺寸贴图（默认 70% 原图）初始不出屏：钳制在所在屏可见区域内
            if let screen = screenContaining(NSPoint(x: f.midX, y: f.midY)) ?? NSScreen.main {
                let vis = screen.visibleFrame
                f.origin.x = min(max(f.origin.x, vis.minX), max(vis.minX, vis.maxX - f.width))
                f.origin.y = min(max(f.origin.y, vis.minY), max(vis.minY, vis.maxY - f.height))
            }
            panel.setFrame(f, display: true)
        }
        // 拖动与双击由 ZoomHostingView 的 AppKit 层处理（performDrag 原生拖拽 + clickCount）
        var view = PinImageView(image: image, model: model) { [weak panel] in
            if let panel = panel { PinController.shared.close(panel) }
        }
        let host = ZoomHostingView(rootView: view)

        host.onScroll = { delta, flags in
            if flags.contains(.option) {
                // ⌥滚轮：调节基准不透明度（Snipaste 式贴图透明调节），与缩放同向
                let factor = delta > 0 ? 0.08 : -0.08
                model.baseOpacity = min(max(model.baseOpacity + factor, 0.25), 1.0)
            } else {
                let factor = delta > 0 ? 1.05 : 0.95
                model.zoom = min(max(model.zoom * factor, 0.1), 6.0)
            }
        }
        host.onMagnify = { delta in
            // 触控板捏合缩放（原仅支持滚轮）
            model.zoom = min(max(model.zoom * (1 + delta), 0.1), 6.0)
        }
        host.onDoubleClick = { [weak panel] in
            if let panel { PinController.shared.close(panel) }
        }
        host.shouldDrag = { [weak model] point, size in
            guard let model else { return true }
            if model.ocrMode { return false }   // OCR 划选优先于拖拽
            // 右上角悬停工具条区域：交给 SwiftUI 点击
            return !(point.x > size.width - 40 && point.y < 96)
        }
        model.currentImage = image
        modelsByPanel[panel] = model
        ensureInteractionMonitors()

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
        modelsByPanel[panel] = nil
        if wasVisible { Toast.shared.show("已取消钉图") }
        teardownMonitorsIfIdle()
    }

    func unpinAll() {
        pins.forEach { $0.orderOut(nil) }
        pins.removeAll()
        modelsByPanel.removeAll()
        teardownMonitorsIfIdle()
    }

    private func teardownMonitorsIfIdle() {
        guard pins.isEmpty else { return }
        interactionMonitors.forEach { NSEvent.removeMonitor($0) }
        interactionMonitors.removeAll()
    }

    private func defaultOrigin() -> NSPoint {
        // 贴图落在鼠标所在屏（多屏下 NSScreen.main 会弹到焦点屏）
        if let screen = screenContaining(NSEvent.mouseLocation) ?? NSScreen.main {
            let vis = screen.visibleFrame
            let offset = CGFloat(pins.count) * 28
            return NSPoint(x: vis.midX - 200 + offset, y: vis.midY - 140 - offset)
        }
        return NSPoint(x: 200, y: 200)
    }
}

final class PinModel: ObservableObject {
    @Published var zoom: CGFloat = 1.0
    /// 当前生效透明度（由 baseOpacity 与临时半透明状态推导）
    @Published var opacity: CGFloat = 1.0
    /// 用户设定基准（⌥滚轮调节，0.25–1.0）
    var baseOpacity: CGFloat = 1.0 { didSet { syncOpacity() } }
    /// 按住 ⌥ 临时半透明，对照下层内容（Snipaste 式）
    var translucent = false { didSet { syncOpacity() } }
    private func syncOpacity() {
        opacity = translucent ? max(baseOpacity * 0.35, 0.15) : baseOpacity
    }
    /// 当前生效图（标注原位替换后变化；nil = 初始图）
    @Published var image: NSImage?
    /// 钉入的图（含初始图；⌘C 复制贴图内容用）
    var currentImage: NSImage?
    /// OCR 划选模式（拖拽排除区）
    @Published var ocrMode = false
    /// 图片替换计数（驱动尺寸重排）
    @Published var imageToken: Int = 0
    /// 内容尺寸变化 → 调整贴图窗口（挂在 class 上保证闭包可达；struct 上赋值会被拷贝吞掉）
    var onResize: ((CGSize) -> Void)?
}

/// 贴图交互宿主：滚轮/捏合缩放、原生拖拽、双击关闭。
/// 指针交互必须留在 AppKit 层——SwiftUI DragGesture(0) 会生成手势识别器，
/// 在 scrollWheel 之前吞掉滚轮事件（缩放失灵根因），且其窗口内坐标位移
/// 与窗口移动互相反馈导致拖拽迟滞。
final class ZoomHostingView<Content: View>: NSHostingView<Content> {
    var onScroll: ((CGFloat, NSEvent.ModifierFlags) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?
    /// 返回 false 的区域不启动拖拽（悬停按钮区/OCR 划选），事件交还 SwiftUI 手势链
    var shouldDrag: ((CGPoint, CGSize) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        // 惯性阶段连发会让一次轻扫缩放过冲，只响应手势本体的滚动
        if event.momentumPhase != [] { return }
        onScroll?(event.scrollingDeltaY, event.modifierFlags)
    }
    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if shouldDrag?(p, bounds.size) ?? true {
            // 原生拖拽循环（与 movableByWindowBackground 同机制）：硬件级跟手
            window?.performDrag(with: event)
        } else {
            super.mouseDown(with: event)   // SwiftUI 手势接管（悬停按钮 / OCR 划选）
        }
    }
}

struct PinImageView: View {
    let image: NSImage
    @ObservedObject var model: PinModel
    let onClose: () -> Void

    @State private var fitScale: CGFloat = 1
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    /// 钉图默认缩放 = 截图原始尺寸的比例（设置→截图 可调，默认 70%）
    private static var defaultScale: CGFloat {
        let s = UserDefaults.standard.object(forKey: "pin.defaultScale") as? Double ?? 0.7
        return CGFloat(min(max(s, 0.25), 2.0))
    }

    /// 当前生效图（标注完成后被原位替换）
    private var displayImage: NSImage { model.image ?? image }

    var body: some View {
        // Snipaste 式裸图贴图：贴图 = 图片本身 + 发丝线 + 投影；无标题栏、无氛围光、无内衬底
        ZStack {
            Image(nsImage: displayImage)
                .resizable()
                .interpolation(.high)
                .frame(width: displayImage.size.width * fitScale * model.zoom,
                       height: displayImage.size.height * fitScale * model.zoom)
                .opacity(model.opacity)
            if model.ocrMode {
                OCRPinOverlay { rect in
                    model.ocrMode = false
                    runPinOCR(rect)
                } onExit: {
                    model.ocrMode = false
                }
            }
        }
        .overlay(
            Rectangle().strokeBorder(hovering ? RubickTheme.primary(scheme) : Color.primary.opacity(0.25),
                                     lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            // ✦ 徽记：贴图上唯一的品牌符号（奥术纸墨语言）
            ArcaneSparkle(size: 10)
                .padding(4)
                .allowsHitTesting(false)
                .opacity(0.9)
        }
        .shadow(color: Color.black.opacity(0.35), radius: 7, y: 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("标注…") { annotateInPlace() }
            Button("识别文字…") { model.ocrMode = true }
            Button("复制图片") { writeImageToPasteboard(displayImage) }
            Button("另存为 PNG…") { saveImageAsPng(displayImage) }
            Divider()
            Button("关闭贴图", role: .destructive) { onClose() }
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                VStack(spacing: 4) {
                    hoverAction("doc.on.doc", help: "回响至剪贴板") {
                        writeImageToPasteboard(displayImage)
                        Toast.shared.show("已复制图片")
                    }
                    hoverAction("square.and.arrow.down", help: "存入魔典") {
                        saveImageAsPng(displayImage)
                    }
                    hoverAction("pin.slash", help: "取消钉图") {
                        onClose()
                    }
                }
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 7).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(5)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .onAppear {
            fitScale = Self.defaultScale
            model.onResize?(contentSize())
        }
        .onChange(of: model.imageToken) { _ in
            // 标注原位替换图片后：重置缩放并按新尺寸重排
            fitScale = Self.defaultScale
            model.zoom = 1.0
            model.onResize?(contentSize())
        }
        .onChange(of: model.zoom) { _ in
            model.onResize?(contentSize())
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// 贴图原位标注：打开标注编辑器，确认后用产物替换贴图内容
    private func annotateInPlace() {
        AnnotationController.shared.show(image: displayImage) { result in
            model.image = result
            model.currentImage = result
            model.imageToken += 1
            Toast.shared.show("贴图已更新为标注结果")
        }
    }

    /// 钉图 OCR：显示坐标 → 图片点坐标 → 像素坐标 → Vision 识别（功能清单 12.2.1）
    private func runPinOCR(_ displayRect: CGRect?) {
        guard let cg = displayImage.cgImage() else {
            Toast.shared.show("无法读取图片")
            return
        }
        let displayScale = max(fitScale * model.zoom, 0.001)
        let pixelScale = CGFloat(cg.width) / max(displayImage.size.width, 1)
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
        OCRService.shared.recognize(image: displayImage, rect: rectInPixels) { result in
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
        // 非 key 面板里 SwiftUI Button 不触发（ShellDock 同款教训），点击判定走 DragGesture(0)
        Image(systemName: symbol)
            .font(.system(size: 11))
            .frame(width: 24, height: 24)
            .foregroundStyle(RubickTheme.onSurface(scheme))
            .background(RoundedRectangle(cornerRadius: 5).fill(.ultraThinMaterial))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                if hypot(v.translation.width, v.translation.height) < 6 { action() }
            })
            .help(help)
    }

    private func contentSize() -> CGSize {
        // 裸图模式：窗口尺寸 = 图片尺寸 + 描边余量（无标题栏/内衬/氛围光空间）
        let borderAllowance: CGFloat = 2
        let imgW = displayImage.size.width * fitScale * model.zoom
        let imgH = displayImage.size.height * fitScale * model.zoom
        return CGSize(width: imgW + borderAllowance, height: imgH + borderAllowance)
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
