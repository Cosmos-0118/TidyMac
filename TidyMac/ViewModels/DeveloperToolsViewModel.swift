import Foundation

@MainActor
final class DeveloperToolsViewModel: ObservableObject {
    @Published var selectedCategory: DeveloperCategory
    @Published private(set) var activeOperation: DeveloperOperation?
    @Published private(set) var banner: OperationBanner?

    private let service: DeveloperOperationsService
    private var operationTask: Task<Void, Never>?

    init(
        service: DeveloperOperationsService = FileSystemDeveloperOperationsService(),
        selectedCategory: DeveloperCategory = .caches,
        banner: OperationBanner? = nil
    ) {
        self.service = service
        self.selectedCategory = selectedCategory
        self.banner = banner
    }

    deinit {
        operationTask?.cancel()
    }

    func runOperation(_ operation: DeveloperOperation) {
        guard activeOperation == nil else { return }
        activeOperation = operation
        banner = nil

        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.service.run(operation: operation)
            guard !Task.isCancelled else { return }
            self.banner = result
            self.activeOperation = nil
        }
    }

    func resetBanner() {
        banner = nil
    }
}
