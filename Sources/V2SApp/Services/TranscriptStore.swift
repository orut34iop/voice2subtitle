import Combine
import Foundation

struct TranscriptEntry: Identifiable, Equatable {
    let id: UUID
    var sourceText: String
    var translatedText: String
    var sourceID: String = ""
    var sourceName: String = ""
    var sourceLanguageID: String = ""
    var targetLanguageID: String = ""
    var capturedAt: Date = Date()
}

/// The full record is independent of the bounded, latency-oriented overlay queue.
@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var entries: [TranscriptEntry] = []
    private var indices: [UUID: Int] = [:]

    func replace(_ entries: [TranscriptEntry]) {
        self.entries = entries
        indices = [:]
        for (index, entry) in entries.enumerated() { indices[entry.id] = index }
    }

    func upsert(_ entry: TranscriptEntry) {
        if let index = indices[entry.id] {
            guard entries[index] != entry else { return }
            entries[index] = entry
        } else {
            indices[entry.id] = entries.count
            entries.append(entry)
        }
    }

    func entry(id: UUID) -> TranscriptEntry? {
        indices[id].map { entries[$0] }
    }

    func updateTranslation(id: UUID, text: String) {
        guard let index = indices[id], entries[index].translatedText != text else { return }
        entries[index].translatedText = text
    }

    func clear() { replace([]) }
}
