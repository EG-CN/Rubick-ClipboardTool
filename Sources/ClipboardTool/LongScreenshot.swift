import AppKit
import CoreGraphics
import os
import ScreenCaptureKit

// MARK: - 长截图（⌘⇧L / 菜单「长截图」）
// 流程：框选区域 → 程序滚动注入 → 分片截屏 → 行对齐拼接；过程 HUD 实时回报，↵ 提前完成，⎋ 取消。

let longShotLog = Logger(subsystem: "local.rubick.screenshot-test", category: "LongShot")

/// 长截图进度 HUD：区域下方进度胶囊 + 右侧实时拼接预览条。
/// 面板都在选区矩形之外，不会被拍进帧里；非激活、不拦截鼠标。
/// 滚动控制模式：手动 = 用户自己滚页面（默认，由人控制）；自动 = 程序匀速注入滚动。
enum LongShotMode { case manual, auto }

final class LongShotHUD {
    static let shared = LongShotHUD()
    private var pillPanel: NSPanel?
    private var stripPanel: NSPanel?
    private var pillView: LongShotPillView?
    private var stripView: LongShotStripView?
    private var tick: Timer?
    private(set) var mode: LongShotMode = .manual

    private init() {}

    func show(rect: CGRect, screen: NSScreen) {
        hide()
        let screenFrame = screen.frame
        // 进度胶囊：默认在区域下方 16pt，贴底时翻到区域上方；水平夹紧屏内。
        let pillSize = CGSize(width: 540, height: 46)
        let pillX = min(max(rect.midX - pillSize.width / 2, screenFrame.minX + 12), screenFrame.maxX - pillSize.width - 12)
        var pillY = rect.minY - pillSize.height - 18
        if pillY < screenFrame.minY + 8 { pillY = rect.maxY + 18 }
        let pillFrame = CGRect(x: pillX, y: pillY, width: pillSize.width, height: pillSize.height)
        let pv = LongShotPillView(frame: CGRect(origin: .zero, size: pillSize))
        let pp = Self.makePanel(frame: pillFrame)
        pp.contentView = pv
        pp.orderFrontRegardless()
        pillPanel = pp; pillView = pv

        // 拼接预览条：区域右侧 22pt（放不下换左侧），高度贴合区域并钳到屏内。
        let stripWidth: CGFloat = 280
        let stripHeight = min(max(rect.height, 260), screen.visibleFrame.height - 60)
        var stripX = rect.maxX + 22
        if stripX + stripWidth > screenFrame.maxX - 12 { stripX = rect.minX - stripWidth - 22 }
        let stripY = min(max(screen.visibleFrame.minY + 20, rect.minY), screen.visibleFrame.maxY - stripHeight)
        let stripFrame = CGRect(x: stripX, y: stripY, width: stripWidth, height: stripHeight)
        let sv = LongShotStripView(frame: CGRect(origin: .zero, size: stripFrame.size))
        let sp = Self.makePanel(frame: stripFrame)
        sp.contentView = sv
        sp.orderFrontRegardless()
        stripPanel = sp; stripView = sv

        tick = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak pv] _ in pv?.phase += 1 }
        tick?.tolerance = 0.03
        RunLoop.main.add(tick!, forMode: .common)
        setMode(mode)
    }

    func setMode(_ m: LongShotMode) {
        mode = m
        pillView?.mode = m
        stripView?.mode = m
    }

    private static func makePanel(frame: CGRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .floating; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        return p
    }

    func update(frames: Int, totalPx: Int, percent: Double, preview: CGImage?) {
        pillView?.stitchedCount = frames
        stripView?.update(preview: preview, percent: percent, totalPx: totalPx)
    }

    func markBottom() {
        pillView?.bottomReached = true
    }

    func hide() {
        tick?.invalidate(); tick = nil
        pillPanel?.orderOut(nil); stripPanel?.orderOut(nil)
        pillPanel = nil; stripPanel = nil; pillView = nil; stripView = nil
    }
}

