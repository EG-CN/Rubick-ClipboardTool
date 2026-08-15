import AppKit
import Carbon.HIToolbox

// MARK: - 标注编辑器快捷键（全部可配置，功能清单 12.1.5）
// 仅标注编辑器打开时生效

final class AnnotateKeyConfig: ObservableObject {
    enum Action: String, CaseIterable {
        case confirm, cancel, undo, redo
        case toolRect, toolEllipse, toolArrow, toolPen, toolText, toolMosaic, toolHighlight
        case ocr, translate
    }

    struct Key {
        var keyCode: UInt16
        var mods: UInt32
        var display: String
    }

    static let shared = AnnotateKeyConfig()

    @Published var keys: [Action: Key] = [:]

    init() {
        loadDefaults()
    }

    private func loadDefaults() {
        let d = UserDefaults.standard
        keys[.confirm] = read(d, "ak.confirm", UInt16(kVK_Return), 0, "↵")
        keys[.cancel] = read(d, "ak.cancel", UInt16(kVK_Escape), 0, "⎋")
        keys[.undo] = read(d, "ak.undo", UInt16(kVK_ANSI_Z), UInt32(cmdKey), "⌘Z")
        keys[.redo] = read(d, "ak.redo", UInt16(kVK_ANSI_Z), UInt32(cmdKey | shiftKey), "⌘⇧Z")
        keys[.toolRect] = read(d, "ak.toolRect", UInt16(kVK_ANSI_1), 0, "1")
        keys[.toolEllipse] = read(d, "ak.toolEllipse", UInt16(kVK_ANSI_2), 0, "2")
        keys[.toolArrow] = read(d, "ak.toolArrow", UInt16(kVK_ANSI_3), 0, "3")
        keys[.toolPen] = read(d, "ak.toolPen", UInt16(kVK_ANSI_4), 0, "4")
        keys[.toolText] = read(d, "ak.toolText", UInt16(kVK_ANSI_5), 0, "5")
        keys[.toolMosaic] = read(d, "ak.toolMosaic", UInt16(kVK_ANSI_6), 0, "6")
        keys[.toolHighlight] = read(d, "ak.toolHighlight", UInt16(kVK_ANSI_7), 0, "7")
        keys[.ocr] = read(d, "ak.ocr", UInt16(kVK_ANSI_O), 0, "O")
        keys[.translate] = read(d, "ak.translate", UInt16(kVK_ANSI_T), 0, "T")
    }

    private func read(_ d: UserDefaults, _ key: String, _ keyCode: UInt16, _ mods: UInt32, _ display: String) -> Key {
        guard let dict = d.dictionary(forKey: key) else {
            return Key(keyCode: keyCode, mods: mods, display: display)
        }
        return Key(keyCode: dict["keyCode"] as? UInt16 ?? keyCode,
                   mods: dict["mods"] as? UInt32 ?? mods,
                   display: dict["display"] as? String ?? display)
    }

    func update(_ action: Action, keyCode: UInt16, mods: UInt32, display: String) {
        keys[action] = Key(keyCode: keyCode, mods: mods, display: display)
        UserDefaults.standard.set(["keyCode": keyCode, "mods": mods, "display": display],
                                  forKey: prefKey(action))
    }

    func reset(_ action: Action) {
        update(action, keyCode: defaultKey(action).keyCode, mods: defaultKey(action).mods, display: defaultKey(action).display)
    }

    func defaultKey(_ action: Action) -> Key {
        switch action {
        case .confirm: return Key(keyCode: UInt16(kVK_Return), mods: 0, display: "↵")
        case .cancel: return Key(keyCode: UInt16(kVK_Escape), mods: 0, display: "⎋")
        case .undo: return Key(keyCode: UInt16(kVK_ANSI_Z), mods: UInt32(cmdKey), display: "⌘Z")
        case .redo: return Key(keyCode: UInt16(kVK_ANSI_Z), mods: UInt32(cmdKey | shiftKey), display: "⌘⇧Z")
        case .toolRect: return Key(keyCode: UInt16(kVK_ANSI_1), mods: 0, display: "1")
        case .toolEllipse: return Key(keyCode: UInt16(kVK_ANSI_2), mods: 0, display: "2")
        case .toolArrow: return Key(keyCode: UInt16(kVK_ANSI_3), mods: 0, display: "3")
        case .toolPen: return Key(keyCode: UInt16(kVK_ANSI_4), mods: 0, display: "4")
        case .toolText: return Key(keyCode: UInt16(kVK_ANSI_5), mods: 0, display: "5")
        case .toolMosaic: return Key(keyCode: UInt16(kVK_ANSI_6), mods: 0, display: "6")
        case .toolHighlight: return Key(keyCode: UInt16(kVK_ANSI_7), mods: 0, display: "7")
        case .ocr: return Key(keyCode: UInt16(kVK_ANSI_O), mods: 0, display: "O")
        case .translate: return Key(keyCode: UInt16(kVK_ANSI_T), mods: 0, display: "T")
        }
    }

    private func prefKey(_ a: Action) -> String {
        "ak.\(a.rawValue)"
    }

    func matches(_ action: Action, event: NSEvent) -> Bool {
        guard let k = keys[action] else { return false }
        return UInt32(event.keyCode) == UInt32(k.keyCode)
            && carbonModifiers(event.modifierFlags) == k.mods
    }

    func label(_ a: Action) -> String {
        switch a {
        case .confirm: return "确认标注"
        case .cancel: return "取消截图"
        case .undo: return "撤销"
        case .redo: return "重做"
        case .toolRect: return "矩形"
        case .toolEllipse: return "椭圆"
        case .toolArrow: return "箭头"
        case .toolPen: return "画笔"
        case .toolText: return "文字"
        case .toolMosaic: return "马赛克"
        case .toolHighlight: return "高亮"
        case .ocr: return "识别图中文字"
        case .translate: return "翻译选中文字"
        }
    }
}
