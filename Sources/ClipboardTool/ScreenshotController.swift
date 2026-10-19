import AppKit

// MARK: - 区域截图（v2.0：CaptureController 自绘管线；系统框选作为回退保留）

final class ScreenshotController {
    static let shared = ScreenshotController()

    var onCaptured: ((NSImage) -> Void)?

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
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rubick-capture-" + UUID().uuidString + ".png")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-o", "-t", "png", file.path]
        proc.terminationHandler = { _ in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: file) }
                completion(NSImage(contentsOf: file))
            }
        }
        do { try proc.run() }
        catch {
            try? FileManager.default.removeItem(at: file)
            completion(nil)
        }
    }
}