/// 进度胶囊：旋转指示 + 已拼接层数 + 快捷键提示；页面到底时切换文案。
final class LongShotPillView: NSView {
    var stitchedCount = 0 { didSet { needsDisplay = true } }
    var bottomReached = false { didSet { needsDisplay = true } }
    var phase: CGFloat = 0 { didSet { needsDisplay = true } }
    var mode: LongShotMode = .manual { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds
        let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        NSColor(calibratedWhite: 0.05, alpha: 0.9).setFill(); path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke(); path.lineWidth = 1; path.stroke()
        // 旋转弧
        let center = CGPoint(x: 26, y: pill.height / 2)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: 8, startAngle: phase * 240, endAngle: phase * 240 + 270, clockwise: false)
        NSColor(calibratedRed: 0.31, green: 0.87, blue: 0.64, alpha: 1).setStroke()
        arc.lineWidth = 2.6; arc.lineCapStyle = .round; arc.stroke()
        // 文案
        let text: String
        if bottomReached { text = "已到页面底部 · 正在收尾" }
        else if mode == .auto { text = "自动滚动中 · 已拼 \(stitchedCount) 屏 · 请勿移动鼠标 · 空格切回手动" }
        else { text = "手动滚动中 · 你来滚页面 · 已拼 \(stitchedCount) 屏 · 空格切自动" }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(at: CGPoint(x: 44, y: pill.height / 2 - 8), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1),
            .paragraphStyle: paragraph
        ])
        // 快捷键帽（右对齐）
        func keycap(_ label: String, rightEdge: CGFloat) -> CGFloat {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)]
            let size = (label as NSString).size(withAttributes: attrs)
            let width = size.width + 14
            let box = CGRect(x: rightEdge - width, y: pill.height / 2 - 11, width: width, height: 22)
            NSColor(calibratedWhite: 1, alpha: 0.09).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).stroke()
            (label as NSString).draw(at: CGPoint(x: box.minX + 7, y: box.midY - size.height / 2 + 1), withAttributes: attrs)
            return box.minX - 8
        }
        var edge = pill.maxX - 18
        edge = keycap("Esc 取消", rightEdge: edge)
        _ = keycap("↵ 完成", rightEdge: edge)
    }
}

/// 拼接预览条：实时缩略图 + 进度条 + 像素总高。
final class LongShotStripView: NSView {
    private var preview: CGImage?
    private var percent: Double = 0
    private var totalPx = 0
    var mode: LongShotMode = .manual { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    func update(preview: CGImage?, percent: Double, totalPx: Int) {
        self.preview = preview
        self.percent = percent
        self.totalPx = totalPx
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let panel = bounds
        let path = NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.05, alpha: 0.9).setFill(); path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.1).setStroke(); path.lineWidth = 1; path.stroke()
        let title = (mode == .auto ? "长截图预览 · 自动" : "长截图预览 · 手动") as NSString
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor(calibratedRed: 0.31, green: 0.87, blue: 0.64, alpha: 1)]
        title.draw(at: CGPoint(x: panel.midX - title.size(withAttributes: titleAttrs).width / 2, y: 12), withAttributes: titleAttrs)
        // 预览图（保持宽高比，贴宽绘制；CG 原点在左下，预览从顶端铺起）
        let box = CGRect(x: 12, y: 34, width: panel.width - 24, height: panel.height - 106)
        if let preview {
            let ratio = CGFloat(preview.height) / max(CGFloat(preview.width), 1)
            let drawH = min(box.height, box.width * ratio)
            let drawW = min(box.width, drawH / max(ratio, 0.0001))
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).addClip()
            ctx.setFillColor(NSColor(calibratedWhite: 0.09, alpha: 1).cgColor)
            ctx.fill(box)
            let drawRect = CGRect(x: box.midX - drawW / 2, y: box.maxY - drawH, width: drawW, height: drawH)
            ctx.draw(preview, in: drawRect)
            ctx.restoreGState()
        } else {
            NSColor(calibratedWhite: 1, alpha: 0.05).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        }
        // 进度条 + 数据
        let bar = CGRect(x: 12, y: panel.height - 58, width: panel.width - 24, height: 5)
        NSColor(calibratedWhite: 1, alpha: 0.1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()
        NSColor(calibratedRed: 0.31, green: 0.87, blue: 0.64, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: max(4, bar.width * CGFloat(percent)), height: 5), xRadius: 2.5, yRadius: 2.5).fill()
        let info = "\(Int(percent * 100))% · \(totalPx) px" as NSString
        let infoAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor(calibratedRed: 0.31, green: 0.87, blue: 0.64, alpha: 1)]
        info.draw(at: CGPoint(x: panel.midX - info.size(withAttributes: infoAttrs).width / 2, y: panel.height - 44), withAttributes: infoAttrs)
    }
}

/// 拼接纯函数引擎：在相邻两帧之间做行对齐（可单测）
enum StitchEngine {

    struct Sampler {
        var data: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int

