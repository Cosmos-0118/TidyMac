import Combine
import Foundation
import OSLog

enum DiagnosticsCategory: String, CaseIterable, Identifiable {
    case dashboard
    case cleanup
    case uninstaller

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dashboard:
            return "Dashboard"
        case .cleanup:
            return "Cleanup"
        case .uninstaller:
            return "Uninstaller"
        }
    }
}

enum DiagnosticsSeverity: Int, Comparable, CaseIterable {
    case info = 0
    case warning = 1
    case error = 2

    static func < (lhs: DiagnosticsSeverity, rhs: DiagnosticsSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .info:
            return "Info"
        case .warning:
            return "Warning"
        case .error:
            return "Error"
        }
    }
}

struct DiagnosticsEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let category: DiagnosticsCategory
    let severity: DiagnosticsSeverity
    let message: String
    let suggestion: String?
    let metadata: [String: String]
}

@MainActor
final class DiagnosticsCenter: ObservableObject {
    static let shared = DiagnosticsCenter()

    @Published private(set) var entries: [DiagnosticsEntry] = []

    private let maxEntries = 200

    private init() {}

    @discardableResult
    func record(
        category: DiagnosticsCategory, severity: DiagnosticsSeverity, message: String,
        suggestion: String? = nil, metadata: [String: String] = [:]
    ) -> DiagnosticsEntry {
        let entry = DiagnosticsEntry(
            timestamp: Date(),
            category: category,
            severity: severity,
            message: message,
            suggestion: suggestion,
            metadata: metadata
        )

        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        return entry
    }

    func clear() {
        entries.removeAll(keepingCapacity: false)
    }

    func preloadForUITests() {
        record(
            category: .dashboard, severity: .info, message: "Seeded diagnostic entry for UI tests.")
    }
}

enum Diagnostics {
    private static let subsystem = "com.tidymac.app"
    private static let dashboardLogger = Logger(
        subsystem: subsystem, category: DiagnosticsCategory.dashboard.rawValue)
    private static let cleanupLogger = Logger(
        subsystem: subsystem, category: DiagnosticsCategory.cleanup.rawValue)
    private static let uninstallerLogger = Logger(
        subsystem: subsystem, category: DiagnosticsCategory.uninstaller.rawValue)

    static func info(
        category: DiagnosticsCategory, message: String, metadata: [String: String] = [:]
    ) {
        log(
            to: logger(for: category), category: category, severity: .info, message: message,
            metadata: metadata)
    }

    static func warning(
        category: DiagnosticsCategory, message: String, metadata: [String: String] = [:]
    ) {
        log(
            to: logger(for: category), category: category, severity: .warning, message: message,
            metadata: metadata)
    }

    static func error(
        category: DiagnosticsCategory, message: String, error: Error? = nil,
        suggestion: String? = nil, metadata: [String: String] = [:]
    ) {
        var enrichedMetadata = metadata
        if let error {
            enrichedMetadata["error"] = String(describing: error)
        }
        log(
            to: logger(for: category), category: category, severity: .error, message: message,
            suggestion: suggestion, metadata: enrichedMetadata)
    }

    private static func logger(for category: DiagnosticsCategory) -> Logger {
        switch category {
        case .dashboard:
            return dashboardLogger
        case .cleanup:
            return cleanupLogger
        case .uninstaller:
            return uninstallerLogger
        }
    }

    private static func log(
        to logger: Logger, category: DiagnosticsCategory, severity: DiagnosticsSeverity,
        message: String, suggestion: String? = nil, metadata: [String: String] = [:]
    ) {
        let serialized = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        switch severity {
        case .info:
            logger.info("\(message, privacy: .public) \(serialized, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public) \(serialized, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public) \(serialized, privacy: .public)")
        }

        Task {
            let entry = await MainActor.run {
                DiagnosticsCenter.shared.record(
                    category: category,
                    severity: severity,
                    message: message,
                    suggestion: suggestion,
                    metadata: metadata
                )
            }
            DiagnosticsPersistence.shared.persist(entry: entry)
        }
    }
}

private final class DiagnosticsPersistence {
    static let shared = DiagnosticsPersistence()

    private let queue = DispatchQueue(label: "com.tidymac.diagnostics.persistence", qos: .utility)
    private let fileManager: FileManager
    private let logURL: URL
    private let maxFileSize: Int64 = 512 * 1024  // 512 KB rolling log

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let diagnosticsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("TidyMac", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        logURL = diagnosticsDirectory.appendingPathComponent(
            "cleanup-diagnostics.jsonl", isDirectory: false)
    }

    func persist(entry: DiagnosticsEntry) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.ensureLogDirectory()
                let data = try self.encode(entry: entry)
                try self.rotateIfNeeded(adding: Int64(data.count))
                try self.append(data: data)
            } catch {
                // Persisting diagnostics should not interrupt the user; log to OS for investigation.
                os_log(
                    "Diagnostics persistence failure: %{public}@", type: .error,
                    String(describing: error))
            }
        }
    }

    private func ensureLogDirectory() throws {
        let directory = logURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func encode(entry: DiagnosticsEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = SerializableEntry(from: entry)
        var data = try encoder.encode(payload)
        data.append(0x0A)  // newline for JSONL format
        return data
    }

    private func rotateIfNeeded(adding bytes: Int64) throws {
        guard fileManager.fileExists(atPath: logURL.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: logURL.path)
        if let fileSize = attributes[.size] as? NSNumber {
            let totalSize = fileSize.int64Value + bytes
            if totalSize > maxFileSize {
                var timestamp = ISO8601DateFormatter().string(from: Date())
                timestamp = timestamp.replacingOccurrences(of: ":", with: "-")
                timestamp = timestamp.replacingOccurrences(of: ".", with: "-")
                let archiveURL = logURL.deletingLastPathComponent().appendingPathComponent(
                    "cleanup-diagnostics-\(timestamp).jsonl")
                try? fileManager.removeItem(at: archiveURL)
                try fileManager.moveItem(at: logURL, to: archiveURL)
            }
        }
    }

    private func append(data: Data) throws {
        if fileManager.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            handle.write(data)
            try handle.close()
        } else {
            try data.write(to: logURL, options: .atomic)
        }
    }

    private struct SerializableEntry: Codable {
        let timestamp: Date
        let category: String
        let severity: String
        let message: String
        let suggestion: String?
        let metadata: [String: String]

        init(from entry: DiagnosticsEntry) {
            timestamp = entry.timestamp
            category = entry.category.rawValue
            severity = entry.severity.label
            message = entry.message
            suggestion = entry.suggestion
            metadata = entry.metadata
        }
    }
}
