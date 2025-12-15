import Foundation

@MainActor
final class LargeFilesFinderViewModel: ObservableObject {
    static let shared = LargeFilesFinderViewModel()
    @Published private(set) var largeFiles: [FileDetail]
    @Published private(set) var scanCompleted: Bool
    @Published private(set) var totalFiles: Int
    @Published private(set) var scannedFiles: Int
    @Published private(set) var permissionIssue: Bool
    @Published private(set) var permissionMessage: String?
    @Published private(set) var isScanning: Bool
    @Published var excludedFileIDs: Set<FileDetail.ID>
    @Published var selection: Set<FileDetail.ID> {
        didSet { persistCache() }
    }

    private let service: LargeFileScanningService
    private let preferencesStore = DeletionPreferencesStore.shared
    private let cacheURL = AppSupportStorage.fileURL(named: "large_files_cache.json")
    private var scanTask: Task<Void, Never>?
    private var didTriggerInitialScan = false
    private var currentSortOrder: [KeyPathComparator<FileDetail>]
    
    private struct CachePayload: Codable {
        let largeFiles: [FileDetail]
        let scanCompleted: Bool
        let totalFiles: Int
        let scannedFiles: Int
        let excludedFileIDs: Set<FileDetail.ID>
        let selection: Set<FileDetail.ID>
        let permissionIssue: Bool
        let permissionMessage: String?
    }

    init(
        service: LargeFileScanningService = FileSystemLargeFileScanningService(),
        initialFiles: [FileDetail] = [],
        scanCompleted: Bool = false,
        totalFiles: Int = 0,
        scannedFiles: Int = 0,
        excluded: Set<FileDetail.ID> = [],
        selection: Set<FileDetail.ID> = [],
        permissionIssue: Bool = false,
        permissionMessage: String? = nil
    ) {
        self.service = service
        self.largeFiles = initialFiles
        self.scanCompleted = scanCompleted
        self.totalFiles = totalFiles
        self.scannedFiles = scannedFiles
        self.permissionIssue = permissionIssue
        self.permissionMessage = permissionMessage
        self.isScanning = false
        self.excludedFileIDs = excluded
        self.selection = selection
        self.currentSortOrder = [KeyPathComparator(\.size, order: .reverse)]

        if !initialFiles.isEmpty {
            let persisted = persistedExclusionIDs(for: initialFiles)
            if !persisted.isEmpty {
                excludedFileIDs.formUnion(persisted)
                self.selection.subtract(persisted)
            }
        } else {
            loadCacheIfAvailable()
        }
    }

    deinit {
        scanTask?.cancel()
    }

    func handleAppear(autoScan: Bool) {
        guard autoScan else { return }
        if isScanning { return }
        if didTriggerInitialScan, scanCompleted, !largeFiles.isEmpty { return }
        didTriggerInitialScan = true
        startScan()
    }

    func startScan(
        thresholdBytes: Int64 = 50 * 1_048_576,
        olderThanDays: Int = 30,
        maxResults: Int = 200
    ) {
        guard !isScanning else { return }

        scanTask?.cancel()
        isScanning = true
        scanCompleted = false
        permissionIssue = false
        permissionMessage = nil
        totalFiles = 0
        scannedFiles = 0
        excludedFileIDs.removeAll(keepingCapacity: true)
        selection.removeAll(keepingCapacity: true)

        scanTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isScanning = false }
            let result = await self.service.scan(
                thresholdBytes: thresholdBytes,
                olderThanDays: olderThanDays,
                maxResults: maxResults
            ) { progress in
                Task { @MainActor [weak self] in
                    guard let self, !(self.scanTask?.isCancelled ?? false) else { return }
                    self.totalFiles = progress.totalFiles
                    self.scannedFiles = progress.scannedFiles
                }
            }

            guard !Task.isCancelled else { return }

            self.largeFiles = result.files
            self.largeFiles.sort(using: self.currentSortOrder)
            let persisted = self.persistedExclusionIDs(for: result.files)
            self.excludedFileIDs = persisted
            self.selection.subtract(persisted)
            self.permissionIssue = result.permissionIssue
            self.permissionMessage = result.permissionMessage
            self.scanCompleted = true
            self.persistCache()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func sort(using comparators: [KeyPathComparator<FileDetail>]) {
        currentSortOrder = comparators
        largeFiles.sort(using: comparators)
        persistCache()
    }

