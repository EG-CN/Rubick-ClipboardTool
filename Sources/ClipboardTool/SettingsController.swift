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
            let w = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
                             styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = false
            w.level = .normal
            w.title = "拉比克设置"
            w.isOpaque = false
            w.backgroundColor = .clear
            w.minSize = NSSize(width: 800, height: 580)
            w.titlebarAppearsTransparent = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = host
            w.center()
            w.isReleasedWhenClosed = false
            window = w
            // 关窗即退出录制态：录制器的本地 keyDown 监控会无条件吞键，
            // 不随窗口关闭清理的话整个 App 对键盘"死机"（P0）
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w,
                                                   queue: .main) { [weak self] _ in
                guard let self = self, self.window === w else { return }
                HotkeyRecorder.shared.stop(notify: false)
                ActivationPolicyKeeper.shared.release("settings")
            }
        }
        ActivationPolicyKeeper.shared.acquire("settings")
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        HotkeyRecorder.shared.stop(notify: false)   // orderOut 不发 willCloseNotification，录制态在这里兜底清理
        window?.orderOut(nil)
        ActivationPolicyKeeper.shared.release("settings")
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
    case .pinClipboard: return "钉剪贴板贴图（Snipaste F3 式）"
    case .dragOCR: return "划图取字（选区识别→复制）"
    case .longScreenshot: return "长截图（实验 · 默认关闭，在此开启后可用 ⌘⇧L）"
    case .screenRecord: return "录屏（区域录制 · 导出 GIF/MP4）"
    case .delayedScreenshot: return "延时截图（倒计时后框选）"
    }
}

// MARK: - 设置视图（Stitch 设计还原：侧边栏 + 品牌头 + 卡片分组）

struct SettingsView: View {
    @EnvironmentObject var store: HistoryStore
    @ObservedObject var recorder = HotkeyRecorder.shared
    @ObservedObject var panelKeys = PanelKeyConfig.shared
    @Environment(\.colorScheme) private var scheme
    @State private var pane: Pane = .overview
    @State private var autoLaunch = false
    @AppStorage("interaction.haptics") private var hapticsEnabled = true
    @State private var ignorePassword = ClipboardMonitor.shared.ignorePasswordManagers
    @State private var pasteAuto = UserDefaults.standard.object(forKey: "pasteAuto") as? Bool ?? true
    @State private var panelForm = UserDefaults.standard.string(forKey: "panel.form") ?? "panel"
    @State private var autoRetract = UserDefaults.standard.object(forKey: "clothesline.autoRetract") as? Bool ?? true
    @State private var ropeMaxWidth = UserDefaults.standard.object(forKey: "clothesline.maxWidth") as? Double ?? 60
    @State private var cardTilt = UserDefaults.standard.object(forKey: "clothesline.tilt") as? Double ?? 3
    @State private var keepOpen = UserDefaults.standard.object(forKey: "keepPanelOpen") as? Bool ?? true
    @State private var limit: Int = HistoryStore.shared.limit
    @State private var trusted = AXIsProcessTrusted()
    @State private var screenAllowed = CaptureController.screenRecordingAllowed()
    @State private var translateEngine = UserDefaults.standard.string(forKey: "translate.engine") ?? "apple"
    @State private var translateDirection = UserDefaults.standard.string(forKey: "translate.direction") ?? "auto"
    @State private var llmBaseURL = UserDefaults.standard.string(forKey: "llm.baseURL") ?? ""
    @State private var llmModel = UserDefaults.standard.string(forKey: "llm.model") ?? ""
    @State private var llmKey = UserDefaults.standard.string(forKey: "llm.apiKey") ?? ""
    @State private var ocrLang = UserDefaults.standard.string(forKey: "ocr.language") ?? "auto"
    @State private var snapOn = UserDefaults.standard.object(forKey: "capture.snap") as? Bool ?? false
    @State private var snapThreshold: Double = UserDefaults.standard.object(forKey: "capture.snapThreshold") as? Double ?? 8
    @State private var captureMode = UserDefaults.standard.string(forKey: "capture.mode") ?? "auto"
    @State private var pinScale: Double = UserDefaults.standard.object(forKey: "pin.defaultScale") as? Double ?? 0.7
    @State private var longShot = UserDefaults.standard.object(forKey: "capture.longShot") as? Bool ?? true
    @State private var delaySeconds = UserDefaults.standard.object(forKey: "capture.delaySeconds") as? Int ?? 3
    @State private var rememberPosition = UserDefaults.standard.object(forKey: "panel.rememberPosition") as? Bool ?? true
    @State private var llmTesting = false

