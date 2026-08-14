import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreGraphics

// MARK: - 截图管线 v2.0：ScreenCaptureKit 自绘选框 + 窗口吸附（功能清单 12.6）
// 未授权屏幕录制时回退系统 screencapture（12.6.4）；截图确认后进入标注编辑器（12.1.1）

final class CaptureController {
    static let shared = CaptureController()

    var onCaptured: ((NSImage) -> Void)?

    private var overlayWindow: NSWindow?
    private var keyMonitor: Any?
    private var capturedDisplays: [CapturedDisplay] = []

    private struct CapturedDisplay {
        let frame: CGRect      // AppKit 全局坐标（点，左下原点）
        let image: CGImage
    }

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
        if mode == "system" || (mode == "auto" && !allowed) {
            systemFallback()
            return
        }
        if !allowed {
            // 用户指定自绘但未授权 → 权限引导（12.6.5）
            PermissionGuide.shared.show { [weak self] granted in
                if granted { self?.startCustom() } else { self?.systemFallback() }
            }
            return
        }
        startCustom()
    }

    /// 系统框选回退（无吸附），截图后仍进标注编辑器（12.6.4）
    private func systemFallback() {
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
                guard !displays.isEmpty else {
                    systemFallback()
                    return
                }
                // 主屏高度：用于把 SC 坐标（左上原点）换算为 AppKit 坐标（左下原点）
                let mainHeight = displays.max(by: { $0.frame.height < $1.frame.height })?.frame.height
                    ?? displays[0].frame.height
                var appkitFrames: [CGRect] = []
                for d in displays {
                    let f = d.frame
                    appkitFrames.append(CGRect(x: f.minX, y: mainHeight - f.maxY,
                                               width: f.width, height: f.height))
                }
                var unionRect = appkitFrames[0]
                for f in appkitFrames.dropFirst() { unionRect = unionRect.union(f) }

                // 每屏各拍一张（冻结画面）
                var shots: [CapturedDisplay] = []
                for (i, d) in displays.enumerated() {
                    let filter = SCContentFilter(display: d, excludingWindows: [])
                    let cfg = SCStreamConfiguration()
                    let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    shots.append(CapturedDisplay(frame: appkitFrames[i], image: cg))
                }

                // 窗口列表（全局 AppKit 坐标），排除自身与过小窗口
                let windows: [CGRect] = content.windows
                    .filter { w in
                        w.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier &&
                        w.frame.width > 60 && w.frame.height > 60
                    }
                    .map { w in
                        CGRect(x: w.frame.minX, y: mainHeight - w.frame.maxY,
                               width: w.frame.width, height: w.frame.height)
                    }

                guard let composite = Self.compositeImage(shots, union: unionRect) else {
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

    private func presentOverlay(composite: NSImage, unionRect: CGRect, windows: [CGRect], displays: [CapturedDisplay]) {
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
            return event
        }
    }

    private func finish(rect: CGRect, composite: NSImage, unionRect: CGRect) {
        teardown()
        guard let cropped = Self.crop(composite, rectInUnion: rect, union: unionRect) else {
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

    // MARK: 合成 / 裁剪

    /// 把各屏截图拼成 union 大小的单图（点坐标）
    private static func compositeImage(_ displays: [CapturedDisplay], union: CGRect) -> NSImage? {
        let img = NSImage(size: union.size)
        img.lockFocus()
        for d in displays {
            let dest = CGRect(x: d.frame.minX - union.minX,
                              y: d.frame.minY - union.minY,
                              width: d.frame.width, height: d.frame.height)
            // 经 NSImage 绘制以正确处理 CGImage 的上下翻转
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

// MARK: - 自绘选框覆盖层视图

struct CaptureOverlayView: View {
    let composite: NSImage
    let unionRect: CGRect
    let windows: [CGRect]
    let snapEnabled: Bool
    let snapThreshold: CGFloat
    let onCancel: () -> Void
    let onConfirm: (CGRect) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var hoverPoint: CGPoint?
    @State private var dragged = false

    /// 窗口坐标 → AppKit 全局坐标（窗口 frame 原点即 unionRect 原点）
    private func global(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + unionRect.minX, y: p.y + unionRect.minY)
    }

    /// 全局坐标 → 窗口本地坐标
    private func local(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - unionRect.minX, y: r.minY - unionRect.minY, width: r.width, height: r.height)
    }

    /// 窗口本地矩形 → AppKit 全局矩形
    private func globalRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX + unionRect.minX, y: r.minY + unionRect.minY, width: r.width, height: r.height)
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
        let (r, w) = SnapLogic.snappedRect(globalSel, windows: windows, threshold: snapThreshold)
        return (local(r), w.map(local))
    }

    /// 悬停窗口（未拖动时）
    private var hoverWindow: CGRect? {
        guard snapEnabled, !dragged, let hp = hoverPoint else { return nil }
        return SnapLogic.window(under: global(hp), windows: windows).map(local)
    }

    var body: some View {
        ZStack {
            Image(nsImage: composite)
                .resizable()
                .frame(width: unionRect.width, height: unionRect.height)
                .ignoresSafeArea()
            Color.black.opacity(0.45)

            if let sel = snappedSelection?.rect ?? selectionRect {
                // 选中区域亮显
                Image(nsImage: CaptureController.crop(composite, rectInUnion: globalRect(sel), union: unionRect) ?? composite)
                    .resizable()
                    .frame(width: sel.width, height: sel.height)
                    .position(x: sel.midX, y: sel.midY)
            }

            if let w = snappedSelection?.window ?? hoverWindow {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(RubickTheme.emeraldBright, lineWidth: 1.5)
                    .background(Rectangle().fill(RubickTheme.emerald.opacity(0.08)))
                    .frame(width: w.width, height: w.height)
                    .position(x: w.midX, y: w.midY)
            }

            if let sel = snappedSelection?.rect ?? selectionRect {
                Rectangle()
                    .strokeBorder(RubickTheme.emeraldBright, lineWidth: 1)
                    .frame(width: sel.width, height: sel.height)
                    .position(x: sel.midX, y: sel.midY)
                Text("\(Int(sel.width)) × \(Int(sel.height))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .position(x: sel.midX, y: max(sel.minY - 14, 12))
            } else {
                Text("拖拽框选 · 悬停窗口单击直截 · ↵ 确认 · ⎋ 取消")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(.top, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .contentShape(Rectangle())
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
