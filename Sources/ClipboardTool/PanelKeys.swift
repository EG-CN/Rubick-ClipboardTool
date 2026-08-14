import AppKit
import Carbon.HIToolbox

// MARK: - 面板内快捷键配置（全部可配置，仅面板打开时生效）

final class PanelKeyConfig: ObservableObject {
    enum PanelAction: String, CaseIterable {
        case navUp, navDown, paste, close, deleteItem, pin, quick
    }

    struct Key {
        var keyCode: UInt16
        var mods: UInt32      // Carbon 风格修饰键
        var display: String
        var quick: Bool       // ⌘1–9 快速选择（特殊模式）
    }

    static let shared = PanelKeyConfig()

    @Published var keys: [PanelAction: Key] = [:]

    init() {
        loadDefaults()
    }

    // MARK: 默认值与持久化

    private func loadDefaults() {
        let d = UserDefaults.standard
        keys[.navUp] = read(d, "pk.navUp", keyCode: UInt16(kVK_UpArrow), mods: 0, display: "↑")
        keys[.navDown] = read(d, "pk.navDown", keyCode: UInt16(kVK_DownArrow), mods: 0, display: "↓")
        keys[.paste] = read(d, "pk.paste", keyCode: UInt16(kVK_Return), mods: 0, display: "↵")
        keys[.close] = read(d, "pk.close", keyCode: UInt16(kVK_Escape), mods: 0, display: "⎋")
        keys[.deleteItem] = read(d, "pk.delete", keyCode: UInt16(kVK_Delete), mods: 0, display: "⌫")
        keys[.pin] = read(d, "pk.pin", keyCode: UInt16(kVK_ANSI_P), mods: 0, display: "P")
        keys[.quick] = read(d, "pk.quick", keyCode: UInt16(kVK_ANSI_1), mods: UInt32(cmdKey), display: "⌘1–9", quick: true)
    }

    private func read(_ d: UserDefaults, _ key: String, keyCode: UInt16, mods: UInt32, display: String, quick: Bool = false) -> Key {
        guard let dict = d.dictionary(forKey: key) else {
            return Key(keyCode: keyCode, mods: mods, display: display, quick: quick)
        }
        return Key(keyCode: dict["keyCode"] as? UInt16 ?? keyCode,
                   mods: dict["mods"] as? UInt32 ?? mods,
                   display: dict["display"] as? String ?? display,
                   quick: dict["quick"] as? Bool ?? quick)
    }

    func update(_ action: PanelAction, keyCode: UInt16, mods: UInt32, display: String, quick: Bool = false) {
        keys[action] = Key(keyCode: keyCode, mods: mods, display: display, quick: quick)
        UserDefaults.standard.set(["keyCode": keyCode, "mods": mods, "display": display, "quick": quick],
                                  forKey: prefKey(action))
    }

    func reset(_ action: PanelAction) {
        let def: Key
        switch action {
        case .navUp: def = Key(keyCode: UInt16(kVK_UpArrow), mods: 0, display: "↑", quick: false)
        case .navDown: def = Key(keyCode: UInt16(kVK_DownArrow), mods: 0, display: "↓", quick: false)
        case .paste: def = Key(keyCode: UInt16(kVK_Return), mods: 0, display: "↵", quick: false)
        case .close: def = Key(keyCode: UInt16(kVK_Escape), mods: 0, display: "⎋", quick: false)
        case .deleteItem: def = Key(keyCode: UInt16(kVK_Delete), mods: 0, display: "⌫", quick: false)
        case .pin: def = Key(keyCode: UInt16(kVK_ANSI_P), mods: 0, display: "P", quick: false)
        case .quick: def = Key(keyCode: UInt16(kVK_ANSI_1), mods: UInt32(cmdKey), display: "⌘1–9", quick: true)
        }
        update(action, keyCode: def.keyCode, mods: def.mods, display: def.display, quick: def.quick)
    }

    private func prefKey(_ a: PanelAction) -> String {
        switch a {
        case .navUp: return "pk.navUp"
        case .navDown: return "pk.navDown"
        case .paste: return "pk.paste"
        case .close: return "pk.close"
        case .deleteItem: return "pk.delete"
        case .pin: return "pk.pin"
        case .quick: return "pk.quick"
        }
    }

    // MARK: 匹配

    func matches(_ action: PanelAction, event: NSEvent) -> Bool {
        guard let k = keys[action] else { return false }
        if k.quick {
            return event.modifierFlags.contains(.command) && quickDigit(event) != nil
        }
        return UInt32(event.keyCode) == UInt32(k.keyCode)
            && carbonModifiers(event.modifierFlags) == k.mods
    }

    /// 顶部数字行键码不连续（5=23, 6=22, 7=26, 8=28, 9=25），必须查表
    private static let digitKeyCodes: [UInt16: Int] = [
        UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3,
        UInt16(kVK_ANSI_4): 4, UInt16(kVK_ANSI_5): 5, UInt16(kVK_ANSI_6): 6,
        UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8, UInt16(kVK_ANSI_9): 9
    ]

    func quickDigit(_ event: NSEvent) -> Int? {
        Self.digitKeyCodes[event.keyCode]
    }

    // MARK: 文案

    func label(_ a: PanelAction) -> String {
        switch a {
        case .navUp: return "向上选择"
        case .navDown: return "向下选择"
        case .paste: return "粘贴所选条目"
        case .close: return "关闭面板"
        case .deleteItem: return "删除所选条目"
        case .pin: return "钉图"
        case .quick: return "快速选择前 9 条"
        }
    }

    /// 面板底部提示（随配置实时联动）
    func hintText() -> String {
        let k = keys
        let up = k[.navUp]?.display ?? "↑"
        let down = k[.navDown]?.display ?? "↓"
        let paste = k[.paste]?.display ?? "↵"
        let del = k[.deleteItem]?.display ?? "⌫"
        let close = k[.close]?.display ?? "⎋"
        let quick = k[.quick]?.display ?? "⌘1–9"
        return "\(up) \(down) 选择 · \(paste) 粘贴 · \(del) 删除 · \(close) 关闭 · \(quick) 快速选择"
    }
}
