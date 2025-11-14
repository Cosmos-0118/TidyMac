import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(Security)
import Security
#endif

// MARK: - Inventory Types

enum CleanupInventorySource: CaseIterable, Hashable {
    case browserCaches
    case orphanedApplicationSupport
    case orphanedPreferences
    case sharedInstallers

    var label: String {
        switch self {
        case .browserCaches:
            return "Browser Caches"
        case .orphanedApplicationSupport:
            return "Orphaned Application Support"
        case .orphanedPreferences:
            return "Unused Preferences"
        case .sharedInstallers:
            return "Shared Installers"
        }
    }

    var telemetryKey: String {
        switch self {
        case .browserCaches:
            return "browser-caches"
        case .orphanedApplicationSupport:
            return "app-support-orphan"
        case .orphanedPreferences:
            return "preferences-orphan"
        case .sharedInstallers:
            return "shared-installers"
        }
    }
}

struct CleanupInventoryEnvironment: Equatable {
    let homeDirectory: URL
    let libraryDirectory: URL
    let applicationSupportDirectory: URL
    let cachesDirectory: URL
    let webKitDirectory: URL
    let preferencesDirectory: URL
    let sharedDirectory: URL

    static func current(fileManager: FileManager = .default) -> CleanupInventoryEnvironment {
        let home = fileManager.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return CleanupInventoryEnvironment(
            homeDirectory: home,
            libraryDirectory: library,
            applicationSupportDirectory: library.appendingPathComponent("Application Support", isDirectory: true),
            cachesDirectory: library.appendingPathComponent("Caches", isDirectory: true),
            webKitDirectory: library.appendingPathComponent("WebKit", isDirectory: true),
            preferencesDirectory: library.appendingPathComponent("Preferences", isDirectory: true),
            sharedDirectory: URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
        )
    }
}

struct URLResourceValuesSnapshot: Equatable {
    let isDirectory: Bool?
    let fileSize: Int64?
    let totalAllocatedSize: Int64?
    let contentAccessDate: Date?
    let contentModificationDate: Date?
    let creationDate: Date?
    let typeIdentifier: String?

    init(values: URLResourceValues) {
        isDirectory = values.isDirectory
        if let fileSize = values.fileSize {
            self.fileSize = Int64(fileSize)
        } else {
            fileSize = nil
        }
        if let totalSize = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
            totalAllocatedSize = Int64(totalSize)
        } else {
            totalAllocatedSize = nil
        }
        contentAccessDate = values.contentAccessDate
        contentModificationDate = values.contentModificationDate
        creationDate = values.creationDate
        typeIdentifier = values.typeIdentifier
    }

    var lastRelevantDate: Date? {
        contentAccessDate ?? contentModificationDate ?? creationDate
    }
}

struct SpotlightSnapshot: Equatable {
    let displayName: String?
    let contentType: String?
    let bundleIdentifier: String?
    let lastUsedDate: Date?

    static let empty = SpotlightSnapshot(displayName: nil, contentType: nil, bundleIdentifier: nil, lastUsedDate: nil)
}

struct RunningApplicationSnapshot: Equatable {
    let bundleIdentifier: String?
    let name: String?
    let launchDate: Date?
    let isActive: Bool
}

struct CleanupCandidate: Identifiable, Equatable {
    let id: String
    let path: String
    let displayName: String
    let category: CleanupInventorySource
    let estimatedSize: Int64?
    let resourceValues: URLResourceValuesSnapshot
    let spotlight: SpotlightSnapshot
    let associatedBundleIdentifier: String?
    let associatedBundlePath: String?
    let codeSignatureHash: String?
    let recentProcess: RunningApplicationSnapshot?
    let reasons: [CleanupReason]

