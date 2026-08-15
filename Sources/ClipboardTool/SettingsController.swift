import AppKit
import SwiftUI
import ServiceManagement
import Combine
import Carbon.HIToolbox

// MARK: - 设置窗口

final class SettingsController {
    static let shared = SettingsController()

    private var window: NSWindow?

    private init() {}

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    func show() {
        if window == nil {
            let host = NSHostingView(rootView: SettingsView().environmentObject(HistoryStore.shared))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "设置"
            w.titlebarAppearsTransparent = true
            w.contentView = host
            w.center()
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
    }
}

// MARK: - 快捷键录制器（全局 + 面板内两类）

enum RecorderTarget: Equatable {
    case global(HotkeyManager.Action)
    case panel(PanelKeyConfig.PanelAction)
    case annotate(AnnotateKeyConfig.Action)
}

final class HotkeyRecorder: ObservableObject {
    static let shared = HotkeyRecorder()

    @Published var target: RecorderTarget?
    @Published var errorMessage: String?
    @Published var version = 0

    private var monitor: Any?

    private init() {}

    var isRecording: Bool { target != nil }

    func start(_ t: RecorderTarget) {
        stop(notify: false)
        target = t
        errorMessage = nil
        version += 1
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func stop(notify: Bool = true) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        target = nil
        errorMessage = nil
        if notify { version += 1 }
    }

    private func fail(_ msg: String) {
        errorMessage = msg
        version += 1
    }

    private func handle(_ event: NSEvent) {
        guard let t = target else { return }
        if event.keyCode == 53 { stop(); return } // ⎋ 取消录制

        let mods = carbonModifiers(event.modifierFlags)
        let keyCode = UInt32(event.keyCode)
        let display = comboDisplay(modifiers: mods, keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)

        switch t {
        case .global(let action):
            recordGlobal(action, event: event, mods: mods, keyCode: keyCode, display: display)
        case .panel(let action):
            recordPanel(action, event: event, mods: mods, keyCode: keyCode, display: display)
        case .annotate(let action):
            recordAnnotate(action, event: event, mods: mods, keyCode: keyCode, display: display)
        }
    }

    // MARK: 全局快捷键校验

    private func recordGlobal(_ action: HotkeyManager.Action, event: NSEvent, mods: UInt32, keyCode: UInt32, display: String) {
        guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            fail("全局快捷键需包含 ⌘ / ⌥ / ⌃ 修饰键")
            return
        }
        for (other, hk) in HotkeyManager.shared.hotkeys
        where other != action && hk.keyCode == keyCode && hk.modifiers == mods {
            fail("与「\(actionLabel(other))」冲突，请换一个组合")
            return
        }
        // 与面板内快捷键交叉冲突
        for (other, k) in PanelKeyConfig.shared.keys
        where !k.quick && UInt32(k.keyCode) == keyCode && k.mods == mods {
            fail("与面板内「\(PanelKeyConfig.shared.label(other))」冲突，请换一个组合")
            return
        }
        // 系统保留组合
        let reservedKeyCodes: [UInt16] = [UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_Tab), UInt16(kVK_Space)]
        let reservedMods: [UInt32] = [
            UInt32(cmdKey | shiftKey), UInt32(cmdKey | shiftKey), UInt32(cmdKey | shiftKey),
            UInt32(cmdKey), UInt32(cmdKey)
        ]
        let reservedNames: [String] = ["系统截图", "系统截图", "系统截图", "系统应用切换器", "Spotlight 搜索"]
        for (i, rc) in reservedKeyCodes.enumerated() where UInt32(rc) == keyCode && reservedMods[i] == mods {
            fail("已被系统占用：\(reservedNames[i])")
            return
        }
        HotkeyManager.shared.update(action, keyCode: keyCode, modifiers: mods, display: display)
        Toast.shared.show("已更新：\(actionLabel(action)) → \(display)")
        stop()
    }

    // MARK: 面板内快捷键校验

    private func recordPanel(_ action: PanelKeyConfig.PanelAction, event: NSEvent, mods: UInt32, keyCode: UInt32, display: String) {
        // 快速选择：必须是 ⌘+数字（1–9）
        if action == .quick {
            guard event.modifierFlags.contains(.command), mods == UInt32(cmdKey),
                  let n = PanelKeyConfig.shared.quickDigit(event), (1...9).contains(n) else {
                fail("需使用 ⌘+数字（1–9）")
                return
            }
            PanelKeyConfig.shared.update(action, keyCode: event.keyCode, mods: mods, display: "⌘1–9", quick: true)
            Toast.shared.show("已更新：\(PanelKeyConfig.shared.label(action)) → ⌘1–9")
            stop()
            return
        }
        for (other, k) in PanelKeyConfig.shared.keys
        where other != action && !k.quick && UInt32(k.keyCode) == keyCode && k.mods == mods {
            fail("与「\(PanelKeyConfig.shared.label(other))」冲突，请换一个")
            return
        }
        for (other, hk) in HotkeyManager.shared.hotkeys
        where hk.keyCode == keyCode && hk.modifiers == mods {
            fail("与「\(actionLabel(other))」冲突，请换一个")
            return
        }
        PanelKeyConfig.shared.update(action, keyCode: event.keyCode, mods: mods, display: display, quick: false)
        Toast.shared.show("已更新：\(PanelKeyConfig.shared.label(action)) → \(display)")
        stop()
    }

    // MARK: 标注编辑器快捷键校验（仅标注编辑器内生效，独立上下文不与其他类交叉冲突）

    private func recordAnnotate(_ action: AnnotateKeyConfig.Action, event: NSEvent, mods: UInt32, keyCode: UInt32, display: String) {
        for (other, k) in AnnotateKeyConfig.shared.keys
        where other != action && k.keyCode == UInt16(keyCode) && k.mods == mods {
            fail("与「\(AnnotateKeyConfig.shared.label(other))」冲突，请换一个")
            return
        }
        AnnotateKeyConfig.shared.update(action, keyCode: UInt16(keyCode), mods: mods, display: display)
        Toast.shared.show("已更新：\(AnnotateKeyConfig.shared.label(action)) → \(display)")
        stop()
    }
}

