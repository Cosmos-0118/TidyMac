import Foundation

struct CleanupConfidenceBreakdown: Equatable, Codable {
    let ageScore: Double
    let ownershipScore: Double
    let activityScore: Double
    let sizeScore: Double
    let duplicateScore: Double
}

struct CleanupConfidence: Equatable, Codable {
    enum RiskTier: String, Codable, CaseIterable {
        case auto
        case review
        case observe

        var displayName: String {
            switch self {
            case .auto:
                return "Auto"
            case .review:
                return "Review"
            case .observe:
                return "Observe"
            }
        }

        var sortRank: Int {
            switch self {
            case .auto:
                return 0
            case .review:
                return 1
            case .observe:
                return 2
            }
        }

        static func fromScore(_ score: Double) -> RiskTier {
            if score >= 70 {
                return .auto
            }
            if score >= 45 {
                return .review
            }
            return .observe
        }
    }

    let score: Double
    let tier: RiskTier
    let breakdown: CleanupConfidenceBreakdown
    let rationale: [String]

    var scoreDescription: String {
        String(format: "%.0f%%", score)
    }
}

extension CleanupConfidence.RiskTier: Comparable {
    static func < (lhs: CleanupConfidence.RiskTier, rhs: CleanupConfidence.RiskTier) -> Bool {
        lhs.sortRank < rhs.sortRank
    }
}
