import AppKit

// 菜单栏应用的入口：设置代理后进入 AppKit 主循环
// （SPM 可执行目标不能用 @main，需手动 NSApplicationMain）
let app = NSApplication.shared
if let index = CommandLine.arguments.firstIndex(of: "--clothesline-preview"), CommandLine.arguments.count > index + 1 {
    do { try ClotheslinePreview.render(to: CommandLine.arguments[index + 1]) }
    catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--ui-preview"), CommandLine.arguments.count > index + 1 {
    do { try UIPreview.render(to: CommandLine.arguments[index + 1]) }
    catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--inline-preview"), CommandLine.arguments.count > index + 1 {
    do { try InlineScreenshotPreview.render(to: CommandLine.arguments[index + 1]) }
    catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--inline-demo") || Bundle.main.bundleIdentifier == "local.rubick.inline-demo" {
    let image = InlineScreenshotPreview.makeScene()
    InlineScreenshotController.shared.show(image:image, union:CGRect(origin:.zero,size:image.size), windows:[])
    app.run()
} else {
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    withExtendedLifetime(appDelegate) {
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
