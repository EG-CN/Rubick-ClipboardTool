import AppKit

// MARK: - 区域截图（v2.0：CaptureController 自绘管线；系统框选作为回退保留）

final class ScreenshotController {
    static let shared = ScreenshotController()

    var onCaptured: ((NSImage) -> Void)?
    private var previousChangeCount = NSPasteboard.general.changeCount

    private init() {
        // v2.0：自绘截图/标注链路的最终产物统一从这里回调（AppDelegate 已接 onCaptured）
        CaptureController.shared.onCaptured = { [weak self] img in
            self?.onCaptured?(img)
        }
    }

    func captureInteractive() {
        CaptureController.shared.captureInteractive()
    }

    /// 系统框选回退（免屏幕录制权限，无吸附）；完成回调
    func captureSystemInteractive(completion: @escaping (NSImage?) -> Void) {
        previousChangeCount = NSPasteboard.general.changeCount
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-c"]   // 交互框选 + 复制到剪贴板（不落盘）
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else {
                    completion(nil)
                    return
                }
                let pb = NSPasteboard.general
                // changeCount 未变 = 用户按 ⎋ 取消
                guard pb.changeCount != self.previousChangeCount else {
                    completion(nil)
                    return
                }
                if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
                   let img = NSImage(data: data) {
                    completion(img)
                } else {
                    completion(nil)
                }
            }
        }
        try? proc.run()
    }
}
