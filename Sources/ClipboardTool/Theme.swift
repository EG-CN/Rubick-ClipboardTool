import SwiftUI

// MARK: - RubickBoard 主题（「奥术纸墨」Arcane Paper/Ink，Stitch v4 提案 C 组落地）
// 设计语言：✦ 四角星徽记 + 衬线字标 + 法术槽选中条，绿色仅点缀；
// 浅色=纸白（Arcane Paper），暗色=墨绿黑（Arcane Ink），大面积留白保持清爽。

enum RubickTheme {
    // 暗色（Arcane Ink：墨绿黑）
    static let darkBackground = Color(hex: 0x10140F)
    static let darkSurfaceContainer = Color(hex: 0x1A201A)
    static let darkSurfaceHigh = Color(hex: 0x232B23)
    static let darkOnSurface = Color(hex: 0xE8EDE6)
    static let darkOnSurfaceVariant = Color(hex: 0x8FA096)
    static let darkOutline = Color(hex: 0x2A332B)

    // 强调色（祖母绿墨水，仅 ✦/选中槽/状态点/主按钮）
    static let emerald = Color(hex: 0x2F7D53)       // 浅色（纸面墨绿）
    static let emeraldBright = Color(hex: 0x5FB98A) // 暗色（薄荷绿）
    static let emeraldDeep = Color(hex: 0x276746)   // 浅色文字绿
    static let arcanePurple = Color(hex: 0x8A2BE2)  // 已退役：仅保留定义兼容旧引用

    // 浅色（Arcane Paper：纸白）
    static let lightText = Color(hex: 0x23281F)
    static let lightMuted = Color(hex: 0x8A9188)

    static func primary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? emeraldBright : emerald
    }
    static func onSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkOnSurface : lightText
    }
    static func muted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkOnSurfaceVariant : lightMuted
    }
    static func surfaceContainer(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkSurfaceContainer : Color.black.opacity(0.035)
    }
    static func surfaceHigh(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkSurfaceHigh : Color.black.opacity(0.05)
    }
    /// 发丝线描边
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkOutline : Color.black.opacity(0.08)
    }
    /// 面板底色（纸白/墨黑，叠在材质上）
    static func panelBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkBackground.opacity(0.55) : Color(hex: 0xFAFAF8).opacity(0.55)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

// MARK: - 法术槽卡片（列表行：空闲全透明，悬停浅洗底，选中=左缘祖母绿渐变条 + 淡绿洗底）

struct SpellSlotModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var hovering: Bool
    var selected: Bool
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(slotFill)
            )
            .overlay(alignment: .leading) {
                if selected {
                    // 法术槽：左缘渐变细条（唯一强识别符号）
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(LinearGradient(colors: [RubickTheme.primary(scheme),
                                                      RubickTheme.primary(scheme).opacity(0.12)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 3)
                        .padding(.vertical, 7)
                        .padding(.leading, 2)
                }
            }
    }

    private var slotFill: Color {
        if selected { return RubickTheme.primary(scheme).opacity(scheme == .dark ? 0.10 : 0.05) }
        if hovering { return RubickTheme.surfaceHigh(scheme).opacity(0.55) }
        return .clear
    }
}

extension View {
    /// 面板列表行专用（v4 奥术纸墨选中语言）
    func spellSlot(hovering: Bool, selected: Bool, cornerRadius: CGFloat = 8) -> some View {
        modifier(SpellSlotModifier(hovering: hovering, selected: selected, cornerRadius: cornerRadius))
    }

    /// 通用卡片（保留旧 API：去发光后的发丝线卡片，供非列表场景使用）
    func glowCard(hovering: Bool, selected: Bool = false, cornerRadius: CGFloat = 8) -> some View {
        modifier(GlowCardModifier(hovering: hovering, selected: selected, cornerRadius: cornerRadius))
    }
}

struct GlowCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var hovering: Bool
    var selected: Bool = false
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        let active = hovering || selected
        return content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(active
                          ? RubickTheme.primary(scheme).opacity(0.06)
                          : RubickTheme.surfaceContainer(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(active ? RubickTheme.primary(scheme) : RubickTheme.hairline(scheme),
                                  lineWidth: active ? 1.2 : 1)
            )
    }
}

// MARK: - ✦ 徽记（拉比克品牌符号）

struct ArcaneSparkle: View {
    var size: CGFloat = 12
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text("✦")
            .font(.system(size: size))
            .foregroundStyle(RubickTheme.primary(scheme))
    }
}
