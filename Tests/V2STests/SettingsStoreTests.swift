import XCTest
@testable import v2s

final class SettingsStoreTests: XCTestCase {
    @MainActor
    func testFlushPersistsOnlyLatestPendingSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: url)
        var settings = AppSettings.default
        for index in 0..<100 {
            settings.glossary = ["index": String(index)]
            store.save(settings)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.flush()
        XCTAssertEqual(store.load().glossary, ["index": "99"])
    }

    @MainActor
    func testDamagedSettingsArePreservedBeforeDefaultsOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        try Data("damaged".utf8).write(to: url)
        let store = SettingsStore(fileURL: url)
        _ = store.load()
        store.save(.default)
        store.flush()
        let backup = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("corrupt-") }
        XCTAssertNotNil(backup)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backup), encoding: .utf8), "damaged")
    }
}

@MainActor
final class SourceSelectionPersistenceTests: XCTestCase {
    private let chrome = InputSource(id: "app:com.google.Chrome", name: "Google Chrome",
        detail: "com.google.Chrome", category: .application)
    private let bluetooth = InputSource(id: "mic:bluetooth", name: "Bluetooth Mic",
        detail: "bluetooth", category: .microphone)

    func testUnavailableChromeSurvivesStartupRefreshAndRelaunchWithoutSelectingMicrophone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: url)
        var settings = AppSettings.default
        settings.selectedSourceID = chrome.id
        settings.selectedSourceIDs = [chrome.id]
        settings.sourceLanguageOverrides = [chrome.id: "fr"]
        settings.sourceOutputLanguageOverrides = [chrome.id: "de"]
        store.save(settings)
        store.flush()
        var snapshot = SourceCatalogSnapshot(applications: [], microphones: [bluetooth])
        let catalog = SourceCatalogService(snapshotProvider: { snapshot })
        let model = AppModel(settingsStore: store, sourceCatalogService: catalog)
        XCTAssertEqual(model.selectedSourceIDs, [chrome.id])
        XCTAssertEqual(model.selectedSourceID, chrome.id)
        XCTAssertTrue(model.selectedSources.isEmpty)
        model.persistSettings()
        model.flushSettings()
        let relaunched = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: catalog)
        XCTAssertEqual(relaunched.selectedSourceIDs, [chrome.id])
        snapshot = SourceCatalogSnapshot(applications: [chrome], microphones: [bluetooth])
        relaunched.refreshSources()
        XCTAssertEqual(relaunched.selectedSources, [chrome])
        XCTAssertEqual(relaunched.sourceLanguageOverrides, settings.sourceLanguageOverrides)
        XCTAssertEqual(relaunched.sourceOutputLanguageOverrides, settings.sourceOutputLanguageOverrides)
        relaunched.flushSettings()
    }

    func testExplicitEmptySelectionDoesNotResurrectLegacyPrimaryOrDefaultDevice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: url)
        var settings = AppSettings.default
        settings.selectedSourceID = chrome.id
        settings.selectedSourceIDs = []
        store.save(settings)
        store.flush()
        let model = AppModel(settingsStore: store, sourceCatalogService: SourceCatalogService(
            snapshotProvider: { SourceCatalogSnapshot(applications: [self.chrome], microphones: [self.bluetooth]) }))
        XCTAssertTrue(model.selectedSourceIDs.isEmpty)
        XCTAssertNil(model.selectedSourceID)
        XCTAssertTrue(model.selectedSources.isEmpty)
        model.refreshSources()
        XCTAssertTrue(model.selectedSourceIDs.isEmpty)
        model.flushSettings()
    }

    func testDeviceReconnectAndReorderedCatalogDoNotChangeUserSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        var snapshot = SourceCatalogSnapshot(applications: [chrome], microphones: [bluetooth])
        let model = AppModel(settingsStore: SettingsStore(fileURL: url),
            sourceCatalogService: SourceCatalogService(snapshotProvider: { snapshot }))
        XCTAssertTrue(model.selectedSourceIDs.isEmpty, "First launch must not opt into a microphone")
        model.selectedSourceIDs = [chrome.id, bluetooth.id]
        snapshot = SourceCatalogSnapshot(applications: [chrome], microphones: [])
        model.refreshSources()
        XCTAssertEqual(model.selectedSourceIDs, [chrome.id, bluetooth.id])
        XCTAssertEqual(model.unavailableSelectedSources, [bluetooth])
        XCTAssertTrue(model.sourceSelectionOptions.contains(bluetooth))
        snapshot = SourceCatalogSnapshot(applications: [], microphones: [])
        model.refreshSources()
        XCTAssertEqual(model.selectedSourceIDs, [chrome.id, bluetooth.id])
        snapshot = SourceCatalogSnapshot(applications: [chrome], microphones: [bluetooth])
        model.refreshSources()
        XCTAssertEqual(Set(model.selectedSources.map(\.id)), [chrome.id, bluetooth.id])
        model.selectedSourceIDs = [chrome.id]
        XCTAssertEqual(SettingsStore(fileURL: url).load().sourceSelectionDetails, [chrome])
        // Discrete selections must already be durable before the debounce or termination hook.
        XCTAssertEqual(SettingsStore(fileURL: url).load().selectedSourceIDs, [chrome.id])
        model.selectedSourceIDs = []
        model.refreshSources()
        XCTAssertTrue(model.selectedSourceIDs.isEmpty)
        model.flushSettings()
        let relaunched = AppModel(settingsStore: SettingsStore(fileURL: url),
            sourceCatalogService: SourceCatalogService(snapshotProvider: { snapshot }))
        XCTAssertTrue(relaunched.selectedSourceIDs.isEmpty)
        relaunched.flushSettings()
    }

    func testMissingSelectedSourceBlocksStartingAvailableSubsetWithoutChangingSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: url)
        var settings = AppSettings.default
        settings.selectedSourceID = chrome.id
        settings.selectedSourceIDs = [chrome.id, bluetooth.id]
        settings.sourceSelectionDetails = [chrome, bluetooth]
        store.save(settings)
        store.flush()
        let model = AppModel(settingsStore: store, sourceCatalogService: SourceCatalogService(
            snapshotProvider: { SourceCatalogSnapshot(applications: [], microphones: [self.bluetooth]) }))
        await model.startSession()
        XCTAssertEqual(model.sessionState, .error)
        XCTAssertEqual(model.selectedSourceIDs, [chrome.id, bluetooth.id])
        XCTAssertTrue(model.statusMessage.contains(chrome.name))
        XCTAssertEqual(model.unavailableSelectedSources, [chrome])
        XCTAssertNil(model.overlayState, "Unavailable selection is rejected before capture or resource preparation")
        XCTAssertEqual(Set(store.load().selectedSourceIDs), [chrome.id, bluetooth.id])
        model.flushSettings()
    }

}
