import Foundation
import Combine
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

    func record(category: DiagnosticsCategory, severity: DiagnosticsSeverity, message: String, suggestion: String? = nil, metadata: [String: String] = [:]) {
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
    }

    func clear() {
        entries.removeAll(keepingCapacity: false)
    }

    func preloadForUITests() {
        record(category: .dashboard, severity: .info, message: "Seeded diagnostic entry for UI tests.")
    }
}

enum Diagnostics {
    private static let subsystem = "com.maccleaner.app"
    private static let dashboardLogger = Logger(subsystem: subsystem, category: DiagnosticsCategory.dashboard.rawValue)
    private static let cleanupLogger = Logger(subsystem: subsystem, category: DiagnosticsCategory.cleanup.rawValue)
    private static let uninstallerLogger = Logger(subsystem: subsystem, category: DiagnosticsCategory.uninstaller.rawValue)

    static func info(category: DiagnosticsCategory, message: String, metadata: [String: String] = [:]) {
        log(to: logger(for: category), category: category, severity: .info, message: message, metadata: metadata)
    }

    static func warning(category: DiagnosticsCategory, message: String, metadata: [String: String] = [:]) {
        log(to: logger(for: category), category: category, severity: .warning, message: message, metadata: metadata)
    }

    static func error(category: DiagnosticsCategory, message: String, error: Error? = nil, suggestion: String? = nil, metadata: [String: String] = [:]) {
        var enrichedMetadata = metadata
        if let error {
            enrichedMetadata["error"] = String(describing: error)
        }
        log(to: logger(for: category), category: category, severity: .error, message: message, suggestion: suggestion, metadata: enrichedMetadata)
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

    private static func log(to logger: Logger, category: DiagnosticsCategory, severity: DiagnosticsSeverity, message: String, suggestion: String? = nil, metadata: [String: String] = [:]) {
        let serialized = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        switch severity {
        case .info:
            logger.info("\(message, privacy: .public) \(serialized, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public) \(serialized, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public) \(serialized, privacy: .public)")
        }

        Task { @MainActor in
            DiagnosticsCenter.shared.record(category: category, severity: severity, message: message, suggestion: suggestion, metadata: metadata)
        }
    }
}