    init(
        path: String,
        displayName: String,
        category: CleanupInventorySource,
        estimatedSize: Int64?,
        resourceValues: URLResourceValuesSnapshot,
        spotlight: SpotlightSnapshot,
        associatedBundleIdentifier: String?,
        associatedBundlePath: String?,
        codeSignatureHash: String?,
        recentProcess: RunningApplicationSnapshot?,
        reasons: [CleanupReason]
    ) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        self.id = normalized
        self.path = normalized
        self.displayName = displayName
        self.category = category
        self.estimatedSize = estimatedSize
        self.resourceValues = resourceValues
        self.spotlight = spotlight
        self.associatedBundleIdentifier = associatedBundleIdentifier
        self.associatedBundlePath = associatedBundlePath
        self.codeSignatureHash = codeSignatureHash
        self.recentProcess = recentProcess
        self.reasons = reasons
    }

    var detailSummary: String {
        var components: [String] = []
        if let estimatedSize {
            components.append(formatByteCount(estimatedSize))
        }
        if let bundleID = associatedBundleIdentifier ?? spotlight.bundleIdentifier {
            components.append("Owner: \(bundleID)")
        }
        if let process = recentProcess, let name = process.name {
            let dateString: String
            if let launchDate = process.launchDate {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                dateString = formatter.localizedString(for: launchDate, relativeTo: Date())
            } else {
                dateString = process.isActive ? "active now" : "recent"
            }
            components.append("Running: \(name) (\(dateString))")
        }
        if let lastDate = resourceValues.lastRelevantDate ?? spotlight.lastUsedDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            components.append("Touched \(formatter.localizedString(for: lastDate, relativeTo: Date()))")
        }
        return components.isEmpty ? category.label : components.joined(separator: " • ")
    }
}

struct CleanupInventoryResult {
    let candidates: [CleanupCandidate]
    let permissionDenied: [String]
}

protocol CleanupInventoryServicing {
    func discoverCandidates(sources: Set<CleanupInventorySource>) -> CleanupInventoryResult
}

protocol RunningApplicationsProviding {
    func runningApplications() -> [RunningApplicationSnapshot]
}

struct WorkspaceRunningApplicationsProvider: RunningApplicationsProviding {
    func runningApplications() -> [RunningApplicationSnapshot] {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications.map { app in
            RunningApplicationSnapshot(
                bundleIdentifier: app.bundleIdentifier,
                name: app.localizedName,
                launchDate: app.launchDate,
                isActive: app.isActive
            )
        }
        #else
        return []
        #endif
    }
}

// MARK: - Application Indexing

private struct ApplicationIndex {
    private let byBundleID: [String: Application]
    private let byNameKey: [String: Application]

    init(applications: [Application]) {
        var idMap: [String: Application] = [:]
        var nameMap: [String: Application] = [:]

        for application in applications {
            let bundleKey = ApplicationIndex.normalize(application.bundleID)
            idMap[bundleKey] = application

            let nameKey = ApplicationIndex.normalize(application.name)
            if nameMap[nameKey] == nil {
                nameMap[nameKey] = application
            }

            let bundleName = URL(fileURLWithPath: application.bundlePath)
                .deletingPathExtension()
                .lastPathComponent
            let bundleNameKey = ApplicationIndex.normalize(bundleName)
            if nameMap[bundleNameKey] == nil {
                nameMap[bundleNameKey] = application
            }
        }

        byBundleID = idMap
        byNameKey = nameMap
    }

    func matchBundle(identifier: String) -> Application? {
        let key = ApplicationIndex.normalize(identifier)
        return byBundleID[key]
    }

    func matchName(_ rawName: String) -> Application? {
        let key = ApplicationIndex.normalize(rawName)
        return byNameKey[key]
    }

    static func normalize(_ value: String) -> String {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = lower.filter { $0.isLetter || $0.isNumber }
        return allowed
    }
}

private struct RunningApplicationIndex {
    private let byBundleID: [String: RunningApplicationSnapshot]
    private let byName: [String: RunningApplicationSnapshot]

