//  Copyright © 2024 MacCleaner, LLC. All rights reserved.

import SwiftUI
#if os(macOS)
import IOKit.ps
#endif

struct Dashboard: View {
    @Environment(\.designSystemPalette) private var palette

    @StateObject private var viewModel: DashboardViewModel

    init() {
        _viewModel = StateObject(wrappedValue: DashboardViewModel())
    }

    init(previewStorageInfo: StorageInfo?, previewMetrics: DashboardMetricSnapshot, previewBattery: BatteryInfo? = nil, previewUptime: TimeInterval = 0) {
        let snapshot = SystemMetricsSnapshot(
            cpuUsage: previewMetrics.cpu,
            memoryUsage: previewMetrics.memory,
            diskUsage: previewMetrics.disk,
            storageInfo: previewStorageInfo,
            batteryInfo: previewBattery,
            systemUptime: previewUptime
        )
        let service = PreviewSystemMonitorService(snapshot: snapshot)
        _viewModel = StateObject(wrappedValue: DashboardViewModel(monitorService: service, initialSnapshot: snapshot))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.large) {
                heroCard

                LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.large) {
                    StatusCard(title: "Storage", iconName: "internaldrive", accent: palette.accentGreen) {
                        storageSection
                    }

                    StatusCard(title: "Battery", iconName: "bolt.horizontal", accent: palette.accentGreen) {
                        batterySection
                    }

                    StatusCard(title: "CPU", iconName: "cpu", accent: palette.accentRed) {
                        gaugeTile(title: "CPU Usage", value: viewModel.cpuUsage, icon: "cpu", accent: palette.accentRed)
                    }

                    StatusCard(title: "Memory", iconName: "memorychip", accent: palette.accentGreen) {
                        gaugeTile(title: "Memory Usage", value: viewModel.memoryUsage, icon: "memorychip", accent: palette.accentGreen)
                    }

                    StatusCard(title: "Disk", iconName: "externaldrive", accent: palette.accentGray) {
                        gaugeTile(title: "Disk Usage", value: viewModel.diskUsage, icon: "externaldrive", accent: palette.accentGray)
                    }

                    StatusCard(title: "Uptime", iconName: "clock.arrow.2.circlepath", accent: palette.accentGray) {
                        uptimeSection
                    }
                }
            }
            .padding(DesignSystem.Spacing.xLarge)
        }
        .background(palette.background.ignoresSafeArea())
        .dynamicTypeSize(.medium ... .accessibility3)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var columns: [GridItem] {
        [GridItem(.flexible(minimum: 320), spacing: DesignSystem.Spacing.large),
         GridItem(.flexible(minimum: 320), spacing: DesignSystem.Spacing.large)]
    }

    private var heroCard: some View {
        StatusCard(title: "System Snapshot", iconName: "sparkles", accent: palette.accentGreen) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.large) {
                HStack(spacing: DesignSystem.Spacing.large) {
                    compactMetric(title: "CPU", value: viewModel.cpuUsage, accent: palette.accentRed)
                    compactMetric(title: "Memory", value: viewModel.memoryUsage, accent: palette.accentGreen)
                    compactMetric(title: "Disk", value: viewModel.diskUsage, accent: palette.accentGray)
                }

                HStack(spacing: DesignSystem.Spacing.large) {
                    if let battery = viewModel.batteryInfo {
                        batteryBadge(for: battery)
                    } else {
                        Text("Battery info unavailable")
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(palette.secondaryText)
                    }

                    Divider()
                        .frame(height: 24)
                        .background(palette.accentGray.opacity(0.3))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Uptime")
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(palette.secondaryText)
                        Text(formatUptime(viewModel.systemUptime))
                            .font(DesignSystem.Typography.body)
                            .foregroundColor(palette.primaryText)
                    }
                }
            }
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.medium) {
            if let storageInfo = viewModel.storageInfo {
                MetricTextRow(title: "Total Space", value: formatBytes(storageInfo.totalSpace))
                    .accessibilityLabel("Total space")
                    .accessibilityValue(Text(formatBytes(storageInfo.totalSpace)))
                MetricTextRow(title: "Free Space", value: formatBytes(storageInfo.freeSpace))
                    .accessibilityLabel("Free space")
                    .accessibilityValue(Text(formatBytes(storageInfo.freeSpace)))
                MetricTextRow(title: "Used Space", value: formatBytes(storageInfo.usedSpace))
                    .accessibilityLabel("Used space")
                    .accessibilityValue(Text(formatBytes(storageInfo.usedSpace)))
            } else {
                Text("Unable to retrieve storage information")
                    .font(DesignSystem.Typography.body)
                    .foregroundColor(palette.accentRed)
                    .accessibilityLabel("Storage information unavailable")
            }
        }
    }

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
            if let battery = viewModel.batteryInfo {
                HStack(spacing: DesignSystem.Spacing.medium) {
                    Gauge(value: battery.percentage, in: 0...100) {
                        Text("Battery")
                    }
                    .tint(palette.accentGreen)
                    .gaugeStyle(.accessoryCircularCapacity)
                    .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Int(battery.percentage))%")
                            .font(DesignSystem.Typography.headline)
                            .foregroundColor(palette.primaryText)
                        Text(batteryStatusText(battery))
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(palette.secondaryText)
                        if let health = battery.health, !health.isEmpty {
                            Text("Health: \(health)")
                                .font(DesignSystem.Typography.caption)
                                .foregroundColor(palette.secondaryText)
                        }
                    }
                }

                if let cycles = battery.cycleCount {
                    MetricTextRow(title: "Cycle Count", value: "\(cycles)")
                }

                if let timeToFull = battery.timeToFullMinutes, battery.isCharging {
                    MetricTextRow(title: "Full in", value: formatMinutes(timeToFull))
                }

                if let timeRemaining = battery.timeRemainingMinutes, battery.powerSourceState == kIOPSBatteryPowerValue {
                    MetricTextRow(title: "Time Remaining", value: formatMinutes(timeRemaining))
                }
            } else {
                Text("Battery details unavailable")
                    .font(DesignSystem.Typography.body)
                    .foregroundColor(palette.secondaryText)
            }
        }
    }

    private var uptimeSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
            Text(formatUptime(viewModel.systemUptime))
                .font(DesignSystem.Typography.headline)
                .foregroundColor(palette.primaryText)
            Text("Time since last reboot")
                .font(DesignSystem.Typography.caption)
                .foregroundColor(palette.secondaryText)
        }
    }

    private func gaugeTile(title: String, value: Double, icon: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.medium) {
            MetricGauge(configuration: .init(
                title: title,
                value: value,
                systemImage: icon,
                accent: accent,
                accessibilityLabel: title
            ))
            Text("Current: \(Int(value))%")
                .font(DesignSystem.Typography.caption)
                .foregroundColor(palette.secondaryText)
        }
    }

    private func compactMetric(title: String, value: Double, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DesignSystem.Typography.caption)
                .foregroundColor(palette.secondaryText)

            HStack(spacing: DesignSystem.Spacing.small) {
                Text("\(Int(value))%")
                    .font(DesignSystem.Typography.headline)
                    .foregroundColor(palette.primaryText)
                ProgressView(value: value, total: 100)
                    .accentColor(accent)
                    .frame(maxWidth: 140)
            }
        }
    }

    private func batteryBadge(for battery: BatteryInfo) -> some View {
        HStack(spacing: DesignSystem.Spacing.small) {
            Image(systemName: battery.isCharging ? "bolt.fill" : "bolt.horizontal")
                .foregroundColor(palette.accentGreen)
            Text("Battery \(Int(battery.percentage))%")
                .font(DesignSystem.Typography.body)
                .foregroundColor(palette.primaryText)
        }
    }

    private func batteryStatusText(_ battery: BatteryInfo) -> String {
        #if os(macOS)
        let source = battery.powerSourceState ?? ""
        if source == kIOPSACPowerValue {
            if battery.isCharging { return "Charging" }
            if battery.isCharged { return "Fully charged (on adapter)" }
            return "On adapter"
        }
        if source == kIOPSBatteryPowerValue {
            return "On battery"
        }
        #endif
        return battery.isCharging ? "Charging" : (battery.isCharged ? "Fully charged" : "On battery")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let mins = totalMinutes % 60

        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if mins > 0 { parts.append("\(mins)m") }
        return parts.isEmpty ? "Just booted" : parts.joined(separator: " ")
    }
}

