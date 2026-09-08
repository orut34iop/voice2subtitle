import XCTest
@testable import v2s

final class SourceDraftStoreTests: XCTestCase {
    private func draft(_ text: String, id: UUID = UUID()) -> DraftSegment {
        DraftSegment(segmentId: id, sourceText: text, stablePrefixLength: 0,
            mutableTailText: text, avgConfidence: 1, startMs: 0, lastUpdateMs: 0,
            silenceMs: 0, stabilityScore: 1, boundaryScore: 0, chunkScore: 1,
            vadProbability: 1, words: [])
    }

    func testSourcesDoNotEraseEachOtherOrShareTranslations() {
        var store = SourceDraftStore()
        let a = InputSource(id: "a", name: "A", detail: "a", category: .microphone)
        let b = InputSource(id: "b", name: "B", detail: "b", category: .application)
        let first = draft("Hello")
        let second = draft("Hello")
        store.update(first, source: a, from: "en", to: "fr")
        store.update(second, source: b, from: "en", to: "ja")
        XCTAssertEqual(store.visible?.source.id, "a")
        XCTAssertTrue(store.setTranslation("bonjour", sourceID: "a", promotionID: first.segmentId, sourceText: "Hello"))
        XCTAssertNil(store.snapshots["b"]?.translatedText)
        store.remove(sourceID: "b")
        XCTAssertEqual(store.visible?.translatedText, "bonjour")
        store.update(second, source: b, from: "en", to: "ja")
        store.remove(sourceID: "a", promotionID: first.segmentId)
        XCTAssertEqual(store.visible?.source.id, "b")
        XCTAssertFalse(store.setTranslation("stale", sourceID: "a", promotionID: first.segmentId, sourceText: "Hello"))
        XCTAssertNil(store.visible?.translatedText)
    }

    func testOldPromotionCannotRemoveNewDraftOfSameSource() {
        var store = SourceDraftStore()
        let source = InputSource(id: "a", name: "A", detail: "a", category: .microphone)
        let old = draft("one")
        let current = draft("two")
        store.update(old, source: source, from: "en", to: "fr")
        store.update(current, source: source, from: "en", to: "fr")
        store.remove(sourceID: "a", promotionID: old.segmentId)
        XCTAssertEqual(store.visible?.draft.segmentId, current.segmentId)
        XCTAssertFalse(store.setTranslation("old", sourceID: "a", promotionID: old.segmentId, sourceText: "one"))
    }
}
