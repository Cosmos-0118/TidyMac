import Foundation

enum DeletionGuardError: LocalizedError {
    case restricted(paths: [String])
    case excluded(paths: [String])

    var errorDescription: String? {
        switch self {
        case .restricted(let paths):
            let display = paths.joined(separator: ", ")
            return "Deletion blocked to protect system path(s): \(display)."
        case .excluded(let paths):
            let display = paths.joined(separator: ", ")
            return "Deletion skipped for protected path(s): \(display)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .restricted:
            return "Adjust your selection to avoid root-level directories."
        case .excluded:
            return "Update the exclusion list from Preferences before retrying."
        }
    }
}

protocol DeletionGuarding {
    func filter(paths: [String]) throws -> DeletionGuardResult
    func ensureAllowed(path: String) throws
    func decision(for path: String) -> DeletionGuard.Decision
}

struct DeletionGuardResult {
    let permitted: [String]
    let excluded: [String]

    var hasPermitted: Bool { !permitted.isEmpty }
}

final class DeletionGuard {
    enum Decision {
        case allow
        case excluded
        case restricted
    }

    static let shared = DeletionGuard()

    private let store = DeletionPreferencesStore.shared
    private init() { }

    func filter(paths: [String]) throws -> DeletionGuardResult {
        var allowed: [String] = []
        var excluded: [String] = []
        var restricted: [String] = []

        for path in paths {
            let normalized = normalize(path)
            switch decisionForNormalizedPath(normalized) {
            case .allow:
                allowed.append(normalized)
            case .excluded:
                excluded.append(normalized)
            case .restricted:
                restricted.append(normalized)
            }
        }

        if !restricted.isEmpty {
            throw DeletionGuardError.restricted(paths: restricted)
        }

        return DeletionGuardResult(permitted: allowed, excluded: excluded)
    }

    func ensureAllowed(path: String) throws {
        let result = try filter(paths: [path])
        if result.permitted.isEmpty {
            throw DeletionGuardError.excluded(paths: result.excluded)
        }
    }

    func decision(for path: String) -> Decision {
        let normalized = normalize(path)
        return decisionForNormalizedPath(normalized)
    }

    // MARK: - Helpers

    private func decisionForNormalizedPath(_ path: String) -> Decision {
        if isRestricted(path) {
            return .restricted
        }

        if store.isExcluded(path: path) {
            return .excluded
        }

        return .allow
    }

    private func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func isRestricted(_ path: String) -> Bool {
        path.isEmpty || path == "/"
    }
}

extension DeletionGuard: DeletionGuarding {}

extension DeletionGuard.Decision {
    var displayName: String {
        switch self {
        case .allow:
            return "Allowed"
        case .excluded:
            return "Excluded"
        case .restricted:
            return "Restricted"
        }
    }

    var telemetryValue: String {
        switch self {
        case .allow:
            return "allow"
        case .excluded:
            return "excluded"
        case .restricted:
            return "restricted"
        }
    }
}
