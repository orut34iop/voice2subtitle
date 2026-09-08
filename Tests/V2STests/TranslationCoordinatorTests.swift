import XCTest
import Translation
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

extension TranslationCoordinatorTests {
    @MainActor
    func testCanonicalLanguageIdentifiersUseTheConfiguredSession() async throws {
        let coordinator = TranslationCoordinator()
        coordinator.availability = { _, _ in .installed }
        let configured = expectation(description: "configured")
        coordinator.onConfigurationChange = { _ in configured.fulfill() }
        let request = Task { try await coordinator.translate("hello", from: "en", to: "zh-Hans") }
        await fulfillment(of: [configured], timeout: 1)
        coordinator.onConfigurationChange = nil
        let runner = Task {
            await coordinator.run(source: "en-US", target: "zh", prepare: {}, translate: { _ in "你好" })
        }
        let translation = try await request.value
        XCTAssertEqual(translation, "你好")
        coordinator.reset()
        await runner.value
    }

    @MainActor
    func testLanguagePairsAreServedInArrivalOrder() async throws {
        let coordinator = TranslationCoordinator()
        coordinator.availability = { _, _ in .installed }
        let configured = expectation(description: "configured")
        coordinator.onConfigurationChange = { _ in configured.fulfill() }
        let first = Task { try await coordinator.translate("A1", from: "en", to: "fr") }
        await fulfillment(of: [configured], timeout: 1)
        coordinator.onConfigurationChange = nil
        let entered = expectation(description: "first backend entered")
        var waiter: CheckedContinuation<String, Never>?
        var order: [String] = []
        let runner = Task {
            await coordinator.run(source: "en", target: "fr", prepare: {}, translate: { text in
                order.append(text)
                return await withCheckedContinuation { waiter = $0; entered.fulfill() }
            })
        }
        await fulfillment(of: [entered], timeout: 1)
        let second = Task { try await coordinator.translate("B", from: "en", to: "ja") }
        for _ in 0..<1000 where coordinator.pendingRequestCount < 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(coordinator.pendingRequestCount, 1)
        let third = Task { try await coordinator.translate("A2", from: "en", to: "fr") }
        for _ in 0..<1000 where coordinator.pendingRequestCount < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(coordinator.pendingRequestCount, 2)
        waiter?.resume(returning: "first")
        await runner.value
        await coordinator.run(source: "en", target: "ja", prepare: {}, translate: { order.append($0); return "second" })
        await coordinator.run(source: "en", target: "fr", prepare: {}, translate: { order.append($0); return "third" })
        let results = try await [first.value, second.value, third.value]
        XCTAssertEqual(results, ["first", "second", "third"])
        XCTAssertEqual(order, ["A1", "B", "A2"])
        coordinator.reset()
    }
}

extension TranslationCoordinatorTests {
    @MainActor
    func testCancellationIncludesUnresponsiveSystemAvailabilityQuery() async {
        let coordinator = TranslationCoordinator()
        let entered = expectation(description: "system query entered")
        let cancelled = expectation(description: "caller cancelled")
        var systemReply: CheckedContinuation<LanguageAvailability.Status, Never>?
        coordinator.availability = { _, _ in
            await withCheckedContinuation { systemReply = $0; entered.fulfill() }
        }
        let request = Task {
            do {
                _ = try await coordinator.translate("hello", from: "en", to: "fr")
                XCTFail("Cancelled request returned")
            } catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("\(error)") }
        }
        await fulfillment(of: [entered], timeout: 1)
        request.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        systemReply?.resume(returning: .installed)
        await request.value
        XCTAssertEqual(coordinator.pendingRequestCount, 0)
        coordinator.reset()
    }
}
