import XCTest
@testable import v2s

final class ModelResourceTests: XCTestCase {
    func testSpeechDescriptorsUseAllSpeechInputLanguages() {
        let descriptors = ModelResourceCatalog.speechDescriptors(
            options: LanguageCatalog.speechInput,
            localizedName: { $0 }
        )

        XCTAssertEqual(
            Set(descriptors.map(\.id)),
            Set(LanguageCatalog.speechInput.map { ModelResourceCatalog.speechResourceID(languageID: $0.id) })
        )
        XCTAssertTrue(descriptors.allSatisfy { $0.kind == .speech })
        XCTAssertTrue(descriptors.allSatisfy { $0.targetLanguageID == nil })
    }

    func testTranslationDescriptorsFilterUnsupportedLanguagesAndSameLanguagePairs() {
        let sources = [
            LanguageOption(id: "en", displayName: "English"),
            LanguageOption(id: "es", displayName: "Spanish"),
            LanguageOption(id: "yue", displayName: "Cantonese"),
        ]
        let targets = [
            LanguageOption(id: "en", displayName: "English"),
            LanguageOption(id: "fr", displayName: "French"),
            LanguageOption(id: "ru", displayName: "Russian"),
        ]

        let descriptors = ModelResourceCatalog.translationDescriptors(
            sourceOptions: sources,
            targetOptions: targets,
            supportedLanguageIDs: ["en", "es", "fr"],
            localizedName: { $0 }
        )

        XCTAssertEqual(
            Set(descriptors.map(\.id)),
            [
                "translation:en->fr",
                "translation:es->en",
                "translation:es->fr",
            ]
        )
        XCTAssertFalse(descriptors.contains { $0.id == "translation:en->en" })
        XCTAssertFalse(descriptors.contains { $0.id.contains("yue") })
        XCTAssertFalse(descriptors.contains { $0.id.contains("ru") })
    }

    func testModelResourceActionAvailabilityUsesRealCapabilities() {
        XCTAssertEqual(
            ModelResourceItem.availableActions(
                for: .speech,
                state: .downloading,
                isUserInitiatedDownload: true
            ),
            [.pause]
        )
        XCTAssertEqual(
            ModelResourceItem.availableActions(
                for: .speech,
                state: .downloading,
                isUserInitiatedDownload: false
            ),
            []
        )
        XCTAssertEqual(
            ModelResourceItem.availableActions(
                for: .translation,
                state: .downloadable,
                isUserInitiatedDownload: false
            ),
            [.download]
        )
        XCTAssertEqual(
            ModelResourceItem.availableActions(
                for: .translation,
                state: .error,
                isUserInitiatedDownload: false
            ),
            [.openSystemSettings]
        )
        XCTAssertEqual(
            ModelResourceItem.availableActions(
                for: .foundationModel,
                state: .systemManaged,
                isUserInitiatedDownload: false
            ),
            [.openSystemSettings]
        )
        XCTAssertEqual(
            ModelResourceItem.availableActions(
                for: .speech,
                state: .installed,
                isUserInitiatedDownload: false
            ),
            []
        )
    }
}
