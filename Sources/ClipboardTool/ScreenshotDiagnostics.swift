import AppKit

/// Test builds only. Geometry and pixel dimensions, never screen contents or window titles.
enum ScreenshotDiagnostics {
    private static var entries: [String] = []
    private static let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rubick-screenshot-layout.txt")
    static func begin() {
        guard Bundle.main.bundleIdentifier == "local.rubick.screenshot-test" else { return }
        entries = ["Screenshot layout \(Date())", "build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown")"]
        for screen in NSScreen.screens {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown"
            entries.append("display=\(id) frame=\(screen.frame) scale=\(screen.backingScaleFactor)")
        }
        flush()
    }
    static func captured(_ shots: [ScreenShot], union: CGRect, image: NSImage) {
        guard Bundle.main.bundleIdentifier == "local.rubick.screenshot-test" else { return }
        entries.append("union=\(union) compositePoints=\(image.size)")
        for shot in shots {
            entries.append("source frame=\(shot.frame) pixels=\(shot.image.width)x\(shot.image.height)")
        }
        flush()
    }
    static func windows(_ panels: [NSPanel], stage: String) {
        guard Bundle.main.bundleIdentifier == "local.rubick.screenshot-test" else { return }
        for (i, panel) in panels.enumerated() {
            entries.append("\(stage) panel[\(i)]=\(panel.frame) screen=\(String(describing: panel.screen?.frame))")
            if let root = panel.contentView {
                entries.append("root frame=\(root.frame) bounds=\(root.bounds)")
                for canvas in root.subviews {
                    entries.append("canvas frame=\(canvas.frame) bounds=\(canvas.bounds) visible=\(canvas.visibleRect)")
                }
            }
        }
        flush()
    }
    private static func flush() {
        try? entries.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