    init?(image: CGImage) {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data else { return nil }
        let ptr = buf.assumingMemoryBound(to: UInt8.self)
        // 实测确认：CGBitmapContext 内存自顶向下（row 0 = 视觉顶行），无需翻转
        self.data = Array(UnsafeBufferPointer(start: ptr, count: w * h * 4))
        self.width = w
        self.height = h
        self.bytesPerRow = w * 4
    }

        /// 取色：hexAt(x,y) 读 RGB（行序自顶向下，见 Sampler 说明）
    func hexAt(_ x: Int, _ y: Int) -> String? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let o = y * bytesPerRow + x * 4
        guard o + 2 < data.count else { return nil }
        return String(format: "#%02X%02X%02X", data[o], data[o + 1], data[o + 2])
    }

    /// 位图内存自顶向下：row 0 = 视觉顶行。比对 RG 两通道（灰阶 UI 单通道易误匹配）
        func rowEquals(_ rowA: Int, in a: Sampler, _ rowB: Int, tolerance: Int = 3, step: Int = 11) -> Bool {
            let offA = rowA * bytesPerRow
            let offB = rowB * a.bytesPerRow
            var mismatches = 0
            var x = 0
            while x + 2 < min(bytesPerRow, a.bytesPerRow) {
                if data[offA + x] != a.data[offB + x] || data[offA + x + 1] != a.data[offB + x + 1] {
                    mismatches += 1
                    if mismatches > tolerance { return false }
                }
                x += step * 4
            }
            return true
        }
    }

    /// 返回 next 相对 prev 的滚动行数。向下滚 s 行 ⟺ 内容上移，next 顶部锚 prev 下方：
    /// 关系为 next[r] == prev[r + s]。0 = 无滚动（页面到底）；nil = 对齐失败。
    /// 锚行取 40–70（避开吸顶导航条，否则 s=0 恒命中会被误判为"到底"）。
    static func scrollOffset(prev: Sampler, next: Sampler, maxSearch: Int = 600) -> Int? {
        let anchorRows = 30
        let anchorBase = 40
        for s in 0...maxSearch {
            guard anchorBase + s + anchorRows < next.height,
                  anchorBase + s + anchorRows < prev.height else { break }
            var matched = 0
            var r = anchorBase
            while r < anchorBase + anchorRows {
                if next.rowEquals(r, in: prev, r + s) { matched += 1 }
                r += 3
            }
            // 10 个锚行里 ≥7 吻合即认为对齐（容忍滚动期间的小动画）
            if matched >= 7 { return s }
        }
        return nil
    }
}

final class LongScreenshot {
    static let shared = LongScreenshot()

    private var running = false
    private var cancelled = false
    private var finishNow = false
    /// 当前滚动控制模式：手动（默认）由用户滚页面，自动为程序注入
    var mode: LongShotMode = .manual
    private var clampedToSingleScreen = false
    private var escMonitor: Any?
    private let maxFrames = 25
    private let maxSearch = 600

    private init() {}

    var enabled: Bool { UserDefaults.standard.object(forKey: "capture.longShot") as? Bool ?? true }