    init(applications: [RunningApplicationSnapshot]) {
        var bundle: [String: RunningApplicationSnapshot] = [:]
        var nameIndex: [String: RunningApplicationSnapshot] = [:]
        for app in applications {
            if let bundleID = app.bundleIdentifier {
                bundle[ApplicationIndex.normalize(bundleID)] = app
            }
            if let name = app.name {
                nameIndex[ApplicationIndex.normalize(name)] = app
            }
        }
        byBundleID = bundle
        byName = nameIndex
    }

    func lookup(bundleIdentifier: String) -> RunningApplicationSnapshot? {
        byBundleID[ApplicationIndex.normalize(bundleIdentifier)]
    }

    func lookup(name: String) -> RunningApplicationSnapshot? {
        byName[ApplicationIndex.normalize(name)]
    }
}

// MARK: - Cleanup Inventory Service

final class CleanupInventoryService: CleanupInventoryServicing {
    private let fileManager: FileManager
    private let environment: CleanupInventoryEnvironment
    private let applicationIndex: ApplicationIndex
    private let runningIndex: RunningApplicationIndex
    private let installedApplications: [Application]
    private let runningApplications: [RunningApplicationSnapshot]

    init(
        fileManager: FileManager = .default,
        environment: CleanupInventoryEnvironment? = nil,
        installedApplications: [Application]? = nil,
        runningApplicationsProvider: RunningApplicationsProviding = WorkspaceRunningApplicationsProvider()
    ) {
        self.fileManager = fileManager
        let resolvedEnvironment = environment ?? .current(fileManager: fileManager)
        self.environment = resolvedEnvironment

        if let installedApplications {
            self.installedApplications = installedApplications
        } else {
            self.installedApplications = CleanupInventoryService.loadInstalledApplications(fileManager: fileManager)
        }

        let running = runningApplicationsProvider.runningApplications()
        self.runningApplications = running
        self.applicationIndex = ApplicationIndex(applications: self.installedApplications)
        self.runningIndex = RunningApplicationIndex(applications: running)
    }

