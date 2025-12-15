import SwiftUI

@MainActor
struct DeveloperTools: View {
    @Environment(\.designSystemPalette) private var palette
    @Namespace private var overlayNamespace

    @StateObject private var viewModel: DeveloperToolsViewModel

    init() {
        _viewModel = StateObject(wrappedValue: DeveloperToolsViewModel())
    }

    init(viewModel: DeveloperToolsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            palette.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.large) {
                header

                if let banner = viewModel.banner {
                    StatusCard(
                        title: banner.success ? "Operation Succeeded" : "Operation Failed",
                        iconName: banner.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        accent: banner.success ? palette.accentGreen : palette.accentRed
                    ) {
                        Text(banner.message)
                            .font(DesignSystem.Typography.body)
                            .foregroundColor(palette.primaryText)
                        if !banner.success, banner.requiresFullDiskAccess {
                            FullDiskAccessButton()
                        }
                    }
                }

                categoryPicker

                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.medium) {
                        ForEach(descriptors(for: viewModel.selectedCategory)) { descriptor in
                            StatusCard(title: descriptor.title, iconName: descriptor.icon, accent: descriptor.accentColor(palette: palette)) {
                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
                                    Text(descriptor.subtitle)
                                        .font(DesignSystem.Typography.body)
                                        .foregroundColor(palette.primaryText)

                                    if let caution = descriptor.cautionText {
                                        Text(caution)
                                            .font(DesignSystem.Typography.caption)
                                            .foregroundColor(palette.secondaryText)
                                    }

                                    HStack {
                                        Button {
                                            viewModel.runOperation(descriptor.operation)
                                        } label: {
                                            Label(descriptor.buttonTitle, systemImage: descriptor.buttonIcon)
                                        }
                                        .buttonStyle(descriptor.buttonStyle)
                                        .disabled(viewModel.activeOperation != nil)

                                        if let secondary = descriptor.secondaryAction {
                                            Button {
                                                secondary.action()
                                            } label: {
                                                Label(secondary.title, systemImage: secondary.icon)
                                            }
                                            .buttonStyle(SecondaryButtonStyle())
                                            .disabled(viewModel.activeOperation != nil)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, DesignSystem.Spacing.large)
                }
                .scrollIndicators(.hidden)

                Spacer(minLength: 0)
            }
            .padding(DesignSystem.Spacing.xLarge)
            .animation(.spring(response: 0.45, dampingFraction: 0.85, blendDuration: 0.18), value: showOverlay)
        }
        .overlay(alignment: .center) {
            if showOverlay {
                overlayCard
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .center)))
            }
        }
        .dynamicTypeSize(.medium ... .accessibility3)
    }

    private var showOverlay: Bool {
        viewModel.activeOperation != nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
            Text("Developer Tools")
                .font(DesignSystem.Typography.title)
                .foregroundColor(palette.primaryText)

            Text("Manage caches, simulators, and toolchains with quick actions.")
                .font(DesignSystem.Typography.caption)
                .foregroundColor(palette.secondaryText)
        }
    }

    private var categoryPicker: some View {
        Picker("Category", selection: $viewModel.selectedCategory) {
            ForEach(DeveloperCategory.allCases) { category in
                Text(category.title).tag(category)
            }
        }
        .pickerStyle(.segmented)
        .padding(.bottom, DesignSystem.Spacing.medium)
        .accessibilityLabel("Developer tooling category")
    }

    private func descriptors(for category: DeveloperCategory) -> [OperationDescriptor] {
        switch category {
        case .caches:
            return [
                OperationDescriptor(
                    title: "Clear DerivedData",
                    subtitle: "Removes Xcode build artifacts and previews for a fresh clean build.",
                    icon: "hammer.circle.fill",
                    operation: .clearDerivedData,
                    tone: .safe,
                    buttonTitle: "Clear DerivedData",
                    buttonIcon: "trash"
                ),
                OperationDescriptor(
                    title: "Reset Xcode Caches",
                    subtitle: "Clears index, module, and SourceKit caches to fix autocomplete issues.",
                    icon: "icloud.slash",
                    operation: .clearXcodeCaches,
                    tone: .safe,
                    buttonTitle: "Reset Caches",
                    buttonIcon: "arrow.counterclockwise"
                ),
                OperationDescriptor(
                    title: "Clean VS Code Support",
                    subtitle: "Deletes VS Code cache and temp extensions data.",
                    icon: "terminal.fill",
                    operation: .clearVSCodeCaches,
                    tone: .safe,
                    buttonTitle: "Clean VS Code",
                    buttonIcon: "trash"
                )
            ]

        case .simulators:
            return [
                OperationDescriptor(
                    title: "Reset Simulator Cache",
                    subtitle: "Flushes CoreSimulator caches without touching installed devices.",
                    icon: "iphone.homebutton.circle",
                    operation: .resetSimulatorCaches,
                    tone: .safe,
                    buttonTitle: "Reset Cache",
                    buttonIcon: "arrow.counterclockwise"
                ),
                OperationDescriptor(
                    title: "Delete Simulator Devices",
                    subtitle: "Removes all simulator devices, forcing Xcode to recreate them on next launch.",
                    icon: "trash.slash",
                    operation: .purgeSimulatorDevices,
                    tone: .destructive,
                    buttonTitle: "Delete Devices",
                    buttonIcon: "trash",
                    cautionText: "This cannot be undone. Downloaded runtimes remain installed."
                )
            ]

        case .toolchains:
            return [
                OperationDescriptor(
                    title: "Clear Toolchain Logs",
                    subtitle: "Deletes log output generated by custom toolchains and swift build diagnostics.",
                    icon: "doc.text.magnifyingglass",
                    operation: .clearToolchainLogs,
                    tone: .safe,
                    buttonTitle: "Clear Logs",
                    buttonIcon: "trash"
                ),
                OperationDescriptor(
                    title: "Remove Custom Toolchains",
                    subtitle: "Deletes third-party toolchains from ~/Library/Developer/Toolchains.",
                    icon: "wrench.and.screwdriver",
                    operation: .purgeCustomToolchains,
                    tone: .destructive,
                    buttonTitle: "Remove Toolchains",
                    buttonIcon: "trash",
                    cautionText: "Apple-provided default toolchains are preserved."
                )
            ]
        }
    }

}

