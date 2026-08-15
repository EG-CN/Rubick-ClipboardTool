import AppKit
import Carbon.HIToolbox

// MARK: - 全局快捷键管理（Carbon HotKey，全部可配置）
// macOS 14+ 该 API 标记 deprecated（警告可忽略），届时可迁移 CGEventTap / NSEvent。

final class HotkeyManager {
    enum Action: UInt32, CaseIterable {
        case togglePanel = 1
        case screenshot = 2
        case openSettings = 3
        case dragTranslate = 4
    }

    static let shared = HotkeyManager()

    struct Hotkey {
        var keyCode: UInt32
        var modifiers: UInt32
        var display: String
    }

    private(set) var hotkeys: [Action: Hotkey] = [:]
    var onAction: ((Action) -> Void)?

    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    private init() {
        loadDefaults()
        installHandler()
        for (action, hotkey) in hotkeys {
            register(action, hotkey: hotkey)
        }
    }

    // MARK: 持久化（UserDefaults）

    private func loadDefaults() {
        let d = UserDefaults.standard
        hotkeys[.togglePanel] = read(d, "hk.panel", keyCode: UInt32(kVK_ANSI_V), mods: UInt32(cmdKey | shiftKey), display: "⌘⇧V")
        hotkeys[.screenshot] = read(d, "hk.screenshot", keyCode: UInt32(kVK_ANSI_A), mods: UInt32(cmdKey | shiftKey), display: "⌘⇧A")
        hotkeys[.openSettings] = read(d, "hk.settings", keyCode: UInt32(kVK_ANSI_Comma), mods: UInt32(cmdKey), display: "⌘,")
        hotkeys[.dragTranslate] = read(d, "hk.dragTranslate", keyCode: UInt32(kVK_ANSI_D), mods: UInt32(cmdKey | shiftKey), display: "⌘⇧D")
    }

    private func read(_ d: UserDefaults, _ key: String, keyCode: UInt32, mods: UInt32, display: String) -> Hotkey {
        guard let dict = d.dictionary(forKey: key) else {
            return Hotkey(keyCode: keyCode, modifiers: mods, display: display)
        }
        return Hotkey(keyCode: dict["keyCode"] as? UInt32 ?? keyCode,
                      modifiers: dict["mods"] as? UInt32 ?? mods,
                      display: dict["display"] as? String ?? display)
    }

    private func keyString(_ a: Action) -> String {
        switch a {
        case .togglePanel: return "hk.panel"
        case .screenshot: return "hk.screenshot"
        case .openSettings: return "hk.settings"
        case .dragTranslate: return "hk.dragTranslate"
        }
    }

    // MARK: 更新 / 重置

    func update(_ action: Action, keyCode: UInt32, modifiers: UInt32, display: String) {
        if let old = refs[action] {
            UnregisterEventHotKey(old)
            refs.removeValue(forKey: action)
        }
        let hk = Hotkey(keyCode: keyCode, modifiers: modifiers, display: display)
        hotkeys[action] = hk
        register(action, hotkey: hk)
        UserDefaults.standard.set(["keyCode": keyCode, "mods": modifiers, "display": display],
                                  forKey: keyString(action))
    }

    func reset(_ action: Action) {
        let def: Hotkey
        switch action {
        case .togglePanel:
            def = Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧V")
        case .screenshot:
            def = Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧A")
        case .openSettings:
            def = Hotkey(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey), display: "⌘,")
        case .dragTranslate:
            def = Hotkey(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧D")
        }
        update(action, keyCode: def.keyCode, modifiers: def.modifiers, display: def.display)
    }

    // MARK: Carbon 注册

    private func register(_ action: Action, hotkey: Hotkey) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode,
                                         hotkey.modifiers,
                                         EventHotKeyID(signature: 0x434C_4950 /* "CLIP" */, id: action.rawValue),
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        if status == noErr, let r = ref {
            refs[action] = r
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hkID)
            if err == noErr, let action = Action(rawValue: hkID.id) {
                DispatchQueue.main.async {
                    HotkeyManager.shared.onAction?(action)
                }
            }
            return noErr
        }
        var ref: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &ref)
        handlerRef = ref
    }
}

// MARK: - 录制辅助（设置页用）

func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.shift) { m |= UInt32(shiftKey) }
    if flags.contains(.option) { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    return m
}

func comboDisplay(modifiers: UInt32, keyCode: UInt16, characters: String?) -> String {
    var s = ""
    if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
    if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
    if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
    let special: [UInt16: String] = [
        36: "↵", 76: "↵", 53: "⎋", 51: "⌫", 49: "空格",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
    if let sp = special[keyCode] { return s + sp }
    if let ch = characters?.uppercased(), !ch.isEmpty { return s + ch }
    return s + "键\(keyCode)"
}
