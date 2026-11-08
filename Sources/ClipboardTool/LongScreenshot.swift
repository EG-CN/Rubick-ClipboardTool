import AppKit
import CoreGraphics
import os
import ScreenCaptureKit

// MARK: - 长截图（⌘⇧L 手动 / 菜单「长截图（自动滚动）」）
// 手动模式：全局监听滚轮事件的精确像素增量（不靠图像匹配），用户自己控制滚动节奏；
// 自动模式：程序注入整数行滚动 + 剖面相关对齐。HUD 实时预览，单击完成，Esc 取消。

/// 文件落盘诊断：unified log 对 info/notice 级不可靠（不落盘），文件版一查一个准。
enum FileTrace {
    static let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rubick-trace.txt")
    static func log(_ line: String) {
        let stamped = Date().formatted(date: .omitted, time: .standard) + "  " + line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(stamped.data(using: .utf8)!)
        } else {
            try? stamped.data(using: .utf8)?.write(to: url)
        }
    }
}

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
        else if mode == .auto { text = "自动滚动中 · 已拼 \(stitchedCount) 屏 · 单击完成" }
        else { text = "手动滚动中 · 已拼 \(stitchedCount) 屏 · 单击完成 · Esc 取消" }
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
        /// 每行亮度剖面（减均值除标准差归一化）：深色/浅色主题通吃，
        /// 亚像素渲染下逐像素匹配会失败，剖面相关不受影响
        private(set) var rowProfile: [Double] = []
        private(set) var rowProfileStd: Double = 0
        /// 每行对比度（采样亮度的 max-min）：区分"有内容的行"和"纯色行"
        private(set) var rowContrast: [Double] = []

        mutating func buildProfile() {
            guard rowProfile.isEmpty else { return }
            var raw = [Double](repeating: 0, count: height)
            let step = max(4, width / 400) * 4
            for y in 0..<height {
                let off = y * bytesPerRow
                var sum = 0, n = 0, x = 0
                while x + 2 < bytesPerRow { sum += Int(data[off + x]) + Int(data[off + x + 1]); n += 1; x += step }
                raw[y] = n == 0 ? 0 : Double(sum) / Double(n * 2)
            }
            let mean = raw.reduce(0, +) / Double(max(raw.count, 1))
            var sq = 0.0
            for v in raw { sq += (v - mean) * (v - mean) }
            let std = (sq / Double(max(raw.count, 1))).squareRoot()
            rowProfileStd = std
            // 归一化：纯色页 std≈0 → 剖面接近 0（配合 std 门槛判"无内容"）
            rowProfile = raw.map { ($0 - mean) / (std + 0.0001) }
            // 行对比度：该行采样亮度的极差
            var contrast = [Double](repeating: 0, count: height)
            for y in 0..<height {
                let off = y * bytesPerRow
                var lo = 255.0, hi = 0.0, x = 0
                while x + 2 < bytesPerRow {
                    let v = Double(data[off + x])
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                    x += step
                }
                contrast[y] = hi - lo
            }
            rowContrast = contrast
        }

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
    /// 关系为 next[r] == prev[r + s]。0 = 无滚动；nil = 对齐失败。
    static func scrollOffset(prev: Sampler, next: Sampler, maxSearch: Int = 600, stickyHeight: Int = 0) -> Int? {
        var p = prev, n = next
        p.buildProfile(); n.buildProfile()
        let anchorRows = 30
        let anchorTop = max(40, stickyHeight + 8)
        // 纯色/近纯色画面：无内容可追踪
        guard p.rowProfileStd > 0.5, n.rowProfileStd > 0.5 else { return 0 }
        // 锚带：对比度最高的 30 行（预留向下搜索余量），避开吸顶区
        let bandCeiling = max(anchorTop, min(p.rowContrast.count, n.rowContrast.count) - maxSearch - anchorRows - 8)
        var bandBase = anchorTop
        var bandContrast = 0.0
        var y = anchorTop
        while y + anchorRows + 40 < bandCeiling {
            var sum = 0.0
            var r = y
            while r < y + anchorRows { sum += p.rowContrast[r]; r += 3 }
            let avg = sum / Double(anchorRows / 3)
            if avg > bandContrast { bandContrast = avg; bandBase = y }
            y += 9
        }
        guard bandContrast > 8 else { return 0 }
        // 剖面相关：归一化行亮度剖面双向全量扫描 + 显著性检验。
        // 亚像素渲染只微扰剖面，逐像素匹配在深色 UI 稀疏内容上会被背景稀释而误判。
        func scan(_ shift: Int) -> Double? {
            let lo = max(bandBase, -shift)
            let hi = min(bandBase + anchorRows, min(n.rowProfile.count, p.rowProfile.count - shift))
            guard hi - lo >= anchorRows / 2 else { return nil }
            var err = 0.0
            for y in lo..<hi { err += abs(n.rowProfile[y] - p.rowProfile[y + shift]) }
            return err / Double(hi - lo)
        }
        var best: (offset: Int, err: Double)?
        var total = 0.0, count = 0
        for s in (-maxSearch)...maxSearch where s != 0 {
            if let e = scan(s) {
                total += e; count += 1
                if best == nil || e < best!.err { best = (s, e) }
            }
        }
        // 显著性：真实对齐的剖面误差显著低于随机对齐（单位方差下随机≈1.1）
        guard count > 0, let best, best.err < (total / Double(count)) * 0.6, best.err < 0.9 else { return nil }
        return best.offset
    }

    private static func variance(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let mean = v.reduce(0, +) / Double(v.count)
        return v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)
    }

}


