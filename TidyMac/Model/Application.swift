import Foundation

struct Application: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let bundleID: String
    let bundlePath: String

    init(id: UUID = UUID(), name: String, bundleID: String, bundlePath: String) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
    }

    var installLocation: InstallLocationCategory {
        InstallLocationCategory(path: resolvedBundlePath)
    }

    var requiresRoot: Bool {
        installLocation.requiresRoot
    }

    var locationDescription: String {
        "Located in \(installLocation.displayName)."
    }

    var resolvedBundlePath: String {
        (bundlePath as NSString).expandingTildeInPath
    }

    var resolvedBundleURL: URL {
        URL(fileURLWithPath: resolvedBundlePath)
    }

    var displayPath: String {
        let home = NSHomeDirectory()
        let expanded = resolvedBundlePath
        if expanded.hasPrefix(home) {
            let relative = expanded.replacingOccurrences(of: home, with: "~")
            return relative
        }
        return bundlePath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case bundleID
        case bundlePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID) ?? name
        bundlePath = try container.decodeIfPresent(String.self, forKey: .bundlePath) ?? "/Applications/\(name).app"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(bundlePath, forKey: .bundlePath)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum InstallLocationCategory: Hashable {
    case systemApplications
    case systemUtilities
    case system
    case user
    case other(path: String)

    init(path: String) {
        let normalizedPath = (path as NSString).expandingTildeInPath

        if normalizedPath.hasPrefix("/Applications/Utilities") {
            self = .systemUtilities
        } else if normalizedPath.hasPrefix("/Applications") {
            self = .systemApplications
        } else if normalizedPath.hasPrefix("/System/Applications") {
            self = .system
        } else if normalizedPath.hasPrefix(NSHomeDirectory()) {
            self = .user
        } else {
            self = .other(path: path)
        }
    }

    var displayName: String {
        switch self {
        case .systemApplications:
            return "/Applications"
        case .systemUtilities:
            return "/Applications/Utilities"
        case .system:
            return "/System/Applications"
        case .user:
            return "~/Applications"
        case let .other(path):
            return InstallLocationCategory.prettyPath(path)
        }
    }

    var requiresRoot: Bool {
        switch self {
        case .user:
            return false
        default:
            return true
        }
    }

    var identifier: String {
        switch self {
        case .systemApplications:
            return "system-applications"
        case .systemUtilities:
            return "system-utilities"
        case .system:
            return "system"
        case .user:
            return "user"
        case let .other(path):
            return path
        }
    }

    private static func prettyPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let home = NSHomeDirectory()
        if expanded.hasPrefix(home) {
            return expanded.replacingOccurrences(of: home, with: "~")
        }
        return path
    }
}