func actionLabel(_ action: HotkeyManager.Action) -> String {
    switch action {
    case .togglePanel: return "呼出历史面板"
    case .screenshot: return "区域截图"
    case .openSettings: return "打开设置"
    case .dragTranslate: return "划图翻译（选区识别+翻译）"
    }
}

// MARK: - 设置视图（Stitch 设计还原：侧边栏 + 品牌头 + 卡片分组）

struct SettingsView: View {
    @EnvironmentObject var store: HistoryStore
    @ObservedObject var recorder = HotkeyRecorder.shared
    @ObservedObject var panelKeys = PanelKeyConfig.shared
    @Environment(\.colorScheme) private var scheme
    @State private var pane: Pane = .general
    @State private var autoLaunch = false
    @State private var ignorePassword = ClipboardMonitor.shared.ignorePasswordManagers
    @State private var pasteAuto = UserDefaults.standard.object(forKey: "pasteAuto") as? Bool ?? true
    @State private var keepOpen = UserDefaults.standard.object(forKey: "keepPanelOpen") as? Bool ?? true
    @State private var limit: Int = HistoryStore.shared.limit
    @State private var trusted = AXIsProcessTrusted()
    @State private var translateEngine = UserDefaults.standard.string(forKey: "translate.engine") ?? "apple"
    @State private var translateDirection = UserDefaults.standard.string(forKey: "translate.direction") ?? "auto"
    @State private var llmBaseURL = UserDefaults.standard.string(forKey: "llm.baseURL") ?? ""
    @State private var llmModel = UserDefaults.standard.string(forKey: "llm.model") ?? ""
    @State private var llmKey = UserDefaults.standard.string(forKey: "llm.apiKey") ?? ""
    @State private var ocrLang = UserDefaults.standard.string(forKey: "ocr.language") ?? "auto"
    @State private var snapOn = UserDefaults.standard.object(forKey: "capture.snap") as? Bool ?? false
    @State private var snapThreshold: Double = UserDefaults.standard.object(forKey: "capture.snapThreshold") as? Double ?? 8
    @State private var captureMode = UserDefaults.standard.string(forKey: "capture.mode") ?? "auto"
    @State private var llmTesting = false

