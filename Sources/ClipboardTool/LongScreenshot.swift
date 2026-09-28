import AppKit
import CoreGraphics

// MARK: - 长截图（实验性，⌘⇧L）
// 流程：框选区域 → 程序滚动注入 → 分片截屏 → 行对齐拼接。规格 A 组「标实验性」。

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
    private var escMonitor: Any?
    private let maxFrames = 25
    private let maxSearch = 600

    private init() {}

    var enabled: Bool { UserDefaults.standard.object(forKey: "capture.longShot") as? Bool ?? true }

    /// rect：AppKit 全局坐标的框选区域
    func start(rect: CGRect) {
        guard !running else { return }
        guard enabled else {
            Toast.shared.showImportant("长截图（实验性）未开启：设置 → 截图")
            return
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
        // ⎋ 中止（全局监听：采集期间本应用非激活）
        cancelled = false
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelled = true }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result = await self.run(rect: rect, displayID: displayID)
            await MainActor.run {
                self.running = false
                if let m = self.escMonitor { NSEvent.removeMonitor(m); self.escMonitor = nil }
                switch result {
                case .success(let image):
                    writeImageToPasteboard(image)
                    HistoryStore.shared.addImage(image)
                    Toast.shared.showImportant("长截图完成（\(Int(image.size.width))×\(Int(image.size.height))）已进剪贴板")
                case .failure(let msg):
                    Toast.shared.showImportant("长截图失败：\(msg)")
                }
            }
        }
    }

    private enum Outcome { case success(NSImage); case failure(String) }

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

    private func run(rect: CGRect, displayID: CGDirectDisplayID) async -> Outcome {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map({ CGDirectDisplayID($0.uint32Value) }) == displayID
        }) else { return .failure("找不到目标屏幕") }

        var frames: [(image: CGImage, sampler: StitchEngine.Sampler)] = []
        var offsets: [Int] = []

        for frame in 0..<maxFrames {
            if cancelled { break }
            guard let full = CGDisplayCreateImage(displayID),
                  let cropped = cropToRect(full, rect: rect, screen: screen),
                  let sampler = StitchEngine.Sampler(image: cropped) else {
                return .failure("截屏失败（第 \(frame + 1) 帧）")
            }
            if let last = frames.last {
                guard let offset = StitchEngine.scrollOffset(prev: last.sampler, next: sampler, maxSearch: maxSearch) else {
                    break   // 对齐失败：以已采集内容收尾
                }
                if offset == 0 { break }         // 页面到底
                offsets.append(offset)
            }
            frames.append((cropped, sampler))
            // 内存：Sampler 只在对齐相邻帧时有用，算完即弃（25 帧 RGBA 常驻可逼近 1GB）
            if frames.count > 1 { frames[frames.count - 2].sampler.data = [] }
            // 滚动一屏（线单位，负值 = 向下滚）
            let src = CGEventSource(stateID: .combinedSessionState)
            if let ev = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1,
                                wheel1: -10, wheel2: 0, wheel3: 0) {
                ev.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        guard let first = frames.first else { return .failure("未采集到帧") }
        guard frames.count > 1 else {
            // 只有 1 帧：页面无滚动，退化为普通截图
            return .success(NSImage(cgImage: first.image, size: CGSize(width: first.image.width, height: first.image.height)))
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
