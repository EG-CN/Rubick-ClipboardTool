import AppKit
import SwiftUI

/// Native layout previews with synthetic data and an isolated history directory.
enum UIPreview {
    static func render(to directory: String) throws {
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HistoryStore(baseDir: root.appendingPathComponent("fixture-history"))
        store.addText("项目讨论记录\n\n截图应在原地完成框选、标注和复制。\n文字默认红色，不显示背景。\n设置页面保留真实透明效果。", sourceApp: "com.apple.Notes")
        store.addText("https://example.com/design", sourceApp: "com.apple.Safari")
        store.addImage(InlineScreenshotPreview.makeScene(), sourceApp: "com.apple.Preview")
        store.addText("下一步：检查布局、快捷键和多屏截图。", sourceApp: "com.apple.Notes")
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            try snapshot(SettingsView().environmentObject(store).environment(\.colorScheme, scheme),
                         size: CGSize(width: 840, height: 590), to: root.appendingPathComponent("settings-\(suffix).png"))
            try snapshot(HistoryPanelView().environmentObject(store).environmentObject(PanelState()).environment(\.colorScheme, scheme),
                         size: CGSize(width: 920, height: 620), to: root.appendingPathComponent("clipboard-\(suffix).png"))
        }
        for pane in SettingsView.Pane.allCases where pane != .overview {
            try snapshot(SettingsView(initialPane: pane).environmentObject(store).environment(\.colorScheme, .light),
                         size: CGSize(width: 840, height: 590), to: root.appendingPathComponent("settings-\(pane.rawValue).png"))
        }
        try InlineScreenshotPreview.render(to: root.appendingPathComponent("screenshot.png").path)
    }

    private static func snapshot<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let rect = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        let host = NSHostingView(rootView: view)
        host.frame = rect
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: rect, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        window.close()
    }
}