    enum Pane: String, CaseIterable {
        case general = "通用", hotkeys = "快捷键", history = "历史", smart = "智能识别", about = "关于"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .hotkeys: return "keyboard"
            case .history: return "clock.arrow.circlepath"
            case .smart: return "text.viewfinder"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.5)
            content
        }
        .frame(width: 680, height: 600)
        .background(.ultraThinMaterial)
        .background(RubickTheme.darkBackground.opacity(scheme == .dark ? 0.5 : 0))
        .onAppear {
            autoLaunch = SMAppService.mainApp.status == .enabled
            trusted = AXIsProcessTrusted()
        }
    }

    // MARK: 侧边栏

    @ViewBuilder
    private func brandEmblem(_ size: CGFloat) -> some View {
        if let icon = NSImage(named: "AppIcon") {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.26))
                .overlay(RoundedRectangle(cornerRadius: size * 0.26)
                    .strokeBorder(RubickTheme.primary(scheme).opacity(0.35), lineWidth: 1))
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.45))
                .foregroundStyle(RubickTheme.primary(scheme))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.26).fill(RubickTheme.primary(scheme).opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: size * 0.26).strokeBorder(RubickTheme.primary(scheme).opacity(0.35), lineWidth: 1))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    brandEmblem(34)
                    Text("拉比克")
                        .font(.system(size: 17, weight: .bold))
                }
                Text("大魔导师版")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(RubickTheme.primary(scheme).opacity(0.8))
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(Pane.allCases, id: \.self) { p in
                    Button {
                        pane = p
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: p.icon)
                                .font(.system(size: 12))
                                .frame(width: 18)
                            Text(p.rawValue)
                                .font(.system(size: 12.5))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(pane == p
                                                                           ? RubickTheme.primary(scheme).opacity(0.12)
                                                                           : Color.clear))
                        .overlay(alignment: .trailing) {
                            if pane == p {
                                Capsule().fill(RubickTheme.primary(scheme))
                                    .frame(width: 3, height: 16)
                                    .padding(.trailing, 3)
                            }
                        }
                        .foregroundStyle(pane == p ? RubickTheme.primary(scheme) : RubickTheme.muted(scheme))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            Button {
                confirmClearHistory()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                    Text("清除奥术缓存")
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(RubickTheme.surfaceHigh(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5))
                .foregroundStyle(RubickTheme.muted(scheme))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 200)
    }

    // MARK: 内容区

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .general: generalPane
        case .hotkeys: hotkeysPane
        case .history: historyPane
        case .smart: smartPane
        case .about: aboutPane
        }
    }

    private func paneHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(RubickTheme.muted(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private func settingCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .glowCard(hovering: false, cornerRadius: 10)
            .padding(.horizontal, 2)
    }

    private var toggleStyle: some ToggleStyle { .switch }

    // MARK: 通用

    private var generalPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                paneHeader("通用设置", subtitle: "管理核心行为与环境魔法。")
                settingCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("开机自启动", isOn: $autoLaunch)
                            .toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                            .onChange(of: autoLaunch) { newValue in
                                do {
                                    if newValue { try SMAppService.mainApp.register() }
                                    else { try SMAppService.mainApp.unregister() }
                                } catch {
                                    autoLaunch = SMAppService.mainApp.status == .enabled
                                }
                            }
                        Text("登录后自动在后台运行，随时呼出。")
                            .font(.system(size: 10.5)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
                settingCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("点选条目后自动粘贴", isOn: $pasteAuto)
                            .toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                            .onChange(of: pasteAuto) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "pasteAuto")
                            }
                        Text("关闭后点选仅复制，需手动 ⌘V。")
                            .font(.system(size: 10.5)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
                settingCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("粘贴后保持面板打开", isOn: $keepOpen)
                            .toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                            .onChange(of: keepOpen) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "keepPanelOpen")
                            }
                        Text("开启后可连续粘贴多条，按 ⎋ 关闭；按住 ⌥ 点击条目可仅复制。")
                            .font(.system(size: 10.5)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
                settingCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("忽略密码管理器内容", isOn: $ignorePassword)
                            .toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                            .onChange(of: ignorePassword) { newValue in
                                ClipboardMonitor.shared.ignorePasswordManagers = newValue
                            }
                        Text("识别 1Password 等复制内容的隐私标记，不入历史。")
                            .font(.system(size: 10.5)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
                settingCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("辅助功能权限（自动粘贴）")
                                    .font(.system(size: 12.5))
                                Text(trusted ? "已授权，点选条目将直接粘贴到输入框" : "未授权，点选仅复制，需手动 ⌘V")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(RubickTheme.muted(scheme))
                            }
                            Spacer()
                            if trusted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(RubickTheme.emerald)
                            } else {
                                Button("打开系统设置") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(RubickTheme.emerald)
                            }
                        }
                        Text("授权后需重启应用，自动粘贴才会生效。")
                            .font(.system(size: 10)).foregroundStyle(RubickTheme.muted(scheme).opacity(0.7))
                    }
                }
                settingCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("屏幕录制权限（自绘截图 + 窗口吸附）")
                                    .font(.system(size: 12.5))
                                Text(CaptureController.screenRecordingAllowed()
                                     ? "已授权，截图使用自绘选框并支持窗口吸附"
                                     : "未授权，截图自动回退系统框选（无吸附）；重新授权后打开设置页刷新")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(RubickTheme.muted(scheme))
                            }
                            Spacer()
                            if CaptureController.screenRecordingAllowed() {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(RubickTheme.emerald)
                            } else {
                                Button("打开系统设置") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(RubickTheme.emerald)
                            }
                        }
                    }
                }
                settingCard {
                    HStack {
                        Text("外观").font(.system(size: 12.5))
                        Spacer()
                        Picker("", selection: themeBinding) {
                            Text("跟随系统").tag("system")
                            Text("浅色").tag("light")
                            Text("深色").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                }
            }
            .padding(16)
        }
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.object(forKey: "theme") as? String ?? "system" },
            set: { v in
                UserDefaults.standard.set(v, forKey: "theme")
                if v == "system" { NSApp.appearance = nil } else {
                    NSApp.appearance = NSAppearance(named: v == "dark" ? .darkAqua : .aqua)
                }
            }
        )
    }

    // MARK: 快捷键

    private var hotkeysPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                paneHeader("快捷键", subtitle: "所有快捷键均可自定义。点击「录制」后按下新组合键。")
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("全局快捷键")
                    VStack(spacing: 0) {
                        ForEach(HotkeyManager.Action.allCases, id: \.rawValue) { action in
                            globalRow(action)
                            Divider().opacity(0.4)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(RubickTheme.surfaceHigh(scheme)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("面板内快捷键（面板打开时生效）")
                    VStack(spacing: 0) {
                        ForEach(PanelKeyConfig.PanelAction.allCases, id: \.rawValue) { action in
                            panelRow(action)
                            Divider().opacity(0.4)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(RubickTheme.surfaceHigh(scheme)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("标注编辑器快捷键（截图标注时生效）")
                    VStack(spacing: 0) {
                        ForEach(AnnotateKeyConfig.Action.allCases, id: \.rawValue) { action in
                            annotateRow(action)
                            Divider().opacity(0.4)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(RubickTheme.surfaceHigh(scheme)))
                }
                if let err = recorder.errorMessage {
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("全部恢复默认") {
                        for action in HotkeyManager.Action.allCases {
                            HotkeyManager.shared.reset(action)
                        }
                        for action in PanelKeyConfig.PanelAction.allCases {
                            PanelKeyConfig.shared.reset(action)
                        }
                        for action in AnnotateKeyConfig.Action.allCases {
                            AnnotateKeyConfig.shared.reset(action)
                        }
                        recorder.stop()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(RubickTheme.emerald)
                }
            }
            .padding(16)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(RubickTheme.muted(scheme))
            .padding(.top, 4)
    }

    private func keyDisplay(_ text: String, recording: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(RubickTheme.surfaceHigh(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                recording ? RubickTheme.primary(scheme) : Color.primary.opacity(0.12), lineWidth: 1))
            .foregroundStyle(recording ? RubickTheme.primary(scheme) : RubickTheme.onSurface(scheme))
    }

    private func globalRow(_ action: HotkeyManager.Action) -> some View {
        let hotkey = HotkeyManager.shared.hotkeys[action]!
        let isRec = recorder.target == .global(action)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(actionLabel(action)).font(.system(size: 12.5))
                Text("全局").font(.system(size: 10)).foregroundStyle(RubickTheme.muted(scheme))
            }
            Spacer()
            keyDisplay(isRec ? "请按下新快捷键…" : hotkey.display, recording: isRec)
            Button(isRec ? "取消" : "录制") {
                if isRec { recorder.stop() } else { recorder.start(.global(action)) }
            }
            .buttonStyle(.bordered).controlSize(.small).tint(RubickTheme.emerald)
            Button("恢复默认") {
                HotkeyManager.shared.reset(action)
                recorder.stop()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func panelRow(_ action: PanelKeyConfig.PanelAction) -> some View {
        let key = PanelKeyConfig.shared.keys[action]!
        let isRec = recorder.target == .panel(action)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(PanelKeyConfig.shared.label(action)).font(.system(size: 12.5))
                Text("面板内").font(.system(size: 10)).foregroundStyle(RubickTheme.muted(scheme))
            }
            Spacer()
            keyDisplay(isRec ? "请按下新快捷键…" : key.display, recording: isRec)
            Button(isRec ? "取消" : "录制") {
                if isRec { recorder.stop() } else { recorder.start(.panel(action)) }
            }
            .buttonStyle(.bordered).controlSize(.small).tint(RubickTheme.emerald)
            Button("恢复默认") {
                PanelKeyConfig.shared.reset(action)
                recorder.stop()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func annotateRow(_ action: AnnotateKeyConfig.Action) -> some View {
        let key = AnnotateKeyConfig.shared.keys[action]!
        let isRec = recorder.target == .annotate(action)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(AnnotateKeyConfig.shared.label(action)).font(.system(size: 12.5))
                Text("标注内").font(.system(size: 10)).foregroundStyle(RubickTheme.muted(scheme))
            }
            Spacer()
            keyDisplay(isRec ? "请按下新快捷键…" : key.display, recording: isRec)
            Button(isRec ? "取消" : "录制") {
                if isRec { recorder.stop() } else { recorder.start(.annotate(action)) }
            }
            .buttonStyle(.bordered).controlSize(.small).tint(RubickTheme.emerald)
            Button("恢复默认") {
                AnnotateKeyConfig.shared.reset(action)
                recorder.stop()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: 历史

    private var historyPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                paneHeader("历史", subtitle: "奥术历史中保留的条目数。")
                settingCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("法术容量").font(.system(size: 12.5))
                            Text("超出后按时间淘汰最旧条目。")
                                .font(.system(size: 10.5)).foregroundStyle(RubickTheme.muted(scheme))
                        }
                        Spacer()
                        Picker("", selection: $limit) {
                            Text("50 条").tag(50)
                            Text("100 条").tag(100)
                            Text("200 条").tag(200)
                            Text("500 条").tag(500)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 110)
                        .onChange(of: limit) { newValue in
                            store.limit = newValue
                        }
                    }
                }
                settingCard {
                    HStack {
                        Text("当前共 \(store.items.count) 条记录")
                            .font(.system(size: 11.5))
                            .foregroundStyle(RubickTheme.muted(scheme))
                        Spacer()
                        Button("清空历史…", role: .destructive) {
                            confirmClearHistory()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: 智能识别（v2.0）

    private var smartPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                paneHeader("智能识别", subtitle: "翻译与 OCR 均本地优先；大模型为可选增强。")
                settingCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("翻译引擎").font(.system(size: 12.5))
                            Spacer()
                            Picker("", selection: $translateEngine) {
                                Text("Apple 离线").tag("apple")
                                Text("大模型").tag("llm")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                            .onChange(of: translateEngine) { v in
                                UserDefaults.standard.set(v, forKey: "translate.engine")
                            }
                        }
                        HStack {
                            Text("翻译方向").font(.system(size: 12.5))
                            Spacer()
                            Picker("", selection: $translateDirection) {
                                Text(TranslateDirection.auto.label).tag(TranslateDirection.auto.rawValue)
                                Text(TranslateDirection.zhToEn.label).tag(TranslateDirection.zhToEn.rawValue)
                                Text(TranslateDirection.enToZh.label).tag(TranslateDirection.enToZh.rawValue)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 180)
                            .onChange(of: translateDirection) { v in
                                UserDefaults.standard.set(v, forKey: "translate.direction")
                            }
                        }
                        Text("Apple 离线翻译完全免费、不上传；大模型翻译质量更高，需自行配置接口。")
                            .font(.system(size: 10.5)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
                settingCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("大模型接口（OpenAI 兼容）")
                            .font(.system(size: 12.5, weight: .semibold))
                        TextField("接口地址（如 https://api.xiaomimimo.com/v1）", text: $llmBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .onChange(of: llmBaseURL) { v in UserDefaults.standard.set(v, forKey: "llm.baseURL") }
                        TextField("模型名（如 mimo-v2.5）", text: $llmModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .onChange(of: llmModel) { v in UserDefaults.standard.set(v, forKey: "llm.model") }
                        SecureField("API Key", text: $llmKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .onChange(of: llmKey) { v in UserDefaults.standard.set(v, forKey: "llm.apiKey") }
                        HStack {
                            Text("Key 仅保存在本机 UserDefaults，不随历史同步。")
                                .font(.system(size: 10)).foregroundStyle(RubickTheme.muted(scheme).opacity(0.8))
                            Spacer()
                            Button(llmTesting ? "测试中…" : "测试连接") {
                                testLLM()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(RubickTheme.emerald)
                            .disabled(llmTesting || llmBaseURL.isEmpty || llmModel.isEmpty || llmKey.isEmpty)
                        }
                    }
                }
                settingCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("OCR 识别语言").font(.system(size: 12.5))
                            Spacer()
                            Picker("", selection: $ocrLang) {
                                ForEach(OCRLanguage.allCases, id: \.rawValue) { l in
                                    Text(l.label).tag(l.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 150)
                            .onChange(of: ocrLang) { v in
                                UserDefaults.standard.set(v, forKey: "ocr.language")
                            }
                        }
                        Text("OCR 由系统 Vision 引擎在本机完成，离线、免费、无次数限制。")
                            .font(.system(size: 10.5)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
                settingCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("窗口吸附", isOn: $snapOn)
                            .toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                            .onChange(of: snapOn) { v in UserDefaults.standard.set(v, forKey: "capture.snap") }
                        Text("实验性功能，默认关闭。开启后：悬停窗口高亮、单击直截整窗、选框边缘自动吸附窗口边界。")
                            .font(.system(size: 10.5)).foregroundStyle(RubickTheme.muted(scheme))
                        HStack {
                            Text("吸附阈值").font(.system(size: 12.5))
                            Spacer()
                            Slider(value: $snapThreshold, in: 2...16, step: 1)
                                .frame(width: 180)
                                .onChange(of: snapThreshold) { v in
                                    UserDefaults.standard.set(v, forKey: "capture.snapThreshold")
                                }
                            Text("\(Int(snapThreshold)) pt")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(RubickTheme.muted(scheme))
                                .frame(width: 40)
                        }
                        HStack {
                            Text("截图模式").font(.system(size: 12.5))
                            Spacer()
                            Picker("", selection: $captureMode) {
                                Text("自动").tag("auto")
                                Text("自绘选框").tag("custom")
                                Text("系统框选").tag("system")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                            .onChange(of: captureMode) { v in
                                UserDefaults.standard.set(v, forKey: "capture.mode")
                            }
                        }
                        Text("自动：已授权屏幕录制 → 自绘（含吸附），否则回退系统框选；标注编辑器两种模式都可用。")
                            .font(.system(size: 10.5)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
            }
            .padding(16)
        }
    }

    private func testLLM() {
        llmTesting = true
        let cfg = LLMConfig(baseURL: llmBaseURL, model: llmModel, apiKey: llmKey)
        guard let req = try? TranslationService.llmRequest(config: cfg, systemPrompt: "ping", userText: "ping") else {
            llmTesting = false
            Toast.shared.show("接口地址无效")
            return
        }
        URLSession.shared.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async {
                llmTesting = false
                if err == nil, let data = data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   obj["choices"] != nil {
                    Toast.shared.show("连接成功 · 大模型可用")
                } else {
                    Toast.shared.show("连接失败：\(err?.localizedDescription ?? "响应异常")")
                }
            }
        }.resume()
    }

    // MARK: 关于

    private var aboutPane: some View {
        VStack(spacing: 10) {
            brandEmblem(72)
                .padding(.top, 40)
            Text("拉比克").font(.system(size: 17, weight: .bold))
            Text("RubickBoard · 大魔导师版")
                .font(.system(size: 10.5, weight: .medium))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(RubickTheme.primary(scheme).opacity(0.85))
            Text("版本 2.0.0")
                .font(.system(size: 11))
                .foregroundStyle(RubickTheme.muted(scheme))
            Text("菜单栏常驻的剪贴板历史与截图钉图工具。\n偷取（复制）、施展（粘贴）、铭刻（钉图），尽在魔典之中。\nSwift + SwiftUI 原生开发，数据仅保存在本机。")
                .font(.system(size: 11.5))
                .foregroundStyle(RubickTheme.muted(scheme))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