    func toggleExclusion(for id: FileDetail.ID, isExcluded: Bool) {
        let file = largeFiles.first { $0.id == id }

        if isExcluded {
            excludedFileIDs.insert(id)
            selection.remove(id)
            if let path = file?.path {
                preferencesStore.updateExclusion(for: path, excluded: true)
            }
        } else {
            excludedFileIDs.remove(id)
            if let path = file?.path {
                preferencesStore.updateExclusion(for: path, excluded: false)
            }
        }

        persistCache()
    }

    func delete(_ file: FileDetail) {
        guard !excludedFileIDs.contains(file.id) else { return }
        do {
            try service.delete(paths: [file.path])
            removeFromState(file)
            persistCache()
        } catch {
            handleDeletionError(error, affectedFiles: [file])
        }
    }

    func delete(_ files: [FileDetail]) {
        let deletable = files.filter { !excludedFileIDs.contains($0.id) }
        let paths = deletable.map(\.path)
        guard !paths.isEmpty else { return }
        do {
            try service.delete(paths: paths)
            deletable.forEach(removeFromState(_:))
            persistCache()
        } catch {
            handleDeletionError(error, affectedFiles: deletable)
        }
    }

    func isExcluded(_ id: FileDetail.ID) -> Bool {
        excludedFileIDs.contains(id)
    }

    private func removeFromState(_ file: FileDetail) {
        largeFiles.removeAll { $0.id == file.id }
        selection.remove(file.id)
        excludedFileIDs.remove(file.id)
    }

    private func handleDeletionError(_ error: Error, affectedFiles: [FileDetail]) {
        if let guardError = error as? DeletionGuardError {
            permissionIssue = true
            permissionMessage = guardError.errorDescription
            return
        }

        permissionIssue = true

        if isPermissionError(error) {
            permissionMessage = permissionPrompt(for: affectedFiles)
            return
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            permissionMessage = message
            return
        }

        permissionMessage = fallbackDeletionMessage(for: affectedFiles)
    }

    private func permissionPrompt(for files: [FileDetail]) -> String {
        if let first = files.first, files.count == 1 {
            return "Grant Full Disk Access to delete \(first.name)."
        }

        if files.count > 1 {
            return "Grant Full Disk Access to delete \(files.count) selected items."
        }

        return "Grant Full Disk Access to delete the selected file."
    }

    private func fallbackDeletionMessage(for files: [FileDetail]) -> String {
        if let first = files.first, files.count == 1 {
            return "Unable to delete \(first.name). Try again or remove it manually."
        }

        if files.count > 1 {
            return "Unable to delete \(files.count) selected items. Try again or remove them manually."
        }

        return "Unable to delete the selected file. Try again or remove it manually."
    }

    private func persistedExclusionIDs(for files: [FileDetail]) -> Set<FileDetail.ID> {
        guard !files.isEmpty else { return [] }
        let storedPaths = preferencesStore.excludedPaths()
        guard !storedPaths.isEmpty else { return [] }

        return Set(files.compactMap { file in
            let normalized = normalize(path: file.path)
            return storedPaths.contains(normalized) ? file.id : nil
        })
    }

    private func loadCacheIfAvailable() {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        do {
            let data = try Data(contentsOf: cacheURL)
            let payload = try JSONDecoder().decode(CachePayload.self, from: data)
            guard !payload.largeFiles.isEmpty else { return }

            largeFiles = payload.largeFiles
            scanCompleted = payload.scanCompleted
            totalFiles = payload.totalFiles
            scannedFiles = payload.scannedFiles
            excludedFileIDs = payload.excludedFileIDs
            selection = payload.selection.subtracting(payload.excludedFileIDs)
            permissionIssue = payload.permissionIssue
            permissionMessage = payload.permissionMessage
            largeFiles.sort(using: currentSortOrder)
        } catch {
            Diagnostics.error(
                category: .cleanup,
                message: "Failed to load large file cache",
                error: error,
                metadata: ["path": cacheURL.path]
            )
        }
    }

    private func persistCache() {
        let payload = CachePayload(
            largeFiles: largeFiles,
            scanCompleted: scanCompleted,
            totalFiles: totalFiles,
            scannedFiles: scannedFiles,
            excludedFileIDs: excludedFileIDs,
            selection: selection,
            permissionIssue: permissionIssue,
            permissionMessage: permissionMessage
        )

        let url = cacheURL
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(payload)
                try data.write(to: url, options: .atomic)
            } catch {
                Diagnostics.error(
                    category: .cleanup,
                    message: "Failed to persist large file cache",
                    error: error,
                    metadata: ["path": url.path]
                )
            }
        }
    }

    private func normalize(path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
