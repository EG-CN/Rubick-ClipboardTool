import AppKit
import SwiftUI

// MARK: - 应用代理：菜单栏状态项 + 服务装配

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let store = HistoryStore.shared
    private let monitor = ClipboardMonitor.shared
    private let hotkeys = HotkeyManager.shared
    private let panelController = HistoryPanelController.shared
    private let pinController = PinController.shared
    private let settingsController = SettingsController.shared
    private let screenshotController = ScreenshotController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 调试模式：打开标注编辑器并自拍截屏到 /tmp（诊断渲染问题用）
        if CommandLine.arguments.contains("--debug-editor-shot") {
            runDebugEditorShot()
            return
        }
        // 单实例握手：响应其他实例的探测
        DistributedNotificationCenter.default().addObserver(
            forName: .init("cbt.areYouRunning"), object: nil, queue: .main
        ) { _ in
            DistributedNotificationCenter.default().postNotificationName(
                .init("cbt.imRunning"), object: nil,
                userInfo: ["pid": ProcessInfo.processInfo.processIdentifier],
                deliverImmediately: true)
        }

        // 单实例：重复启动时直接退出（功能清单 5.4）
        if isDuplicateInstance() {
            NSApp.terminate(nil)
            return
        }

        // 纯菜单栏应用（不占 Dock）
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        panelController.statusButton = statusItem.button   // 面板锚定菜单栏图标
        wireServices()
        hotkeys.onAction = { [weak self] action in
            self?.handleHotkey(action)
        }

        // 首次启动引导辅助功能权限（模拟粘贴需要）
        if !AXIsProcessTrusted() {
            requestAccessibilityIfNeeded()
        }
    }

    /// 是否已有同应用实例在运行
    private func isDuplicateInstance() -> Bool {
        // 1) 分布式通知握手（可靠，不依赖进程枚举）
        let center = DistributedNotificationCenter.default()
        let myPID = ProcessInfo.processInfo.processIdentifier
        var gotReply = false
        var token: NSObjectProtocol?
        token = center.addObserver(forName: .init("cbt.imRunning"), object: nil, queue: .main) { note in
            if let pid = note.userInfo?["pid"] as? Int32, pid != myPID {
                gotReply = true
            }
        }
        center.postNotificationName(.init("cbt.areYouRunning"), object: nil,
                                    userInfo: ["pid": myPID], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(0.35)
        while Date() < deadline && !gotReply {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if let token = token { center.removeObserver(token) }
        if gotReply { return true }

        // 2) bundleID / 可执行路径比对兜底
        let myBundleID = Bundle.main.bundleIdentifier
        let myExec = Bundle.main.executableURL?.path
        let others = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != myPID else { return false }
            if let myBundleID = myBundleID, let bid = app.bundleIdentifier {
                return bid == myBundleID
            }
            return myExec != nil && app.executableURL?.path == myExec
        }
        return !others.isEmpty
    }

    /// 调试：生成彩色测试图 → 打开标注编辑器 → 应用自身权限截屏 → /tmp/rubick-editor.png
    private func runDebugEditorShot() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let img = Self.debugTestImage()
            AnnotationController.shared.show(image: img) { _ in }
            // 等视图 onAppear 设置 imageRect 后再注入（displaySize 需正确）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                AnnotationController.shared.debugAddSampleAnnotations()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                let screen = NSScreen.main ?? NSScreen.screens.first
                if let sid = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                   let cg = CGDisplayCreateImage(CGDirectDisplayID(sid.uint32Value)) {
                    let ns = NSImage(cgImage: cg, size: screen?.frame.size ?? .zero)
                    try? ns.pngData()?.write(to: URL(fileURLWithPath: "/tmp/rubick-editor.png"))
                }
                // 展平成品的验证图
                if let flat = AnnotationController.shared.debugFlattenedImage() {
                    try? flat.pngData()?.write(to: URL(fileURLWithPath: "/tmp/rubick-flattened.png"))
                }
                NSApp.terminate(nil)
            }
        }
    }

    static func debugTestImage() -> NSImage {
        let size = CGSize(width: 900, height: 560)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 560,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for i in 0..<12 {
            NSColor(hue: CGFloat(i) / 12.0, saturation: 0.65, brightness: 0.9, alpha: 1).setFill()
            NSRect(x: CGFloat(i % 4) * 225, y: CGFloat(i / 4) * 190, width: 225, height: 190).fill()
        }
        // 右下区域：平滑渐变 + 细字（马赛克/模糊效果验证区）
        let grad = NSGradient(colors: [NSColor.red, NSColor.blue, NSColor.yellow])!
        grad.draw(in: NSRect(x: 500, y: 30, width: 380, height: 200), angle: -45)
        let smallAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.black
        ]
        ("SECRET 12345 TOP SECRET" as NSString).draw(at: NSPoint(x: 520, y: 120), withAttributes: smallAttrs)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 42),
            .foregroundColor: NSColor.white
        ]
        ("RUBICK DEBUG IMAGE" as NSString).draw(at: NSPoint(x: 60, y: 120), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: 服务装配

    private func wireServices() {
        store.limit = UserDefaults.standard.object(forKey: "historyLimit") as? Int ?? 50
        monitor.ignorePasswordManagers = UserDefaults.standard.object(forKey: "ignorePassword") as? Bool ?? true
        monitor.onText = { [weak self] text in
            self?.store.addText(text)
        }
        monitor.onImage = { [weak self] img in
            self?.store.addImage(img)
        }
        monitor.start()
        screenshotController.onCaptured = { [weak self] img in
            self?.store.addImage(img)
            ShotActionBar.shared.show(image: img)   // 截图后可选直接钉图（功能清单 3.5）
        }
    }

    private func handleHotkey(_ action: HotkeyManager.Action) {
        switch action {
        case .togglePanel:
            panelController.toggle(fromHotkey: true)   // 快捷键呼出：面板跟随鼠标弹出
        case .screenshot:
            panelController.close()
            ShotActionBar.shared.hide()
            screenshotController.captureInteractive()
        case .dragTranslate:
            panelController.close()
            ShotActionBar.shared.hide()
            CaptureController.shared.captureForTranslation()
        case .openSettings:
            settingsController.toggle()
        }
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let glyph = NSImage(named: "menuGlyph") {
                glyph.isTemplate = true
                glyph.size = NSSize(width: 17, height: 17)
                button.image = glyph
            } else {
                button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "拉比克")
            }
            button.toolTip = "拉比克 · 剪贴板历史"
        }
        let menu = NSMenu()

        let panelItem = NSMenuItem(title: "打开历史面板", action: #selector(togglePanel), keyEquivalent: "v")
        panelItem.keyEquivalentModifierMask = [.command, .shift]
        panelItem.target = self
        menu.addItem(panelItem)

        let shotItem = NSMenuItem(title: "区域截图", action: #selector(captureScreenshot), keyEquivalent: "a")
        shotItem.keyEquivalentModifierMask = [.command, .shift]
        shotItem.target = self
        menu.addItem(shotItem)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "清空历史…", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出拉比克", action: #selector(quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: 菜单动作

    @objc private func togglePanel() {
        panelController.toggle()
    }

    @objc private func captureScreenshot() {
        panelController.close()
        screenshotController.captureInteractive()
    }

    @objc private func clearHistory() {
        confirmClearHistory()
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func quit() {
        pinController.unpinAll()
        NSApp.terminate(nil)
    }
}
