import Foundation
import XCTest
@testable import v2s

final class AppSettingsTests: XCTestCase {
    func testAllInternalSourceIsStableAndLocalized() {
        let source = InputSource.allInternalSources

        XCTAssertEqual(source.id, InputSource.allInternalSourcesID)
        XCTAssertEqual(source.category, .application)
        XCTAssertTrue(source.isAllInternalSources)
        XCTAssertEqual(source.displayName(in: "zh-Hans"), "全部内部来源")
    }

    func testLegacyApplicationSelectionsMigrateToAllInternalSources() {
        let migrated = InputSource.migratingLegacyApplicationSourceIDs([
            "app:com.apple.Safari",
            "app:com.google.Chrome",
            "mic:built-in"
        ])

        XCTAssertEqual(migrated, [InputSource.allInternalSourcesID, "mic:built-in"])
        XCTAssertEqual(
            InputSource.migratingLegacyApplicationSourceID("app:com.apple.Safari"),
            InputSource.allInternalSourcesID
        )
    }

    func testLegacyApplicationLanguageOverrideMigratesToAllInternalSources() {
        let migrated = InputSource.migratingLegacyApplicationSourceValues(
            [
                "app:com.apple.Safari": "ja",
                "app:com.google.Chrome": "en",
                "mic:built-in": "zh-Hans"
            ],
            preferredSourceID: "app:com.google.Chrome"
        )

        XCTAssertEqual(
            migrated,
            [InputSource.allInternalSourcesID: "en", "mic:built-in": "zh-Hans"]
        )
    }

    func testAllInternalAudioTapIsGlobalMonoMix() {
        let description = makeAllInternalAudioTapDescription()

        XCTAssertTrue(description.isExclusive)
        XCTAssertTrue(description.isMono)
        XCTAssertTrue(description.processes.isEmpty)
    }

    @MainActor
    func testSourceCatalogExposesOnlyAggregateInternalSource() {
        let snapshot = SourceCatalogService().loadSnapshot()

        XCTAssertEqual(snapshot.applications, [.allInternalSources])
    }

    func testLegacySingleSourceSettingsDecodeIntoMultiSourceFields() throws {
        let json = """
        {
          "selectedSourceID": "mic-1",
          "inputLanguageID": "en",
          "outputLanguageID": "ja",
          "overlayStyle": {
            "translatedFontSize": 20,
            "sourceFontSize": 16,
            "backgroundOpacity": 0.7,
            "subtitleColor": { "kind": "defaultSubtitle" },
            "textColor": { "kind": "defaultText" },
            "backgroundColor": { "kind": "defaultBackground" },
            "showsTextOutline": true,
            "textOutlineColor": { "kind": "defaultTextOutline" },
            "attachToSource": true,
            "translatedFirst": true
          },
          "subtitleMode": "balanced",
          "subtitleDisplayMode": "both",
          "glossary": {}
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.selectedSourceID, "mic-1")
        XCTAssertEqual(settings.selectedSourceIDs, ["mic-1"])
        XCTAssertTrue(settings.sourceLanguageOverrides.isEmpty)
        XCTAssertTrue(settings.sourceOutputLanguageOverrides.isEmpty)
        XCTAssertTrue(settings.releasedSpeechResourceIDs.isEmpty)
    }

    func testMultiSourceSettingsRoundTripPreservesOverrides() throws {
        let settings = AppSettings(
            selectedSourceID: "mic-1",
            selectedSourceIDs: ["mic-1", "app-1"],
            sourceLanguageOverrides: ["app-1": "fr"],
            sourceOutputLanguageOverrides: ["mic-1": "zh-Hans", "app-1": "de"],
            inputLanguageID: "en",
            outputLanguageID: "ja",
            interfaceLanguageID: "en",
            overlayStyle: .default,
            subtitleMode: .balanced,
            subtitleDisplayMode: .both,
            glossary: ["CEO": "Chief Executive Officer"],
            releasedSpeechResourceIDs: ["speech:ja", "speech:en"]
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.selectedSourceID, "mic-1")
        XCTAssertEqual(decoded.selectedSourceIDs, ["mic-1", "app-1"])
        XCTAssertEqual(decoded.sourceLanguageOverrides, ["app-1": "fr"])
        XCTAssertEqual(
            decoded.sourceOutputLanguageOverrides,
            ["mic-1": "zh-Hans", "app-1": "de"]
        )
        XCTAssertEqual(decoded.inputLanguageID, "en")
        XCTAssertEqual(decoded.outputLanguageID, "ja")
        XCTAssertEqual(decoded.interfaceLanguageID, "en")
        XCTAssertEqual(decoded.glossary, ["CEO": "Chief Executive Officer"])
        XCTAssertEqual(decoded.releasedSpeechResourceIDs, ["speech:ja", "speech:en"])
    }
}
