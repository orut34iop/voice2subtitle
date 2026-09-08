import Foundation

/// Task-local ownership propagates into child tasks, including progress polling.
@MainActor
final class ResourcePreparationCoordinator {
    @TaskLocal static var operationID: UUID?
    private var currentID: UUID?
    private(set) var task: Task<Void, Never>?
    var isRunning: Bool { task != nil }
    var acceptsUpdates: Bool {
        guard !Task.isCancelled else { return false }
        guard let operationID = Self.operationID else { return true }
        return operationID == currentID
    }

    func replace(operation: @escaping @MainActor () async -> Void) {
        cancel()
        let id = UUID()
        currentID = id
        task = Task { [weak self] in
            await Self.$operationID.withValue(id) { await operation() }
            guard let self, self.currentID == id else { return }
            self.task = nil
        }
    }

    func cancel() {
        currentID = nil
        task?.cancel()
        task = nil
    }

    func waitForCurrent() async {
        while let task {
            await task.value
            if Task.isCancelled { return }
        }
    }
}
