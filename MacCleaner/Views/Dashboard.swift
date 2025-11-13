//  Copyright © 2024 MacCleaner, LLC. All rights reserved.

import SwiftUI

struct Dashboard: View {
    @Environment(\.designSystemPalette) private var palette

    @StateObject private var viewModel: DashboardViewModel

    init() {
        _viewModel = StateObject(wrappedValue: DashboardViewModel())
    }

    init(previewStorageInfo: StorageInfo?, previewMetrics: DashboardMetricSnapshot) {
        let snapshot = SystemMetricsSnapshot(
            cpuUsage: previewMetrics.cpu,
            memoryUsage: previewMetrics.memory,
            diskUsage: previewMetrics.disk,
            storageInfo: previewStorageInfo
        )
        let service = PreviewSystemMonitorService(snapshot: snapshot)
        _viewModel = StateObject(wrappedValue: DashboardViewModel(monitorService: service, initialSnapshot: snapshot))
    }

    var body: some View {
        ScrollView {
            Grid(horizontalSpacing: DesignSystem.Spacing.large, verticalSpacing: DesignSystem.Spacing.large) {
                GridRow {
                    StatusCard(title: "Storage Overview", iconName: "internaldrive", accent: palette.accentGreen) {
                        storageSection
                    }
                    .gridCellColumns(2)
                }

                GridRow {
                    MetricGauge(configuration: .init(
                        title: "CPU Usage",
                        value: viewModel.cpuUsage,
                        systemImage: "cpu",
                        accent: palette.accentRed,
                        accessibilityLabel: "Current CPU usage"
                    ))

                    MetricGauge(configuration: .init(
                        title: "Memory Usage",
                        value: viewModel.memoryUsage,
                        systemImage: "memorychip",
                        accent: palette.accentGreen,
                        accessibilityLabel: "Current memory usage"
                    ))

                    MetricGauge(configuration: .init(
                        title: "Disk Usage",
                        value: viewModel.diskUsage,
                        systemImage: "externaldrive",
                        accent: palette.accentGray,
                        accessibilityLabel: "Current disk usage"
                    ))
                }
            }
            .padding(DesignSystem.Spacing.xLarge)
        }
        .background(palette.background.ignoresSafeArea())
        .dynamicTypeSize(.medium ... .accessibility3)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
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

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
    Dashboard(previewStorageInfo: DashboardPreviewData.storage, previewMetrics: DashboardPreviewData.metrics)
        .environment(\.designSystemPalette, .macCleanerDark)
}

#Preview("Dashboard • Error") {
    Dashboard(previewStorageInfo: nil, previewMetrics: DashboardMetricSnapshot(cpu: 37, memory: 55, disk: 81))
        .environment(\.designSystemPalette, .macCleanerDark)
}
#endif
