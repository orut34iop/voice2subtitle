import Combine
import Foundation
import Translation

/// Owns a waiter independently of the framework task. Every exit resolves it at most once.
@MainActor
private final class OperationCompletion<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func resume(returning value: Value) {
        let waiter = continuation
        continuation = nil
        waiter?.resume(returning: value)
    }
    func resume(throwing error: Error) {
        let waiter = continuation
        continuation = nil
        waiter?.resume(throwing: error)
    }
}

private extension OperationCompletion where Value == Void {
    func resume() { resume(returning: ()) }
}

@MainActor
final class TranslationCoordinator: ObservableObject {
    private static let runnerIdleTimeout: TimeInterval = 0.35

    private struct LanguagePair: Equatable {
        let source: String
        let target: String
    }

    private enum PendingOperation {
        case prepare(
            id: UUID,
            generation: Int,
            pair: LanguagePair,
            continuation: OperationCompletion<Void>
        )
        case translate(
            id: UUID,
            generation: Int,
            pair: LanguagePair,
            text: String,
            continuation: OperationCompletion<String>
        )

        var id: UUID {
            switch self {
            case .prepare(let id, _, _, _), .translate(let id, _, _, _, _):
                return id
            }
        }

        var generation: Int {
            switch self {
            case .prepare(_, let generation, _, _), .translate(_, let generation, _, _, _):
                return generation
            }
        }

        var pair: LanguagePair {
            switch self {
            case .prepare(_, _, let pair, _), .translate(_, _, let pair, _, _):
                return pair
            }
        }
    }

    private enum OperationWaitResult {
        case signaled
        case timedOut
    }

    enum ServiceError: LocalizedError, AppLocalizableError {
        case unavailableOnSystem
        case unsupportedPair(String, String)

        func localizedDescription(languageID: String) -> String {
            switch self {
            case .unavailableOnSystem:
                return AppLocalization.string(.translationRequiresMacOS15OrNewer, languageID: languageID)
            case .unsupportedPair(let source, let target):
                return AppLocalization.string(
                    .translationUnsupportedFromToFormat,
                    languageID: languageID,
                    source,
                    target
                )
            }
        }

        var errorDescription: String? {
            localizedDescription(languageID: "en")
        }
    }

    var onConfigurationChange: ((TranslationSession.Configuration?) -> Void)?

    private(set) var configuration: TranslationSession.Configuration? {
        didSet {
            onConfigurationChange?(configuration)
        }
    }

    private var currentPair: LanguagePair?
    private var pendingOperations: [PendingOperation] = []
    private var activeRunnerID: UUID?
    private var cancelActiveBackend: (() -> Void)?
    private var activeOperation: PendingOperation?
    private var activeOperationID: UUID? { activeOperation?.id }
    private var generation: Int = 0
    private var runnerAvailabilityWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var operationSignalWaiters: [UUID: CheckedContinuation<OperationWaitResult, Never>] = [:]
    var consecutiveTimeouts: Int = 0

