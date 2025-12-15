import Foundation

final class CleanupProgress {
    private let lock = NSLock()
    private var totalUnits: Double
    private var completedUnits: Double

    init(initialTotal: Int) {
        totalUnits = max(Double(initialTotal), 1)
        completedUnits = 0
    }

    func registerAdditionalUnits(_ units: Int, update: @escaping (Double) -> Void) {
        guard units > 0 else { return }
        let progress: Double
        lock.lock()
        totalUnits += Double(units)
        progress = completedUnits / max(totalUnits, 1)
        lock.unlock()
        update(progress)
    }

    func advance(by units: Int = 1, update: @escaping (Double) -> Void) {
        guard units > 0 else { return }
        let progress: Double
        lock.lock()
        completedUnits += Double(units)
        if completedUnits > totalUnits {
            totalUnits = completedUnits
        }
        progress = completedUnits / max(totalUnits, 1)
        lock.unlock()
        update(progress)
    }
}
