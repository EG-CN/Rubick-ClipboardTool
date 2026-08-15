import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreGraphics

// MARK: - 截图管线 v2.0：ScreenCaptureKit 自绘选框 + 窗口吸附（功能清单 12.6）
// 未授权屏幕录制时回退系统 screencapture（12.6.4）；截图确认后进入标注编辑器（12.1.1）

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
    private var capturedDisplays: [ScreenShot] = []

    private init() {}

    // MARK: 配置

    var snapEnabled: Bool { UserDefaults.standard.object(forKey: "capture.snap") as? Bool ?? true }
    var snapThreshold: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "capture.snapThreshold") as? Double ?? 8) }
    var mode: String { UserDefaults.standard.string(forKey: "capture.mode") ?? "auto" }   // auto / custom / system

    static func screenRecordingAllowed() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: 入口

    func captureInteractive() {
        let allowed = Self.screenRecordingAllowed()
        if mode == "system" {
            systemFallback()
            return
        }
        if !allowed {
            let guideShown = UserDefaults.standard.bool(forKey: "capture.guideShown")
            if mode == "custom" || !guideShown {
                UserDefaults.standard.set(true, forKey: "capture.guideShown")
                PermissionGuide.shared.show { [weak self] granted in
                    if granted { self?.startCustom() } else { self?.systemFallback() }
                }
                return
            }
            systemFallback()
            return
        }
        startCustom()
    }

    /// 系统框选回退（无吸附），截图后仍进标注编辑器（12.6.4）
    private func systemFallback() {
        Toast.shared.show("系统框选模式（未授权屏幕录制，无窗口吸附）")
        ScreenshotController.shared.captureSystemInteractive { img in
            guard let img = img else { return }
            AnnotationController.shared.show(image: img) { [weak self] result in
                self?.onCaptured?(result)
            }
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
        let view = CaptureOverlayView(
            composite: composite,
            unionRect: unionRect,
            windows: windows,
            snapEnabled: snapEnabled,
            snapThreshold: snapThreshold,
            onCancel: { [weak self] in self?.teardown() },
            onConfirm: { [weak self] rect in
                self?.finish(rect: rect, composite: composite, unionRect: unionRect)
            }
        )
        let window = NSWindow(contentRect: unionRect,
                              styleMask: [.borderless],
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
        NSApp.activate(ignoringOtherApps: true)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.overlayWindow?.isVisible == true else { return event }
            if event.keyCode == 53 {   // ⎋ 取消
                self.teardown()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {   // ↵ 确认当前选区
                NotificationCenter.default.post(name: .init("cbt.captureConfirm"), object: nil)
                return nil
            }
            return event
        }
    }

    private func finish(rect: CGRect, composite: NSImage, unionRect: CGRect) {
        teardown()
        guard let cropped = ImageCompose.crop(composite, rectInUnion: rect, union: unionRect) else {
            systemFallback()
            return
        }
        AnnotationController.shared.show(image: cropped) { [weak self] result in
            self?.onCaptured?(result)
        }
    }

    private func teardown() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        capturedDisplays = []
    }
}

// MARK: - 自绘选框覆盖层视图

struct CaptureOverlayView: View {
    let composite: NSImage
    let unionRect: CGRect
    let windows: [(frame: CGRect, title: String)]
    let snapEnabled: Bool
    let snapThreshold: CGFloat
    let onCancel: () -> Void
    let onConfirm: (CGRect) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var hoverPoint: CGPoint?
    @State private var dragged = false

    private var windowFrames: [CGRect] { windows.map { $0.frame } }

    /// SwiftUI 视图点（左上原点）→ AppKit 全局点（左下原点）
    private func global(_ p: CGPoint) -> CGPoint {
        let r = SnapLogic.appKitRect(fromViewRect: CGRect(origin: p, size: .zero),
                                     viewHeight: unionRect.height,
                                     windowOrigin: unionRect.origin)
        return r.origin
    }

    /// AppKit 全局矩形 → 视图坐标（左上原点）
    private func local(_ r: CGRect) -> CGRect {
        SnapLogic.viewRect(fromAppKitRect: r, viewHeight: unionRect.height, windowOrigin: unionRect.origin)
    }

    /// 视图矩形（左上原点）→ AppKit 全局矩形（左下原点）
    private func globalRect(_ r: CGRect) -> CGRect {
        SnapLogic.appKitRect(fromViewRect: r, viewHeight: unionRect.height, windowOrigin: unionRect.origin)
    }