private extension DeveloperTools {
    var overlayCard: some View {
        ZStack {
            palette.background.opacity(0.55)
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.surface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(palette.accentGreen.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: palette.accentGray.opacity(0.35), radius: 28, x: 0, y: 12)
                .frame(maxWidth: 520)
                .frame(height: 260)
                .overlay {
                    VStack(spacing: DesignSystem.Spacing.large) {
                        HStack(spacing: DesignSystem.Spacing.small) {
                            Image(systemName: "hammer.circle")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(palette.accentGreen)
                            Text("Running Tooling Task")
                                .font(DesignSystem.Typography.headline)
                                .foregroundColor(palette.primaryText)
                        }

                        VStack(spacing: DesignSystem.Spacing.small) {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(palette.accentGreen)
                            Text("We’re applying your developer action. This usually finishes in a moment.")
                                .font(DesignSystem.Typography.caption)
                                .foregroundColor(palette.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(DesignSystem.Spacing.xLarge)
                }
        }
    }
}

// MARK: - Supporting Types

private struct OperationDescriptor: Identifiable {
    struct SecondaryAction {
        let title: String
        let icon: String
        let action: () -> Void
    }

    enum Tone {
        case safe
        case destructive
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let operation: DeveloperOperation
    let tone: Tone
    let buttonTitle: String
    let buttonIcon: String
    var cautionText: String?
    var secondaryAction: SecondaryAction?

    func accentColor(palette: DesignSystemPalette) -> Color {
        tone == .safe ? palette.accentGreen : palette.accentRed
    }

    var buttonStyle: some ButtonStyle {
        tone == .safe ? AnyButtonStyle(PrimaryActionButtonStyle()) : AnyButtonStyle(DestructiveButtonStyle())
    }
}

// Wraps any button style to satisfy type erasure.
private struct AnyButtonStyle: ButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        makeBodyClosure = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}
