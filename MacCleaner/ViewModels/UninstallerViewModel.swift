import Foundation

struct UninstallBanner: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let success: Bool
    let requiresFullDiskAccess: Bool
}

@MainActor
final class UninstallerViewModel: ObservableObject {
    @Published private(set) var applications: [Application]
    @Published var selectedApplication: Application?
    @Published var isLoading: Bool
    @Published var banner: UninstallBanner?
    @Published var searchText: String

    private let service: ApplicationInventoryService
    private var didTriggerInitialFetch = false

    init(
        service: ApplicationInventoryService = FileSystemApplicationInventoryService(),
        applications: [Application] = [],
        selected: Application? = nil,
        isLoading: Bool = false,
        searchText: String = ""
    ) {
        self.service = service
        self.applications = applications
        self.selectedApplication = selected ?? applications.first
        self.isLoading = isLoading
        self.banner = nil
        self.searchText = searchText
    }

    func handleAppear(autoFetch: Bool) {
        guard autoFetch, !didTriggerInitialFetch else { return }
        didTriggerInitialFetch = true
        Task { await refreshApplications() }
    }

    func refreshApplications() async {
        guard !isLoading else { return }
        isLoading = true
        banner = nil

        let currentSelectionPath = selectedApplication?.resolvedBundlePath
        let fetched = await service.fetchApplications()

        applications = fetched
        if let currentSelectionPath,
           let matching = fetched.first(where: { $0.resolvedBundlePath == currentSelectionPath }) {
            selectedApplication = matching
        } else {
            selectedApplication = fetched.first
        }

        isLoading = false
    }

    func uninstallSelectedApplication() async {
        guard let app = selectedApplication else { return }
        await uninstall(app)
    }

    func uninstall(_ app: Application) async {
        do {
            try await service.uninstall(application: app)
            applications.removeAll { $0.id == app.id }
            banner = UninstallBanner(
                title: "Uninstalled",
                message: "\(app.name) was removed successfully.",
                success: true,
                requiresFullDiskAccess: false
            )
            if selectedApplication?.id == app.id {
                selectedApplication = applications.first
            }
        } catch let uninstallError as ApplicationUninstallError {
            handleUninstallError(uninstallError, for: app)
        } catch {
            banner = UninstallBanner(
                title: "Uninstall Failed",
                message: "We couldn't remove \(app.name). Try again or remove it manually from Finder.",
                success: false,
                requiresFullDiskAccess: false
            )
        }
    }

    func selectApplication(_ app: Application) {
        selectedApplication = app
    }

    var filteredApplications: [Application] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return applications }
        let term = trimmed.lowercased()
        return applications.filter { app in
            app.name.lowercased().contains(term) || app.bundleID.lowercased().contains(term)
        }
    }

    func filteredGroups() -> [ApplicationGroup] {
        let grouped = Dictionary(grouping: filteredApplications) { $0.installLocation }
        return grouped
            .map { key, value in
                ApplicationGroup(
                    id: key.identifier,
                    title: key.displayName,
                    requiresRoot: key.requiresRoot,
                    apps: value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                )
            }
            .sorted { $0.title < $1.title }
    }

    var appSummary: String {
        if isLoading {
            return "Refreshing installed applications…"
        }

        if applications.isEmpty {
            return "No installed applications detected yet."
        }

        let total = applications.count
        let filteredCount = filteredApplications.count

        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return total == 1 ? "1 installed application." : "\(total) installed applications detected."
        }

        if filteredCount == 0 {
            return "No apps match your search."
        }

        return filteredCount == 1 ? "1 match found." : "\(filteredCount) matches found."
    }

    func ensureSelectionConsistency() {
        guard let selection = selectedApplication else {
            selectedApplication = filteredApplications.first
            return
        }

        if !filteredApplications.contains(selection) {
            selectedApplication = filteredApplications.first
        }
    }

    private func handleUninstallError(_ error: ApplicationUninstallError, for app: Application) {
        switch error.reason {
        case .permissionDenied:
            banner = UninstallBanner(
                title: "Uninstall Failed",
                message: "MacCleaner needs additional permissions to remove \(app.name). Grant Full Disk Access or run with administrator privileges.",
                success: false,
                requiresFullDiskAccess: true
            )
        case .administratorRequired(let message):
            banner = UninstallBanner(
                title: "Administrator Required",
                message: message ?? "Approve the administrator prompt to remove \(app.name).",
                success: false,
                requiresFullDiskAccess: true
            )
        case .userCancelled:
            banner = UninstallBanner(
                title: "Uninstall Cancelled",
                message: "The uninstall request for \(app.name) was cancelled before completion.",
                success: false,
                requiresFullDiskAccess: false
            )
        case .generic(let message):
            banner = UninstallBanner(
                title: "Uninstall Failed",
                message: message,
                success: false,
                requiresFullDiskAccess: false
            )
        }
    }
}

struct ApplicationGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let requiresRoot: Bool
    var apps: [Application]
}