    func discoverCandidates(sources: Set<CleanupInventorySource> = Set(CleanupInventorySource.allCases)) -> CleanupInventoryResult {
        var permissionFailures: [String] = []
        var aggregated: [CleanupCandidate] = []

        if sources.contains(.browserCaches) {
            let result = discoverBrowserCaches()
            aggregated.append(contentsOf: result.candidates)
            permissionFailures.append(contentsOf: result.permissionDenied)
        }

        if sources.contains(.orphanedApplicationSupport) {
            let result = discoverOrphanedApplicationSupport()
            aggregated.append(contentsOf: result.candidates)
            permissionFailures.append(contentsOf: result.permissionDenied)
        }

        if sources.contains(.orphanedPreferences) {
            let result = discoverOrphanedPreferences()
            aggregated.append(contentsOf: result.candidates)
            permissionFailures.append(contentsOf: result.permissionDenied)
        }

        if sources.contains(.sharedInstallers) {
            let result = discoverSharedInstallers()
            aggregated.append(contentsOf: result.candidates)
            permissionFailures.append(contentsOf: result.permissionDenied)
        }

        let deduped = dedupeByPath(aggregated)
        let sorted = deduped.sorted { lhs, rhs in
            switch (lhs.estimatedSize, rhs.estimatedSize) {
            case let (l?, r?) where l != r:
                return l > r
            case (nil, nil):
                break
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                break
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        if !sorted.isEmpty {
            Diagnostics.info(
                category: .cleanup,
                message: "Inventory scan produced \(sorted.count) candidate(s).",
                metadata: [
                    "sources": sources.map { $0.telemetryKey }.joined(separator: ","),
                    "permissionFailures": "\(permissionFailures.count)"
                ]
            )
        }

        return CleanupInventoryResult(
            candidates: sorted,
            permissionDenied: permissionFailures.uniqued()
        )
    }
}

// MARK: - Discovery Helpers

private extension CleanupInventoryService {
    typealias DiscoveryOutcome = (candidates: [CleanupCandidate], permissionDenied: [String])

    func discoverBrowserCaches() -> DiscoveryOutcome {
        var results: [CleanupCandidate] = []
        var failures: [String] = []

        struct BrowserCacheTarget {
            let relativePath: String
            let displayName: String
            let bundleIdentifier: String?
        }

        let library = environment.libraryDirectory
        let targets: [BrowserCacheTarget] = [
            BrowserCacheTarget(relativePath: "Caches/com.apple.Safari", displayName: "Safari Cache", bundleIdentifier: "com.apple.Safari"),
            BrowserCacheTarget(relativePath: "Caches/com.apple.WebKit.WebContent", displayName: "Safari WebKit Cache", bundleIdentifier: "com.apple.Safari"),
            BrowserCacheTarget(relativePath: "WebKit", displayName: "Safari WebKit", bundleIdentifier: "com.apple.Safari"),
            BrowserCacheTarget(relativePath: "Caches/com.google.Chrome", displayName: "Chrome Cache", bundleIdentifier: "com.google.Chrome"),
            BrowserCacheTarget(relativePath: "Application Support/Google/Chrome", displayName: "Chrome Profiles", bundleIdentifier: "com.google.Chrome"),
            BrowserCacheTarget(relativePath: "Caches/com.microsoft.Edge", displayName: "Edge Cache", bundleIdentifier: "com.microsoft.Edge"),
            BrowserCacheTarget(relativePath: "Application Support/Microsoft Edge", displayName: "Edge Profiles", bundleIdentifier: "com.microsoft.Edge")
        ]

        for target in targets {
            let url = library.appendingPathComponent(target.relativePath, isDirectory: true)
            guard exists(url) else { continue }
            do {
                let candidate = try makeCandidate(
                    for: url,
                    name: target.displayName,
                    category: .browserCaches,
                    explicitBundleIdentifier: target.bundleIdentifier,
                    additionalReasons: [
                        CleanupReason(code: "browser-cache", label: "Browser cache", detail: target.displayName)
                    ],
                    approximateSize: true
                )
                results.append(candidate)
            } catch DiscoveryError.permissionDenied {
                failures.append(url.path)
            } catch {
                Diagnostics.warning(
                    category: .cleanup,
                    message: "Failed to inspect browser cache at \(url.path).",
                    metadata: ["error": String(describing: error)]
                )
            }
        }

        return (results, failures)
    }

    func discoverOrphanedApplicationSupport() -> DiscoveryOutcome {
        var results: [CleanupCandidate] = []
        var failures: [String] = []

        let root = environment.applicationSupportDirectory
        guard exists(root) else { return (results, failures) }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for entry in contents {
                guard try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                let name = entry.lastPathComponent
                if name.hasPrefix("com.apple.") { continue }
                if applicationIndex.matchName(name) != nil { continue }
                if applicationIndex.matchBundle(identifier: name) != nil { continue }
                if runningIndex.lookup(name: name) != nil { continue }

                let modificationDetail = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                let ageReason: CleanupReason? = modificationDetail?.contentModificationDate.map { date in
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .short
                    let relative = formatter.localizedString(for: date, relativeTo: Date())
                    return CleanupReason(code: "stale", label: "No activity", detail: "Modified \(relative)")
                }

                var reasons = [
                    CleanupReason(code: "orphan-support", label: "No installed owner", detail: name)
                ]
                if let ageReason { reasons.append(ageReason) }

                do {
                    let candidate = try makeCandidate(
                        for: entry,
                        name: "App Support • \(displayName(for: entry))",
                        category: .orphanedApplicationSupport,
                        explicitBundleIdentifier: nil,
                        additionalReasons: reasons,
                        approximateSize: true
                    )
                    results.append(candidate)
                } catch DiscoveryError.permissionDenied {
                    failures.append(entry.path)
                }
            }
        } catch {
            failures.append(root.path)
        }

        return (results, failures)
    }

    func discoverOrphanedPreferences() -> DiscoveryOutcome {
        var results: [CleanupCandidate] = []
        var failures: [String] = []

        let root = environment.preferencesDirectory
        guard exists(root) else { return (results, failures) }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            for entry in contents where entry.pathExtension == "plist" {
                let base = entry.deletingPathExtension().lastPathComponent
                if applicationIndex.matchBundle(identifier: base) != nil { continue }
                if base.hasPrefix("com.apple.") { continue }

                let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                let staleDate = values?.contentModificationDate ?? Date.distantPast
                let daysOld = Calendar.current.dateComponents([.day], from: staleDate, to: Date()).day ?? 0
                guard daysOld >= 90 else { continue }

                let detail = "No matching app • Modified \(daysOld) day(s) ago"
                let reason = CleanupReason(code: "orphan-preference", label: "Unused preference", detail: detail)

                do {
                    let candidate = try makeCandidate(
                        for: entry,
                        name: "Preference • \(entry.lastPathComponent)",
                        category: .orphanedPreferences,
                        explicitBundleIdentifier: nil,
                        additionalReasons: [reason],
                        approximateSize: false
                    )
                    results.append(candidate)
                } catch DiscoveryError.permissionDenied {
                    failures.append(entry.path)
                }
            }
        } catch {
            failures.append(root.path)
        }

        return (results, failures)
    }

