import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreGraphics

// MARK: - 截图管线 v2.0：ScreenCaptureKit 自绘选框 + 窗口吸附（功能清单 12.6）
// 未授权屏幕录制时回退系统 screencapture（12.6.4）；截图确认后进入标注编辑器（12.1.1）

/// 无边框面板也能成为键盘焦点（Esc/↵ 等按键必需）
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 单屏截图素材（AppKit 全局坐标，左下原点）
struct ScreenShot {
    let frame: CGRect
    let image: CGImage
}

/// 选框会话状态（悬停高亮的窗口，视图坐标）
final class CaptureSessionState: ObservableObject {
    @Published var hoverWindowViewFrame: CGRect?
}

/// 合成 / 裁剪（纯函数，可单元测试）
enum ImageCompose {
    /// 物理像素合成：按分片真实像素密度建位图（Retina 2x 全程不降采样）
    static func composite(_ shots: [ScreenShot], union: CGRect) -> NSImage? {
        let scale = shots.map { CGFloat($0.image.width) / max($0.frame.width, 1) }.max() ?? 1
        let pw = max(Int((union.width * scale).rounded()), 1)
        let ph = max(Int((union.height * scale).rounded()), 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = union.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for d in shots {
            let dest = CGRect(x: d.frame.minX - union.minX,
                              y: d.frame.minY - union.minY,
                              width: d.frame.width, height: d.frame.height)
            NSImage(cgImage: d.image, size: d.frame.size).draw(in: dest)
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: union.size)
        img.addRepresentation(rep)
        return img
    }

    static func crop(_ composite: NSImage, rectInUnion: CGRect, union: CGRect) -> NSImage? {
        // 继承合成图像素密度（Retina 2x），rep.size 仍为点尺寸
        let scale = composite.cgImage().map { CGFloat($0.width) / max(composite.size.width, 1) } ?? 1
        let pw = max(Int((rectInUnion.width * scale).rounded()), 1)
        let ph = max(Int((rectInUnion.height * scale).rounded()), 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = rectInUnion.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let from = NSRect(x: rectInUnion.minX - union.minX,
                          y: rectInUnion.minY - union.minY,
                          width: rectInUnion.width, height: rectInUnion.height)
        composite.draw(in: NSRect(origin: .zero, size: rectInUnion.size),
                       from: from, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: rectInUnion.size)
        out.addRepresentation(rep)
        return out
    }
}

final class CaptureController {
    static let shared = CaptureController()

    var onCaptured: ((NSImage) -> Void)?

    private var overlayWindow: NSWindow?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var hoverMonitor: Any?
    private var capturedDisplays: [ScreenShot] = []
    private var previousApp: NSRunningApplication?

    private init() {}

    // MARK: 配置

    var snapEnabled: Bool { UserDefaults.standard.object(forKey: "capture.snap") as? Bool ?? true }
    var snapThreshold: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "capture.snapThreshold") as? Double ?? 8) }
    var mode: String { UserDefaults.standard.string(forKey: "capture.mode") ?? "auto" }   // auto / custom / system

    static func screenRecordingAllowed() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: 入口

    enum CapturePurpose {
        case normal      // 普通截图（→ 标注编辑器）
        case translate   // 划图翻译（→ OCR + 自动翻译）
        case ocr         // 划图取字（→ OCR + 复制到剪贴板，Easydict 静默模式）
        case long        // 长截图（→ 滚动采集 + 拼接，实验性）
    }

    private var pendingPurpose: CapturePurpose = .normal

    func captureInteractive() {
        pendingPurpose = .normal
        beginCapture()
    }

    /// 长截图（实验性）：框选区域 → 滚动采集 → 行对齐拼接（⌘⇧L）
    func captureForLong() {
        pendingPurpose = .long
        beginCapture()
    }

    /// 划图翻译（Bob 式）：滑选文字区域 → OCR → 自动翻译（功能清单 12.9）
    func captureForTranslation() {
        pendingPurpose = .translate
        beginCapture()
    }

    /// 划图取字（Easydict 静默 OCR 式）：滑选区域 → OCR → 直接复制到剪贴板
    func captureForOCR() {
        pendingPurpose = .ocr
        beginCapture()
    }

    private func beginCapture() {
        let allowed = Self.screenRecordingAllowed()
        if mode == "system" {
            systemFallback()
            return
        }
        if !allowed {
            // 未授权屏幕录制：每次都弹引导（避免静默回退系统框选，用户误以为功能没生效）
            PermissionGuide.shared.show { [weak self] granted in
                if granted { self?.startCustom() } else { self?.systemFallback() }
            }
            return
        }
        startCustom()
    }

    /// 系统框选回退（无吸附），截图后仍进标注编辑器（12.6.4）
    private func systemFallback() {
        Toast.shared.show("系统框选模式（未授权屏幕录制，无窗口吸附）")
        ScreenshotController.shared.captureSystemInteractive { [weak self] img in
            guard let self = self, let img = img else { return }
            self.handleCapturedImage(img)
        }
    }

    // MARK: 自绘流程

    private func startCustom() {
        if overlayWindow != nil { teardown(restoreFocus: false) }   // 双触发：先拆旧覆盖层与监听
        // 像素采集/合成必须留在后台（MainActor 整段提升会让 CGDisplayCreateImage
        // 与全屏合成阻塞主线程）；仅 UI 触点（systemFallback/presentOverlay）回主线程
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let displays = content.displays
                let screens = NSScreen.screens
                guard !displays.isEmpty else {
                    await MainActor.run { self.systemFallback() }
                    return
                }

                // 各屏 AppKit 帧：按 displayID 与 NSScreen 精确配对——SC 与 NSScreen 的
                // 数组顺序没有协议保证，按索引硬配在多屏时会整屏内容串位
                let screensByDisplayID: [CGDirectDisplayID: NSScreen] = Dictionary(
                    uniqueKeysWithValues: screens.compactMap { s in
                        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                        return (CGDirectDisplayID(n.uint32Value), s)
                    })
                let appkitFrames: [CGRect] = displays.compactMap { screensByDisplayID[$0.displayID]?.frame }
                guard appkitFrames.count == displays.count else {
                    await MainActor.run { self.systemFallback() }
                    return
                }
                let unionRect = appkitFrames.dropFirst().reduce(appkitFrames[0]) { $0.union($1) }

                // 主屏（AppKit 原点所在屏）高度：SC 窗口坐标（左上原点）→ AppKit（左下原点）
                let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens[0]
                let primaryHeight = primary.frame.height

                // 每屏各拍一张（冻结画面）
                // 经典 API 优先：返回完整合成画面（含所有窗口）；macOS 26 上曾出现
                // SCScreenshotManager 仅返回壁纸的情况，故以其兜底。
                var shots: [ScreenShot] = []
                for d in displays {
                    guard let screen = screensByDisplayID[d.displayID] else {
                        await MainActor.run { self.systemFallback() }
                        return
                    }
                    var cg: CGImage?
                    if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                        cg = CGDisplayCreateImage(CGDirectDisplayID(num.uint32Value))
                    }
                    if cg == nil {
                        let filter = SCContentFilter(display: d, excludingWindows: [])
                        cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: SCStreamConfiguration())
                    }
                    guard let captured = cg else {
                        await MainActor.run { self.systemFallback() }
                        return
                    }
                    shots.append(ScreenShot(frame: screen.frame, image: captured))
                }

                // 窗口列表（AppKit 坐标）+ 标题
                let displayFramesSC = displays.map { $0.frame }   // SC 坐标，供整屏窗过滤
                let windows: [(frame: CGRect, title: String)] = content.windows
                    .filter { w in
                        w.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier &&
                        w.frame.width > 60 && w.frame.height > 60
                    }
                    // 排除桌面/壁纸窗（Dock 拥有或无归属）；全屏应用窗口保留——
                    // 此前按"≈整屏"一刀切，导致全屏 App 无法智能选窗
                    .filter { w in
                        let isNearlyFull = displayFramesSC.contains { d in
                            w.frame.width >= d.width * 0.97 && w.frame.height >= d.height * 0.97
                        }
                        guard isNearlyFull else { return true }
                        let bid = w.owningApplication?.bundleIdentifier ?? ""
                        return !(bid.isEmpty || bid == "com.apple.dock")
                    }
                    .map { w in
                        let f = w.frame
                        let appkit = CGRect(x: f.minX,
                                            y: primaryHeight - f.maxY,
                                            width: f.width, height: f.height)
                        return (appkit, w.title ?? "")
                    }

                guard let composite = ImageCompose.composite(shots, union: unionRect) else {
                    systemFallback()
                    return
                }

                let finalShots = shots
                let finalWindows = windows
                await MainActor.run {
                    self.presentOverlay(composite: composite, unionRect: unionRect,
                                        windows: finalWindows, displays: finalShots)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.systemFallback()
                }
            }
        }
    }

    private func presentOverlay(composite: NSImage, unionRect: CGRect, windows: [(frame: CGRect, title: String)], displays: [ScreenShot]) {
        capturedDisplays = displays
        previousApp = NSWorkspace.shared.frontmostApplication
        // 窗口帧 AppKit → 视图坐标（选框视图左上原点），供吸附/悬停/单击整窗
        let windowViewFrames = windows.map { w in
            SnapLogic.viewRect(fromAppKitRect: w.frame, viewHeight: unionRect.height, windowOrigin: unionRect.origin)
        }
        let session = CaptureSessionState()

        let view = CaptureOverlayView(
            composite: composite,
            unionRect: unionRect,
            windowFrames: windowViewFrames,
            session: session,
            hintText: pendingPurpose == .translate
                ? "拖选需要翻译的文字区域 · ↵ 确认 · ⎋ 取消"
                : (pendingPurpose == .ocr
                   ? "拖选要取字的区域 · 识别后直接复制 · ⎋ 取消"
                   : (pendingPurpose == .long
                      ? "框选长截图区域 · 确认后自动滚动采集 · ⎋ 取消"
                      : "拖拽框选 · 单击窗口直截 · ⌥ 禁吸附 · ⎋ 取消")),
            onCancel: { [weak self] in self?.teardown(restoreFocus: true) },
            onConfirm: { [weak self] rect in
                self?.finish(rect: rect, composite: composite, unionRect: unionRect)
            }
        )
        // 非激活面板：显示与按键照常，但不激活应用
        // .stationary:覆盖窗不参与空间切换——这是发起截图时"整屏跳动"的根因
        let window = KeyablePanel(contentRect: unionRect,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        // 不开这个，mouseMoved 事件不会投递到本窗口，悬停选窗高亮整体失灵
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: view)
        overlayWindow = window
        if !AXIsProcessTrusted() {
            Toast.shared.showImportant("提示：⎋/↵ 快捷键需辅助功能权限；拖拽与单击不受影响")
        }
        // 呼出加固：临时转 regular 激活——未激活时覆盖层在全屏空间不可见、
        // 首击被激活消费、⎋/↵ 本地监听不触发（面板同款根因）；teardown 还原
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 成为 key（非激活面板不抢应用焦点）：保证首击即生效、按键走本地监听
        window.makeKeyAndOrderFront(nil)

        // 悬停窗口高亮（鼠标移动即刷新，Snipaste 式）
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .otherMouseDragged]) { [weak self, weak session] event in
            guard let self = self, self.overlayWindow?.isVisible == true else { return event }
            if let session = session {
                let m = NSEvent.mouseLocation
                let viewPoint = CGPoint(x: m.x - unionRect.origin.x,
                                        y: unionRect.height - (m.y - unionRect.origin.y))
                session.hoverWindowViewFrame = SnapLogic.window(under: viewPoint, windows: windowViewFrames)
            }
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.overlayWindow?.isVisible == true else { return event }
            if event.keyCode == 53 {   // ⎋ 取消
                self.teardown(restoreFocus: true)
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {   // ↵ 确认当前选区
                NotificationCenter.default.post(name: .init("cbt.captureConfirm"), object: nil)
                return nil
            }
            return event
        }

        // 全局监听兜底：应用未激活时也能收到 Esc / ↵
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.overlayWindow?.isVisible == true else { return }
            if event.keyCode == 53 {
                DispatchQueue.main.async { self.teardown(restoreFocus: true) }
            } else if event.keyCode == 36 || event.keyCode == 76 {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .init("cbt.captureConfirm"), object: nil)
                }
            }
        }
    }

    private func finish(rect: CGRect, composite: NSImage, unionRect: CGRect) {
        teardown(restoreFocus: false)
        // 取整到整点边界，避免半像素采样让成品边缘发虚
        let r = rect.integral
        if pendingPurpose == .long {
            // 长截图：首帧裁剪后交给滚动采集拼接（不经编辑器）
            LongScreenshot.shared.start(rect: r)
            return
        }
        guard let cropped = ImageCompose.crop(composite, rectInUnion: r, union: unionRect) else {
            systemFallback()
            return
        }
        // 即拍即复制：选区确认的瞬间原图就进剪贴板（监听会自动入册历史）。
        // 此后无论标注后确认还是 ⎋ 取消，⌘V 拿到的都是这次截图——修复自绘路径从不写剪贴板的缺陷
        writeImageToPasteboard(cropped)
        handleCapturedImage(cropped, at: r)
    }

    /// 截图产物分发：普通截图 → 标注编辑器（选区原地弹出）；划图翻译 → OCR+翻译；划图取字 → OCR+复制
    private func handleCapturedImage(_ image: NSImage, at rect: CGRect? = nil) {
        let purpose = pendingPurpose
        pendingPurpose = .normal
        switch purpose {
        case .translate:
            runOCRTranslate(image)
        case .ocr:
            runOCRCopy(image)
        case .long:
            // 长截图在 finish 已分流，正常不应到达；兜底走普通编辑器
            AnnotationController.shared.show(image: image, at: rect) { [weak self] result in
                self?.onCaptured?(result)
            }
        case .normal:
            AnnotationController.shared.show(image: image, at: rect) { [weak self] result in
                self?.onCaptured?(result)
            }
        }
    }

    /// 划图翻译：Vision 本地 OCR → 自动翻译 → 结果面板
    private func runOCRTranslate(_ image: NSImage) {
        Toast.shared.show("识别文字并翻译中…")
        OCRService.shared.recognize(image: image) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let r):
                    let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        Toast.shared.show("该区域未识别到文字")
                        return
                    }
                    TranslationService.shared.translate(text) { t in
                        DispatchQueue.main.async {
                            switch t {
                            case .success(let translated):
                                TextResultPanel.shared.show(kind: .translation, source: text, result: translated)
                            case .failure(let err):
                                Toast.shared.show("翻译失败：\(err.localizedDescription)")
                            }
                        }
                    }
                case .failure(let err):
                    Toast.shared.show("识别失败：\(err.localizedDescription)")
                }
            }
        }
    }

    /// 划图取字：Vision 本地 OCR → 识别结果直接进剪贴板（历史自动入册，⌘V 即贴）
    private func runOCRCopy(_ image: NSImage) {
        Toast.shared.show("正在识别文字…")
        OCRService.shared.recognize(image: image, languageCorrection: false) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let r):
                    let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        Toast.shared.show("该区域未识别到文字")
                        return
                    }
                    writeTextToPasteboard(text)
                    Toast.shared.show("已复制 \(text.count) 个字 · ⌘V 粘贴")
                case .failure(let err):
                    Toast.shared.show("识别失败：\(err.localizedDescription)")
                }
            }
        }
    }

    private func teardown(restoreFocus: Bool) {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        ActivationPolicyKeeper.shared.release("overlay")
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = hoverMonitor { NSEvent.removeMonitor(m); hoverMonitor = nil }
        capturedDisplays = []
        if restoreFocus, let prev = previousApp, !prev.isTerminated,
           prev.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            prev.activate(options: [.activateIgnoringOtherApps])
        }
        previousApp = nil
    }
}

