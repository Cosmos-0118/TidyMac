import Foundation
import Darwin

struct SystemMetricsSnapshot {
    let cpuUsage: Double
    let memoryUsage: Double
    let diskUsage: Double
    let storageInfo: StorageInfo?
}

@preconcurrency
protocol SystemMonitorServiceProtocol {
    func metricsStream(interval: TimeInterval) -> AsyncStream<SystemMetricsSnapshot>
    func latestMetrics() async -> SystemMetricsSnapshot
}

final class SystemMonitorService: SystemMonitorServiceProtocol {
    private var previousLoadInfo: host_cpu_load_info?
    private var didLogCPUError = false
    private var didLogMemoryError = false
    private var didLogDiskError = false

    func metricsStream(interval: TimeInterval = 1.0) -> AsyncStream<SystemMetricsSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let snapshot = await latestMetrics()
                    continuation.yield(snapshot)
                    let delay = UInt64(max(interval, 0.1) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: delay)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func latestMetrics() async -> SystemMetricsSnapshot {
        let cpu = cpuUsage()
        let memory = memoryUsage()
        let disk = diskUsage()
        let storage = getStorageInfo()
        return SystemMetricsSnapshot(cpuUsage: cpu, memoryUsage: memory, diskUsage: disk, storageInfo: storage)
    }

    private func cpuUsage() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var loadInfo = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            if !didLogCPUError {
                Diagnostics.error(
                    category: .dashboard,
                    message: "host_statistics returned error for CPU usage.",
                    metadata: ["code": "\(result)"]
                )
                didLogCPUError = true
            }
            return 0
        }

        let user = Double(loadInfo.cpu_ticks.0)
        let system = Double(loadInfo.cpu_ticks.1)
        let idle = Double(loadInfo.cpu_ticks.2)
        let nice = Double(loadInfo.cpu_ticks.3)
        let total = user + system + idle + nice

        guard total > 0 else {
            previousLoadInfo = loadInfo
            return 0
        }

        if let previous = previousLoadInfo {
            let prevUser = Double(previous.cpu_ticks.0)
            let prevSystem = Double(previous.cpu_ticks.1)
            let prevIdle = Double(previous.cpu_ticks.2)
            let prevNice = Double(previous.cpu_ticks.3)
            let prevTotal = prevUser + prevSystem + prevIdle + prevNice

            let totalDiff = total - prevTotal
            let idleDiff = idle - prevIdle

            previousLoadInfo = loadInfo

            guard totalDiff > 0 else { return 0 }
            let usage = (1 - (idleDiff / totalDiff)) * 100
            return max(0, min(usage, 100))
        } else {
            previousLoadInfo = loadInfo
            let usage = (1 - (idle / total)) * 100
            return max(0, min(usage, 100))
        }
    }

    private func memoryUsage() -> Double {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            if !didLogMemoryError {
                Diagnostics.error(
                    category: .dashboard,
                    message: "task_info returned error for memory usage.",
                    metadata: ["code": "\(result)"]
                )
                didLogMemoryError = true
            }
            return 0
        }

        let usedMemory = Double(taskInfo.resident_size)
        let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
        guard totalMemory > 0 else { return 0 }
        let usage = (usedMemory / totalMemory) * 100
        return max(0, min(usage, 100))
    }

    private func diskUsage() -> Double {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
            if let totalSize = attributes[.systemSize] as? Int64,
               let freeSize = attributes[.systemFreeSize] as? Int64,
               totalSize > 0 {
                let usedSize = totalSize - freeSize
                let usage = Double(usedSize) / Double(totalSize) * 100
                return max(0, min(usage, 100))
            }
        } catch {
            if !didLogDiskError {
                Diagnostics.error(
                    category: .dashboard,
                    message: "Failed to read file system attributes for disk usage.",
                    error: error
                )
                didLogDiskError = true
            }
            return 0
        }
        return 0
    }
}
