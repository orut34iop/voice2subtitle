import AppKit
import Foundation
import XCTest
@testable import v2s

final class OverlayPreviewStateTests: XCTestCase {
    @MainActor
    func testOverlayKeepsConfiguredLevelAndUpdatesWhileVisible() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            sourceCatalogService: SourceCatalogService()
        )
        model.overlayStyle.attachToSource = false
        model.overlayStyle.alwaysOnTopInFullscreen = true
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = OverlayWindowController(model: model, showTranscript: {})
        let panels = NSApp.windows.compactMap { $0 as? NSPanel }
            .filter { !existingWindows.contains(ObjectIdentifier($0)) }
        defer {
            panels.forEach { $0.orderOut(nil) }
            model.flushSettings()
            withExtendedLifetime(controller) {}
        }
        XCTAssertEqual(panels.count, 7)
        XCTAssertTrue(panels.allSatisfy { $0.level.rawValue >= NSWindow.Level.screenSaver.rawValue })

        model.showOverlayPreview()
        await drainWindowUpdates()
        XCTAssertTrue(panels.allSatisfy(\.isVisible))
        model.overlayStyle.alwaysOnTopInFullscreen = false
        await drainWindowUpdates()
        XCTAssertEqual(Set(panels.map { $0.level.rawValue }),
                       [NSWindow.Level.statusBar.rawValue, NSWindow.Level.statusBar.rawValue + 1])
        model.overlayStyle.alwaysOnTopInFullscreen = true
        await drainWindowUpdates()
        XCTAssertEqual(Set(panels.map { $0.level.rawValue }),
                       [NSWindow.Level.screenSaver.rawValue, NSWindow.Level.screenSaver.rawValue + 1])
        model.isOverlayVisible = false
        await drainWindowUpdates()
    }

    @MainActor
    private func drainWindowUpdates() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testDraftTranslationIsOnlyReturnedForMatchingDraft() {
        let firstPromotionID = UUID()
        let secondPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.draftSourceText = "Change type is not at all."
        state.draftPromotionID = firstPromotionID
        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type is not at all.",
            promotionID: firstPromotionID
        )

        XCTAssertEqual(
            state.currentDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: firstPromotionID
            ),
            "Old translation"
        )
        XCTAssertNil(
            state.currentDraftTranslatedText(
                for: "Okay.",
                promotionID: secondPromotionID
            )
        )
    }

    func testMismatchedDraftTranslationIsCleared() {
        let firstPromotionID = UUID()
        let secondPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type is not at all.",
            promotionID: firstPromotionID
        )
        state.clearDraftTranslationIfMismatched(
            sourceText: "Okay.",
            promotionID: secondPromotionID
        )

        XCTAssertNil(state.draftTranslatedText)
        XCTAssertNil(state.draftTranslationSourceText)
        XCTAssertNil(state.draftTranslationPromotionID)
    }

    func testSamePromotionDraftTranslationStaysVisibleDuringSourceUpdate() {
        let promotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type",
            promotionID: promotionID
        )
        state.clearDraftTranslationIfMismatched(
            sourceText: "Change type is not at all.",
            promotionID: promotionID
        )

        XCTAssertEqual(
            state.visibleDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: promotionID
            ),
            "Old translation"
        )
        XCTAssertNil(
            state.currentDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: promotionID
            )
        )
    }

    func testNilPromotionDraftTranslationStillRequiresExactSourceMatch() {
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type",
            promotionID: nil
        )

        XCTAssertNil(
            state.visibleDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: nil
            )
        )
    }
}
