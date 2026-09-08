import Foundation

/// A session token is invalidated synchronously, before any asynchronous cleanup starts.
@MainActor
final class SessionLifecycle {
    private(set) var currentID: UUID?
    private var cleanup: [() async -> Void] = []

    func begin() -> UUID? {
        guard currentID == nil else { return nil }
        let id = UUID()
        currentID = id
        return id
    }

    func accepts(_ id: UUID) -> Bool { currentID == id }

    func register(id: UUID, stop: @escaping () async -> Void) -> Bool {
        guard accepts(id) else { return false }
        cleanup.append(stop)
        return true
    }

    /// Returns owned cleanup work so a caller can wait for it without holding the old token live.
    func invalidate() -> [() async -> Void] {
        currentID = nil
        let operations = cleanup
        cleanup.removeAll()
        return operations
    }
}
