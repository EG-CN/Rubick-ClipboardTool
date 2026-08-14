import AppKit

// MARK: - 区域截图（v1 方案 B：系统 screencapture -i -c，免屏幕录制权限）

final class ScreenshotController {
    static let shared = ScreenshotController()

    var onCaptured: ((NSImage) -> Void)?
    private var previousChangeCount = NSPasteboard.general.changeCount

    private init() {}

    func captureInteractive() {
        previousChangeCount = NSPasteboard.general.changeCount
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-c"]   // 交互框选 + 复制到剪贴板（不落盘）
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let pb = NSPasteboard.general
                // changeCount 未变 = 用户按 ⎋ 取消
                guard pb.changeCount != self.previousChangeCount else { return }
                if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
                   let img = NSImage(data: data) {
                    self.onCaptured?(img)
                }
            }
        }
        try? proc.run()
    }
}
