import XCTest
@testable import v2s

final class CaptionPipelineTests: XCTestCase {
    @MainActor
    func testRealIngressPreservesEvictedRecordsAndRejectsCallbacksFromStoppedSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lifecycle = SessionLifecycle()
        let model = AppModel(settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            sourceCatalogService: SourceCatalogService(), sessionLifecycle: lifecycle)
        let source = InputSource(id: "test:a", name: "A", detail: "a", category: .application)
        let sessionID = lifecycle.begin()!
        let texts = ["apple", "river", "mountain", "computer", "garden", "photograph", "journey", "window"]
        for text in texts {
            model.enqueueRecognizedSentence(RecognizedSentence(text: text), sessionID: sessionID,
                source: source, sourceLanguageID: "en", targetLanguageID: "en")
        }
        XCTAssertEqual(model.transcriptEntries.map(\.sourceText), texts)
        let other = InputSource(id: "test:b", name: "B", detail: "b", category: .application)
        model.enqueueRecognizedSentence(RecognizedSentence(text: "window"), sessionID: sessionID,
            source: other, sourceLanguageID: "en", targetLanguageID: "en")
        XCTAssertEqual(model.transcriptEntries.count, texts.count + 1)
        XCTAssertEqual(model.transcriptEntries.last?.sourceID, other.id)
        model.stopSession()
        let newID = lifecycle.begin()!
        model.enqueueRecognizedSentence(RecognizedSentence(text: "stale"), sessionID: sessionID,
            source: source, sourceLanguageID: "en", targetLanguageID: "en")
        XCTAssertEqual(model.transcriptEntries.count, texts.count + 1)
        model.enqueueRecognizedSentence(RecognizedSentence(text: "fresh"), sessionID: newID,
            source: source, sourceLanguageID: "en", targetLanguageID: "en")
        XCTAssertEqual(model.transcriptEntries.last?.sourceText, "fresh")
        model.stopSession()
        model.flushSettings()
    }

    @MainActor
    func testStoppedCaptureCannotRestartOrRequestPermissions() async {
        let session = LiveTranscriptionSession()
        await session.stopAndWait()
        await session.stopAndWait()
        do {
            try await session.start(
                source: InputSource(id: "test", name: "Test", detail: "missing", category: .microphone),
                localeIdentifier: "en-US", interfaceLanguageID: "en",
                transcriptHandler: { _ in XCTFail("stale callback") },
                partialHandler: { _ in XCTFail("stale draft") },
                errorHandler: { _ in XCTFail("stale error") })
            XCTFail("A stopped single-use capture cannot start")
        } catch is CancellationError { }
        catch { XCTFail("Expected cancellation before system APIs: \(error)") }
    }
}
