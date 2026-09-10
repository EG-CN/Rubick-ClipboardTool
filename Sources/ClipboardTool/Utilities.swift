import AppKit
import ApplicationServices
import UniformTypeIdentifiers

// MARK: - 剪贴板写入

func writeTextToPasteboard(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}

func writeImageToPasteboard(_ image: NSImage) {
    let pb = NSPasteboard.general
    pb.clearContents()
    // 同时声明 PNG/TIFF 字节 + NSImage 对象：部分 App（微信/浏览器富文本框）
    // 不读 NSImage 对象类型，只认具体图片字节类型
    pb.declareTypes([.png, .tiff], owner: nil)
    if let png = image.pngData() {
        pb.setData(png, forType: .png)
    }
    if let tiff = image.tiffRepresentation {
        pb.setData(tiff, forType: .tiff)
    }
    pb.writeObjects([image])
}

/// 复制应用内已有内容到剪贴板（抑制监听重复入册；历史由调用方显式维护）
func copyImageToClipboardSuppressingMonitor(_ image: NSImage) {
    ClipboardMonitor.shared.suppressNextCapture()
    writeImageToPasteboard(image)
}

// MARK: - 模拟粘贴（⌘V，需辅助功能权限）

func simulatePaste() {
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.03)
    up?.post(tap: .cghidEventTap)
}

// MARK: - 辅助功能权限（首次启动引导）

func requestAccessibilityIfNeeded() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}

// MARK: - 确认弹窗（清空历史）

func confirmClearHistory() {
    let alert = NSAlert()
    alert.messageText = "清空全部历史？"
    alert.informativeText = "将删除 \(HistoryStore.shared.items.count) 条记录，此操作不可撤销。已钉在桌面的贴图不受影响。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "清空")
    alert.addButton(withTitle: "取消")
    if alert.runModal() == .alertFirstButtonReturn {
        HistoryStore.shared.clear()
        Toast.shared.show("已清空历史")
    }
}

// MARK: - 另存为 PNG（钉图右键菜单）

func saveImageAsPng(_ image: NSImage) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "贴图-\(Int(image.size.width))x\(Int(image.size.height)).png"
    NSApp.activate(ignoringOtherApps: true)
    if panel.runModal() == .OK, let url = panel.url {
        try? image.pngData()?.write(to: url)
    }
}
