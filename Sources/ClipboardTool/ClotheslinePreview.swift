import AppKit

/// Synthetic content only; never writes fixtures into the user's history.
enum ClotheslinePreview {
    static func render(to directory: String) throws {
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HistoryStore(baseDir: root.appendingPathComponent("fixture-history"))
        store.addText("这版方案已更新，\n请看一下标注的位置。")
        store.addImage(InlineScreenshotPreview.makeScene())
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        store.addText("好的，收到。\n我看完后回复你。")
        for expanded in [false, true] {
            let rect = CGRect(x: 0, y: 0, width: 980, height: expanded ? 224 : 34)
            let panel = ClotheslinePanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            let view = ClotheslineView(frame: rect, store: store); view.expanded = expanded
            panel.contentView = view
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: rect, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: root.appendingPathComponent(expanded ? "clothesline-expanded.png" : "clothesline-collapsed.png"))
            panel.close()
        }
        store.saveNow()
    }
}