    func prepareIfNeeded(
        from sourceIdentifier: String,
        to targetIdentifier: String
    ) async throws {
        guard sourceIdentifier != targetIdentifier else {
            return
        }

        let pair = LanguagePair(source: sourceIdentifier, target: targetIdentifier)
        let requestGeneration = generation
        let status = try await availabilityStatus(for: pair)
        guard requestGeneration == generation else {
            throw CancellationError()
        }

        guard status != .installed else {
            return
        }

        try Task.checkCancellation()
        let operationID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueue(
                    .prepare(
                        id: operationID,
                        generation: requestGeneration,
                        pair: pair,
                        continuation: OperationCompletion(continuation)
                    )
                )
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelOperation(id: operationID)
            }
        }
    }

    func translate(_ text: String, from sourceIdentifier: String, to targetIdentifier: String) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            return ""
        }

        guard sourceIdentifier != targetIdentifier else {
            return trimmedText
        }

        let pair = LanguagePair(source: sourceIdentifier, target: targetIdentifier)
        let requestGeneration = generation
        _ = try await availabilityStatus(for: pair)
        guard requestGeneration == generation else {
            throw CancellationError()
        }

        try Task.checkCancellation()
        let operationID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueue(
                    .translate(
                        id: operationID,
                        generation: requestGeneration,
                        pair: pair,
                        text: trimmedText,
                        continuation: OperationCompletion(continuation)
                    )
                )
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelOperation(id: operationID)
            }
        }
    }

    @available(macOS 15.0, *)
    func run(using session: TranslationSession) async {
        await run(
            source: session.sourceLanguage?.minimalIdentifier,
            target: session.targetLanguage?.minimalIdentifier,
            prepare: { try await session.prepareTranslation() },
            translate: { try await session.translate($0).targetText },
            cancelBackend: { if #available(macOS 26.0, *) { session.cancel() } }
        )
    }

    func run(
        source: String?, target: String?,
        prepare: () async throws -> Void,
        translate: (String) async throws -> String,
        cancelBackend: @escaping () -> Void = {}
    ) async {
        let runnerID = UUID()

        while Task.isCancelled == false {
            if activeRunnerID == nil {
                activeRunnerID = runnerID
                break
            }

            if activeRunnerID == runnerID {
                break
            }

            await waitForRunnerAvailability(runnerID: runnerID)
        }

        guard Task.isCancelled == false else {
            return
        }

        let runnerGeneration = generation

        defer {
            if activeRunnerID == runnerID {
                activeRunnerID = nil
                signalRunnerAvailabilityWaiters()
                if generation == runnerGeneration, let nextPair = pendingOperations.first?.pair {
                    activate(pair: nextPair)
                }
            }
        }

        guard runnerGeneration == generation else {
            return
        }

        guard let anchoredPair = currentPair,
              source.map({ Locale.Language(identifier: $0).maximalIdentifier }) == Locale.Language(identifier: anchoredPair.source).maximalIdentifier,
              target.map({ Locale.Language(identifier: $0).maximalIdentifier }) == Locale.Language(identifier: anchoredPair.target).maximalIdentifier else {
            return
        }

        while Task.isCancelled == false {
            guard runnerGeneration == generation, activeRunnerID == runnerID else {
                return
            }

            guard let operation = await nextOperation(
                for: anchoredPair,
                generation: runnerGeneration,
                idleTimeout: Self.runnerIdleTimeout
            ) else {
                return
            }

            guard activeRunnerID == runnerID else { return }
            activeOperation = operation
            cancelActiveBackend = cancelBackend

            switch operation {
            case .prepare(let id, _, _, let continuation):
                do {
                    try await prepare()
                    finishOperation(id: id, continuation: continuation)
                } catch {
                    finishOperation(id: id, continuation: continuation, error: error)
                }

            case .translate(let id, _, _, let text, let continuation):
                do {
                    let response = try await translate(text)
                    let translatedText = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    finishOperation(
                        id: id,
                        continuation: continuation,
                        result: translatedText.isEmpty ? text : translatedText
                    )
                } catch {
                    finishOperation(id: id, continuation: continuation, error: error)
                }
            }
        }
    }

    func reset() {
        generation &+= 1
        cancelOutstandingOperations()
        currentPair = nil
        configuration = nil
    }

    /// Invalidate the current TranslationSession so SwiftUI's `.translationTask()`
    /// provides a fresh session. Use this to recover from a stuck translation state
    /// without requiring a full app restart.
    func invalidateSession() {
        configuration?.invalidate()
        activeRunnerID = nil
        signalRunnerAvailabilityWaiters()
        configuration = nil
    }

    /// Full recovery: invalidate the stuck session, reset all state, then immediately
    /// create a fresh configuration for the given language pair so a new runner can start.
    /// The old runner (stuck in session.translate()) will see a generation mismatch and exit.
    func recoverSession(source: String, target: String) {
        var oldConfig = configuration
        // Bump generation so the stuck runner exits when it finally returns
        generation &+= 1
        cancelOutstandingOperations()

        // Invalidate the old session so SwiftUI provides a fresh one
        oldConfig?.invalidate()

        // Immediately create a new configuration for the current pair
        // so SwiftUI's .translationTask() fires with a new session
        currentPair = LanguagePair(source: source, target: target)
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )
    }

    private func enqueue(_ operation: PendingOperation) {
        activate(pair: operation.pair)
        pendingOperations.append(operation)
        signalOperationWaiters()
    }

    private func activate(pair: LanguagePair) {
        if activeRunnerID != nil, currentPair != pair {
            return
        }

        if currentPair != pair || configuration == nil {
            currentPair = pair
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: pair.source),
                target: Locale.Language(identifier: pair.target)
            )
            return
        }

        if activeRunnerID == nil {
            // Each TranslationSession is view-anchored and should be refreshed
            // once the previous runner has drained and exited.
            configuration?.invalidate()
        }
    }

    private func cancelOperation(id: UUID) {
        if let index = pendingOperations.firstIndex(where: { $0.id == id }) {
            let operation = pendingOperations.remove(at: index)
            cancel(operation)
            return
        }

        if let operation = activeOperation, operation.id == id {
            cancel(operation)
            let cancelBackend = cancelActiveBackend
            cancelActiveBackend = nil
            activeOperation = nil
            cancelBackend?()
            // Detach the logical waiter immediately, even if the framework is unresponsive.
            activeRunnerID = nil
            signalRunnerAvailabilityWaiters()
            configuration?.invalidate()
            signalOperationWaiters()
        }
    }

    private func cancelOutstandingOperations() {
        if let activeOperation { cancel(activeOperation) }
        let cancelBackend = cancelActiveBackend
        cancelActiveBackend = nil
        cancelBackend?()
        for operation in pendingOperations { cancel(operation) }
        pendingOperations.removeAll()
        activeRunnerID = nil
        activeOperation = nil
        consecutiveTimeouts = 0
        signalRunnerAvailabilityWaiters()
        signalOperationWaiters()
    }

    private func cancel(_ operation: PendingOperation) {
        switch operation {
        case .prepare(_, _, _, let continuation):
            continuation.resume(throwing: CancellationError())
        case .translate(_, _, _, _, let continuation):
            continuation.resume(throwing: CancellationError())
        }
    }

    @available(macOS 15.0, *)
    private func nextOperation(
        for pair: LanguagePair,
        generation: Int,
        idleTimeout: TimeInterval
    ) async -> PendingOperation? {
        let deadline = Date().addingTimeInterval(idleTimeout)

        while Task.isCancelled == false {
            guard generation == self.generation else {
                return nil
            }

            if let first = pendingOperations.first {
                guard first.pair == pair && first.generation == generation else { return nil }
                return pendingOperations.removeFirst()
            }

            if await waitForOperationSignal(for: pair, generation: generation, until: deadline) == .timedOut {
                return nil
            }
        }

        return nil
    }

    private func waitForRunnerAvailability(runnerID: UUID) async {
        let waiterID = UUID()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if activeRunnerID == nil || activeRunnerID == runnerID {
                    continuation.resume()
                    return
                }

                runnerAvailabilityWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeRunnerAvailabilityWaiter(id: waiterID)
            }
        }
    }

    private func resumeRunnerAvailabilityWaiter(id: UUID) {
        guard let continuation = runnerAvailabilityWaiters.removeValue(forKey: id) else {
            return
        }

        continuation.resume()
    }

    private func signalRunnerAvailabilityWaiters() {
        let waiters = runnerAvailabilityWaiters
        runnerAvailabilityWaiters.removeAll()

        for continuation in waiters.values {
            continuation.resume()
        }
    }

    private func waitForOperationSignal(
        for pair: LanguagePair,
        generation: Int,
        until deadline: Date
    ) async -> OperationWaitResult {
        guard deadline.timeIntervalSinceNow > 0 else {
            return .timedOut
        }

        let waiterID = UUID()
        let timeoutTask = Task { @MainActor [weak self] in
            let remaining = max(0, deadline.timeIntervalSinceNow)
            if remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                } catch {
                    return
                }
            }

            self?.resumeOperationWaiter(id: waiterID, result: .timedOut)
        }

        return await withTaskCancellationHandler {
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<OperationWaitResult, Never>) in
                guard self.generation == generation else {
                    continuation.resume(returning: .signaled)
                    return
                }

                if self.pendingOperations.contains(where: { $0.pair == pair && $0.generation == generation }) {
                    continuation.resume(returning: .signaled)
                    return
                }

                self.operationSignalWaiters[waiterID] = continuation
            }

            timeoutTask.cancel()
            return result
        } onCancel: {
            timeoutTask.cancel()
            Task { @MainActor [weak self] in
                self?.resumeOperationWaiter(id: waiterID, result: .timedOut)
            }
        }
    }

    private func resumeOperationWaiter(id: UUID, result: OperationWaitResult) {
        guard let continuation = operationSignalWaiters.removeValue(forKey: id) else {
            return
        }

        continuation.resume(returning: result)
    }

    private func signalOperationWaiters() {
        let waiters = operationSignalWaiters
        operationSignalWaiters.removeAll()

        for continuation in waiters.values {
            continuation.resume(returning: .signaled)
        }
    }

    private func finishOperation(
        id: UUID,
        continuation: OperationCompletion<Void>,
        error: Error? = nil
    ) {
        if activeOperationID == id {
            activeOperation = nil
            cancelActiveBackend = nil
        }

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func finishOperation(
        id: UUID,
        continuation: OperationCompletion<String>,
        result: String? = nil,
        error: Error? = nil
    ) {
        if activeOperationID == id {
            activeOperation = nil
            cancelActiveBackend = nil
        }

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: result ?? "")
        }
    }

    var availability: (String, String) async -> LanguageAvailability.Status = { source, target in
        await LanguageAvailability().status(
            from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)
        )
    }

    private func availabilityStatus(for pair: LanguagePair) async throws -> LanguageAvailability.Status {
        guard #available(macOS 15.0, *) else {
            throw ServiceError.unavailableOnSystem
        }

        let availabilityStatus = await availability(pair.source, pair.target)

        guard availabilityStatus != .unsupported else {
            throw ServiceError.unsupportedPair(pair.source, pair.target)
        }

        return availabilityStatus
    }
}