    /// rect：AppKit 全局坐标的框选区域
    func start(rect: CGRect) {
        longShotLog.notice("start: rect=\(NSStringFromRect(rect), privacy: .public) enabled=\(self.enabled)")
        guard !running else { longShotLog.notice("start: 已在运行中，忽略"); return }
        defer { if !running { ClotheslineController.shared.resumeAfterCapture() } }
        guard enabled else {
            longShotLog.notice("start: 功能未开启")
            Toast.shared.showImportant("长截图未开启：设置 → 截图")
            return
        }
        // 跨屏选区钳制到中心点所在屏（多屏拼接不支持）
        var rect = rect
        let spanning = NSScreen.screens.filter { $0.frame.intersects(rect) }
        if spanning.count > 1 {
            let c = NSPoint(x: rect.midX, y: rect.midY)
            guard let center = screenContaining(c) else {
                Toast.shared.showImportant("长截图：无法定位所在屏幕")
                return
            }
            rect = rect.intersection(center.frame)
            clampedToSingleScreen = true
        }
        guard let screen = screenContaining(NSPoint(x: rect.midX, y: rect.midY)),
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            Toast.shared.showImportant("长截图：无法定位所在屏幕")
            return
        }
        running = true
        let displayID = CGDirectDisplayID(num.uint32Value)
        // 光标移到区域中心：滚动事件投向光标下的窗口
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: center, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        // 先收起 Toast：采集期间屏上浮层会被拍进帧里，还会破坏行对齐
        Toast.shared.hide()
        // HUD 在区域外（胶囊在下方、预览条在右侧），不会被拍进帧
        LongShotHUD.shared.show(rect: rect, screen: screen)
        // ⎋ 取消（丢弃） / ↵ 提前完成（保留已拼内容）：全局监听，采集期间本应用非激活
        cancelled = false; finishNow = false
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { longShotLog.notice("keydown: Esc → 取消"); self?.cancelled = true }
            if event.keyCode == 36 || event.keyCode == 76 { longShotLog.notice("keydown: ↵ → 提前完成"); self?.finishNow = true }
            if event.keyCode == 49 {
                self?.mode = self?.mode == .auto ? .manual : .auto
                if let m = self?.mode {
                    longShotLog.notice("mode → \(m == .auto ? "auto" : "manual")")
                    LongShotHUD.shared.setMode(m)
                }
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result = await self.run(rect: rect, displayID: displayID)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.running = false
                LongShotHUD.shared.hide()
                ClotheslineController.shared.resumeAfterCapture()
                if let m = self.escMonitor { NSEvent.removeMonitor(m); self.escMonitor = nil }
                switch result {
                case .success(let image):
                    writeImageToPasteboard(image)
                    HistoryStore.shared.addImage(image)
                    let note = self.clampedToSingleScreen ? "（已限制单屏）" : ""
                    Toast.shared.showImportant("长截图完成\(note)（\(Int(image.size.width))×\(Int(image.size.height))）已进剪贴板")
                case .failure(let msg):
                    Toast.shared.showImportant("长截图失败：\(msg)")
                case .cancelled:
                    break   // 用户主动取消：安静收场
                }
            }
        }
    }

    private enum Outcome { case success(NSImage); case failure(String); case cancelled }

    /// ScreenCaptureKit 兜底采集（按目标屏真实像素尺寸，避免被默认流拉成 1920×1080）
    private static func screenKitCapture(displayID: CGDirectDisplayID) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = max(CGDisplayPixelsWide(displayID), 1)
        config.height = max(CGDisplayPixelsHigh(displayID), 1)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func cropToRect(_ display: CGImage, rect: CGRect, screen: NSScreen) -> CGImage? {
        let scale = CGFloat(display.width) / max(screen.frame.width, 1)
        let localX = rect.minX - screen.frame.minX
        // CGImage.cropping(to:) 是左上原点像素坐标：py = 距屏顶的距离（此前按底部原点算会截到镜像区域）
        let topDist = screen.frame.maxY - rect.maxY
        let px = (localX * scale).rounded()
        let py = (topDist * scale).rounded()
        let pw = (rect.width * scale).rounded()
        let ph = (rect.height * scale).rounded()
        return display.cropping(to: CGRect(x: px, y: py, width: pw, height: ph))
    }

    /// 拼接进度预览：把已采集帧缩到 160pt 宽的画布上（仅喂 HUD，不影响成品）
    private static func makePreview(frames: [(image: CGImage, sampler: StitchEngine.Sampler)], offsets: [Int], width: Int = 160) -> CGImage? {
        guard let first = frames.first else { return nil }
        let scale = Double(width) / Double(max(first.image.width, 1))
        let frameH = Double(first.image.height)
        let totalH = frameH + Double(offsets.reduce(0, +))
        let outH = Int(max(1, totalH * scale))
        guard let ctx = CGContext(data: nil, width: width, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        var shifted = 0.0
        for (i, f) in frames.enumerated() {
            if i > 0 { shifted += Double(offsets[i - 1]) }
            let y = (totalH - shifted - frameH) * scale
            ctx.draw(f.image, in: CGRect(x: 0, y: y, width: Double(width), height: frameH * scale))
        }
        return ctx.makeImage()
    }

    private func run(rect: CGRect, displayID: CGDirectDisplayID) async -> Outcome {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map({ CGDirectDisplayID($0.uint32Value) }) == displayID
        }) else { return .failure("找不到目标屏幕") }

        var frames: [(image: CGImage, sampler: StitchEngine.Sampler)] = []
        var offsets: [Int] = []
        var lastOffset: Int?

        var iteration = 0
        while frames.count < (mode == .auto ? 25 : 60) {
            iteration += 1
            if cancelled { longShotLog.notice("run: 第 \(iteration) 轮前收到取消"); return .cancelled }
            // 经典 API 优先，失败回退 SCScreenshotManager（macOS 26 上两者都偶发单边失效）
            var full = CGDisplayCreateImage(displayID)
            if full == nil {
                longShotLog.error("iter \(iteration): CGDisplayCreateImage 失败，回退 ScreenCaptureKit")
                full = try? await Self.screenKitCapture(displayID: displayID)
            }
            guard let full,
                  let cropped = cropToRect(full, rect: rect, screen: screen),
                  let sampler = StitchEngine.Sampler(image: cropped) else {
                longShotLog.error("iter \(iteration): 采集失败 full=\(full != nil)")
                return .failure("截屏失败（第 \(iteration) 轮）")
            }
            if frames.isEmpty { longShotLog.notice("首帧 OK \(cropped.width, privacy: .public)×\(cropped.height, privacy: .public)") }
            // 步长自适应上限须与对齐搜索窗联动（Retina 像素行），否则步长大会撞穿搜索窗
            let step = lastOffset.map { min(24, max(10, $0 / 8)) } ?? 12
            let searchWindow = max(maxSearch, step * 60)
            if let last = frames.last {
                guard let offset = StitchEngine.scrollOffset(prev: last.sampler, next: sampler, maxSearch: searchWindow) else {
                    longShotLog.notice("iter \(iteration): 对齐失败，以已采集 \(frames.count) 帧收尾")
                    break   // 对齐失败：以已采集内容收尾
                }
                if offset == 0 {
                    if mode == .auto {
                        longShotLog.notice("iter \(iteration): 页面到底（offset=0）")
                        await MainActor.run { LongShotHUD.shared.markBottom() }
                        break     // 自动模式：到底即停
                    }
                    // 手动模式：用户还没滚，不追加帧继续等待
                    if finishNow { longShotLog.notice("run: ↵ 提前完成，共 \(frames.count) 帧"); break }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    continue
                }
                longShotLog.notice("iter \(iteration): 新增 \(offset) px")
                offsets.append(offset)
                lastOffset = offset
            }
            frames.append((cropped, sampler))
            // 内存：Sampler 只在对齐相邻帧时有用，算完即弃（25 帧 RGBA 常驻可逼近 1GB）
            if frames.count > 1 { frames[frames.count - 2].sampler.data = [] }
            // 进度回报：层数 + 已拼高度 + 小图预览（HUD 在主线程）
            let frameCount = frames.count
            let totalPx = (frames.first?.image.height ?? 0) + offsets.reduce(0, +)
            let percent = Double(frameCount) / Double(mode == .auto ? 25 : 60)
            let preview = Self.makePreview(frames: frames, offsets: offsets)
            await MainActor.run {
                LongShotHUD.shared.update(frames: frameCount, totalPx: totalPx, percent: percent, preview: preview)
            }
            if finishNow { longShotLog.notice("run: ↵ 提前完成，共 \(frames.count) 帧"); break }   // ↵ 提前完成：保留已拼内容
            // 自动模式才注入滚动；手动模式滚不滚、滚多快由用户决定
            if mode == .auto {
                let src = CGEventSource(stateID: .combinedSessionState)
                if let ev = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1,
                                    wheel1: -Int32(step), wheel2: 0, wheel3: 0) {
                    ev.post(tap: .cghidEventTap)
                }
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        if cancelled { return .cancelled }
        guard let first = frames.first else { return .failure("未采集到帧") }
        guard frames.count > 1 else {
            // 只有 1 帧：页面无滚动，退化为普通截图（保持 Retina 点尺寸）
            let scale = CGFloat(first.image.width) / max(rect.width, 1)
            return .success(NSImage(cgImage: first.image,
                                    size: CGSize(width: CGFloat(first.image.width) / scale,
                                                 height: CGFloat(first.image.height) / scale)))
        }

        let pw = first.image.width
        let ph = first.image.height
        let totalH = ph + offsets.reduce(0, +)
        guard let ctx = CGContext(data: nil, width: pw, height: totalH,
                                  bitsPerComponent: 8, bytesPerRow: pw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .failure("拼接画布创建失败")
        }
        ctx.interpolationQuality = .none
        var shifted = 0
        for (i, f) in frames.enumerated() {
            if i > 0 { shifted += offsets[i - 1] }
            // 帧顶在拼接画布中的像素 y（自顶向下）：shifted → CG y = totalH - shifted - ph
            ctx.draw(f.image, in: CGRect(x: 0, y: CGFloat(totalH - shifted - ph),
                                         width: CGFloat(pw), height: CGFloat(ph)))
        }
        guard let out = ctx.makeImage() else { return .failure("拼接输出失败") }
        let scale = CGFloat(pw) / max(rect.width, 1)
        return .success(NSImage(cgImage: out, size: CGSize(width: CGFloat(pw) / scale, height: CGFloat(totalH) / scale)))
    }
}
