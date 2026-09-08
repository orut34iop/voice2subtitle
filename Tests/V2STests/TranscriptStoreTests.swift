import XCTest
@testable import v2s

final class TranscriptStoreTests: XCTestCase {
    @MainActor
    func testRecordsSurviveDisplayEvictionAndReceiveLateTranslation() {
        let store = TranscriptStore()
        var display: [UUID] = []
        var all: [UUID] = []
        for index in 0..<100 {
            let id = UUID()
            all.append(id)
            store.upsert(TranscriptEntry(id: id, sourceText: "Sentence \(index)", translatedText: ""))
            display.append(id)
            while display.count > 3 { display.remove(at: 1) }
        }
        XCTAssertEqual(display.count, 3)
        XCTAssertEqual(store.entries.count, 100)
        XCTAssertEqual(store.entries.map(\.id), all)
        store.updateTranslation(id: all[20], text: "Late translation")
        XCTAssertEqual(store.entry(id: all[20])?.translatedText, "Late translation")
        store.clear()
        store.updateTranslation(id: all[20], text: "Stale translation")
        XCTAssertTrue(store.entries.isEmpty)
    }
}
