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
    let confidence: CleanupConfidence?

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
        reasons: [CleanupReason],
        confidence: CleanupConfidence? = nil
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
        self.confidence = confidence
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
        if let confidence {
            components.append("Confidence: \(confidence.tier.displayName) (\(confidence.scoreDescription))")
            if let rationale = confidence.rationale.first {
                components.append(rationale)
            }
        }
        return components.isEmpty ? category.label : components.joined(separator: " • ")
    }

    func updating(confidence newConfidence: CleanupConfidence?, additionalReasons: [CleanupReason] = []) -> CleanupCandidate {
        var mergedReasons: [CleanupReason] = []
        var seen: Set<String> = []
        for reason in reasons + additionalReasons {
            if seen.insert(reason.id).inserted {
                mergedReasons.append(reason)
            }
        }
        return CleanupCandidate(
            path: path,
            displayName: displayName,
            category: category,
            estimatedSize: estimatedSize,
            resourceValues: resourceValues,
            spotlight: spotlight,
            associatedBundleIdentifier: associatedBundleIdentifier,
            associatedBundlePath: associatedBundlePath,
            codeSignatureHash: codeSignatureHash,
            recentProcess: recentProcess,
            reasons: mergedReasons,
            confidence: newConfidence ?? confidence
        )
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
        let duplicateMap = duplicateContexts(for: deduped)
        let scored = deduped.map { candidate -> CleanupCandidate in
            let evaluation = computeConfidence(for: candidate, duplicateContext: duplicateMap[candidate.id])
            let additionalReasons = evaluation.duplicateReason.map { [$0] } ?? []
            return candidate.updating(confidence: evaluation.confidence, additionalReasons: additionalReasons)
        }

        let sorted = scored.sorted { lhs, rhs in
            let leftTier = lhs.confidence?.tier.sortRank ?? CleanupConfidence.RiskTier.review.sortRank
            let rightTier = rhs.confidence?.tier.sortRank ?? CleanupConfidence.RiskTier.review.sortRank
            if leftTier != rightTier {
                return leftTier < rightTier
            }
            let leftScore = lhs.confidence?.score ?? 0
            let rightScore = rhs.confidence?.score ?? 0
            if leftScore != rightScore {
                return leftScore > rightScore
            }
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
                    "permissionFailures": "\(permissionFailures.count)",
                    "autoTier": "\(sorted.filter { $0.confidence?.tier == .auto }.count)"
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

    private struct ConfidenceComputationResult {
        let confidence: CleanupConfidence
        let duplicateReason: CleanupReason?
    }

    private struct DuplicateContext {
        let groupID: String
        let isPrimary: Bool
        let siblings: [CleanupCandidate]
        let primary: CleanupCandidate
        let totalCount: Int
    }

    private struct DuplicateSignature: Hashable {
        let size: Int64
        let hash: String
    }

    private func duplicateContexts(for candidates: [CleanupCandidate]) -> [String: DuplicateContext] {
        var signatureMap: [DuplicateSignature: [CleanupCandidate]] = [:]
        var hashCache: [String: String] = [:]
        let minimumSize: Int64 = 5 * 1_048_576

        for candidate in candidates {
            guard candidate.resourceValues.isDirectory != true else { continue }
            guard let size = candidate.estimatedSize
                ?? candidate.resourceValues.totalAllocatedSize
                ?? candidate.resourceValues.fileSize else { continue }
            guard size >= minimumSize else { continue }
            guard fileManager.isReadableFile(atPath: candidate.path) else { continue }

            let hash: String
            if let cached = hashCache[candidate.path] {
                hash = cached
            } else if let computed = contentHash(forFileAt: candidate.path) {
                hashCache[candidate.path] = computed
                hash = computed
            } else {
                continue
            }

            let signature = DuplicateSignature(size: size, hash: hash)
            signatureMap[signature, default: []].append(candidate)
        }

        var contexts: [String: DuplicateContext] = [:]
    for (signature, group) in signatureMap where group.count > 1 {
            let sorted = group.sorted { lhs, rhs in
                let leftDate = lhs.resourceValues.lastRelevantDate ?? lhs.spotlight.lastUsedDate ?? Date.distantPast
                let rightDate = rhs.resourceValues.lastRelevantDate ?? rhs.spotlight.lastUsedDate ?? Date.distantPast
                return leftDate > rightDate
            }
            guard let primary = sorted.first else { continue }
            for (index, candidate) in sorted.enumerated() {
                let siblings = sorted.enumerated().filter { $0.offset != index }.map { $0.element }
                contexts[candidate.id] = DuplicateContext(
                    groupID: signature.hash,
                    isPrimary: index == 0,
                    siblings: siblings,
                    primary: primary,
                    totalCount: sorted.count
                )
            }
        }

        return contexts
    }

    private func computeConfidence(for candidate: CleanupCandidate, duplicateContext: DuplicateContext?) -> ConfidenceComputationResult {
        let now = Date()
        var rationale: [String] = []

        let age = ageScore(for: candidate, now: now, rationale: &rationale)
        let ownership = ownershipScore(for: candidate, rationale: &rationale)
        let activity = activityScore(for: candidate, now: now, rationale: &rationale)
        let size = sizeScore(for: candidate, rationale: &rationale)
        let duplicate = duplicateScore(for: candidate, context: duplicateContext, rationale: &rationale)

        switch candidate.category {
        case .browserCaches:
            rationale.append("Browser cache can be safely rebuilt")
        case .orphanedApplicationSupport:
            rationale.append("No linked application data")
        case .orphanedPreferences:
            rationale.append("Legacy preference file")
        case .sharedInstallers:
            rationale.append("Installer image copy")
        }

        let weighted = age * 0.26 + ownership * 0.24 + activity * 0.18 + size * 0.17 + duplicate.score * 0.15
        let categoryBonus: Double
        switch candidate.category {
        case .browserCaches:
            categoryBonus = 0.12
        case .sharedInstallers:
            categoryBonus = 0.15
        case .orphanedApplicationSupport:
            categoryBonus = 0.08
        case .orphanedPreferences:
            categoryBonus = 0.05
        }

        let finalScore = min(max(weighted + categoryBonus, 0), 1)
        let percentage = round(finalScore * 100)
        let tier = CleanupConfidence.RiskTier.fromScore(percentage)
        let breakdown = CleanupConfidenceBreakdown(
            ageScore: age,
            ownershipScore: ownership,
            activityScore: activity,
            sizeScore: size,
            duplicateScore: duplicate.score
        )

    let trimmedRationale = Array(rationale.uniqued().prefix(5))

        let confidence = CleanupConfidence(
            score: percentage,
            tier: tier,
            breakdown: breakdown,
            rationale: trimmedRationale
        )

        return ConfidenceComputationResult(confidence: confidence, duplicateReason: duplicate.reason)
    }

    private func ageScore(for candidate: CleanupCandidate, now: Date, rationale: inout [String]) -> Double {
        if let lastDate = candidate.resourceValues.lastRelevantDate ?? candidate.spotlight.lastUsedDate {
            let days = max(0, Calendar.current.dateComponents([.day], from: lastDate, to: now).day ?? 0)
            let score: Double
            switch days {
            case 0..<14:
                score = 0.2
            case 14..<30:
                score = 0.35
            case 30..<90:
                score = 0.55
            case 90..<180:
                score = 0.75
            case 180..<365:
                score = 0.9
            default:
                score = 1.0
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            rationale.append("No activity for \(formatter.localizedString(for: lastDate, relativeTo: now))")
            return score
        }

        rationale.append("No usage metadata available")
        return 0.6
    }

    private func ownershipScore(for candidate: CleanupCandidate, rationale: inout [String]) -> Double {
        if let bundleID = candidate.associatedBundleIdentifier ?? candidate.spotlight.bundleIdentifier {
            if candidate.associatedBundlePath == nil {
                rationale.append("Owner app \(bundleID) not installed")
                return 0.95
            } else {
                rationale.append("Owner app \(bundleID) installed")
                return 0.25
            }
        }

        rationale.append("No owner application")
        return 1.0
    }

    private func activityScore(for candidate: CleanupCandidate, now: Date, rationale: inout [String]) -> Double {
        guard let process = candidate.recentProcess else {
            rationale.append("No running processes")
            return 0.9
        }

        if process.isActive {
            rationale.append("Owner app currently active")
            return 0.0
        }

        if let launchDate = process.launchDate {
            let interval = now.timeIntervalSince(launchDate)
            switch interval {
            case ..<3_600:
                rationale.append("Owner app used within the last hour")
                return 0.1
            case ..<21_600:
                rationale.append("Owner app used earlier today")
                return 0.25
            case ..<86_400:
                rationale.append("Owner app used today")
                return 0.35
            case ..<604_800:
                rationale.append("Owner app used this week")
                return 0.55
            case ..<2_592_000:
                rationale.append("Owner app idle for weeks")
                return 0.7
            default:
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                rationale.append("Owner app idle since \(formatter.localizedString(for: launchDate, relativeTo: now))")
                return 0.85
            }
        }

        rationale.append("Owner app recently seen")
        return 0.4
    }

    private func sizeScore(for candidate: CleanupCandidate, rationale: inout [String]) -> Double {
        guard let size = candidate.estimatedSize
            ?? candidate.resourceValues.totalAllocatedSize
            ?? candidate.resourceValues.fileSize else {
            rationale.append("Size unknown")
            return 0.5
        }

        let score: Double
        switch size {
        case let value where value >= 10 * 1_073_741_824: // >= 10 GB
            score = 1.0
        case let value where value >= 1 * 1_073_741_824: // >= 1 GB
            score = 0.85
        case let value where value >= 512 * 1_048_576: // >= 512 MB
            score = 0.7
        case let value where value >= 200 * 1_048_576: // >= 200 MB
            score = 0.55
        case let value where value >= 50 * 1_048_576: // >= 50 MB
            score = 0.4
        default:
            score = 0.25
        }

        rationale.append("Size \(formatByteCount(size))")
        return score
    }

    private func duplicateScore(for candidate: CleanupCandidate, context: DuplicateContext?, rationale: inout [String]) -> (score: Double, reason: CleanupReason?) {
        guard let context else {
            return (0.5, nil)
        }

        if context.isPrimary {
            rationale.append("Primary copy for duplicate set (\(context.totalCount) copies)")
            return (0.2, nil)
        }

        let primaryName = URL(fileURLWithPath: context.primary.path).lastPathComponent
        let detail: String
        if let firstSibling = context.siblings.first {
            detail = "Matches \(URL(fileURLWithPath: firstSibling.path).lastPathComponent)"
        } else {
            detail = "Matches \(primaryName)"
        }

        rationale.append("Older duplicate - primary copy at \(primaryName)")
        let reason = CleanupReason(code: "duplicate", label: "Duplicate copy", detail: detail)
        return (1.0, reason)
    }

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
