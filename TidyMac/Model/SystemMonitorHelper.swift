import Foundation
import Darwin
#if os(macOS)
import IOKit.ps
#endif

struct BatteryInfo: Equatable {
    let percentage: Double
    let isCharging: Bool
    let isCharged: Bool
    let powerSourceState: String?
    let cycleCount: Int?
    let health: String?
    let timeRemainingMinutes: Int?
    let timeToFullMinutes: Int?
}

struct SystemMetricsSnapshot {
    let cpuUsage: Double
    let memoryUsage: Double
    let diskUsage: Double
    let storageInfo: StorageInfo?
    let batteryInfo: BatteryInfo?
    let systemUptime: TimeInterval
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
        let battery = batteryInfo()
        let uptime = ProcessInfo.processInfo.systemUptime
        return SystemMetricsSnapshot(cpuUsage: cpu, memoryUsage: memory, diskUsage: disk, storageInfo: storage, batteryInfo: battery, systemUptime: uptime)
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
        // Prefer system-wide memory for accuracy over app-only resident size.
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            if !didLogMemoryError {
                Diagnostics.error(
                    category: .dashboard,
                    message: "host_statistics64 returned error for memory usage.",
                    metadata: ["code": "\(result)"]
                )
                didLogMemoryError = true
            }
            return 0
        }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Double(pageSize)

        let active = Double(stats.active_count) * page
        let inactive = Double(stats.inactive_count) * page
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        let used = active + inactive + wired + compressed

        let free = Double(stats.free_count) * page
        let speculative = Double(stats.speculative_count) * page
        let total = used + free + speculative

        guard total > 0 else { return 0 }
        let usage = (used / total) * 100
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

    private func batteryInfo() -> BatteryInfo? {
#if os(macOS)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef], !sources.isEmpty else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard let type = description[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType else { continue }

            let currentCapacity = description[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int ?? 0
            guard maxCapacity > 0 else { continue }

            let percentage = max(0, min(Double(currentCapacity) / Double(maxCapacity) * 100, 100))
            let isCharging = (description[kIOPSIsChargingKey as String] as? Bool) ?? false
            let isCharged = (description[kIOPSIsChargedKey as String] as? Bool) ?? false
            let powerSourceState = description[kIOPSPowerSourceStateKey as String] as? String
            let cycleCount = description["CycleCount"] as? Int
            let health = (description[kIOPSBatteryHealthKey as String] as? String).flatMap { normalizeHealth($0) }

            func normalizedTime(_ key: String) -> Int? {
                guard let value = description[key] as? Int else { return nil }
                return value >= 0 ? value : nil
            }

            let timeRemaining = powerSourceState == kIOPSBatteryPowerValue ? normalizedTime(kIOPSTimeToEmptyKey as String) : nil
            let timeToFull = (powerSourceState == kIOPSACPowerValue && isCharging) ? normalizedTime(kIOPSTimeToFullChargeKey as String) : nil

            return BatteryInfo(
                percentage: percentage,
                isCharging: isCharging,
                isCharged: isCharged,
                powerSourceState: powerSourceState,
                cycleCount: cycleCount,
                health: health,
                timeRemainingMinutes: timeRemaining,
                timeToFullMinutes: timeToFull
            )
        }

        return nil
#else
    return nil
#endif
    }
}

private func normalizeHealth(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let lower = trimmed.lowercased()
    switch lower {
    case "good": return "Good"
    case "check battery", "checkbattery": return "Check Battery"
    case "fair": return "Fair"
    case "poor": return "Poor"
    default:
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}
