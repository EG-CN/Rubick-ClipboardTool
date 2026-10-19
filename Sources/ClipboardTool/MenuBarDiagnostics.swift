import AppKit

/// Opt-in focus smoke check. Records window metadata, never desktop contents.
enum MenuBarDiagnostics {
    static func run(to path: String) {
        var records: [[String: Any]] = []
        func record(_ stage: String) {
            records.append([
                "stage": stage,
                "accessory": NSApp.activationPolicy() == .accessory,
                "keyWindowVisible": NSApp.keyWindow?.isVisible == true,
                "nonactivating": NSApp.keyWindow?.styleMask.contains(.nonactivatingPanel) == true,
                "textResponder": NSApp.keyWindow?.firstResponder is NSTextView
            ])
        }
        SettingsController.shared.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            record("settings")
            SettingsController.shared.close()
            HistoryPanelController.shared.show(fromHotkey: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                record("clipboard")
                HistoryPanelController.shared.close(restoresFocus: false)
                guard let screen = NSScreen.main else { return }
                let image = InlineScreenshotPreview.makeScene()
                image.size = screen.frame.size
                InlineScreenshotController.shared.show(image: image, union: screen.frame, windows: [])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    record("screenshot")
                    InlineScreenshotController.shared.close(restoreFocus: false)
                    SettingsController.shared.show()
                    if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                    }
                }
            }
        }
    }
}
