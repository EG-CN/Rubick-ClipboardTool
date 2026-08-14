import AppKit

// 菜单栏应用的入口：设置代理后进入 AppKit 主循环
// （SPM 可执行目标不能用 @main，需手动 NSApplicationMain）
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