// MARK: - 自绘选框覆盖层视图

struct CaptureOverlayView: View {
    let composite: NSImage
    let unionRect: CGRect
    /// 可吸附窗口帧（视图坐标，左上原点）
    var windowFrames: [CGRect] = []
    @ObservedObject var session: CaptureSessionState
    var hintText: String = "拖拽框选 · 手柄微调 · ↵/✓ 确认 · ⎋ 取消"
    let onCancel: () -> Void
    let onConfirm: (CGRect) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    /// 拖拽落定后的待确认选区：显示 8 手柄可微调（规格 A1）
    @State private var pendingSelection: CGRect?
    @State private var resizeBase: CGRect?
    @State private var resizeHandle: SelHandle?

    enum SelHandle: CaseIterable {
        case tl, t, tr, l, r, bl, b, br
        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .tl: return CGPoint(x: r.minX, y: r.minY)
            case .t:  return CGPoint(x: r.midX, y: r.minY)
            case .tr: return CGPoint(x: r.maxX, y: r.minY)
            case .l:  return CGPoint(x: r.minX, y: r.midY)
            case .r:  return CGPoint(x: r.maxX, y: r.midY)
            case .bl: return CGPoint(x: r.minX, y: r.maxY)
            case .b:  return CGPoint(x: r.midX, y: r.maxY)
            case .br: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }
    }

    /// 视图矩形（左上原点）→ AppKit 全局矩形（左下原点）
    private func globalRect(_ r: CGRect) -> CGRect {
        SnapLogic.appKitRect(fromViewRect: r, viewHeight: unionRect.height, windowOrigin: unionRect.origin)
    }

    /// 原始选区（未吸附）
    private var rawSelection: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 吸附后选区（⌥ 临时禁用吸附）——仅拖拽中生效，落定后进入 pendingSelection
    private var dragSelection: CGRect? {
        guard let raw = rawSelection else { return nil }
        let optionHeld = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        guard CaptureController.shared.snapEnabled, !optionHeld, !windowFrames.isEmpty else { return raw }
        return SnapLogic.snappedRect(raw, windows: windowFrames, threshold: CaptureController.shared.snapThreshold).rect
    }

    /// 当前生效选区
    private var selectionRect: CGRect? { dragSelection ?? pendingSelection }

    private func confirmPending() {
        guard let sel = pendingSelection, sel.width > 3, sel.height > 3 else { return }
        // 钳制在合成画布内：拖出边界的部分不参与采样
        let g = globalRect(sel)
        guard let clamped = g.intersection(unionRect) as CGRect?, !clamped.isNull, clamped.width > 3, clamped.height > 3 else { return }
        onConfirm(clamped)
    }

    private func resizedRect(from base: CGRect, handle: SelHandle, t: CGSize) -> CGRect {
        // 锚定对边语义：拖左手柄时右边缘固定，越过后钳在 10px，不翻转吸附
        var minX = base.minX, minY = base.minY, maxX = base.maxX, maxY = base.maxY
        if handle == .tl || handle == .l || handle == .bl { minX = min(base.maxX - 10, base.minX + t.width) }
        if handle == .tr || handle == .r || handle == .br { maxX = max(base.minX + 10, base.maxX + t.width) }
        if handle == .tl || handle == .t || handle == .tr { minY = min(base.maxY - 10, base.minY + t.height) }
        if handle == .bl || handle == .b || handle == .br { maxY = max(base.minY + 10, base.maxY + t.height) }
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 10), height: max(maxY - minY, 10))
    }

    var body: some View {
        ZStack {
            Image(nsImage: composite)
                .resizable()
                .frame(width: unionRect.width, height: unionRect.height)
                .ignoresSafeArea()

            // 规格修复：选区外恒定压暗（此前悬停切换明暗跳变）
            if let sel = selectionRect {
                DimWithHole(hole: sel)
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
            } else {
                Color.black.opacity(0.5)
                    .allowsHitTesting(false)
            }

            // 悬停窗口高亮（Snipaste 式，压暗之上提亮）
            if dragStart == nil && pendingSelection == nil,
               let hover = session.hoverWindowViewFrame {
                Rectangle()
                    .strokeBorder(RubickTheme.emeraldBright, lineWidth: 2)
                    .background(RubickTheme.emerald.opacity(0.12))
                    .frame(width: hover.width, height: hover.height)
                    .position(x: hover.midX, y: hover.midY)
                    .allowsHitTesting(false)
            }

            if let sel = selectionRect {
                Rectangle()
                    .strokeBorder(RubickTheme.emeraldBright, lineWidth: 1.5)
                    .frame(width: sel.width, height: sel.height)
                    .position(x: sel.midX, y: sel.midY)
                    .allowsHitTesting(false)
                Text("\(Int(sel.width)) × \(Int(sel.height))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .position(x: sel.minX + 6, y: max(sel.minY - 15, 14))
                    .allowsHitTesting(false)
            } else if session.hoverWindowViewFrame == nil && dragStart == nil && pendingSelection == nil {
                hintPill(hintText)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 18)
                    .allowsHitTesting(false)
            }

            // 待确认选区：8 手柄微调（规格 A1）+ 选区下方 ✓/✗（规格 A2 落点）
            if let sel = pendingSelection {
                ForEach(SelHandle.allCases, id: \.self) { h in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
                        .frame(width: 9, height: 9)
                        .position(h.point(in: sel))
                        .contentShape(Circle().inset(by: -6))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    if resizeHandle != h || resizeBase == nil {
                                        resizeHandle = h
                                        resizeBase = sel
                                    }
                                    if let base = resizeBase {
                                        pendingSelection = resizedRect(from: base, handle: h, t: v.translation)
                                    }
                                }
                                .onEnded { _ in resizeHandle = nil; resizeBase = nil }
                        )
                }
                HStack(spacing: 8) {
                    confirmPill(icon: "checkmark", label: "确认", tint: .green) { confirmPending() }
                    confirmPill(icon: "xmark", label: "取消", tint: .white) { pendingSelection = nil }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.72)))
                .position(x: sel.midX,
                          y: sel.maxY + 26 > unionRect.height - 16 ? max(sel.minY - 28, 20) : sel.maxY + 26)
            }
        }
        .contentShape(Rectangle())
        .onReceive(NotificationCenter.default.publisher(for: .init("cbt.captureConfirm"))) { _ in
            confirmPending()
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard pendingSelection == nil else { return }   // 待确认态不再起框
                    dragStart = dragStart ?? v.startLocation
                    dragCurrent = v.location
                }
                .onEnded { v in
                    // 手柄拖拽中：主手势的 onEnded 一律忽略（防双手势竞争误清选区）
                    if resizeHandle != nil || resizeBase != nil { return }
                    // 待确认态：点选区外取消；选区内静默（确认走 ✓/↵）
                    if let sel = pendingSelection {
                        if !sel.insetBy(dx: -8, dy: -8).contains(v.location) { pendingSelection = nil }
                        return
                    }
                    dragCurrent = v.location
                    defer { dragStart = nil; dragCurrent = nil }
                    guard let raw = rawSelection, raw.width > 3, raw.height > 3 else {
                        // 单击：命中的窗口直截整窗（Snipaste 式），空白处取消
                        if let win = SnapLogic.window(under: v.location, windows: windowFrames) {
                            onConfirm(globalRect(win))
                        } else {
                            onCancel()
                        }
                        return
                    }
                    // 拖拽落定 → 待确认态（8 手柄微调，↵/✓ 确认）
                    pendingSelection = selectionRect ?? raw
                }
        )
        .onAppear { NSCursor.crosshair.set() }
        .onDisappear { NSCursor.arrow.set() }
    }

    private func confirmPill(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(label).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(tint == .green ? Color.green : Color.white.opacity(0.9))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint == .green ? Color.green.opacity(0.7) : Color.white.opacity(0.35), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onEnded { v in
            if hypot(v.translation.width, v.translation.height) < 6 { action() }
        })
    }

    private func hintPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(.black.opacity(0.65)))
            .overlay(Capsule().strokeBorder(RubickTheme.emerald.opacity(0.35), lineWidth: 0.8))
    }
}

