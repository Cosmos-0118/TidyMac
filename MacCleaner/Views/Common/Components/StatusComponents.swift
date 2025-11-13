import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct StatusCard<Content: View>: View {
    let title: String
    let iconName: String
    let accent: Color
    @ViewBuilder private let content: () -> Content

    @Environment(\.designSystemPalette) private var palette

    init(title: String, iconName: String, accent: Color, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.iconName = iconName
        self.accent = accent
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.medium) {
            HStack(spacing: DesignSystem.Spacing.small) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(accent)
                }

                Text(title)
                    .font(DesignSystem.Typography.headline)
                    .foregroundColor(palette.primaryText)
            }

            content()
        }
        .padding(DesignSystem.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(0.25), lineWidth: 1)
        )
    .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isSummaryElement)
    }
}

struct MetricGauge: View {
    struct Configuration {
        let title: String
        let value: Double
        let systemImage: String
        let accent: Color
        let accessibilityLabel: String
    }

    let configuration: Configuration

    @Environment(\.designSystemPalette) private var palette

    var body: some View {
        StatusCard(title: configuration.title, iconName: configuration.systemImage, accent: configuration.accent) {
            Gauge(value: configuration.value, in: 0...100) {
                Text(configuration.title)
            } currentValueLabel: {
                Text(String(format: "%.0f%%", configuration.value))
                    .font(DesignSystem.Typography.headline)
                    .foregroundColor(palette.primaryText)
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(configuration.accent)
            .accessibilityLabel(configuration.accessibilityLabel)
            .accessibilityValue(Text(String(format: "%.0f percent", configuration.value)))
        }
    }
}

#if canImport(AppKit)
struct FullDiskAccessButton: View {
    var label: String = "Open Full Disk Access Settings"

    var body: some View {
        Button {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
            NSWorkspace.shared.open(url)
        } label: {
            Label(label, systemImage: "gear")
        }
        .buttonStyle(SecondaryButtonStyle())
    }
}
#else
struct FullDiskAccessButton: View {
    var label: String = "Open Full Disk Access Settings"

    var body: some View {
        EmptyView()
    }
}
#endif
