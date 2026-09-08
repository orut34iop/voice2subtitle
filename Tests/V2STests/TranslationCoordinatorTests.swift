import XCTest
@testable import v2s

final class TranslationCoordinatorTests: XCTestCase {
    @MainActor
    func testCancellingActiveRequestReturnsBeforeBackendAndLateCompletionIsIgnored() async {
        let coordinator = TranslationCoordinator()
        coordinator.availability = { _, _ in .installed }
        let configured = expectation(description: "configured")
        coordinator.onConfigurationChange = { _ in configured.fulfill() }
        let cancelled = expectation(description: "logical request cancelled")
        let request = Task {
            do {
                _ = try await coordinator.translate("hello", from: "en", to: "fr")
                XCTFail("Cancelled request must not return a translation")
            } catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        await fulfillment(of: [configured], timeout: 1)
        coordinator.onConfigurationChange = nil
        let entered = expectation(description: "backend entered")
        var backend: CheckedContinuation<String, Never>?
        let runner = Task {
            await coordinator.run(source: "en", target: "fr", prepare: {}, translate: { _ in
                await withCheckedContinuation { continuation in
                    backend = continuation
                    entered.fulfill()
                }
            })
        }
        await fulfillment(of: [entered], timeout: 1)
        request.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        // No cooperation from the backend was needed to release the caller.
        backend?.resume(returning: "obsolete")
        await runner.value
        coordinator.reset()
    }

    @MainActor
    func testResetReleasesActiveAndQueuedRequestsExactlyOnce() async {
        let coordinator = TranslationCoordinator()
        coordinator.availability = { _, _ in .installed }
        let configured = expectation(description: "configured")
        coordinator.onConfigurationChange = { _ in configured.fulfill() }
        let cancelled = expectation(description: "all waiters cancelled")
        cancelled.expectedFulfillmentCount = 2
        func request(_ text: String) async {
            do {
                _ = try await coordinator.translate(text, from: "en", to: "fr")
                XCTFail("reset request returned")
            } catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("\(error)") }
        }
        let first = Task { await request("first") }
        await fulfillment(of: [configured], timeout: 1)
        coordinator.onConfigurationChange = nil
        let entered = expectation(description: "backend entered")
        var backend: CheckedContinuation<String, Never>?
        let runner = Task {
            await coordinator.run(source: "en", target: "fr", prepare: {}, translate: { _ in
                await withCheckedContinuation { backend = $0; entered.fulfill() }
            })
        }
        await fulfillment(of: [entered], timeout: 1)
        let second = Task { await request("second") }
        await Task.yield()
        coordinator.reset()
        second.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        backend?.resume(returning: "late")
        await runner.value
        await first.value
        await second.value
    }
}
