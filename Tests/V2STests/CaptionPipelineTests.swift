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
                speechActivityHandler: { _ in XCTFail("stale speech activity") },
                errorHandler: { _ in XCTFail("stale error") })
            XCTFail("A stopped single-use capture cannot start")
        } catch is CancellationError { }
        catch { XCTFail("Expected cancellation before system APIs: \(error)") }
    }
}


final class SubtitleAutoHideTests: XCTestCase {
    @MainActor
    func testSilenceDeadlineSurvivesMissingBuffersAndLateCaptions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lifecycle = SessionLifecycle()
        let model = AppModel(settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            sourceCatalogService: SourceCatalogService(), sessionLifecycle: lifecycle)
        defer { model.stopSession(); model.flushSettings() }
        let id = lifecycle.begin()!
        model.showOverlayPreview()
        model.beginSubtitleAutoHideMonitoring()
        XCTAssertTrue(model.shouldShowOverlay)
        try await Task.sleep(for: .seconds(2.8))
        XCTAssertFalse(model.isOverlayHiddenForSilence)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.isOverlayHiddenForSilence)
        XCTAssertFalse(model.shouldShowOverlay)
        XCTAssertTrue(model.isOverlayVisible, "Automatic hiding must preserve the manual visibility setting")

        let source = InputSource(id: "test:a", name: "A", detail: "a", category: .application)
        model.enqueueRecognizedSentence(RecognizedSentence(text: "A late recognition result"), sessionID: id,
            source: source, sourceLanguageID: "en", targetLanguageID: "en")
        XCTAssertFalse(model.shouldShowOverlay)
        XCTAssertEqual(model.transcriptEntries.last?.sourceText, "A late recognition result")

        model.recordSpeechActivity(sessionID: id, at: .now.advanced(by: .seconds(-4)))
        XCTAssertFalse(model.shouldShowOverlay, "A stale queued speech callback must not reopen the overlay")
        model.recordSpeechActivity(sessionID: id, at: .now)
        XCTAssertTrue(model.shouldShowOverlay)
        model.isOverlayVisible = false
        model.recordSpeechActivity(sessionID: id, at: .now)
        XCTAssertFalse(model.shouldShowOverlay, "Speech must not undo a manual hide")
    }

    @MainActor
    func testAnySourceSpeechExtendsDeadlineAndStoppedSessionCannotReopenIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lifecycle = SessionLifecycle()
        let model = AppModel(settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            sourceCatalogService: SourceCatalogService(), sessionLifecycle: lifecycle)
        defer { model.stopSession(); model.flushSettings() }
        let first = lifecycle.begin()!
        model.showOverlayPreview()
        model.beginSubtitleAutoHideMonitoring()
        try await Task.sleep(for: .seconds(2))
        // All selected sources feed the same session deadline; silence on one source
        // cannot hide subtitles while another source is still speaking.
        model.recordSpeechActivity(sessionID: first, at: .now)
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertTrue(model.shouldShowOverlay)
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(model.shouldShowOverlay)
        model.stopSession()
        XCTAssertFalse(model.isOverlayHiddenForSilence)
        model.showOverlayPreview()
        XCTAssertTrue(model.shouldShowOverlay, "Idle previews remain available")
        let second = lifecycle.begin()!
        model.beginSubtitleAutoHideMonitoring()
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertFalse(model.shouldShowOverlay)
        model.recordSpeechActivity(sessionID: first, at: .now)
        XCTAssertFalse(model.shouldShowOverlay)
        model.recordSpeechActivity(sessionID: second, at: .now)
        XCTAssertTrue(model.shouldShowOverlay)
    }

    @MainActor
    func testToggleTakesEffectDuringSessionAndPersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        let lifecycle = SessionLifecycle()
        let model = AppModel(settingsStore: store, sourceCatalogService: SourceCatalogService(), sessionLifecycle: lifecycle)
        defer { model.stopSession(); model.flushSettings() }
        _ = lifecycle.begin()
        model.showOverlayPreview()
        model.beginSubtitleAutoHideMonitoring()
        model.autoHideSubtitles = false
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertTrue(model.shouldShowOverlay)
        model.autoHideSubtitles = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.shouldShowOverlay, "Enabling uses elapsed silence, not a new grace period")
        model.autoHideSubtitles = false
        XCTAssertTrue(model.shouldShowOverlay)
        model.flushSettings()
        XCTAssertFalse(store.load().autoHideSubtitles)
        model.stopSession()
        model.autoHideSubtitles = true
        model.showOverlayPreview()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.shouldShowOverlay)
    }
}
