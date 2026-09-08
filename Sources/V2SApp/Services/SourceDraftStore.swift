import Foundation

/// Each source owns its text and translation. The overlay keeps one owner until it yields.
struct SourceDraftStore {
    struct Snapshot {
        let source: InputSource
        var draft: DraftSegment
        let sourceLanguageID: String
        let targetLanguageID: String
        var translatedText: String?
        var translatedSourceText: String?
    }
    private(set) var snapshots: [String: Snapshot] = [:]
    private var order: [String] = []
    var visible: Snapshot? { order.first.flatMap { snapshots[$0] } }

    mutating func update(_ draft: DraftSegment, source: InputSource, from: String, to: String) {
        let previous = snapshots[source.id]
        let sameDraft = previous?.draft.segmentId == draft.segmentId
            && previous?.sourceLanguageID == from && previous?.targetLanguageID == to
        snapshots[source.id] = Snapshot(
            source: source, draft: draft, sourceLanguageID: from, targetLanguageID: to,
            translatedText: sameDraft ? previous?.translatedText : nil,
            translatedSourceText: sameDraft ? previous?.translatedSourceText : nil
        )
        if !order.contains(source.id) { order.append(source.id) }
    }

    mutating func remove(sourceID: String, promotionID: UUID? = nil) {
        if let promotionID, snapshots[sourceID]?.draft.segmentId != promotionID { return }
        snapshots[sourceID] = nil
        order.removeAll { $0 == sourceID }
    }

    @discardableResult
    mutating func setTranslation(_ text: String, sourceID: String, promotionID: UUID, sourceText: String) -> Bool {
        guard var snapshot = snapshots[sourceID], snapshot.draft.segmentId == promotionID,
              snapshot.draft.sourceText == sourceText else { return false }
        snapshot.translatedText = text
        snapshot.translatedSourceText = sourceText
        snapshots[sourceID] = snapshot
        return true
    }

    mutating func clear() { snapshots.removeAll(); order.removeAll() }
}
