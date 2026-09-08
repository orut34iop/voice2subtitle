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
