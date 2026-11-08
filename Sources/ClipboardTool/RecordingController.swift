import AppKit
import AVFoundation
import AVKit
import os
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

private let recordLog = Logger(subsystem: "local.rubick.screenshot-test", category: "Record")

/// 区域录屏：SCRecordingOutput 直录 MP4（macOS 15+），控制条照效果图 ③，
/// 停止后进入预览导出窗（照效果图 ④：修剪 + GIF/MP4 导出）。
final class RecordingController: NSObject, SCStreamDelegate {

    static let shared = RecordingController()

    private var stream: SCStream?
    /// 15+ 类型用 Any 存引用（部署目标 14，属性不能用带可用性的类型）
    private var recording: Any?
    private var rect: CGRect = .zero
    private var controlPanel: NSPanel?
    private var controlView: RecordControlView?
    private var startedAt: Date?
    private var timer: Timer?
    private var exportWindow: NSWindow?
    private var movieURL: URL?

    private(set) var isRecording = false

    override private init() {}

    var directory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/拉比克", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// rect：AppKit 全局坐标（左下原点）的录制区域
    func start(rect: CGRect) {
        guard stream == nil else { return }
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
        }), let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            Toast.shared.showImportant("录屏：无法定位所在屏幕")
            return
        }
        self.rect = rect
        recordLog.notice("start rect=\(NSStringFromRect(rect))")
        FileTrace.log("record start rect=\(NSStringFromRect(rect))")

        let stamp = Self.stampFormatter.string(from: Date())
        let url = directory.appendingPathComponent("录屏 \(stamp).mp4")
        movieURL = url

        guard #available(macOS 15.0, *) else {
            Toast.shared.showImportant("录屏需要 macOS 15 及以上")
            return
        }
        Task { @MainActor in
            do {
                try await beginRecording(rect: rect, screen: screen, displayID: CGDirectDisplayID(num.uint32Value), url: url)
            } catch {
                recordLog.error("start failed: \(error.localizedDescription)")
                Toast.shared.showImportant("录屏启动失败：\(error.localizedDescription)")
                stream = nil; recording = nil; isRecording = false
            }
        }
    }

    /// 15+ 专属：SCRecordingOutput 直录 MP4 管线
    @available(macOS 15.0, *)
    @MainActor
    private func beginRecording(rect: CGRect, screen: NSScreen, displayID: CGDirectDisplayID, url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            Toast.shared.showImportant("录屏：找不到目标显示器")
            return
        }
        let scale = screen.backingScaleFactor
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // sourceRect 为显示器坐标（左上原点）：把 AppKit 底原点选区转成顶原点
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX,
                                   y: screen.frame.height - rect.maxY,
                                   width: rect.width, height: rect.height)
        config.width = max(Int((rect.width * scale).rounded()), 2)
        config.height = max(Int((rect.height * scale).rounded()), 2)
        config.showsCursor = true
        config.capturesAudio = false

        let outCfg = SCRecordingOutputConfiguration()
        outCfg.outputURL = url
        outCfg.videoCodecType = .hevc
        outCfg.outputFileType = .mp4
        let recording = SCRecordingOutput(configuration: outCfg, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try await stream.addRecordingOutput(recording)
        try await stream.startCapture()

        self.stream = stream
        self.recording = recording
        self.startedAt = Date()
        self.isRecording = true
        showControlBar(rect: rect)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            let secs = Int(Date().timeIntervalSince(startedAt))
            self.controlView?.seconds = secs
        }
        recordLog.notice("recording started → \(url.lastPathComponent)")
        FileTrace.log("record started → \(url.lastPathComponent)")
    }

    func stop(keepFile: Bool = true) {
        guard let stream = stream else { return }
        self.stream = nil
        timer?.invalidate(); timer = nil
        controlPanel?.orderOut(nil); controlPanel = nil
        controlView = nil
        let url = movieURL
        Task { @MainActor in
            try? await stream.stopCapture()
            // SCRecordingOutput 异步收尾文件，等 didFinish 回调后再弹导出窗
            if !keepFile { self.movieURL = nil }
            try? await Task.sleep(nanoseconds: 900_000_000)
            self.isRecording = false
            if keepFile, let url, FileManager.default.fileExists(atPath: url.path) {
                self.presentExport(url: url)
            }
        }
    }

    func restart() {
        let r = rect
        stop(keepFile: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.start(rect: r)
        }
    }

    // MARK: 控制条（效果图 ③）

    private func showControlBar(rect: CGRect) {
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
        }) else { return }
        let size = CGSize(width: 470, height: 56)
        let x = min(max(rect.midX - size.width / 2, screen.frame.minX + 12), screen.frame.maxX - size.width - 12)
        var y = rect.minY - size.height - 16
        if y < screen.frame.minY + 8 { y = rect.maxY + 16 }
        let view = RecordControlView(frame: NSRect(origin: .zero, size: size),
                                     onStop: { [weak self] in self?.stop(keepFile: true) },
                                     onRestart: { [weak self] in self?.restart() },
                                     onCamera: { Toast.shared.show("摄像头画中画：下一版本") })
        let panel = NSPanel(contentRect: CGRect(x: x, y: y, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        controlPanel = panel; controlView = view
    }

    // MARK: 预览导出窗（效果图 ④）

    private func presentExport(url: URL) {
        exportWindow?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "录屏预览"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: RecordingExportView(
            movieURL: url,
            region: rect,
            onClose: { [weak self] in self?.exportWindow?.close() },
            onReRecord: { [weak self] in
                self?.exportWindow?.close()
                self?.start(rect: self?.rect ?? .zero)
            }
        ))
        exportWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()
}