    private var selectionRect: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 实时吸附后的全局选区（本地坐标输出）
    private var snappedSelection: (rect: CGRect, window: CGRect?)? {
        guard let sel = selectionRect, snapEnabled else { return nil }
        let globalSel = CGRect(x: sel.minX + unionRect.minX, y: sel.minY + unionRect.minY,
                               width: sel.width, height: sel.height)
        let (r, w) = SnapLogic.snappedRect(globalSel, windows: windowFrames, threshold: snapThreshold)
        return (local(r), w.map(local))
    }

    /// 悬停窗口（未拖动时）
    private var hoverWindow: CGRect? {
        guard snapEnabled, !dragged, let hp = hoverPoint else { return nil }
        return SnapLogic.window(under: global(hp), windows: windowFrames).map(local)
    }

    private func title(for frame: CGRect) -> String? {
        windows.first(where: { $0.frame == frame })?.title
    }

    var body: some View {
        ZStack {
            Image(nsImage: composite)
                .resizable()
                .frame(width: unionRect.width, height: unionRect.height)
                .ignoresSafeArea()
            Color.black.opacity(0.48)

            if let sel = snappedSelection?.rect ?? selectionRect {
                // 选中区域亮显（原画面亮度）
                Image(nsImage: ImageCompose.crop(composite, rectInUnion: globalRect(sel), union: unionRect) ?? composite)
                    .resizable()
                    .frame(width: sel.width, height: sel.height)
                    .position(x: sel.midX, y: sel.midY)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            // 窗口高亮（吸附目标 / 悬停窗口）
            if let w = snappedSelection?.window ?? hoverWindow {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(RubickTheme.emerald.opacity(0.10))
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(RubickTheme.emeraldBright, lineWidth: 2)
                    if let t = title(for: globalRect(w)), !t.isEmpty {
                        Text(t)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(RubickTheme.emerald.opacity(0.9)))
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, -14)
                    }
                }
                .frame(width: w.width, height: w.height)
                .position(x: w.midX, y: w.midY)
                .shadow(color: RubickTheme.emerald.opacity(0.35), radius: 6)
            }

            // 选区描边 + 角标 + 尺寸
            if let sel = snappedSelection?.rect ?? selectionRect {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(RubickTheme.emeraldBright, lineWidth: 1.5)
                    .frame(width: sel.width, height: sel.height)
                    .position(x: sel.midX, y: sel.midY)
                cornerBrackets(sel)
                Text("\(Int(sel.width)) × \(Int(sel.height))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(RubickTheme.emerald.opacity(0.9)))
                    .position(x: sel.minX + 6, y: max(sel.minY - 15, 14))
            } else {
                hintPill("拖拽框选 · 悬停窗口单击直截 · ↵ 确认 · ⎋ 取消")
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 18)
            }
        }
        .contentShape(Rectangle())
        .onReceive(NotificationCenter.default.publisher(for: .init("cbt.captureConfirm"))) { _ in
            if let sel = selectionRect, sel.width > 3, sel.height > 3 {
                if let snapped = snappedSelection?.rect {
                    onConfirm(globalRect(snapped))
                } else {
                    onConfirm(globalRect(sel))
                }
            } else if let hw = hoverWindow {
                onConfirm(globalRect(hw))
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hoverPoint = p
            case .ended: hoverPoint = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    dragged = true
                    dragStart = dragStart ?? v.startLocation
                    dragCurrent = v.location
                }
                .onEnded { v in
                    dragCurrent = v.location
                    defer { dragStart = nil; dragCurrent = nil; dragged = false }
                    guard let sel = selectionRect, sel.width > 3, sel.height > 3 else {
                        // 单击：有悬停窗口 → 直截整窗；否则取消
                        if let hw = hoverWindow {
                            onConfirm(globalRect(hw))
                        } else {
                            onCancel()
                        }
                        return
                    }
                    if let snapped = snappedSelection?.rect {
                        onConfirm(globalRect(snapped))
                    } else {
                        onConfirm(globalRect(sel))
                    }
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
            .shadow(color: RubickTheme.emerald.opacity(0.15), radius: 6)
    }

    private func cornerBrackets(_ r: CGRect) -> some View {
        let l: CGFloat = 14
        return Path { p in
            // 左上
            p.move(to: CGPoint(x: r.minX, y: r.minY + l))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
            // 右上
            p.move(to: CGPoint(x: r.maxX - l, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
            // 左下
            p.move(to: CGPoint(x: r.minX, y: r.maxY - l))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + l, y: r.maxY))
            // 右下
            p.move(to: CGPoint(x: r.maxX - l, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - l))
        }
        .stroke(Color.white, lineWidth: 2)
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
                            styleMask: [.titled, .fullSizeContentView],
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
        NSApp.activate(ignoringOtherApps: true)
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
            Text("拉比克需要「屏幕录制」权限来实现窗口吸附与自绘截图选框。所有画面仅在本机处理，绝不上传网络。")
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
