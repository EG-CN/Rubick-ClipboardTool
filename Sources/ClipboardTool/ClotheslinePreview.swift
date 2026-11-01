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
        let portrait = NSImage(size: CGSize(width: 220, height: 340), flipped: false) { rect in
            NSColor(calibratedRed: 0.90, green: 0.94, blue: 0.91, alpha: 1).setFill(); rect.fill()
            for i in 0..<6 {
                NSColor(calibratedRed: 0.25, green: 0.55, blue: 0.40, alpha: CGFloat(i + 3) / 9).setFill()
                NSBezierPath(roundedRect: CGRect(x: 20, y: 30 + i * 45, width: 180, height: 28), xRadius: 4, yRadius: 4).fill()
            }
            return true
        }
        store.addImage(portrait)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        store.addText("项目沟通记录\n\n这次改版让截图与文字按内容比例展示。\n横图、竖图和文字便签有不同尺寸。\n保持原始内容，拖入对话直接使用。")
        store.addText("好的，收到。\n我看完后回复你。")
        let files = root.appendingPathComponent("fixture-files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let md = files.appendingPathComponent("设计说明.md")
        let csv = files.appendingPathComponent("项目预算.csv")
        try "# 示例文件\n用于随手夹预览，不含用户内容。".write(to: md, atomically: true, encoding: .utf8)
        try "项目,预算\n设计,1000\n开发,2000".write(to: csv, atomically: true, encoding: .utf8)
        store.addFiles([md.path, csv.path])
        for expanded in [false, true] {
            let rect = CGRect(x: 0, y: 0, width: expanded ? 1512 : 96, height: expanded ? 416 : 26)
            let panel = ClotheslinePanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            let view = ClotheslineView(frame: rect, store: store); view.expanded = expanded
            panel.contentView = view
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: rect, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: root.appendingPathComponent(expanded ? "clothesline-expanded.png" : "clothesline-collapsed.png"))
            if expanded {
                view.updateHover(at: CGPoint(x: 200, y: 80))
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                view.cacheDisplay(in: rect, to: bitmap)
                if let hover = bitmap.representation(using: .png, properties: [:]) {
                    try hover.write(to: root.appendingPathComponent("clothesline-hover.png"))
                }
            }
            if expanded {
                view.updateHover(at: CGPoint(x: 109, y: 54))
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                view.cacheDisplay(in: rect, to: bitmap)
                if let hint = bitmap.representation(using: .png, properties: [:]) {
                    try hint.write(to: root.appendingPathComponent("clothesline-clip-hint.png"))
                }
            }
            panel.close()
        }
        store.saveNow()
    }
}
