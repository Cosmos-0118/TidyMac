import SwiftUI

struct DesignSystemPalette: Equatable {
    let background: Color
    let surface: Color
    let accentGreen: Color
    let accentRed: Color
    let accentGray: Color
    let primaryText: Color
    let secondaryText: Color

    static let macCleanerDark = DesignSystemPalette(
        background: Color("ThemeBackground"),
        surface: Color("ThemeSurface"),
        accentGreen: Color("ThemeAccentGreen"),
        accentRed: Color("ThemeAccentRed"),
        accentGray: Color("ThemeAccentGray"),
        primaryText: Color.white,
        secondaryText: Color.white.opacity(0.7)
    )
}

private struct DesignSystemPaletteKey: EnvironmentKey {
    static let defaultValue: DesignSystemPalette = .macCleanerDark
}

extension EnvironmentValues {
    var designSystemPalette: DesignSystemPalette {
        get { self[DesignSystemPaletteKey.self] }
        set { self[DesignSystemPaletteKey.self] = newValue }
    }
}

enum DesignSystem {
    enum Typography {
        static let title = Font.system(size: 28, weight: .bold, design: .rounded)
        static let headline = Font.system(size: 20, weight: .semibold)
        static let body = Font.system(size: 16, weight: .regular)
        static let caption = Font.system(size: 13, weight: .medium)
    }

    enum Spacing {
        static let xSmall: CGFloat = 6
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xLarge: CGFloat = 32
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.designSystemPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, DesignSystem.Spacing.small)
            .padding(.horizontal, DesignSystem.Spacing.large)
            .background(palette.accentGreen.opacity(configuration.isPressed ? 0.85 : 1.0))
            .foregroundColor(palette.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: palette.accentGreen.opacity(configuration.isPressed ? 0.15 : 0.35), radius: configuration.isPressed ? 3 : 8, y: configuration.isPressed ? 1 : 4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.designSystemPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, DesignSystem.Spacing.small)
            .padding(.horizontal, DesignSystem.Spacing.large)
            .background(palette.accentRed.opacity(configuration.isPressed ? 0.85 : 1.0))
            .foregroundColor(palette.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: palette.accentRed.opacity(configuration.isPressed ? 0.15 : 0.35), radius: configuration.isPressed ? 3 : 8, y: configuration.isPressed ? 1 : 4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.designSystemPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, DesignSystem.Spacing.small)
            .padding(.horizontal, DesignSystem.Spacing.large)
            .background(palette.surface.opacity(configuration.isPressed ? 0.8 : 1.0))
            .foregroundColor(palette.secondaryText)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(palette.accentGray.opacity(0.4), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