/// 全屏遮罩挖孔（选区亮显，偶奇填充）
struct DimWithHole: Shape {
    var hole: CGRect

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        p.addRect(hole)
        return p
    }
}

// MARK: - 屏幕录制权限引导（12.6.5，Stitch 风格）

final class PermissionGuide {
    static let shared = PermissionGuide()

    private var panel: NSPanel?
    private var timer: Timer?
    private var completion: ((Bool) -> Void)?

    private init() {}

    func show(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        if panel == nil {
            let view = PermissionGuideView(
                onGrant: { [weak self] in self?.requestAndWait() },
                onFallback: { [weak self] in self?.finish(false) }
            )
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: view)
            p.center()
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    private func requestAndWait() {
        // 点击后立即收起弹窗，直接带用户去系统设置的屏幕录制页
        panel?.orderOut(nil)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        _ = CGRequestScreenCaptureAccess()
        var attempts = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] t in
            attempts += 1
            if CGPreflightScreenCaptureAccess() {
                t.invalidate()
                Toast.shared.show("屏幕录制已授权")
                self?.finish(true)
            } else if attempts >= 14 {   // ~8 秒
                t.invalidate()
                Toast.shared.show("若已开启仍未生效：屏幕录制权限需重启拉比克后生效")
                self?.finish(false)
            }
        }
    }

    private func finish(_ granted: Bool) {
        timer?.invalidate()
        panel?.orderOut(nil)
        let cb = completion
        completion = nil
        cb?(granted)
    }
}

struct PermissionGuideView: View {
    let onGrant: () -> Void
    let onFallback: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "record.circle")
                .font(.system(size: 30))
                .foregroundStyle(RubickTheme.primary(scheme))
            Text("开启屏幕录制权限")
                .font(.system(size: 14, weight: .bold))
            Text("拉比克需要「屏幕录制」权限来实现窗口吸附与自绘截图选框。所有画面仅在本机处理，绝不上传网络。\n（授权后若仍提示未开启，退出并重新打开拉比克即可生效。）")
                .font(.system(size: 11.5))
                .foregroundStyle(RubickTheme.muted(scheme))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            HStack(spacing: 10) {
                Button("去开启权限", action: onGrant)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(RubickTheme.emerald)
                Button("使用系统框选继续（无吸附）", action: onFallback)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(RubickTheme.muted(scheme))
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 420, height: 220)
        .background(.ultraThinMaterial)
        .background(RubickTheme.darkBackground.opacity(scheme == .dark ? 0.55 : 0))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RubickTheme.primary(scheme).opacity(0.3), lineWidth: 0.8))
    }
}
