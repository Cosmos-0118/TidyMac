//  Copyright © 2024 MacCleaner, LLC. All rights reserved.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct Uninstaller: View {
    @Environment(\.designSystemPalette) private var palette

    private let autoFetch: Bool
    @StateObject private var viewModel: UninstallerViewModel
    @State private var uninstallConfirmation = false

    init(autoFetch: Bool = true, viewModel: UninstallerViewModel? = nil) {
        self.autoFetch = autoFetch
        _viewModel = StateObject(wrappedValue: viewModel ?? UninstallerViewModel())
    }

    init(previewApplications: [Application]) {
        autoFetch = false
        _viewModel = StateObject(wrappedValue: UninstallerViewModel(applications: previewApplications))
    }

    var body: some View {
        ZStack {
            palette.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.large) {
                header

                HStack(alignment: .top, spacing: DesignSystem.Spacing.large) {
                    sidebar
                        .frame(minWidth: 260, maxWidth: 320, maxHeight: .infinity)

                    detailPane
                        .frame(maxWidth: .infinity, alignment: .top)
                }

                Spacer(minLength: 0)
            }
            .padding(DesignSystem.Spacing.xLarge)
        }
        .dynamicTypeSize(.medium ... .accessibility3)
        .onAppear {
            viewModel.handleAppear(autoFetch: autoFetch)
        }
        .onChange(of: viewModel.searchText) { _ in
            viewModel.ensureSelectionConsistency()
        }
        .confirmationDialog(
            "Uninstall \(viewModel.selectedApplication?.name ?? "application")?",
            isPresented: $uninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                if let app = viewModel.selectedApplication {
                    Task { await viewModel.uninstall(app) }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.medium) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
                Text("Uninstaller")
                    .font(DesignSystem.Typography.title)
                    .foregroundColor(palette.primaryText)

                Text("Review installed apps, understand their install location, and uninstall with confidence.")
                    .font(DesignSystem.Typography.body)
                    .foregroundColor(palette.secondaryText)

                Text(viewModel.appSummary)
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(palette.secondaryText)
            }

            HStack(spacing: DesignSystem.Spacing.medium) {
                searchField

                Button {
                    Task { await viewModel.refreshApplications() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(viewModel.isLoading)
                .help("Refresh installed application list")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: DesignSystem.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(palette.secondaryText)

            TextField("Search by name or bundle ID", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .foregroundColor(palette.primaryText)
                .disableAutocorrection(true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, DesignSystem.Spacing.medium)
        .background(palette.surface.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.accentGray.opacity(0.3), lineWidth: 1)
        )
        .accessibilityLabel("Search installed applications")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.medium) {
            if viewModel.isLoading {
                VStack(spacing: DesignSystem.Spacing.small) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(palette.accentGreen)
                    Text("Scanning for applications…")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(palette.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if viewModel.applications.isEmpty {
                emptySidebarState
            } else if viewModel.filteredApplications.isEmpty {
                noResultsSidebarState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.medium) {
                        ForEach(viewModel.filteredGroups()) { group in
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
                                groupHeader(for: group)

                                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
                                    ForEach(group.apps) { app in
                                        sidebarRow(for: app)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, DesignSystem.Spacing.small)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(DesignSystem.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(palette.surface.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.accentGray.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var detailPane: some View {
        if let app = viewModel.selectedApplication {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.large) {
                    StatusCard(title: app.name, iconName: "app.badge", accent: palette.accentGray) {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
                            Text(app.locationDescription)
                                .font(DesignSystem.Typography.body)
                                .foregroundColor(palette.primaryText)
                            Text(app.bundleID)
                                .font(DesignSystem.Typography.caption)
                                .foregroundColor(palette.secondaryText)
                        }
                    }

                    if let banner = viewModel.banner {
                        StatusCard(
                            title: banner.title,
                            iconName: banner.success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                            accent: banner.success ? palette.accentGreen : palette.accentRed
                        ) {
                            Text(banner.message)
                                .font(DesignSystem.Typography.body)
                                .foregroundColor(palette.primaryText)
                            if banner.requiresFullDiskAccess {
                                FullDiskAccessButton()
                            }
                        }
                    }

                    if app.requiresRoot {
                        StatusCard(title: "Admin Privileges Required", iconName: "lock.shield.fill", accent: palette.accentRed) {
                            Text("Apps installed to \(app.installLocation.displayName) require administrator approval to remove. Run MacCleaner with elevated privileges or uninstall manually if the automatic removal fails.")
                                .font(DesignSystem.Typography.body)
                                .foregroundColor(palette.primaryText)
                            FullDiskAccessButton()
                        }
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.medium) {
                        Text("Details")
                            .font(DesignSystem.Typography.headline)
                            .foregroundColor(palette.primaryText)

                        detailRow(label: "Location", value: app.displayPath)
                        detailRow(label: "Requires Root", value: app.requiresRoot ? "Yes" : "No")
                    }

                    HStack(spacing: DesignSystem.Spacing.medium) {
                        Button {
                            uninstallConfirmation = true
                        } label: {
                            Label(app.requiresRoot ? "Request Uninstall" : "Uninstall", systemImage: "trash")
                        }
                        .buttonStyle(DestructiveButtonStyle())

                        Button {
                            revealInFinder(app)
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(DesignSystem.Spacing.large)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(palette.surface.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(palette.accentGray.opacity(0.25), lineWidth: 1)
            )
            .padding(.top, DesignSystem.Spacing.small)
        } else if viewModel.isLoading {
            StatusCard(title: "Loading Applications", iconName: "arrow.triangle.2.circlepath", accent: palette.accentGray) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(palette.accentGreen)
                    Text("Refreshing the installed apps catalog…")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(palette.secondaryText)
                }
            }
            .padding(.top, DesignSystem.Spacing.small)
        } else if viewModel.applications.isEmpty {
            StatusCard(title: "No Applications Found", iconName: "macwindow", accent: palette.accentGray) {
                Text("We couldn't find any apps to uninstall. Refresh after installing or relocating apps.")
                    .font(DesignSystem.Typography.body)
                    .foregroundColor(palette.primaryText)
            }
            .padding(.top, DesignSystem.Spacing.small)
        } else {
            StatusCard(title: "Select an Application", iconName: "cursorarrow.rays", accent: palette.accentGreen) {
                Text("Choose an app from the sidebar to review its details and uninstall options.")
                    .font(DesignSystem.Typography.body)
                    .foregroundColor(palette.primaryText)
            }
            .padding(.top, DesignSystem.Spacing.small)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundColor(palette.secondaryText)
            Spacer()
            Text(value)
                .font(DesignSystem.Typography.body)
                .foregroundColor(palette.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, DesignSystem.Spacing.xSmall)
    }

    private func groupHeader(for group: ApplicationGroup) -> some View {
        HStack {
            Text(group.title)
                .font(DesignSystem.Typography.caption)
                .foregroundColor(palette.secondaryText)
            Spacer()
            if group.requiresRoot {
                Label("Admin", systemImage: "lock")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(palette.accentRed)
            }
        }
    }

    private func sidebarRow(for app: Application) -> some View {
        let isSelected = viewModel.selectedApplication?.id == app.id

        return Button {
            viewModel.selectApplication(app)
        } label: {
            HStack(spacing: DesignSystem.Spacing.medium) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill((isSelected ? palette.accentGreen : palette.accentGray).opacity(0.18))
                        .frame(width: 44, height: 44)

                    Image(systemName: app.requiresRoot ? "lock.shield" : "macwindow")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(app.requiresRoot ? palette.accentRed : palette.accentGreen)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
                    Text(app.name)
                        .font(DesignSystem.Typography.headline)
                        .foregroundColor(palette.primaryText)

                    Text(app.bundleID)
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(palette.secondaryText)
                }

                Spacer()

                if app.requiresRoot {
                    Image(systemName: "bolt.shield")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(palette.accentRed)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.medium)
            .padding(.vertical, DesignSystem.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? palette.accentGreen.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? palette.accentGreen.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(app.name)")
        .accessibilityHint(app.requiresRoot ? "Requires admin privileges" : "User-installed app")
    }

    private var emptySidebarState: some View {
        VStack(spacing: DesignSystem.Spacing.medium) {
            Image(systemName: "tray")
                .font(.system(size: 38, weight: .semibold))
                .foregroundColor(palette.accentGray)
            Text("No applications detected.")
                .font(DesignSystem.Typography.headline)
                .foregroundColor(palette.primaryText)
            Text("Install apps or refresh the list to populate the uninstaller queue.")
                .font(DesignSystem.Typography.caption)
                .foregroundColor(palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var noResultsSidebarState: some View {
        VStack(spacing: DesignSystem.Spacing.medium) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 38, weight: .semibold))
                .foregroundColor(palette.accentGray)
            Text("No matches")
                .font(DesignSystem.Typography.headline)
                .foregroundColor(palette.primaryText)
            Text("Try a different search term or clear the filter to browse all apps.")
                .font(DesignSystem.Typography.caption)
                .foregroundColor(palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func revealInFinder(_ app: Application) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([app.resolvedBundleURL])
        #endif
    }
}

// MARK: - Preview

#if DEBUG
private enum UninstallerPreviewData {
    static var applications: [Application] {
        guard let asset = NSDataAsset(name: "UninstallerSample") else { return [] }
        return (try? JSONDecoder().decode([Application].self, from: asset.data)) ?? []
    }
}

#Preview("Uninstaller • Loaded") {
    Uninstaller(previewApplications: UninstallerPreviewData.applications)
        .environment(\.designSystemPalette, .macCleanerDark)
}

#Preview("Uninstaller • Empty") {
    Uninstaller(previewApplications: [])
        .environment(\.designSystemPalette, .macCleanerDark)
}
#endif