    func discoverSharedInstallers() -> DiscoveryOutcome {
        var results: [CleanupCandidate] = []
        var failures: [String] = []

        let root = environment.sharedDirectory
        guard exists(root) else { return (results, failures) }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for entry in contents {
                let ext = entry.pathExtension.lowercased()
                guard ["dmg", "pkg", "zip"].contains(ext) else { continue }

                let reason = CleanupReason(code: "shared-installer", label: "Shared installer", detail: entry.lastPathComponent)

                do {
                    let candidate = try makeCandidate(
                        for: entry,
                        name: "Installer • \(entry.lastPathComponent)",
                        category: .sharedInstallers,
                        explicitBundleIdentifier: nil,
                        additionalReasons: [reason],
                        approximateSize: true
                    )
                    results.append(candidate)
                } catch DiscoveryError.permissionDenied {
                    failures.append(entry.path)
                }
            }
        } catch {
            failures.append(root.path)
        }

        return (results, failures)
    }

    enum DiscoveryError: Error {
        case permissionDenied
    }

    func makeCandidate(
        for url: URL,
        name: String,
        category: CleanupInventorySource,
        explicitBundleIdentifier: String?,
        additionalReasons: [CleanupReason],
        approximateSize: Bool
    ) throws -> CleanupCandidate {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .contentAccessDateKey,
            .contentModificationDateKey,
            .creationDateKey,
            .typeIdentifierKey
        ]

        do {
            let values = try url.resourceValues(forKeys: resourceKeys)
            let snapshot = URLResourceValuesSnapshot(values: values)
            let estimatedSize = approximateSize ? estimateSize(for: url, values: values) : snapshot.fileSize ?? snapshot.totalAllocatedSize

            let spotlight = loadSpotlightMetadata(for: url)
            let bundleIdentifier = explicitBundleIdentifier
                ?? spotlight.bundleIdentifier
                ?? inferBundleIdentifier(from: url)

            let associatedApplication = bundleIdentifier.flatMap { applicationIndex.matchBundle(identifier: $0) }
            let associatedBundlePath = associatedApplication?.resolvedBundlePath
            let signatureHash = associatedBundlePath.flatMap { codeSignatureHash(for: URL(fileURLWithPath: $0)) }
            let recentProcess = bundleIdentifier.flatMap { runningIndex.lookup(bundleIdentifier: $0) }
                ?? nameLookupRecentProcess(for: url)

            return CleanupCandidate(
                path: url.path,
                displayName: name,
                category: category,
                estimatedSize: estimatedSize,
                resourceValues: snapshot,
                spotlight: spotlight,
                associatedBundleIdentifier: bundleIdentifier,
                associatedBundlePath: associatedBundlePath,
                codeSignatureHash: signatureHash,
                recentProcess: recentProcess,
                reasons: additionalReasons
            )
        } catch {
            if isPermissionError(error) {
                throw DiscoveryError.permissionDenied
            }
            throw error
        }
    }

    func estimateSize(for url: URL, values: URLResourceValues) -> Int64? {
        if let direct = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize {
            return Int64(direct)
        }

        var total: Int64 = 0
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var inspected = 0
        let limit = 5_000

        for case let child as URL in enumerator {
            if inspected >= limit { break }
            inspected += 1
            do {
                let childValues = try child.resourceValues(forKeys: Set(keys))
                guard childValues.isRegularFile == true else { continue }
                if let size = childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? childValues.fileSize {
                    total += Int64(size)
                }
            } catch {
                continue
            }
        }

        return total > 0 ? total : nil
    }

    func loadSpotlightMetadata(for url: URL) -> SpotlightSnapshot {
        #if canImport(CoreServices)
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else {
            return .empty
        }

        let displayName = MDItemCopyAttribute(item, kMDItemDisplayName) as? String
        let contentType = MDItemCopyAttribute(item, kMDItemContentType) as? String
        let bundleIdentifier = MDItemCopyAttribute(item, kMDItemCFBundleIdentifier) as? String
        let lastUsedDate = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        return SpotlightSnapshot(
            displayName: displayName,
            contentType: contentType,
            bundleIdentifier: bundleIdentifier,
            lastUsedDate: lastUsedDate
        )
        #else
        return .empty
        #endif
    }

    func inferBundleIdentifier(from url: URL) -> String? {
        let name = url.lastPathComponent
        if let match = applicationIndex.matchName(name) {
            return match.bundleID
        }
        return nil
    }

    func codeSignatureHash(for bundleURL: URL) -> String? {
        #if canImport(Security)
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else { return nil }
        var information: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(code, SecCSFlags(), &information)
        guard copyStatus == errSecSuccess, let info = information as? [String: Any] else { return nil }
        guard let unique = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    func nameLookupRecentProcess(for url: URL) -> RunningApplicationSnapshot? {
        let name = url.lastPathComponent
        return runningIndex.lookup(name: name)
    }

    func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func displayName(for url: URL) -> String {
        fileManager.displayName(atPath: url.path)
    }

    func dedupeByPath(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        var seen: Set<String> = []
        var filtered: [CleanupCandidate] = []
        for candidate in candidates {
            if seen.insert(candidate.id).inserted {
                filtered.append(candidate)
            }
        }
        return filtered
    }

    static func loadInstalledApplications(fileManager: FileManager) -> [Application] {
        let home = fileManager.homeDirectoryForCurrentUser
        let locations: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]

        var discovered: [Application] = []
        var seenPaths: Set<String> = []

        for location in locations {
            guard fileManager.fileExists(atPath: location.path) else { continue }
            guard let items = try? fileManager.contentsOfDirectory(
                at: location,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in items where url.pathExtension == "app" {
                let path = url.path
                if !seenPaths.insert(path.lowercased()).inserted { continue }
                let bundle = Bundle(url: url)
                let bundleID = bundle?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
                let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                let application = Application(name: displayName, bundleID: bundleID, bundlePath: path)
                discovered.append(application)
            }
        }

        return discovered
    }
}

// MARK: - CleanupCategory Bridge

extension CleanupCategory.CleanupItem {
    init(candidate: CleanupCandidate, isSelected: Bool = true) {
        self.init(
            path: candidate.path,
            name: candidate.displayName,
            size: candidate.estimatedSize,
            detail: candidate.detailSummary,
            isSelected: isSelected,
            reasons: candidate.reasons,
            metadata: candidate
        )
    }
}
