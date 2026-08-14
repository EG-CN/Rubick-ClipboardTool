import SwiftUI

// MARK: - RubickBoard 主题（Stitch 设计系统 → SwiftUI 还原）

enum RubickTheme {
    // 深色（Stitch Material3 dark palette）
    static let darkBackground = Color(hex: 0x0E150F)
    static let darkSurfaceContainer = Color(hex: 0x1A211B)
    static let darkSurfaceHigh = Color(hex: 0x242C25)
    static let darkOnSurface = Color(hex: 0xDCE5DA)
    static let darkOnSurfaceVariant = Color(hex: 0xBBCBBB)
    static let darkOutline = Color(hex: 0x869486)

    // 强调色（祖母绿）
    static let emerald = Color(hex: 0x2ECC71)       // 浅色模式主强调 / primary-container
    static let emeraldBright = Color(hex: 0x54E98A) // 深色模式 primary
    static let emeraldDeep = Color(hex: 0x005027)   // 浅色模式文字绿
    static let arcanePurple = Color(hex: 0x8A2BE2)  // 奥术紫（钉图氛围光）

    // 浅色
    static let lightText = Color(hex: 0x1A211B)
    static let lightMuted = Color(hex: 0x869486)

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

// MARK: - 发光描边卡片（Stitch glow-border）

struct GlowCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var hovering: Bool
    var selected: Bool = false
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        let active = hovering || selected
        let border = RubickTheme.primary(scheme)
        return content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(active
                          ? RubickTheme.primary(scheme).opacity(0.08)
                          : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(active ? border : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: active ? RubickTheme.emerald.opacity(0.3) : .clear, radius: 4, x: 0, y: 0)
    }
}

extension View {
    func glowCard(hovering: Bool, selected: Bool = false, cornerRadius: CGFloat = 8) -> some View {
        modifier(GlowCardModifier(hovering: hovering, selected: selected, cornerRadius: cornerRadius))
    }
}