final class LongScreenshot {
    static let shared = LongScreenshot()

    private var running = false
    private var cancelled = false
    private var finishNow = false
    private var clampedToSingleScreen = false
    private var escMonitor: Any?
    private var scrollMonitor: Any?
    private let maxFramesManual = 60
    private let maxFramesAuto = 25
    private var stickyHeight = 0
    private var mode: LongShotMode = .manual
    /// 手动模式：滚动事件累计的页面滚动位置（px，向下为正）
    private var manualScrollPx = 0
    /// 已采集帧的滚动位置
    private var framePositions: [Int] = []
    private var captureAnchor = 0
    private var captureScale: CGFloat = 2

    private init() {}

    var enabled: Bool { UserDefaults.standard.object(forKey: "capture.longShot") as? Bool ?? false }

    /// rect：AppKit 全局坐标（左下原点）的框选区域；mode 本次采集的滚动控制模式
    func start(rect: CGRect, mode requested: LongShotMode = .manual) {
        guard !running else { return }
        defer { if !running { ClotheslineController.shared.resumeAfterCapture() } }
        guard enabled else {
            Toast.shared.showImportant("长截图未开启：设置 → 截图")
            return
        }
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
        mode = requested
        cancelled = false; finishNow = false
        manualScrollPx = 0; captureAnchor = 0; framePositions = []; stickyHeight = 0
        captureScale = screen.backingScaleFactor
        let displayID = CGDirectDisplayID(num.uint32Value)

        Toast.shared.hide()
        LongShotHUD.shared.show(rect: rect, screen: screen)
        LongShotHUD.shared.setMode(mode)
        FileTrace.log("start rect=\(NSStringFromRect(rect)) mode=\(mode == .auto ? "auto" : "manual")")

        // ⎋ 取消（全局监听：采集期间本应用非激活）；完成手势 = 单击
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown {
                FileTrace.log("click → 完成")
                self.finishNow = true
                return
            }
            if event.keyCode == 53 { FileTrace.log("keydown: Esc → 取消"); self.cancelled = true }
        }
        // 手动模式：监听滚轮事件的精确像素增量——滚动偏移直接度量，零图像匹配
        if mode == .manual {
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.mode == .manual, !self.cancelled, !self.finishNow else { return }
                let loc = NSEvent.mouseLocation
                guard rect.insetBy(dx: -40, dy: -40).contains(loc) else { return }
                let delta: Int
                if event.hasPreciseScrollingDeltas {
                    delta = Int(-event.scrollingDeltaY * self.captureScale)
                } else {
                    delta = Int(-event.scrollingDeltaY * 16)
                }
                self.manualScrollPx = max(0, self.manualScrollPx + delta)
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result = await self.run(rect: rect, displayID: displayID)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.running = false
                LongShotHUD.shared.hide()
                if let m = self.scrollMonitor { NSEvent.removeMonitor(m); self.scrollMonitor = nil }
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
                    break
                }
            }
        }
    }

    private enum Outcome { case success(NSImage); case failure(String); case cancelled }

    private func cropToRect(_ display: CGImage, rect: CGRect, screen: NSScreen) -> CGImage? {
        let scale = CGFloat(display.width) / max(screen.frame.width, 1)
        let localX = rect.minX - screen.frame.minX
        let topDist = screen.frame.maxY - rect.maxY
        let px = (localX * scale).rounded()
        let py = (topDist * scale).rounded()
        let pw = (rect.width * scale).rounded()
        let ph = (rect.height * scale).rounded()
        return display.cropping(to: CGRect(x: px, y: py, width: pw, height: ph))
    }

    private func screenContaining(_ p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) }
    }

    private func run(rect: CGRect, displayID: CGDirectDisplayID) async -> Outcome {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map({ CGDirectDisplayID($0.uint32Value) }) == displayID
        }) else { return .failure("找不到目标屏幕") }

        var frames: [(image: CGImage, sampler: StitchEngine.Sampler)] = []
        var positions: [Int] = []
        var lastOffset: Int?
        var alignFailures = 0
        var lastHUDUpdate: TimeInterval = 0
        let cap = mode == .auto ? maxFramesAuto : maxFramesManual
        let regionPxH = Int((rect.height * captureScale).rounded())

        var iteration = 0
        while frames.count < cap {
            iteration += 1
            if cancelled { FileTrace.log("run: 取消"); return .cancelled }

            // ── 采集一帧 ──
            var full = CGDisplayCreateImage(displayID)
            if full == nil {
                full = try? await Self.screenKitCapture(displayID: displayID)
            }
            guard let full,
                  let cropped = cropToRect(full, rect: rect, screen: screen),
                  var sampler = StitchEngine.Sampler(image: cropped) else {
                FileTrace.log("iter \(iteration): 采集失败")
                return .failure("截屏失败（第 \(iteration) 轮）")
            }
            sampler.buildProfile()

            var pos: Int
            if mode == .manual {
                pos = min(max(manualScrollPx, 0), 20000)
                // 滚动位置没推进：不追加帧
                if !frames.isEmpty, pos <= captureAnchor + 8 {
                    if finishNow { break }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    continue
                }
            } else {
                pos = frames.isEmpty ? 0 : (positions.last ?? 0) + (lastOffset ?? 0)
            }

            // ── 对齐（仅自动模式需要；手动模式位置由滚动事件直接度量）──
            if mode == .auto, let last = frames.last {
                guard let offset = StitchEngine.scrollOffset(prev: last.sampler, next: sampler, maxSearch: 600, stickyHeight: stickyHeight) else {
                    alignFailures += 1
                    FileTrace.log("iter \(iteration): 对齐失败（连续 \(alignFailures) 次）")
                    if alignFailures >= 3 { break }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    continue
                }
                alignFailures = 0
                if offset == 0 {
                    FileTrace.log("iter \(iteration): 页面到底")
                    await MainActor.run { LongShotHUD.shared.markBottom() }
                    break
                }
                lastOffset = offset
            }

            // ── 吸顶检测（第 2 帧、确认有滚动时）──
            if frames.count == 1 {
                let f1 = frames[0].sampler
                var sticky = 0
                while sticky < min(f1.height, sampler.height, 300),
                      sampler.rowEquals(sticky, in: f1, sticky, tolerance: 3) { sticky += 1 }
                if sticky > 4 {
                    stickyHeight = sticky
                    FileTrace.log("吸顶区检测：\(sticky) px（拼接时跳过）")
                }
            }

            frames.append((cropped, sampler))
            positions.append(pos)
            captureAnchor = pos   // 关键：记录已采集位置，否则没滚动也会重复采集
            if frames.count > 1, mode == .auto { frames[frames.count - 2].sampler.data = [] }

            // ── 进度 HUD ──
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastHUDUpdate > 0.35 || frames.count == 1 {
                lastHUDUpdate = now
                let totalPx = pos + regionPxH
                let percent = min(1, Double(frames.count) / Double(cap))
                let preview = Self.makePreview(frames: frames, positions: positions, stickyHeight: stickyHeight)
                await MainActor.run {
                    LongShotHUD.shared.update(frames: frames.count, totalPx: totalPx, percent: percent, preview: preview)
                }
            }

            if finishNow { FileTrace.log("run: 完成，共 \(frames.count) 帧"); break }

            // ── 自动模式注入滚动；手动模式等用户 ──
            if mode == .auto {
                let step = lastOffset.map { min(24, max(10, $0 / 8)) } ?? 12
                let src = CGEventSource(stateID: .combinedSessionState)
                if let ev = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1,
                                    wheel1: -Int32(step), wheel2: 0, wheel3: 0) {
                    ev.post(tap: .cghidEventTap)
                }
                lastOffset = nil   // 注入后由匹配器重新度量
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        if cancelled { return .cancelled }
        guard let first = frames.first else { return .failure("未采集到帧") }
        let pw = first.image.width
        let ph = first.image.height
        let top = positions.first ?? 0
        let bottom = (positions.last ?? 0) + ph
        let totalH = max(bottom - top, ph)
        guard frames.count > 1 || (mode == .auto) else {
            let scale = CGFloat(pw) / max(rect.width, 1)
            return .success(NSImage(cgImage: first.image,
                                    size: CGSize(width: CGFloat(pw) / scale,
                                                 height: CGFloat(ph) / scale)))
        }
        guard let ctx = CGContext(data: nil, width: pw, height: totalH,
                                  bitsPerComponent: 8, bytesPerRow: pw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .failure("拼接画布创建失败")
        }
        ctx.interpolationQuality = .none
        for (i, f) in frames.enumerated() {
            let pos = positions[i]
            let skip = i == 0 ? 0 : min(stickyHeight, ph - 8)
            let drawH = ph - skip
            guard drawH > 0,
                  let sub = f.image.cropping(to: CGRect(x: 0, y: skip, width: pw, height: drawH)) else { continue }
            // 帧 i 的内容顶 = pos + skip（吸顶行只保留首帧的）
            ctx.draw(sub, in: CGRect(x: 0, y: CGFloat(totalH - pos - skip - drawH),
                                     width: CGFloat(pw), height: CGFloat(drawH)))
        }
        guard let out = ctx.makeImage() else { return .failure("拼接输出失败") }
        let scale = CGFloat(pw) / max(rect.width, 1)
        return .success(NSImage(cgImage: out, size: CGSize(width: CGFloat(pw) / scale, height: CGFloat(totalH) / scale)))
    }

    /// 拼接进度预览：把已采集帧按各自滚动位置缩到 160pt 宽画布
    private static func makePreview(frames: [(image: CGImage, sampler: StitchEngine.Sampler)], positions: [Int], stickyHeight: Int, width: Int = 160) -> CGImage? {
        guard let first = frames.first, let lastPos = positions.last else { return nil }
        let scale = Double(width) / Double(max(first.image.width, 1))
        let frameH = Double(first.image.height)
        let totalH = Double(lastPos) + frameH
        let outH = Int(max(1, totalH * scale))
        guard let ctx = CGContext(data: nil, width: width, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        for (i, f) in frames.enumerated() {
            let skip = i == 0 ? 0 : stickyHeight
            let y = (Double(positions[i] + skip)) * scale
            ctx.draw(f.image, in: CGRect(x: 0, y: y, width: Double(width), height: frameH * scale))
        }
        return ctx.makeImage()
    }

    /// ScreenCaptureKit 兜底采集
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
}