private struct MetricTextRow: View {
    @Environment(\.designSystemPalette) private var palette
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(DesignSystem.Typography.body)
                .foregroundColor(palette.secondaryText)
            Spacer()
            Text(value)
                .font(DesignSystem.Typography.body)
                .foregroundColor(palette.primaryText)
        }
    }
}

struct DashboardMetricSnapshot {
    let cpu: Double
    let memory: Double
    let disk: Double
}

#if DEBUG
import AppKit

private enum DashboardPreviewData {
    static var storage: StorageInfo? = {
        guard let asset = NSDataAsset(name: "DashboardSample") else {
            return StorageInfo(totalSpace: 512_000_000_000, freeSpace: 210_000_000_000, usedSpace: 302_000_000_000)
        }
        return try? JSONDecoder().decode(StorageInfo.self, from: asset.data)
    }()

    static let metrics = DashboardMetricSnapshot(cpu: 42, memory: 63, disk: 78)
    static let battery = BatteryInfo(
        percentage: 82,
        isCharging: true,
        isCharged: false,
        powerSourceState: kIOPSACPowerValue,
        cycleCount: 315,
        health: "Good",
        timeRemainingMinutes: nil,
        timeToFullMinutes: 55
    )
}

private struct PreviewSystemMonitorService: SystemMonitorServiceProtocol {
    let snapshot: SystemMetricsSnapshot

    func metricsStream(interval _: TimeInterval) -> AsyncStream<SystemMetricsSnapshot> {
        AsyncStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    func latestMetrics() async -> SystemMetricsSnapshot {
        snapshot
    }
}

#Preview("Dashboard • Loaded") {
    Dashboard(previewStorageInfo: DashboardPreviewData.storage, previewMetrics: DashboardPreviewData.metrics, previewBattery: DashboardPreviewData.battery, previewUptime: 98_000)
        .environment(\.designSystemPalette, .macCleanerDark)
}

#Preview("Dashboard • Error") {
    Dashboard(previewStorageInfo: nil, previewMetrics: DashboardMetricSnapshot(cpu: 37, memory: 55, disk: 81), previewBattery: nil, previewUptime: 2_000)
        .environment(\.designSystemPalette, .macCleanerDark)
}
#endif
