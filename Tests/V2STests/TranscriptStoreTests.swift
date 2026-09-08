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

extension TranscriptStoreTests {
    @MainActor
    func testOneHourRecordAndTranslationBackfillPerformance() {
        let entries = (0..<3600).map { index in
            TranscriptEntry(id: UUID(), sourceText: "Meeting sentence \(index): decisions and follow-up actions.", translatedText: "")
        }
        let store = TranscriptStore()
        measure {
            store.clear()
            for entry in entries { store.upsert(entry) }
            for entry in entries { store.updateTranslation(id: entry.id, text: "Translated meeting sentence.") }
        }
        XCTAssertEqual(store.entries.count, 3600)
        XCTAssertTrue(store.entries.allSatisfy { !$0.translatedText.isEmpty })
    }
}