    enum Pane: String, CaseIterable {
        case overview = "概览", general = "通用", history = "剪贴板", capture = "截图与钉图", hotkeys = "快捷键", smart = "识别与翻译", about = "关于"

        var icon: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .capture: return "viewfinder"
            case .general: return "gearshape"
            case .hotkeys: return "keyboard"
            case .history: return "clock.arrow.circlepath"
            case .smart: return "text.viewfinder"
            case .about: return "info.circle"
            }
        }
    }

    init(initialPane: Pane = .overview) {
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .frame(minWidth: 800, idealWidth: 840, maxWidth: .infinity, minHeight: 550, idealHeight: 590, maxHeight: .infinity)
        // 稿为不透明黑曜石（obsidian-900）——behind-window 毛玻璃会把桌面内容透进来
        .background(Color(red: 0.063, green: 0.067, blue: 0.086))
        .tint(RubickTheme.primary(scheme))
        .onAppear {
            autoLaunch = SMAppService.mainApp.status == .enabled
            trusted = AXIsProcessTrusted()
            screenAllowed = CaptureController.screenRecordingAllowed()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            trusted = AXIsProcessTrusted()
            screenAllowed = CaptureController.screenRecordingAllowed()
            autoLaunch = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: 侧边栏

    private func brandEmblem(_ size: CGFloat) -> some View {
        RubickEmblem(size: size)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 品牌区（稿：R 徽标 + 名称 + 版本 Preferences 副标）
            HStack(spacing: 10) {
                brandEmblem(28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("拉比克").font(.system(size: 15, weight: .semibold))
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.8") Preferences")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RubickTheme.muted(scheme).opacity(0.75))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(Pane.allCases, id: \.self) { p in
                    Button {
                        pane = p
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: p.icon)
                                .font(.system(size: 13))
                                .frame(width: 18)
                            Text(p.rawValue)
                                .font(.system(size: 13))
                            Spacer()
                            // 选中态右缘发光点（稿 shadow 0 0 8px primary）
                            if pane == p {
                                Circle()
                                    .fill(RubickTheme.primary(scheme))
                                    .frame(width: 6, height: 6)
                                    .shadow(color: RubickTheme.primary(scheme), radius: 4)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(pane == p
                                                                           ? RubickTheme.primary(scheme).opacity(0.14)
                                                                           : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(pane == p
                                                                                ? RubickTheme.primary(scheme).opacity(0.25)
                                                                                : .clear, lineWidth: 1))
                        .foregroundStyle(pane == p ? RubickTheme.primary(scheme) : RubickTheme.muted(scheme))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            // 底部状态行（稿：绿点 物理悬挂就绪 · macOS 版本）
            HStack(spacing: 6) {
                Circle()
                    .fill(RubickTheme.emerald)
                    .frame(width: 7, height: 7)
                    .shadow(color: RubickTheme.emerald, radius: 3)
                Text("物理悬挂就绪")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(RubickTheme.muted(scheme))
                Spacer()
                let v = ProcessInfo.processInfo.operatingSystemVersion
                Text("macOS \(v.majorVersion).\(v.minorVersion)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(RubickTheme.muted(scheme).opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 206)
        .background(Color(red: 0.039, green: 0.043, blue: 0.055))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
        }
    }

    // MARK: 内容区

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .overview: overviewPane
        case .capture: capturePane
        case .general: generalPane
        case .hotkeys: hotkeysPane
        case .history: historyPane
        case .smart: smartPane
        case .about: aboutPane
        }
    }

    private func paneHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 21, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(RubickTheme.muted(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private func settingCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.025)))
            .padding(.horizontal, 2)
    }

    private var toggleStyle: some ToggleStyle { SettingsRowToggleStyle() }

    private var overviewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    Text("概览").font(.system(size: 21, weight: .semibold))
                    Circle().fill(RubickTheme.primary(scheme)).frame(width: 6, height: 6)
                    Text("正在运行").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 0) {
                    overviewHeading("常用操作")
                    overviewAction("剪贴板历史", action: .togglePanel) {
                        SettingsController.shared.close()
                        HistoryPanelController.shared.show(fromHotkey: true)
                    }
                    Divider().opacity(0.35)
                    overviewAction("区域截图", action: .screenshot) {
                        SettingsController.shared.close()
                        CaptureController.shared.captureInteractive()
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    overviewHeading("系统权限")
                    permissionRow("屏幕录制", allowed: screenAllowed, privacy: "Privacy_ScreenCapture")
                    Divider().opacity(0.35)
                    permissionRow("辅助功能", allowed: trusted, privacy: "Privacy_Accessibility")
                }
                VStack(alignment: .leading, spacing: 0) {
                    overviewHeading("启动")
                    HStack {
                        Text("开机自动启动")
                        Spacer()
                        Toggle("开机自动启动", isOn: $autoLaunch).labelsHidden().toggleStyle(.switch)
                    }
                        .padding(.vertical, 12)
                        .onChange(of: autoLaunch) { enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch {
                                autoLaunch = SMAppService.mainApp.status == .enabled
                                Toast.shared.show("无法更改开机启动：" + error.localizedDescription)
                            }
                        }
                }
            }
            .font(.system(size: 14))
            .padding(32)
        }
    }

    private func overviewHeading(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .padding(.bottom, 10)
    }

    private func overviewAction(_ title: String, action: HotkeyManager.Action,
                                perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack {
                Text(title)
                Spacer()
                Text(HotkeyManager.shared.hotkeys[action]?.display ?? "")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.frame(minHeight: 46).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func permissionRow(_ title: String, allowed: Bool, privacy: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer()
            Text(allowed ? "已开启" : "待确认")
                .font(.system(size: 12))
                .foregroundStyle(allowed ? RubickTheme.primary(scheme) : .secondary)
            Button("管理") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + privacy) {
                    NSWorkspace.shared.open(url)
                }
            }.buttonStyle(.link).font(.system(size: 12))
        }.frame(minHeight: 46)
    }

    // MARK: 通用

    private var generalPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("通用", subtitle: "启动与外观")
                settingCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("触控板触觉反馈", isOn: $hapticsEnabled)
                            .toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                        Text("展开夹子、移除记录或放入文件时轻触反馈，需要支持触觉反馈的触控板。")
                            .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
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
                            .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
                settingCard {
                    HStack {
                        Text("外观").font(.system(size: 14))
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
            .padding(28)
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
            .padding(28)
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
                Text(actionLabel(action)).font(.system(size: 14))
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
                Text(PanelKeyConfig.shared.label(action)).font(.system(size: 14))
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
                Text(AnnotateKeyConfig.shared.label(action)).font(.system(size: 14))
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

    // MARK: 随手夹 · 实时外观预览 + 悬挂画布交互（照 Stitch「偏好设置-外观」1:1）

    /// 蓝图网格 + 环境辉光 + 麻绳与拍立得卡实时预览
    private var clotheslineLivePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.039, green: 0.043, blue: 0.055))
            Canvas { ctx, size in
                let step: CGFloat = 16
                var y: CGFloat = 0
                while y < size.height {
                    ctx.stroke(Path { $0.move(to: .init(x: 0, y: y)); $0.addLine(to: .init(x: size.width, y: y)) },
                               with: .color(.white.opacity(0.02)), lineWidth: 1)
                    y += step
                }
                var x: CGFloat = 0
                while x < size.width {
                    ctx.stroke(Path { $0.move(to: .init(x: x, y: 0)); $0.addLine(to: .init(x: x, y: size.height)) },
                               with: .color(.white.opacity(0.02)), lineWidth: 1)
                    x += step
                }
            }
            RadialGradient(colors: [RubickTheme.emerald.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.5, y: 0.35), startRadius: 10, endRadius: 280)
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(RubickTheme.emerald).frame(width: 5, height: 5)
                    Text("实时外观预览 (LIVE PREVIEW)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .kerning(0.8)
                        .foregroundStyle(RubickTheme.muted(scheme))
                    Spacer()
                    Text("\(Int(ropeMaxWidth))% 宽度 · \(String(format: "%.1f", cardTilt))° 摇摆")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RubickTheme.emerald.opacity(0.9))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(RubickTheme.emerald.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(RubickTheme.emerald.opacity(0.25), lineWidth: 0.8))
                }
                GeometryReader { geo in
                    ZStack {
                        // 悬链绳：暗主线 + 亮虚线（照稿 #8d6e46 / #d4a373）
                        let w = geo.size.width, h = geo.size.height
                        Path { p in
                            p.move(to: CGPoint(x: w * 0.056, y: h * 0.34))
                            p.addQuadCurve(to: CGPoint(x: w * 0.944, y: h * 0.34),
                                           control: CGPoint(x: w * 0.5, y: h * 0.64))
                        }
                        .stroke(Color(red: 0.553, green: 0.431, blue: 0.275), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        Path { p in
                            p.move(to: CGPoint(x: w * 0.056, y: h * 0.34))
                            p.addQuadCurve(to: CGPoint(x: w * 0.944, y: h * 0.34),
                                           control: CGPoint(x: w * 0.5, y: h * 0.64))
                        }
                        .stroke(Color(red: 0.831, green: 0.639, blue: 0.451).opacity(0.6),
                                style: StrokeStyle(lineWidth: 1.1, dash: [3, 3]))
                        // 两端木锚钉
                        ForEach([w * 0.056, w * 0.944], id: \.self) { px in
                            Circle().fill(Color(red: 0.55, green: 0.33, blue: 0.12).opacity(0.85))
                                .frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(Color(red: 0.85, green: 0.64, blue: 0.25).opacity(0.6), lineWidth: 1))
                                .shadow(color: .black.opacity(0.7), radius: 2, y: 1.5)
                                .position(x: px, y: h * 0.34)
                        }
                        HStack(spacing: 24) {
                            miniPolaroid(rotation: -cardTilt, clip: .chrome, caption: "Code.ts")
                            miniPolaroid(rotation: cardTilt * 0.66, clip: .emerald, caption: "Preview #1", active: true)
                            miniPolaroid(rotation: -cardTilt * 0.83, clip: .gold, caption: "Asset.png")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(13)
        }
        .frame(height: 156)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: cardTilt)
        .animation(.easeOut(duration: 0.2), value: ropeMaxWidth)
    }

    private enum PreviewClip { case chrome, emerald, gold }

    /// 拍立得缩样：夹子 + 相纸 + 图注，倾角跟随「卡片倾斜幅度」
    private func miniPolaroid(rotation: Double, clip: PreviewClip, caption: String, active: Bool = false) -> some View {
        VStack(spacing: 0) {
            Group {
                switch clip {
                case .chrome:
                    LinearGradient(colors: [Color(white: 0.86), Color(white: 0.62)], startPoint: .top, endPoint: .bottom)
                case .emerald:
                    LinearGradient(colors: [RubickTheme.emerald.opacity(0.9), RubickTheme.emerald.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                case .gold:
                    LinearGradient(colors: [Color(red: 0.96, green: 0.78, blue: 0.36), Color(red: 0.85, green: 0.60, blue: 0.16)], startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: 13, height: 15)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.3), lineWidth: 0.8))
            .overlay(Rectangle().fill(Color.black.opacity(0.55)).frame(width: 5, height: 1.6).offset(y: -4))
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1.5)
            .zIndex(1)
            .offset(y: 6)
            VStack(spacing: 3) {
                Group {
                    if active {
                        VStack(spacing: 3) {
                            HStack {
                                Circle().fill(RubickTheme.emerald).frame(width: 3.5, height: 3.5)
                                Text("LIVE").font(.system(size: 5.5, design: .monospaced)).foregroundStyle(RubickTheme.emerald)
                                Spacer()
                            }
                            RoundedRectangle(cornerRadius: 1).fill(RubickTheme.emerald.opacity(0.6)).frame(height: 4)
                            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.22)).frame(height: 2.5)
                        }
                    } else if caption == "Asset.png" {
                        Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(.white.opacity(0.35))
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            RoundedRectangle(cornerRadius: 1).fill(RubickTheme.emerald.opacity(0.4)).frame(height: 4)
                            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.16)).frame(width: 30, height: 2.5)
                            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.12)).frame(width: 20, height: 2.5)
                        }
                    }
                }
                .frame(width: active ? 58 : 48, height: active ? 42 : 36)
                .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.067, green: 0.075, blue: 0.094)))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.6))
                Text(caption)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.957, green: 0.945, blue: 0.918)))
            .shadow(color: .black.opacity(0.55), radius: active ? 10 : 7, y: 5)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(active ? RubickTheme.emerald.opacity(0.35) : .clear, lineWidth: 1))
        }
        .rotationEffect(.degrees(rotation))
    }

    /// 分组行：左（标题+mono 徽章+说明）右（控件）
    private func canvasRow<Control: View>(badge: String, title: String, desc: String,
                                          @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(badge)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RubickTheme.muted(scheme))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
                }
                Text(desc).font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
                    .frame(maxWidth: 350, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func valueChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(RubickTheme.emerald)
            .frame(width: 52)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8))
    }

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            clotheslineLivePreview
            Text("悬挂画布交互 (CANVAS DYNAMICS)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .kerning(1.1)
                .foregroundStyle(RubickTheme.muted(scheme))
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                canvasRow(badge: "Haptic", title: "触觉反馈",
                          desc: "拖拽卡片卡入吊绳夹具或释放吸附时，通过触控板触发精准震动反馈。") {
                    Toggle("", isOn: $hapticsEnabled).labelsHidden().toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                }
                Divider().opacity(0.5)
                canvasRow(badge: "Auto Retract", title: "取空自动收绳",
                          desc: "当最后一张截图卡片被移出或粘贴消费完毕后，自动收起麻绳并隐藏悬浮条。") {
                    Toggle("", isOn: $autoRetract).labelsHidden().toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                        .onChange(of: autoRetract) { v in
                            UserDefaults.standard.set(v, forKey: "clothesline.autoRetract")
                        }
                }
                Divider().opacity(0.5)
                canvasRow(badge: "Global Hotkey", title: "呼出快捷键",
                          desc: "随时唤醒屏幕悬挂板以便拖放新剪贴内容或快速回溯。") {
                    Button {
                        pane = .hotkeys
                    } label: {
                        HStack(spacing: 4) {
                            ForEach(Array(HotkeyManager.shared.panelShortcutDisplay), id: \.self) { ch in
                                Text(String(ch))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.85))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                            }
                            Image(systemName: "pencil")
                                .font(.system(size: 11))
                                .foregroundStyle(RubickTheme.muted(scheme))
                        }
                    }
                    .buttonStyle(.plain)
                }
                Divider().opacity(0.5)
                canvasRow(badge: "Max Span", title: "绳子最大宽度",
                          desc: "悬挂绳横向跨度占当前屏幕分辨率宽度的百分比。") {
                    HStack(spacing: 10) {
                        Slider(value: $ropeMaxWidth, in: 30...95, step: 5)
                            .frame(width: 150).tint(RubickTheme.emerald)
                            .onChange(of: ropeMaxWidth) { v in
                                UserDefaults.standard.set(v, forKey: "clothesline.maxWidth")
                            }
                        valueChip("\(Int(ropeMaxWidth))%")
                    }
                }
                Divider().opacity(0.5)
                canvasRow(badge: "Tilt Randomness", title: "卡片倾斜幅度",
                          desc: "拍立得相纸自然摆动的不规则倾角范围。") {
                    HStack(spacing: 10) {
                        Slider(value: $cardTilt, in: 0...10, step: 1)
                            .frame(width: 150).tint(RubickTheme.emerald)
                            .onChange(of: cardTilt) { v in
                                UserDefaults.standard.set(v, forKey: "clothesline.tilt")
                            }
                        valueChip("±\(Int(cardTilt))°")
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            // 底部同步脚注
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(RubickTheme.emerald)
                Text("外观改动已即时同步至 macOS 系统常驻托盘")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(RubickTheme.muted(scheme))
                Spacer()
                Text("帮助文档 ↗")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(RubickTheme.muted(scheme))
            }
            .padding(.top, 2)
        }
    }

    private var historyPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                paneHeader("剪贴板", subtitle: "面板、粘贴与历史记录")
                settingCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("面板形态").font(.system(size: 14))
                        Picker("面板形态", selection: $panelForm) {
                            Text("原生").tag("panel")
                            Text("Dock").tag("dock")
                            Text("随手夹").tag("clothesline")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 320)
                        .onChange(of: panelForm) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "panel.form")
                            ClipboardPresentation.apply()
                        }
                        Toggle("记住面板呼出位置", isOn: $rememberPosition)
                            .disabled(panelForm != "panel")
                            .toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                            .onChange(of: rememberPosition) { v in
                                UserDefaults.standard.set(v, forKey: "panel.rememberPosition")
                            }
                        Text("原生：双栏历史；Dock：底部卡片；随手夹：拖文件到刘海触发，平时不留任何入口。\(HotkeyManager.shared.panelShortcutDisplay) 随时呼出。")
                            .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }

                // 随手夹区块（照 Stitch「偏好设置-外观」1:1：实时预览 + 悬挂画布交互分组）
                canvasSection
                settingCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("触发策略").font(.system(size: 13, weight: .medium))
                        Text("随手夹：拖文件到刘海触发，平时不留任何入口。复制/截图不会自动触发，\(HotkeyManager.shared.panelShortcutDisplay) 随时调出。")
                            .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
                settingCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(panelForm == "panel" ? "双击条目后自动粘贴" : "单击卡片后自动粘贴", isOn: $pasteAuto)
                            .toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                            .onChange(of: pasteAuto) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "pasteAuto")
                            }
                        Text("关闭后取用条目仅复制，需手动 ⌘V。")
                            .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
                settingCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("粘贴后保持面板打开", isOn: $keepOpen)
                            .disabled(panelForm == "clothesline")
                            .toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                            .onChange(of: keepOpen) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "keepPanelOpen")
                            }
                        Text(panelForm == "clothesline" ? "照片墙取用后自动收起，拖拽取消时保持展开；点外部或按 Esc 也可收起。" : "开启后可连续粘贴多条，按 ⎋ 关闭；按住 ⌥ 点击条目可仅复制。")
                            .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
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
                            .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
                settingCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("保留记录数").font(.system(size: 14))
                            Text("超出后按时间淘汰最旧条目。")
                                .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
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
            .padding(28)
        }
    }

    // MARK: 智能识别（v2.0）

    private var smartPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                paneHeader("识别与翻译", subtitle: "翻译与 OCR 均本地优先；大模型为可选增强。")
                settingCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("翻译引擎").font(.system(size: 14))
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
                            Text("翻译方向").font(.system(size: 14))
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
                            .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
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
                            Text("OCR 识别语言").font(.system(size: 14))
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
                            .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
            }
            .padding(28)
        }
    }

    private var capturePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("截图与钉图", subtitle: "框选、标注与悬浮贴图")
                settingCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("窗口吸附", isOn: $snapOn)
                            .toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                            .onChange(of: snapOn) { v in UserDefaults.standard.set(v, forKey: "capture.snap") }
                        Text("悬停识别窗口，单击选中窗口范围，也可拖动框选。")
                            .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
                        HStack {
                            Text("吸附阈值").font(.system(size: 14))
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
                            Text("截图模式").font(.system(size: 14))
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
                        Text("自动与自绘模式使用拉比克原地标注；系统框选仅在主动选择时启用。")
                            .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
                        HStack {
                            Text("延时截图").font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $delaySeconds) {
                                Text("1 秒").tag(1)
                                Text("3 秒").tag(3)
                                Text("5 秒").tag(5)
                                Text("10 秒").tag(10)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                            .onChange(of: delaySeconds) { v in
                                UserDefaults.standard.set(v, forKey: "capture.delaySeconds")
                            }
                        }
                        Toggle("长截图（实验性）", isOn: $longShot)
                            .toggleStyle(toggleStyle).tint(RubickTheme.emerald)
                            .onChange(of: longShot) { v in UserDefaults.standard.set(v, forKey: "capture.longShot") }
                        HStack {
                            Text("贴图默认大小").font(.system(size: 14))
                            Spacer()
                            Slider(value: $pinScale, in: 0.25...2.0, step: 0.05)
                                .frame(width: 180)
                                .onChange(of: pinScale) { v in
                                    UserDefaults.standard.set(v, forKey: "pin.defaultScale")
                                }
                            Text("\(Int(pinScale * 100))%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(RubickTheme.muted(scheme))
                                .frame(width: 40)
                        }
                        Text("钉图按截图原始尺寸的这个比例显示（默认 70%），钉住后可滚轮/捏合继续缩放。")
                            .font(.system(size: 12)).foregroundStyle(RubickTheme.muted(scheme))
                    }
                }
            }
            .padding(28)
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
            Text("Rubick · 剪贴板与截图")
                .font(.system(size: 10.5, weight: .medium))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(RubickTheme.primary(scheme).opacity(0.85))
            Text("版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"))
                .font(.system(size: 11))
                .foregroundStyle(RubickTheme.muted(scheme))
            Text("菜单栏常驻的剪贴板历史与截图钉图工具。\n剪贴板历史保存在本机。")
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

private struct SettingsRowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label
            Spacer()
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch)
        }.frame(minHeight: 32)
    }
}
