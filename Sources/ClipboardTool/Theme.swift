import SwiftUI

// MARK: - RubickBoard 主题（Stitch "Obsidian Emerald" 设计系统 → SwiftUI 还原）
// 设计原则：低干扰、克制。色调分层 + 1px 发丝线定结构；强调色仅用于交互态
// （选中边框/激活筛选片/状态点/主图标），禁用发光与彩色渐变。

enum RubickTheme {
    // 深色（中性冷灰，Stitch 色板）
    static let darkBackground = Color(hex: 0x17191B)
    static let darkSurfaceContainer = Color(hex: 0x1F2321)
    static let darkSurfaceHigh = Color(hex: 0x262B29)
    static let darkOnSurface = Color(hex: 0xE2E8E4)
    static let darkOnSurfaceVariant = Color(hex: 0xA8B3AC)
    static let darkOutline = Color(hex: 0x3A423E)

    // 强调色（去饱和祖母绿，仅交互态使用）
    static let emerald = Color(hex: 0x3E8E63)       // 浅色模式主强调
    static let emeraldBright = Color(hex: 0x6BB98C) // 深色模式 primary（发丝线/图标可读）
    static let emeraldDeep = Color(hex: 0x2F6B4C)   // 浅色模式文字绿
    static let arcanePurple = Color(hex: 0x8A2BE2)  // 已退役：仅保留定义兼容旧引用

    // 浅色
    static let lightText = Color(hex: 0x1E2220)
    static let lightMuted = Color(hex: 0x6F7B74)

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
        scheme == .dark ? darkSurfaceContainer : Color.white.opacity(0.65)
    }
    static func surfaceHigh(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkSurfaceHigh : Color.black.opacity(0.05)
    }
    /// 发丝线描边（结构线，选中时换强调色）
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkOutline : Color.black.opacity(0.12)
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

// MARK: - 列表卡片（Stitch tonal layering：色调分层 + 发丝线，无发光无阴影）

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

extension View {
    func glowCard(hovering: Bool, selected: Bool = false, cornerRadius: CGFloat = 8) -> some View {
        modifier(GlowCardModifier(hovering: hovering, selected: selected, cornerRadius: cornerRadius))
    }
}
