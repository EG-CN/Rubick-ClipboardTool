import SwiftUI

// MARK: - RubickBoard 主题（「秘黑奥术」Arcane Obsidian，Stitch 2026-10-06 方案落地）
// 设计语言：✦ 星徽 + Newsreader 衬线气质 + 机械键帽 + 祖母绿三阶荧光；
// 暗色=秘黑奥术（#101419 底 + 祖母绿辉光），亮色=晨雾纸墨（保留 Arcane Paper）。
// 完整规格见 docs/UI方向-ArcaneObsidian-设计系统.md

enum RubickTheme {
    // 暗色（Arcane Obsidian：秘黑奥术）
    static let darkBackground = Color(hex: 0x101419)
    static let darkSurfaceContainer = Color(hex: 0x181C21)  // container-low
    static let darkSurfaceHigh = Color(hex: 0x262A30)       // container-high
    static let darkOnSurface = Color(hex: 0xE0E2EA)
    static let darkOnSurfaceVariant = Color(hex: 0x94A3B8)  // Text Muted
    static let darkOutline = Color(hex: 0x3C4A42)           // outline_variant
    /// 暗色荧光强调（Arcane Phosphor，选中/聚焦辉光）
    static let arcaneGlow = Color(hex: 0x34D399)

    // 强调色（祖母绿三阶：Core/Phosphor/Verdant）
    static let emerald = Color(hex: 0x2F7D53)       // 浅色（纸面墨绿）
    static let emeraldBright = Color(hex: 0x34D399) // 暗色（Arcane Phosphor）
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
    /// 面板底衬（奥术夜幕/黎明：顶部极光渐变 + 基底色，垫在材质后透出）
    static func panelAurora(_ scheme: ColorScheme) -> some View {
        let base = scheme == .dark ? Color(hex: 0x101419) : Color(hex: 0xFBFCFA)
        let glowTop = scheme == .dark ? Color(hex: 0x0F2A22) : Color(hex: 0xD9EBDB)
        return ZStack {
            base
            LinearGradient(colors: [glowTop.opacity(scheme == .dark ? 0.85 : 0.65),
                                    base.opacity(0)],
                           startPoint: UnitPoint(x: 0.5, y: 0),
                           endPoint: UnitPoint(x: 0.5, y: 0.5))
        }
    }

    /// 渐变发丝描边（顶部祖母绿 → 底部近乎透明）
    static func panelGradientBorder(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(colors: [primary(scheme).opacity(0.35), primary(scheme).opacity(0.04)],
                       startPoint: .top, endPoint: .bottom)
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

// MARK: - 机械键帽（Arcane Obsidian 特征件：快捷键真实按键质感）

struct Keycap: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(RubickTheme.onSurface(scheme).opacity(0.9))
            .padding(.horizontal, 6)
            .frame(minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.4)).frame(height: 1).blur(radius: 0.5)
            }
    }
}

// MARK: - ✦ 徽记（拉比克品牌符号）

struct ArcaneSparkle: View {
    var size: CGFloat = 12
    var glow: Bool = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text("✦")
            .font(.system(size: size))
            .foregroundStyle(RubickTheme.primary(scheme))
            .shadow(color: glow ? RubickTheme.primary(scheme).opacity(0.6) : .clear, radius: glow ? 3 : 0)
    }
}
