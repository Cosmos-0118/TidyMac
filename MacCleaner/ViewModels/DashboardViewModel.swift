import Foundation
import Combine

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var storageInfo: StorageInfo?
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var memoryUsage: Double = 0
    @Published private(set) var diskUsage: Double = 0

    private let monitorService: SystemMonitorServiceProtocol
    private var metricsTask: Task<Void, Never>?

    init(monitorService: SystemMonitorServiceProtocol = SystemMonitorService(), initialSnapshot: SystemMetricsSnapshot? = nil) {
        self.monitorService = monitorService
        if let snapshot = initialSnapshot {
            apply(snapshot)
        } else {
            storageInfo = getStorageInfo()
        }
    }

    func start() {
        guard metricsTask == nil else { return }
        metricsTask = Task {
            for await snapshot in monitorService.metricsStream(interval: 1.0) {
                self.apply(snapshot)
            }
        }
    }

    func stop() {
        metricsTask?.cancel()
        metricsTask = nil
    }

    func refreshStorageInfo() {
        storageInfo = getStorageInfo()
    }

    deinit {
        metricsTask?.cancel()
    }

    private func apply(_ snapshot: SystemMetricsSnapshot) {
        cpuUsage = snapshot.cpuUsage
        memoryUsage = snapshot.memoryUsage
        diskUsage = snapshot.diskUsage
        storageInfo = snapshot.storageInfo
    }
}
