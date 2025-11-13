//  Copyright © 2024 MacCleaner, LLC. All rights reserved.

import SwiftUI

struct ContentView: View {
    private let palette = DesignSystemPalette.macCleanerDark
    @State private var selection: Destination? = .dashboard
    @StateObject private var diagnosticsCenter = DiagnosticsCenter.shared
    @State private var showDiagnostics = false

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
        } detail: {
            detailView(for: selection)
                .environment(\.designSystemPalette, palette)
                .preferredColorScheme(.dark)
        }
        .environment(\.designSystemPalette, palette)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "ladybug")
                }
                .help("Open diagnostics panel")
                .accessibilityIdentifier("DiagnosticsButton")
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsPanel(center: diagnosticsCenter)
                .environment(\.designSystemPalette, palette)
        }
    }

    @ViewBuilder
    private func detailView(for destination: Destination?) -> some View {
        switch destination ?? .dashboard {
        case .dashboard:
            Dashboard()
        case .systemCleanup:
            SystemCleanup()
        case .largeFiles:
            LargeFilesFinder()
        case .uninstaller:
            Uninstaller()
        case .developerTools:
            DeveloperTools()
        }
    }

    enum Destination: Hashable {
        case dashboard
        case systemCleanup
        case largeFiles
        case uninstaller
        case developerTools
    }
}

struct Sidebar: View {
    @Environment(\.designSystemPalette) private var palette
    @Binding var selection: ContentView.Destination?

    @State private var searchText: String = ""
    @State private var metrics: SystemMetricsSnapshot?
    @State private var metricsTask: Task<Void, Never>?

    private let monitorService = SystemMonitorService()

    private let destinations: [SidebarItem] = [
        SidebarItem(
            destination: .dashboard,
            title: "Dashboard",
            icon: "gauge",
            blurb: "Instant health overview",
            accent: \DesignSystemPalette.accentGreen,
            detail: { snapshot in
                guard let snapshot else { return "Collecting system metrics…" }
                let cpu = Sidebar.formatPercentage(snapshot.cpuUsage)
                let memory = Sidebar.formatPercentage(snapshot.memoryUsage)
                return "CPU \(cpu) • Memory \(memory)"
            },
            badge: { snapshot in
                guard let snapshot, snapshot.cpuUsage > 80 else { return nil }
                return SidebarBadge(label: "High CPU", accent: \DesignSystemPalette.accentRed)
            }
        ),
        SidebarItem(
            destination: .systemCleanup,
            title: "System Cleanup",
            icon: "trash",
            blurb: "Purge caches & clutter",
            accent: \DesignSystemPalette.accentGreen,
            detail: { snapshot in
                guard let usesDisk = snapshot?.diskUsage else { return "Review cleanup plans" }
                let disk = Sidebar.formatPercentage(usesDisk)
                return usesDisk > 75
                    ? "Disk usage at \(disk) • Run cleanup soon"
                    : "Disk usage \(disk)"
            },
            badge: { snapshot in
                guard let usage = snapshot?.diskUsage, usage > 85 else { return nil }
                return SidebarBadge(label: "Critical", accent: \DesignSystemPalette.accentRed)
            }
        ),
        SidebarItem(
            destination: .largeFiles,
            title: "Large & Old Files",
            icon: "doc.text.magnifyingglass",
            blurb: "Track bloated directories",
            accent: \DesignSystemPalette.accentGray,
            detail: { snapshot in
                guard let info = snapshot?.storageInfo else { return "Scan your home folder" }
                let free = Sidebar.formatBytes(info.freeSpace)
                return "Free space \(free)"
            },
            badge: { snapshot in
                guard let info = snapshot?.storageInfo else { return nil }
                let freeRatio = Double(info.freeSpace) / Double(info.totalSpace)
                if freeRatio < 0.15 {
                    return SidebarBadge(label: "Low Space", accent: \DesignSystemPalette.accentRed)
                } else if freeRatio < 0.35 {
                    return SidebarBadge(label: "Tight", accent: \DesignSystemPalette.accentGreen)
                }
                return nil
            }
        ),
        SidebarItem(
            destination: .uninstaller,
            title: "Uninstaller",
            icon: "trash.slash",
            blurb: "Remove unused apps",
            accent: \DesignSystemPalette.accentRed,
            detail: { snapshot in
                guard let disk = snapshot?.diskUsage else { return "Review installed apps" }
                let percent = Sidebar.formatPercentage(disk)
                return "System volume at \(percent)"
            },
            badge: { snapshot in
                guard let disk = snapshot?.diskUsage, disk > 70 else { return nil }
                return SidebarBadge(label: "Worth a look", accent: \DesignSystemPalette.accentGray)
            }
        ),
        SidebarItem(
            destination: .developerTools,
            title: "Developer",
            icon: "hammer",
            blurb: "Xcode & simulator hygiene",
            accent: \DesignSystemPalette.accentGray,
            detail: { _ in "Trim derived data & logs" },
            badge: { _ in nil }
        )
    ]

