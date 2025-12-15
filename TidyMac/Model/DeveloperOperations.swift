import Foundation

enum DeveloperCategory: String, CaseIterable, Identifiable {
    case caches
    case simulators
    case toolchains

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caches:
            return "Caches"
        case .simulators:
            return "Simulators"
        case .toolchains:
            return "Toolchains"
        }
    }
}

enum DeveloperOperation: String {
    case clearDerivedData
    case clearXcodeCaches
    case clearVSCodeCaches
    case resetSimulatorCaches
    case purgeSimulatorDevices
    case clearToolchainLogs
    case purgeCustomToolchains
}

struct OperationBanner: Equatable {
    let success: Bool
    let message: String
    let requiresFullDiskAccess: Bool
}
