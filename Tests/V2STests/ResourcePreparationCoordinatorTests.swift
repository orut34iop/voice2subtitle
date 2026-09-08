import XCTest
@testable import v2s

final class ResourcePreparationCoordinatorTests: XCTestCase {
    @MainActor
    func testOldTaskCannotPublishOrClearItsReplacement() async {
        let coordinator = ResourcePreparationCoordinator()
        let oldEntered = expectation(description: "old entered")
        let newEntered = expectation(description: "new entered")
        let oldExited = expectation(description: "old exited")
        var oldWaiter: CheckedContinuation<Void, Never>?
        var newWaiter: CheckedContinuation<Void, Never>?
        coordinator.replace {
            await withCheckedContinuation { oldWaiter = $0; oldEntered.fulfill() }
            XCTAssertFalse(coordinator.acceptsUpdates)
            oldExited.fulfill()
        }
        await fulfillment(of: [oldEntered], timeout: 1)
        coordinator.replace {
            await withCheckedContinuation { newWaiter = $0; newEntered.fulfill() }
            XCTAssertTrue(coordinator.acceptsUpdates)
        }
        await fulfillment(of: [newEntered], timeout: 1)
        oldWaiter?.resume()
        await fulfillment(of: [oldExited], timeout: 1)
        XCTAssertTrue(coordinator.isRunning)
        newWaiter?.resume()
        await coordinator.waitForCurrent()
        XCTAssertFalse(coordinator.isRunning)
    }
}