    var body: some View {
        ZStack {
            palette.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.large) {
                header
                searchField
                metricsCard

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.medium) {
                        ForEach(filteredDestinations) { item in
                            destinationRow(for: item)
                        }
                    }
                    .padding(.vertical, DesignSystem.Spacing.small)
                }
                .scrollIndicators(.hidden)

                Spacer(minLength: 0)

                footnote
            }
            .padding(DesignSystem.Spacing.xLarge)
        }
        .preferredColorScheme(.dark)
        .onAppear { startMetricsTask() }
        .onDisappear { metricsTask?.cancel() }
        .onChange(of: searchText) { _ in
            guard let current = selection else {
                selection = filteredDestinations.first?.destination
                return
            }

            if !filteredDestinations.contains(where: { $0.destination == current }) {
                selection = filteredDestinations.first?.destination
            }
        }
    }

    private var filteredDestinations: [SidebarItem] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return destinations }
        return destinations.filter { item in
            item.title.localizedCaseInsensitiveContains(term) ||
            item.blurb.localizedCaseInsensitiveContains(term)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
            Text("MacCleaner")
                .font(DesignSystem.Typography.title)
                .foregroundColor(palette.primaryText)

            Text("Stay ahead with proactive system care.")
                .font(DesignSystem.Typography.body)
                .foregroundColor(palette.secondaryText)
        }
    }

    private var searchField: some View {
        HStack(spacing: DesignSystem.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(palette.secondaryText)
            TextField("Find a workspace", text: $searchText)
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
        .accessibilityLabel("Search MacCleaner sections")
    }

    @ViewBuilder
    private var metricsCard: some View {
        if let snapshot = metrics {
            StatusCard(title: "Live Snapshot", iconName: "waveform.path.ecg", accent: palette.accentGreen) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
                    metricRow(label: "CPU", value: snapshot.cpuUsage, accent: palette.accentGreen)
                    metricRow(label: "Memory", value: snapshot.memoryUsage, accent: palette.accentRed)
                    metricRow(label: "Disk", value: snapshot.diskUsage, accent: palette.accentGray)
                }
            }
        } else {
            StatusCard(title: "Gathering Metrics", iconName: "timer", accent: palette.accentGray) {
                Text("Collecting CPU, memory, and disk data…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(palette.secondaryText)
            }
        }
    }

    private func metricRow(label: String, value: Double, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
            HStack {
                Text(label)
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(palette.secondaryText)
                Spacer()
                Text(Self.formatPercentage(value))
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(palette.primaryText)
            }

            ProgressView(value: value / 100)
                .tint(accent)
                .progressViewStyle(.linear)
        }
    }

    private func destinationRow(for item: SidebarItem) -> some View {
        let isSelected = selection == item.destination
        let accent = palette[keyPath: item.accent]
        let badge = item.badge(metrics)

        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                selection = item.destination
            }
        } label: {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.medium) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accent.opacity(0.18))
                        .frame(width: 44, height: 44)

                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(accent)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
                    HStack(spacing: DesignSystem.Spacing.small) {
                        Text(item.title)
                            .font(DesignSystem.Typography.headline)
                            .foregroundColor(palette.primaryText)

                        if let badge {
                            Text(badge.label.uppercased())
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(palette[keyPath: badge.accent].opacity(0.18))
                                .foregroundColor(palette[keyPath: badge.accent])
                                .clipShape(Capsule(style: .continuous))
                                .accessibilityHidden(true)
                        }
                    }

                    Text(item.detail(metrics) ?? item.blurb)
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(palette.secondaryText)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? accent : palette.secondaryText)
            }
            .padding(.horizontal, DesignSystem.Spacing.medium)
            .padding(.vertical, DesignSystem.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.2) : palette.surface.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.45) : palette.accentGray.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(item.title)")
    }

    private var footnote: some View {
        HStack(spacing: DesignSystem.Spacing.small) {
            Image(systemName: "bolt.fill")
                .foregroundColor(palette.accentGreen)
            Text("Smart tips refresh as your system state changes.")
                .font(DesignSystem.Typography.caption)
                .foregroundColor(palette.secondaryText)
        }
    }

    private func startMetricsTask() {
        metricsTask?.cancel()
        metricsTask = Task {
            for await snapshot in monitorService.metricsStream(interval: 3) {
                await MainActor.run {
                    metrics = snapshot
                }
            }
        }
    }

    private static func formatPercentage(_ value: Double) -> String {
        let clamped = max(0, min(value, 100))
        return String(format: "%.0f%%", clamped)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct SidebarItem: Identifiable {
    let destination: ContentView.Destination
    let title: String
    let icon: String
    let blurb: String
    let accent: KeyPath<DesignSystemPalette, Color>
    let detail: (SystemMetricsSnapshot?) -> String?
    let badge: (SystemMetricsSnapshot?) -> SidebarBadge?

    var id: ContentView.Destination { destination }
}

private struct SidebarBadge {
    let label: String
    let accent: KeyPath<DesignSystemPalette, Color>
}

#Preview {
    ContentView()
}