/// 录制控制条视图：红点 + 计时 + 停止/重录 + 摄像头占位
final class RecordControlView: NSView {
    var seconds = 0 { didSet { timerLabel.stringValue = Self.clock(seconds) } }
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let onStop: () -> Void
    private let onRestart: () -> Void
    private let onCamera: () -> Void

    init(frame: NSRect, onStop: @escaping () -> Void, onRestart: @escaping () -> Void, onCamera: @escaping () -> Void) {
        self.onStop = onStop; self.onRestart = onRestart; self.onCamera = onCamera
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.94).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.layer?.backgroundColor = NSColor(srgbRed: 0.94, green: 0.27, blue: 0.27, alpha: 1).cgColor
        dot.layer?.shadowColor = NSColor.red.cgColor
        dot.layer?.shadowOpacity = 0.8; dot.layer?.shadowRadius = 5

        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        timerLabel.textColor = .white

        let stack = NSStackView(views: [dot, timerLabel])
        stack.spacing = 12
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        func button(_ symbol: String, title: String, red: Bool = false, disabled: Bool = false, action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(),
                             target: self, action: action)
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 9
            b.layer?.backgroundColor = red ? NSColor(srgbRed: 0.94, green: 0.27, blue: 0.27, alpha: 1).cgColor
                                           : NSColor.white.withAlphaComponent(0.08).cgColor
            b.contentTintColor = red ? .white : NSColor.white.withAlphaComponent(0.85)
            if disabled { b.alphaValue = 0.4 }
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 34).isActive = true
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            return b
        }
        let stop = button("stop.fill", title: "停止", red: true, action: #selector(stopClicked))
        let restart = button("arrow.counterclockwise", title: "重新录制", action: #selector(restartClicked))
        let camera = button("video", title: "摄像头画中画", disabled: true, action: #selector(cameraClicked))
        let camLabel = NSTextField(labelWithString: "摄像头")
        camLabel.font = NSFont.systemFont(ofSize: 11.5)
        camLabel.textColor = .white.withAlphaComponent(0.5)
        let keyHint = NSTextField(labelWithString: "⌘⌥R 停止")
        keyHint.font = NSFont.systemFont(ofSize: 10.5)
        keyHint.textColor = .white.withAlphaComponent(0.4)

        let actions = NSStackView(views: [stop, restart, camera, camLabel, keyHint])
        actions.spacing = 10
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func stopClicked() { onStop() }
    @objc private func restartClicked() { onRestart() }
    @objc private func cameraClicked() { onCamera() }

    static func clock(_ secs: Int) -> String {
        String(format: "%02d:%02d", secs / 60, secs % 60)
    }
}

// MARK: - 预览导出窗（SwiftUI，效果图 ④）

struct RecordingExportView: View {
    let movieURL: URL
    let region: CGRect
    let onClose: () -> Void
    let onReRecord: () -> Void

    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var gifSelected = true
    @State private var thumbs: [NSImage] = []
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            playerSection
            trimSection
            formatRow
            pathRow
        }
        .frame(width: 880, height: 600)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.07, alpha: 1)))
        .task { await load() }
    }

    private var trimmedDuration: Double { max(0.5, trimEnd - trimStart) }

    private var playerSection: some View {
        PlayerRepresentable(url: movieURL)
            .frame(height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .padding(.top, 16)
    }

    private var trimSection: some View {
        HStack(spacing: 12) {
            VStack {
                Text(Self.clock(trimStart)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text("起点").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }.frame(width: 70)
            TrimBar(duration: duration, thumbs: thumbs, start: $trimStart, end: $trimEnd)
                .frame(height: 44)
            VStack {
                Text(Self.clock(trimEnd)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text("终点").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }.frame(width: 70)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var formatRow: some View {
        HStack(spacing: 14) {
            Picker("", selection: $gifSelected) {
                Text("GIF").tag(true)
                Text("MP4").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            Text(metaText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button("重新录制") { onReRecord() }
                .buttonStyle(.bordered)
            Button(gifSelected ? "导出 GIF" : "导出 MP4") { Task { await export() } }
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: NSColor(srgbRed: 0.063, green: 0.725, blue: 0.506, alpha: 1)))
                .disabled(exporting)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var metaText: String {
        gifSelected
            ? String(format: "15 fps · 宽 800 · 约 %.1f MB", trimmedDuration * 15 * 0.045)
            : "HEVC · 原始分辨率 · 60 fps"
    }

    private var pathRow: some View {
        Text("▸ MP4 原片已自动保存：\(movieURL.path) · 修剪后导出生成新文件")
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
    }

    private var targetURL: URL {
        movieURL.deletingPathExtension()
            .appendingPathComponent(" · 修剪")
            .appendingPathExtension(gifSelected ? "gif" : "mp4")
    }

    private func load() async {
        let asset = AVURLAsset(url: movieURL)
        let dur = (try? await asset.load(.duration)) ?? CMTime(seconds: 0, preferredTimescale: 600)
        duration = CMTimeGetSeconds(dur)
        trimEnd = duration
        // 12 张胶片缩略图
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 120, height: 70)
        var images: [NSImage] = []
        for i in 0..<12 {
            let t = duration * (Double(i) + 0.5) / 12
            if let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                images.append(NSImage(cgImage: cg, size: NSSize(width: 100, height: 56)))
            }
        }
        thumbs = images
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        let asset = AVURLAsset(url: movieURL)
        let out = targetURL
        try? FileManager.default.removeItem(at: out)
        if gifSelected {
            await exportGIF(asset: asset, to: out)
        } else {
            await exportMP4(asset: asset, to: out)
        }
        if FileManager.default.fileExists(atPath: out.path) {
            Toast.shared.showImportant("已导出：\(out.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([out])
            onClose()
        }
    }

    private func exportMP4(asset: AVURLAsset, to out: URL) async {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return }
        session.outputURL = out
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                                        end: CMTime(seconds: trimEnd, preferredTimescale: 600))
        try? await session.export(to: out, as: .mp4)
    }

    private func exportGIF(asset: AVURLAsset, to out: URL) async {
        let fps = 15
        let count = max(1, Int(trimmedDuration * Double(fps)))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 800, height: 4000)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else { return }
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]
        ]
        for i in 0..<count {
            let t = trimStart + Double(i) / Double(fps)
            guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
    }

    private static func clock(_ secs: Double) -> String {
        let s = Int(secs)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct PlayerRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.controlsStyle = .inline
        view.player?.play()
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

@available(macOS 15.0, *)
extension RecordingController: SCRecordingOutputDelegate {
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFinishRecordingWithError error: (any Error)?) {
        if let error {
            recordLog.error("didFinish with error: \(error.localizedDescription)")
        } else {
            recordLog.notice("didFinish recording OK")
        }
    }
}

/// 修剪胶片条：缩略图 + 黄色双拉手（照效果图 ④）
struct TrimBar: View {
    let duration: Double
    let thumbs: [NSImage]
    @Binding var start: Double
    @Binding var end: Double

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = geo.size.height
            let sx = w * start / max(duration, 0.001)
            let ex = w * end / max(duration, 0.001)
            ZStack(alignment: .leading) {
                HStack(spacing: 2) {
                    if thumbs.isEmpty {
                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06))
                    } else {
                        ForEach(thumbs.indices, id: \.self) { i in
                            Image(nsImage: thumbs[i])
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .clipped()
                        }
                    }
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Color.black.opacity(0.5).frame(width: sx)
                Color.black.opacity(0.5).frame(width: max(0, w - ex)).offset(x: ex)
                Rectangle().stroke(Color.yellow, lineWidth: 1.5)
                    .frame(width: max(10, ex - sx), height: h + 8)
                    .offset(x: sx)
                Circle().fill(Color.yellow).frame(width: 12, height: 12)
                    .offset(x: sx - 6)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trimBar")).onChanged { v in
                        start = min(max(0, v.location.x / w), end - 0.5) * duration
                    })
                Circle().fill(Color.yellow).frame(width: 12, height: 12)
                    .offset(x: ex - 6)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trimBar")).onChanged { v in
                        end = max(min(duration, v.location.x / w), start + 0.5) * duration
                    })
            }
        }
        .coordinateSpace(name: "trimBar")
    }
}
