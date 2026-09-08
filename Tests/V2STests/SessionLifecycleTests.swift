import XCTest
@testable import v2s

final class SessionLifecycleTests: XCTestCase {
    @MainActor
    func testOverlappingStartsAreRejectedAndOldCallbacksStayInvalidAfterRestart() async {
        let lifecycle = SessionLifecycle()
        let oldID = lifecycle.begin()!
        XCTAssertNil(lifecycle.begin())
        var stopped = 0
        XCTAssertTrue(lifecycle.register(id: oldID) { stopped += 1 })
        let cleanup = lifecycle.invalidate()
        XCTAssertFalse(lifecycle.accepts(oldID))
        let newID = lifecycle.begin()!
        XCTAssertFalse(lifecycle.accepts(oldID))
        XCTAssertTrue(lifecycle.accepts(newID))
        XCTAssertFalse(lifecycle.register(id: oldID) { XCTFail("stale registration") })
        for operation in cleanup { await operation() }
        XCTAssertEqual(stopped, 1)
        XCTAssertTrue(lifecycle.accepts(newID))
        XCTAssertTrue(lifecycle.invalidate().isEmpty)
        XCTAssertTrue(lifecycle.invalidate().isEmpty)
    }
}
