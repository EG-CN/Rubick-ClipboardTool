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

/// 合成 / 裁剪（纯函数，可单元测试）
enum ImageCompose {
    static func composite(_ shots: [ScreenShot], union: CGRect) -> NSImage? {
        let img = NSImage(size: union.size)
        img.lockFocus()
        for d in shots {
            let dest = CGRect(x: d.frame.minX - union.minX,
                              y: d.frame.minY - union.minY,
                              width: d.frame.width, height: d.frame.height)
            NSImage(cgImage: d.image, size: d.frame.size).draw(in: dest)
        }
        img.unlockFocus()
        return img
    }

    static func crop(_ composite: NSImage, rectInUnion: CGRect, union: CGRect) -> NSImage? {
        let out = NSImage(size: rectInUnion.size)
        out.lockFocus()
        let from = NSRect(x: rectInUnion.minX - union.minX,
                          y: rectInUnion.minY - union.minY,
                          width: rectInUnion.width, height: rectInUnion.height)
        composite.draw(in: NSRect(origin: .zero, size: rectInUnion.size),
                       from: from, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}

final class CaptureController {
    static let shared = CaptureController()

    var onCaptured: ((NSImage) -> Void)?

    private var overlayWindow: NSWindow?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var capturedDisplays: [ScreenShot] = []
    private var previousApp: NSRunningApplication?

    private init() {}

    // MARK: 配置

    var snapEnabled: Bool { UserDefaults.standard.object(forKey: "capture.snap") as? Bool ?? false }
    var snapThreshold: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "capture.snapThreshold") as? Double ?? 8) }
    var mode: String { UserDefaults.standard.string(forKey: "capture.mode") ?? "auto" }   // auto / custom / system

    static func screenRecordingAllowed() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: 入口

    enum CapturePurpose {
        case normal      // 普通截图（→ 标注编辑器）
        case translate   // 划图翻译（→ OCR + 自动翻译）
    }

    private var pendingPurpose: CapturePurpose = .normal

    func captureInteractive() {
        pendingPurpose = .normal
        beginCapture()
    }

    /// 划图翻译（Bob 式）：滑选文字区域 → OCR → 自动翻译（功能清单 12.9）
    func captureForTranslation() {
        pendingPurpose = .translate
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
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let displays = content.displays
                let screens = NSScreen.screens
                guard !displays.isEmpty else {
                    systemFallback()
                    return
                }

                // 各屏 AppKit 帧：直接取 NSScreen 原生坐标（免手工换算，多屏/异高屏都稳）
                let appkitFrames: [CGRect] = screens.map { $0.frame }
                guard appkitFrames.count == displays.count else {
                    systemFallback()
                    return
                }
                var unionRect = appkitFrames[0]
                for f in appkitFrames.dropFirst() { unionRect = unionRect.union(f) }

                // 主屏（AppKit 原点所在屏）高度：SC 窗口坐标（左上原点）→ AppKit（左下原点）
                let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens[0]
                let primaryHeight = primary.frame.height

                // 每屏各拍一张（冻结画面）
                // 经典 API 优先：返回完整合成画面（含所有窗口）；macOS 26 上曾出现
                // SCScreenshotManager 仅返回壁纸的情况，故以其兜底。
                var shots: [ScreenShot] = []
                for (i, d) in displays.enumerated() {
                    var cg: CGImage?
                    if let num = screens[i].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                        cg = CGDisplayCreateImage(CGDirectDisplayID(num.uint32Value))
                    }
                    if cg == nil {
                        let filter = SCContentFilter(display: d, excludingWindows: [])
                        cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: SCStreamConfiguration())
                    }
                    guard let captured = cg else {
                        systemFallback()
                        return
                    }
                    shots.append(ScreenShot(frame: appkitFrames[i], image: captured))
                }

                // 窗口列表（AppKit 坐标）+ 标题
                let windows: [(frame: CGRect, title: String)] = content.windows
                    .filter { w in
                        w.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier &&
                        w.frame.width > 60 && w.frame.height > 60
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

                await MainActor.run {
                    self.presentOverlay(composite: composite, unionRect: unionRect,
                                        windows: windows, displays: shots)
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
        let view = CaptureOverlayView(
            composite: composite,
            unionRect: unionRect,
            hintText: pendingPurpose == .translate
                ? "拖选需要翻译的文字区域 · ↵ 确认 · ⎋ 取消"
                : "拖拽框选 · ↵ 确认 · ⎋ 取消",
            onCancel: { [weak self] in self?.teardown(restoreFocus: true) },
            onConfirm: { [weak self] rect in
                self?.finish(rect: rect, composite: composite, unionRect: unionRect)
            }
        )
        // 非激活面板：显示与按键照常，但不激活应用、不切换桌面空间
        // （修复：多桌面/全屏空间下按 ⌘⇧A/⌘⇧D 触发“页面跳动”）
        let window = KeyablePanel(contentRect: unionRect,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.contentView = NSHostingView(rootView: view)
        overlayWindow = window
        window.makeKeyAndOrderFront(nil)

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
        guard let cropped = ImageCompose.crop(composite, rectInUnion: rect, union: unionRect) else {
            systemFallback()
            return
        }
        handleCapturedImage(cropped, at: rect)
    }

    /// 截图产物分发：普通截图 → 标注编辑器（选区原地弹出）；划图翻译 → OCR+翻译
    private func handleCapturedImage(_ image: NSImage, at rect: CGRect? = nil) {
        let purpose = pendingPurpose
        pendingPurpose = .normal
        if purpose == .translate {
            runOCRTranslate(image)
        } else {
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

    private func teardown(restoreFocus: Bool) {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
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
    var hintText: String = "拖拽框选 · ↵ 确认 · ⎋ 取消"
    let onCancel: () -> Void
    let onConfirm: (CGRect) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    /// 视图矩形（左上原点）→ AppKit 全局矩形（左下原点）
    private func globalRect(_ r: CGRect) -> CGRect {
        SnapLogic.appKitRect(fromViewRect: r, viewHeight: unionRect.height, windowOrigin: unionRect.origin)
    }

    private var selectionRect: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var body: some View {
        ZStack {
            Image(nsImage: composite)
                .resizable()
                .frame(width: unionRect.width, height: unionRect.height)
                .ignoresSafeArea()

            // 挖孔遮罩：选区处透出原图（跟手、所见即所截）
            if let sel = selectionRect {
                DimWithHole(hole: sel)
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
            } else {
                Color.black.opacity(0.5)
            }

            if let sel = selectionRect {
                // 仅一个绿色细框
                Rectangle()
                    .strokeBorder(RubickTheme.emeraldBright, lineWidth: 1.5)
                    .frame(width: sel.width, height: sel.height)
                    .position(x: sel.midX, y: sel.midY)
                Text("\(Int(sel.width)) × \(Int(sel.height))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .position(x: sel.minX + 6, y: max(sel.minY - 15, 14))
            } else {
                hintPill(hintText)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 18)
            }
        }
        .contentShape(Rectangle())
        .onReceive(NotificationCenter.default.publisher(for: .init("cbt.captureConfirm"))) { _ in
            if let sel = selectionRect, sel.width > 3, sel.height > 3 {
                onConfirm(globalRect(sel))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragStart = dragStart ?? v.startLocation
                    dragCurrent = v.location
                }
                .onEnded { v in
                    dragCurrent = v.location
                    defer { dragStart = nil; dragCurrent = nil }
                    guard let sel = selectionRect, sel.width > 3, sel.height > 3 else {
                        onCancel()   // 单击空白 = 取消
                        return
                    }
                    onConfirm(globalRect(sel))
                }
        )
        .onAppear { NSCursor.crosshair.set() }
        .onDisappear { NSCursor.arrow.set() }
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
        _ = CGRequestScreenCaptureAccess()
        var attempts = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            attempts += 1
            if CGPreflightScreenCaptureAccess() {
                t.invalidate()
                self?.finish(true)
            } else if attempts >= 120 {   // 最多等 60 秒
                t.invalidate()
                Toast.shared.show("未检测到授权：请到 系统设置→隐私与安全性→屏幕录制 开启后重启拉比克")
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
