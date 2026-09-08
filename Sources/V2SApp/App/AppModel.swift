import Combine
import Foundation
import AppKit
import Speech
import SwiftUI
import Translation
#if canImport(FoundationModels)
import FoundationModels
#endif

private enum AppBuildInfo {
    static let marketingVersion = "0.3.32"
    static let buildNumber = "202609081527"
    static let repositoryURLString = "https://github.com/franklioxygen/v2s"
    static let repositoryURL = URL(string: repositoryURLString)
}

@MainActor
final class AppModel: ObservableObject {
    static let translationModelResourcePollingIntervalNanoseconds: UInt64 = 2_000_000_000
    static let translationModelResourceMonitoringTimeout: TimeInterval = 30 * 60
    static let externalModelResourceRefreshIntervalNanoseconds: UInt64 = 2_000_000_000
    static let externalModelResourceRefreshDuration: TimeInterval = 5 * 60

    private let settingsStore: SettingsStore
    private let sourceCatalogService: SourceCatalogService
    let translationCoordinator = TranslationCoordinator()
    private let glossaryService = GlossaryService()
    let transcriptStore = TranscriptStore()
    private let sessionLifecycle = SessionLifecycle()
    private var sessionStartTask: Task<Void, Never>?
    private var sessionStopTask: Task<Void, Never>?
    private var captionPipelineID = UUID()
    private var liveTranscriptionSession: LiveTranscriptionSession?
    private var liveTranscriptionSessions: [LiveTranscriptionSession] = []
    private var captionDisplayTask: Task<Void, Never>?
    private var captionTranslationTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingCaptions: [QueuedCaption] = []
    private var readyCaptionTranslations: [UUID: String] = [:]
    private var captionTranslationWaiters: [UUID: [UUID: CheckedContinuation<String?, Never>]] = [:]
    private var displayedCaption: QueuedCaption?
    var isBootstrapping = true
    private var usesSystemInterfaceLanguage = true
    private var draftTranslationTasks: [String: Task<Void, Never>] = [:]
    private var sourceDrafts = SourceDraftStore()
    private var draftTranslationInputs: [String: String] = [:]
    private var draftClearTask: Task<Void, Never>?
    private var committedCaptionArchiveTask: Task<Void, Never>?
    let resourcePreparation = ResourcePreparationCoordinator()
    var modelResourceRefreshTask: Task<Void, Never>?
    var modelResourceDownloadTasks: [String: Task<Void, Never>] = [:]
    var modelResourceRemovalTasks: [String: Task<Void, Never>] = [:]
    var externalModelResourceRefreshTask: Task<Void, Never>?
    private var lifecycleCancellables = Set<AnyCancellable>()
    var releasedSpeechResourceIDs: Set<String> = []
    private var activeDraftSourceLanguageID: String?
    private var activeDraftTargetLanguageID: String?
    private var lastDraftSourceID: String?
    private var draftClearGeneration: Int = 0
    private var displayedCaptionLastVisualUpdateAt = Date.distantPast
    private var displayedCaptionLastVisualUpdateWasLateTranslation = false
    // Revision tracking: captionID → (committedTranslation, committedAt, revisionCount)
    private var translationRevisions: [UUID: (text: String, committedAt: Date, count: Int)] = [:]
    private var recentRecognizedCaptionTexts: [RecentRecognizedCaption] = []
    private var recentArchivedCaption: RecentArchivedCaption?
    private var finalizedDraftPromotionIDs: [(id: UUID, time: Date)] = []
    private var transcriptInputLanguageID: String?
    private var transcriptOutputLanguageID: String?
    private var statusDescriptor: StatusDescriptor = .ready
    @Published private(set) var applicationSources: [InputSource] = []
    @Published private(set) var microphoneSources: [InputSource] = []
    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var statusMessage = ""
    @Published private(set) var overlayState: OverlayPreviewState?
    @Published var languageResourceStatuses: [LanguageResourceStatus] = []
    @Published var modelResources: [ModelResourceItem] = []
    @Published private(set) var translationHostConfiguration: TranslationSession.Configuration?
    var transcriptEntries: [TranscriptEntry] { transcriptStore.entries }
    @Published private(set) var transcriptGeneration: Int = 0
    @Published var isOverlayVisible = false
    @Published private(set) var overlayHistoryVisibleCount = 0
    @Published private(set) var overlayHistoryScrollOffset = 0

    @Published var selectedSourceID: String? {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
        }
    }

    @Published var selectedSourceIDs: Set<String> {
        didSet {
            let primarySourceID = preferredPrimarySourceID(for: selectedSourceIDs)
            if selectedSourceID != primarySourceID {
                selectedSourceID = primarySourceID
            }
            persistSettings()
            syncOverlayPreviewIfNeeded()
        }
    }

    @Published var inputLanguageID: String {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
            scheduleSelectedLanguageResourcePreparation(openSystemSettingsIfNeeded: true)
        }
    }

    @Published var sourceLanguageOverrides: [String: String] {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
            if sessionState != .running {
                scheduleSelectedLanguageResourcePreparation(openSystemSettingsIfNeeded: true)
            }
        }
    }

    @Published var sourceOutputLanguageOverrides: [String: String] {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
            if sessionState != .running {
                scheduleSelectedLanguageResourcePreparation(openSystemSettingsIfNeeded: true)
            }
        }
    }

    @Published var outputLanguageID: String {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
            scheduleSelectedLanguageResourcePreparation(
                refreshTranslations: liveTranscriptionSession != nil,
                openSystemSettingsIfNeeded: true
            )
        }
    }

    @Published var interfaceLanguageID: String {
        didSet {
            guard oldValue != interfaceLanguageID else { return }
            usesSystemInterfaceLanguage = false
            persistSettings()
            AppLocalization.updateEmbeddedBundleLocalizationLanguageID(resolvedInterfaceLanguageID)
            relocalizeInterface(from: oldValue)
        }
    }

    @Published var overlayStyle: OverlayStyle {
        didSet {
            persistSettings()
        }
    }

    @Published var subtitleMode: SubtitleMode {
        didSet {
            persistSettings()
        }
    }

    @Published var subtitleDisplayMode: SubtitleDisplayMode {
        didSet {
            guard oldValue != subtitleDisplayMode else { return }
            persistSettings()
            handleSubtitleDisplayModeChange()
        }
    }

    @Published var glossary: [String: String] {
        didSet {
            persistSettings()
        }
    }

    init(
        settingsStore: SettingsStore,
        sourceCatalogService: SourceCatalogService
    ) {
        self.settingsStore = settingsStore
        self.sourceCatalogService = sourceCatalogService

        let settings = settingsStore.load()
        self.selectedSourceID = settings.selectedSourceID
        var initialSelectedSourceIDs = Set(settings.selectedSourceIDs)
        if initialSelectedSourceIDs.isEmpty, let selectedSourceID = settings.selectedSourceID {
            initialSelectedSourceIDs = [selectedSourceID]
        }
        self.selectedSourceIDs = initialSelectedSourceIDs
        self.sourceLanguageOverrides = settings.sourceLanguageOverrides.mapValues {
            LanguageCatalog.supportedSpeechInputLanguageID(for: $0)
        }
        self.sourceOutputLanguageOverrides = settings.sourceOutputLanguageOverrides
        self.inputLanguageID = LanguageCatalog.supportedSpeechInputLanguageID(for: settings.inputLanguageID)
        self.outputLanguageID = settings.outputLanguageID
        self.usesSystemInterfaceLanguage = settings.interfaceLanguageID == nil
        self.interfaceLanguageID = LanguageCatalog.preferredInterfaceLanguageID(
            storedIdentifier: settings.interfaceLanguageID
        )
        let normalizedOverlayStyle = AppModel.normalizedOverlayStyle(settings.overlayStyle)
        self.overlayStyle = normalizedOverlayStyle
        self.subtitleMode = settings.subtitleMode
        self.subtitleDisplayMode = settings.subtitleDisplayMode
        self.glossary = settings.glossary
        self.releasedSpeechResourceIDs = Set(settings.releasedSpeechResourceIDs)
        self.translationHostConfiguration = nil
        AppLocalization.updateEmbeddedBundleLocalizationLanguageID(self.interfaceLanguageID)

        translationCoordinator.onConfigurationChange = { [weak self] configuration in
            self?.translationHostConfiguration = configuration
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshModelResourcesAfterExternalChange()
                }
            }
            .store(in: &lifecycleCancellables)

        isBootstrapping = false
        applyStatusMessage()
        if normalizedOverlayStyle != settings.overlayStyle {
            persistSettings()
        }
        refreshSources()
    }

    deinit {
        modelResourceRefreshTask?.cancel()
        modelResourceDownloadTasks.values.forEach { $0.cancel() }
        modelResourceRemovalTasks.values.forEach { $0.cancel() }
        externalModelResourceRefreshTask?.cancel()
    }

    convenience init() {
        self.init(
            settingsStore: SettingsStore(),
            sourceCatalogService: SourceCatalogService()
        )
    }

    var allSources: [InputSource] {
        applicationSources + microphoneSources
    }

    var selectedSource: InputSource? {
        allSources.first(where: { $0.id == selectedSourceID })
    }

    var selectedSources: [InputSource] {
        let selectedSourceIDs = self.selectedSourceIDs
        guard selectedSourceIDs.isEmpty == false else {
            return selectedSource.map { [$0] } ?? []
        }

        return allSources.filter { selectedSourceIDs.contains($0.id) }
    }

    var selectedSourceDisplayName: String {
        sourceDisplayName(for: selectedSources)
    }

    private func sourceDisplayName(for sources: [InputSource]) -> String {
        let names = sources.map(\.name)
        switch names.count {
        case 0:
            return localized(.selectedSource)
        case 1:
            return names[0]
        default:
            if sources.count == allSources.count, allSources.isEmpty == false {
                return localized(.allSources)
            }
            return AppLocalization.multipleSourcesText(
                count: names.count,
                languageID: resolvedInterfaceLanguageID
            )
        }
    }

    func languageID(for source: InputSource) -> String {
        sourceLanguageOverrides[source.id] ?? inputLanguageID
    }

    func languageOverrideID(for source: InputSource) -> String? {
        sourceLanguageOverrides[source.id]
    }

    func setLanguageID(_ languageID: String, for source: InputSource) {
        var overrides = sourceLanguageOverrides
        let normalizedLanguageID = LanguageCatalog.supportedSpeechInputLanguageID(for: languageID)
        if normalizedLanguageID == inputLanguageID {
            overrides.removeValue(forKey: source.id)
        } else {
            overrides[source.id] = normalizedLanguageID
        }
        sourceLanguageOverrides = overrides
    }

    func setLanguageOverrideID(_ languageID: String?, for source: InputSource) {
        guard let languageID else {
            var overrides = sourceLanguageOverrides
            overrides.removeValue(forKey: source.id)
            sourceLanguageOverrides = overrides
            return
        }

        setLanguageID(languageID, for: source)
    }

    func outputLanguageIDForSource(_ source: InputSource) -> String {
        sourceOutputLanguageOverrides[source.id] ?? outputLanguageID
    }

    func outputLanguageOverrideID(for source: InputSource) -> String? {
        sourceOutputLanguageOverrides[source.id]
    }

    func setOutputLanguageID(_ languageID: String, for source: InputSource) {
        var overrides = sourceOutputLanguageOverrides
        if languageID == outputLanguageID {
            overrides.removeValue(forKey: source.id)
        } else {
            overrides[source.id] = languageID
        }
        sourceOutputLanguageOverrides = overrides
    }

    func setOutputLanguageOverrideID(_ languageID: String?, for source: InputSource) {
        guard let languageID else {
            var overrides = sourceOutputLanguageOverrides
            overrides.removeValue(forKey: source.id)
            sourceOutputLanguageOverrides = overrides
            return
        }

        setOutputLanguageID(languageID, for: source)
    }

    var sessionButtonTitle: String {
        if sessionState == .running || sessionState == .starting {
            return localized(.stop)
        }

        if isPreparingSelectedLanguageResources {
            return localized(.wait)
        }

        if hasBlockingLanguageResourceStatuses {
            return localized(.pleaseDownloadLanguageResource)
        }

        return localized(.start)
    }

    var sessionButtonSymbolName: String {
        sessionState == .running ? "stop.fill" : "play.fill"
    }

    var showsSessionWaitIndicator: Bool {
        sessionState != .running && isPreparingSelectedLanguageResources
    }

    var isSessionButtonDisabled: Bool {
        if sessionState == .running || sessionState == .starting {
            return false
        }

        return sessionStopTask != nil || sessionState == .stopping || selectedSources.isEmpty
            || isPreparingSelectedLanguageResources
            || hasBlockingLanguageResourceStatuses
    }

    var sessionBadgeText: String {
        sessionState.displayName(in: resolvedInterfaceLanguageID)
    }

    var isLanguagePairLocked: Bool {
        sessionState == .running || sessionState == .starting || sessionState == .stopping
    }

    var resolvedInterfaceLanguageID: String {
        LanguageCatalog.preferredInterfaceLanguageID(storedIdentifier: interfaceLanguageID)
    }

    var interfaceLocale: Locale {
        AppLocalization.locale(for: resolvedInterfaceLanguageID)
    }

    var appVersionDisplayText: String {
        "v\(AppBuildInfo.marketingVersion)"
    }

    var appRepositoryURL: URL? {
        AppBuildInfo.repositoryURL
    }

    var showsOriginalSubtitle: Bool {
        subtitleDisplayMode.showsOriginalSubtitle
    }

    var showsTranslatedSubtitle: Bool {
        subtitleDisplayMode.showsTranslatedSubtitle
    }

    func localized(_ key: AppTextKey, _ arguments: CVarArg...) -> String {
        AppLocalization.formattedString(key, languageID: resolvedInterfaceLanguageID, arguments: arguments)
    }

    private var listeningPlaceholderText: String {
        localized(.listening)
    }

    private var captureStoppedText: String {
        localized(.captureStopped)
    }

    private var unableToStartText: String {
        localized(.unableToStart)
    }

    private var previewInputSource: InputSource {
        InputSource(
            id: InputSource.preview.id,
            name: localized(.previewSource),
            detail: InputSource.preview.detail,
            category: InputSource.preview.category
        )
    }

    func localizedErrorDescription(_ error: Error) -> String {
        AppLocalization.localizedErrorDescription(error, languageID: resolvedInterfaceLanguageID)
    }

    private func setStatus(_ descriptor: StatusDescriptor) {
        guard statusDescriptor != descriptor else {
            return
        }

        statusDescriptor = descriptor
        applyStatusMessage()
    }

    private func applyStatusMessage() {
        let message: String

        switch statusDescriptor {
        case .ready:
            message = localized(.ready)
        case .noInputSourcesDetected:
            message = localized(.noSourcesDetected) + "."
        case .running(let sourceName):
            message = localized(.runningOnFormat, sourceName)
        case .chooseInputSourceBeforeStarting:
            message = localized(.chooseInputSourceBeforeStarting)
        case .checkingLanguageResources:
            message = localized(.checkingLanguageResources)
        case .downloadLanguageResourcesInSystemSettings:
            message = localized(.downloadRequiredLanguageResourcesSystemSettings)
        case .preparing(let sourceName):
            message = localized(.preparingSourceFormat, sourceName)
        case .showingOverlayPreview:
            message = localized(.showingOverlayPreview)
        case .custom(let customMessage):
            message = customMessage
        }

        guard statusMessage != message else {
            return
        }

        statusMessage = message
    }

    private func relocalizeInterface(from oldLanguageID: String) {
        applyStatusMessage()
        relocalizeOverlaySentinelTexts(from: oldLanguageID)

        if liveTranscriptionSession == nil,
           sessionState != .error,
           isOverlayVisible {
            syncOverlayPreviewIfNeeded()
        }

        if !resourcePreparation.isRunning, languageResourceStatuses.isEmpty == false {
            scheduleSelectedLanguageResourcePreparation(openSystemSettingsIfNeeded: false)
        }
    }

    private func relocalizeOverlaySentinelTexts(from oldLanguageID: String) {
        guard var overlayState else { return }

        let oldListening = AppLocalization.string(.listening, languageID: oldLanguageID)
        let oldCaptureStopped = AppLocalization.string(.captureStopped, languageID: oldLanguageID)
        let oldUnableToStart = AppLocalization.string(.unableToStart, languageID: oldLanguageID)

        if overlayState.translatedText == oldListening {
            overlayState.translatedText = listeningPlaceholderText
        } else if overlayState.translatedText == oldCaptureStopped {
            overlayState.translatedText = captureStoppedText
        } else if overlayState.translatedText == oldUnableToStart {
            overlayState.translatedText = unableToStartText
        }

        self.overlayState = overlayState
    }

    func refreshSources() {
        let snapshot = sourceCatalogService.loadSnapshot()
        if applicationSources != snapshot.applications {
            applicationSources = snapshot.applications
        }
        if microphoneSources != snapshot.microphones {
            microphoneSources = snapshot.microphones
        }

        let availableSources = snapshot.applications + snapshot.microphones
        let availableSourceIDs = Set(availableSources.map(\.id))
        let retainedSelectedSourceIDs = selectedSourceIDs.intersection(availableSourceIDs)

        if retainedSelectedSourceIDs != selectedSourceIDs {
            selectedSourceIDs = retainedSelectedSourceIDs
        }

        if selectedSourceIDs.isEmpty, let defaultSourceID = preferredDefaultSourceID(in: snapshot) {
            selectedSourceIDs = [defaultSourceID]
        }

        let primarySourceID = preferredPrimarySourceID(for: selectedSourceIDs)
        if selectedSourceID != primarySourceID {
            selectedSourceID = primarySourceID
        }

        if sessionState == .running {
            setStatus(.running(sourceName: selectedSourceDisplayName))
        } else {
            setStatus(availableSources.isEmpty ? .noInputSourcesDetected : .ready)
        }
    }

    func toggleSession() {
        if sessionState == .running || sessionState == .starting {
            stopSession()
        } else if sessionState != .stopping, sessionStartTask == nil {
            sessionStartTask = Task { [weak self] in
                await self?.startSession()
            }
        }
    }

    func startSession() async {
        guard sessionStopTask == nil, sessionState != .stopping, let sessionID = sessionLifecycle.begin() else { return }
        sessionState = .starting
        defer {
            if sessionLifecycle.accepts(sessionID) {
                sessionStartTask = nil
                if sessionState == .starting { sessionState = .idle }
                if sessionState != .running { _ = sessionLifecycle.invalidate() }
            }
        }
        refreshSources()

        let selectedSources = self.selectedSources
        guard selectedSources.isEmpty == false else {
            sessionState = .error
            setStatus(.chooseInputSourceBeforeStarting)
            return
        }
        let selectedSourceName = selectedSourceDisplayName

        resetLiveTextPipeline()
        setStatus(.checkingLanguageResources)
        await awaitSelectedLanguageResourcePreparationIfNeeded()
        guard !Task.isCancelled, sessionLifecycle.accepts(sessionID) else { return }
        guard hasBlockingLanguageResourceStatuses == false else {
            setStatus(.downloadLanguageResourcesInSystemSettings)
            return
        }

        let previousTranscriptEntries = transcriptEntries
        let previousTranscriptInputLanguageID = transcriptInputLanguageID
        let previousTranscriptOutputLanguageID = transcriptOutputLanguageID
        let selectedInputLanguageIDs = Set(selectedSources.map { languageID(for: $0) })
        let selectedOutputLanguageIDs = Set(selectedSources.map { outputLanguageIDForSource($0) })
        resetTranscript(
            sourceLanguageID: selectedInputLanguageIDs.count == 1 ? selectedInputLanguageIDs.first! : inputLanguageID,
            targetLanguageID: selectedOutputLanguageIDs.count == 1 ? selectedOutputLanguageIDs.first! : outputLanguageID
        )

        isOverlayVisible = true
        overlayState = OverlayPreviewState(
            translatedText: listeningPlaceholderText,
            sourceText: localized(.waitingForAudioFromFormat, selectedSourceName),
            sourceName: selectedSourceName
        )
        overlayHistoryScrollOffset = 0
        setStatus(.preparing(sourceName: selectedSourceName))

        let config = ModeConfig.config(for: subtitleMode)
        let recognitionHints = recognitionContextualStrings()
        var startedSessions: [LiveTranscriptionSession] = []
        var startedSources: [InputSource] = []
        var startErrors: [(source: InputSource, message: String)] = []
        var attemptedMicrophoneFallback = false

        func startSource(_ source: InputSource) async {
            let sourceLanguageID = languageID(for: source)
            let targetLanguageID = outputLanguageIDForSource(source)
            guard !Task.isCancelled, sessionLifecycle.accepts(sessionID) else { return }
            let session = LiveTranscriptionSession()
            guard sessionLifecycle.register(id: sessionID, stop: { await session.stopAndWait() }) else { return }

            do {
                try await session.start(
                    source: source,
                    localeIdentifier: LanguageCatalog.speechLocaleIdentifier(for: sourceLanguageID),
                    interfaceLanguageID: resolvedInterfaceLanguageID,
                    modeConfig: config,
                    contextualStrings: recognitionHints,
                    transcriptHandler: { [weak self] sentence in
                        guard let self, self.sessionLifecycle.accepts(sessionID) else { return }
                        self.enqueueRecognizedSentence(
                            sentence,
                            source: source,
                            sourceLanguageID: sourceLanguageID,
                            targetLanguageID: targetLanguageID
                        )
                    },
                    partialHandler: { [weak self] draft in
                        guard let self, self.sessionLifecycle.accepts(sessionID) else { return }
                        self.handlePartialDraft(
                            draft,
                            source: source,
                            sourceLanguageID: sourceLanguageID,
                            targetLanguageID: targetLanguageID
                        )
                    },
                    errorHandler: { [weak self] message in
                        guard let self, self.sessionLifecycle.accepts(sessionID) else { return }
                        self.stopSession()
                        self.sessionState = .error
                        self.setStatus(.custom(message))
                        self.overlayState = OverlayPreviewState(
                            translatedText: self.captureStoppedText,
                            sourceText: message,
                            sourceName: source.name
                        )
                    }
                )
                guard !Task.isCancelled, sessionLifecycle.accepts(sessionID) else {
                    await session.stopAndWait()
                    return
                }
                startedSessions.append(session)
                startedSources.append(source)
                liveTranscriptionSessions = startedSessions
                liveTranscriptionSession = startedSessions.first
                processCaptionQueueIfNeeded()
            } catch {
                await session.stopAndWait()
                startErrors.append((source: source, message: localizedErrorDescription(error)))
            }
        }

        for source in selectedSources {
            await startSource(source)
        }

        guard !Task.isCancelled, sessionLifecycle.accepts(sessionID) else { return }
        if startedSessions.isEmpty,
           selectedSources.allSatisfy({ $0.category == .application }),
           let fallbackSource = microphoneSources.first {
            attemptedMicrophoneFallback = true
            await startSource(fallbackSource)
        }

        guard !Task.isCancelled, sessionLifecycle.accepts(sessionID) else { return }
        guard startedSessions.isEmpty == false else {
            for session in startedSessions {
                session.stop()
            }
            resetLiveTextPipeline()
            liveTranscriptionSession = nil
            liveTranscriptionSessions.removeAll()
            restoreTranscript(
                entries: previousTranscriptEntries,
                sourceLanguageID: previousTranscriptInputLanguageID,
                targetLanguageID: previousTranscriptOutputLanguageID
            )
            sessionState = .error
            let localizedError = (
                attemptedMicrophoneFallback ? startErrors.last?.message : startErrors.first?.message
            ) ?? unableToStartText
            setStatus(.custom(localizedError))
            overlayState = OverlayPreviewState(
                translatedText: unableToStartText,
                sourceText: localizedError,
                sourceName: selectedSourceName
            )
            overlayHistoryScrollOffset = 0
            return
        }

        liveTranscriptionSessions = startedSessions
        liveTranscriptionSession = startedSessions.first

        let startedSourceName = sourceDisplayName(for: startedSources)
        sessionState = .running
        setStatus(.running(sourceName: startedSourceName))

        if startedSourceName != selectedSourceName {
            overlayState = OverlayPreviewState(
                translatedText: listeningPlaceholderText,
                sourceText: localized(.waitingForAudioFromFormat, startedSourceName),
                sourceName: startedSourceName
            )
        }
    }

    func stopSession() {
        let operations = sessionLifecycle.invalidate()
        sessionStartTask?.cancel()
        let startTask = sessionStartTask
        sessionStartTask = nil
        resourcePreparation.cancel()
        languageResourceStatuses.removeAll { !$0.isError }
        resetLiveTextPipeline()
        liveTranscriptionSessions.removeAll()
        liveTranscriptionSession = nil
        isOverlayVisible = false
        overlayState = nil
        guard sessionStopTask == nil else { return }
        sessionState = .stopping
        sessionStopTask = Task { [weak self] in
            for operation in operations { await operation() }
            // The cancelled starter cannot publish state; don't block UI on a system permission prompt.
            _ = startTask
            guard let self else { return }
            self.sessionStopTask = nil
            if self.sessionState == .stopping {
                self.sessionState = .idle
                self.setStatus(self.allSources.isEmpty ? .noInputSourcesDetected : .ready)
            }
        }
    }

    func showOverlayPreview() {
        let source = selectedSource ?? previewInputSource
        overlayState = makePreviewState(for: source)
        overlayHistoryScrollOffset = 0
        isOverlayVisible = true

        if sessionState != .running {
            setStatus(.showingOverlayPreview)
        }
    }

    func toggleOverlayVisibility() {
        if isOverlayVisible {
            isOverlayVisible = false
            if sessionState != .running {
                overlayState = nil
            }
        } else {
            showOverlayPreview()
        }
    }

    func updateOverlayStyle(_ update: (inout OverlayStyle) -> Void) {
        var style = overlayStyle
        update(&style)
        overlayStyle = AppModel.normalizedOverlayStyle(style)
    }

    func updateOverlayHistoryVisibleCount(_ count: Int) {
        let clampedCount = max(0, count)
        guard overlayHistoryVisibleCount != clampedCount else { return }
        overlayHistoryVisibleCount = clampedCount
        clampOverlayHistoryScrollOffset()
    }

    func scrollOverlayHistory(by delta: Int) {
        guard delta != 0 else { return }
        setOverlayHistoryScrollOffset(overlayHistoryScrollOffset + delta)
    }

    func setOverlayHistoryScrollOffset(_ offset: Int) {
        let clampedOffset = min(max(offset, 0), overlayHistoryMaxScrollOffset)
        guard overlayHistoryScrollOffset != clampedOffset else { return }
        overlayHistoryScrollOffset = clampedOffset
    }

    func flushSettings() { settingsStore.flush() }

    func persistSettings() {
        guard isBootstrapping == false else {
            return
        }

        let settings = AppSettings(
            selectedSourceID: selectedSourceID,
            selectedSourceIDs: orderedSelectedSourceIDs(),
            sourceLanguageOverrides: sourceLanguageOverrides,
            sourceOutputLanguageOverrides: sourceOutputLanguageOverrides,
            inputLanguageID: inputLanguageID,
            outputLanguageID: outputLanguageID,
            interfaceLanguageID: usesSystemInterfaceLanguage ? nil : interfaceLanguageID,
            overlayStyle: overlayStyle,
            subtitleMode: subtitleMode,
            subtitleDisplayMode: subtitleDisplayMode,
            glossary: glossary,
            releasedSpeechResourceIDs: releasedSpeechResourceIDs.sorted()
        )

        settingsStore.save(settings)
    }

    private static func normalizedOverlayStyle(_ style: OverlayStyle) -> OverlayStyle {
        var normalized = style
        normalized.translatedFirst = true
        normalized.fontOpacity = min(max(normalized.fontOpacity, 0.0), 1.0)
        return normalized
    }

    private func recognitionContextualStrings() -> [String] {
        glossary.keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                }
                return lhs.count < rhs.count
            }
    }

    func languageName(for identifier: String) -> String {
        LanguageCatalog.displayName(for: identifier, in: resolvedInterfaceLanguageID)
    }

    private func preferredPrimarySourceID(for selectedSourceIDs: Set<String>) -> String? {
        if let selectedSourceID, selectedSourceIDs.contains(selectedSourceID) {
            return selectedSourceID
        }

        return allSources.first(where: { selectedSourceIDs.contains($0.id) })?.id
    }

    private func orderedSelectedSourceIDs() -> [String] {
        let orderedSourceIDs = allSources.map(\.id).filter { selectedSourceIDs.contains($0) }
        let remainingSourceIDs = selectedSourceIDs.subtracting(Set(orderedSourceIDs)).sorted()
        return orderedSourceIDs + remainingSourceIDs
    }

    private func preferredDefaultSourceID(in snapshot: SourceCatalogSnapshot) -> String? {
        snapshot.microphones.first?.id ?? snapshot.applications.first?.id
    }

    func selectedResourcePreparationRequirements() -> (
        speechLanguageIDs: [String],
        translationPairs: [LanguagePairRequirement]
    ) {
        let selectedSources = self.selectedSources
        guard selectedSources.isEmpty == false else {
            let translationPairs = showsTranslatedSubtitle && inputLanguageID != outputLanguageID
                ? [LanguagePairRequirement(sourceLanguageID: inputLanguageID, targetLanguageID: outputLanguageID)]
                : []
            return ([inputLanguageID], translationPairs)
        }

        let speechLanguageIDs = Set(selectedSources.map { languageID(for: $0) }).sorted()
        let translationPairs = showsTranslatedSubtitle
            ? Set(
                selectedSources.compactMap { source -> LanguagePairRequirement? in
                    let sourceLanguageID = languageID(for: source)
                    let targetLanguageID = outputLanguageIDForSource(source)
                    guard sourceLanguageID != targetLanguageID else {
                        return nil
                    }
                    return LanguagePairRequirement(
                        sourceLanguageID: sourceLanguageID,
                        targetLanguageID: targetLanguageID
                    )
                }
            )
            .sorted {
                if $0.sourceLanguageID == $1.sourceLanguageID {
                    return $0.targetLanguageID < $1.targetLanguageID
                }
                return $0.sourceLanguageID < $1.sourceLanguageID
            }
            : []

        return (speechLanguageIDs, translationPairs)
    }

    @available(macOS 15.0, *)
    func runTranslationHost(using session: TranslationSession) async {
        await translationCoordinator.run(using: session)
    }

    private func handlePartialDraft(
        _ draft: DraftSegment?, source: InputSource,
        sourceLanguageID: String, targetLanguageID: String
    ) {
        guard sessionLifecycle.currentID != nil else { return }
        if let draft, isFinalizedDraftPromotionID(draft.segmentId) { return }
        guard var draft, !sanitizedDisplayText(draft.sourceText).isEmpty else {
            sourceDrafts.remove(sourceID: source.id)
            draftTranslationTasks.removeValue(forKey: source.id)?.cancel()
            if let visible = sourceDrafts.visible {
                renderDraft(visible)
            } else if lastDraftSourceID == source.id, !isDraftPromotionPending() {
                scheduleDraftClear()
            }
            return
        }
        draft.sourceText = sanitizedDisplayText(draft.sourceText)
        sourceDrafts.update(draft, source: source, from: sourceLanguageID, to: targetLanguageID)
        if let visible = sourceDrafts.visible { renderDraft(visible) }
        if shouldReserveDraftTranslationSlot(sourceLanguageID: sourceLanguageID, targetLanguageID: targetLanguageID) {
            scheduleDraftTranslation(
                for: draft.sourceText, promotionID: draft.segmentId,
                sourceLanguageID: sourceLanguageID, targetLanguageID: targetLanguageID,
                sourceID: source.id
            )
        } else {
            draftTranslationTasks.removeValue(forKey: source.id)?.cancel()
            sourceDrafts.setTranslation(draft.sourceText, sourceID: source.id,
                                       promotionID: draft.segmentId, sourceText: draft.sourceText)
            if let visible = sourceDrafts.visible { renderDraft(visible) }
        }
    }

    private func renderDraft(_ snapshot: SourceDraftStore.Snapshot) {
        cancelCommittedCaptionArchive()
        cancelPendingDraftClear()
        let draft = snapshot.draft
        activeDraftSourceLanguageID = snapshot.sourceLanguageID
        activeDraftTargetLanguageID = snapshot.targetLanguageID
        lastDraftSourceID = snapshot.source.id
        overlayState?.draftSourceText = draft.sourceText
        overlayState?.draftStablePrefixLength = min(draft.stablePrefixLength, draft.sourceText.count)
        overlayState?.draftPromotionID = draft.segmentId
        overlayState?.sourceName = snapshot.source.name
        overlayState?.setDraftTranslation(snapshot.translatedText,
            sourceText: snapshot.translatedSourceText ?? draft.sourceText, promotionID: draft.segmentId)
        dismissListeningPlaceholderIfNeeded()
    }

    private func finishSourceDraft(sourceID: String, promotionID: UUID) {
        let isCurrent = sourceDrafts.snapshots[sourceID]?.draft.segmentId == promotionID
        sourceDrafts.remove(sourceID: sourceID, promotionID: promotionID)
        if isCurrent { draftTranslationTasks.removeValue(forKey: sourceID)?.cancel() }
        if let visible = sourceDrafts.visible {
            renderDraft(visible)
        } else if overlayState?.draftPromotionID == promotionID {
            clearDraftOverlay()
        }
    }

    private func scheduleDraftClear() {
        draftClearTask?.cancel()
        draftClearGeneration &+= 1
        let generation = draftClearGeneration

        draftClearTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: Self.draftClearDelayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  liveTranscriptionSession != nil,
                  generation == draftClearGeneration else { return }

            clearDraftOverlay()
            scheduleCommittedCaptionArchiveIfNeeded()
        }
    }

    private func cancelPendingDraftClear() {
        draftClearTask?.cancel()
        draftClearTask = nil
        draftClearGeneration &+= 1
    }

    private func clearDraftOverlay() {
        draftClearTask?.cancel()
        draftClearTask = nil
        overlayState?.draftSourceText = nil
        overlayState?.draftStablePrefixLength = 0
        overlayState?.draftPromotionID = nil
        overlayState?.clearDraftTranslation()
        activeDraftSourceLanguageID = nil
        activeDraftTargetLanguageID = nil
        lastDraftSourceID = nil
    }

    private func scheduleDraftTranslation(
        for text: String, promotionID: UUID?,
        sourceLanguageID: String, targetLanguageID: String,
        sourceID: String? = nil
    ) {
        guard let sourceID = sourceID ?? lastDraftSourceID, let promotionID else { return }
        if let snapshot = sourceDrafts.snapshots[sourceID], snapshot.translatedSourceText == text { return }
        let inputKey = promotionID.uuidString + ":" + text
        if draftTranslationTasks[sourceID] != nil, draftTranslationInputs[sourceID] == inputKey { return }
        draftTranslationInputs[sourceID] = inputKey
        draftTranslationTasks.removeValue(forKey: sourceID)?.cancel()
        let pipelineID = captionPipelineID
        draftTranslationTasks[sourceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return }
            guard !Task.isCancelled, captionPipelineID == pipelineID else { return }
            let translated = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    try? await self.translationCoordinator.translate(text, from: sourceLanguageID, to: targetLanguageID)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }
            guard !Task.isCancelled, captionPipelineID == pipelineID else { return }
            draftTranslationTasks[sourceID] = nil
            guard let translated else { return }
            let resolved = glossaryService.apply(to: translated, glossary: glossary)
            guard !shouldTreatAsMissingTranslation(resolved, sourceText: text,
                sourceLanguageID: sourceLanguageID, targetLanguageID: targetLanguageID) else { return }
            if sourceDrafts.setTranslation(resolved, sourceID: sourceID, promotionID: promotionID, sourceText: text),
               sourceDrafts.visible?.source.id == sourceID, let visible = sourceDrafts.visible {
                renderDraft(visible)
            }
        }
    }

    // MARK: - Overlay history

    /// Archives the current committed caption, then clears the live overlay text.
    private func clearOverlayText() {
        if let currentCaption = currentCommittedCaptionHistoryPayload() {
            rememberArchivedCaption(
                sourceText: currentCaption.sourceText,
                promotionID: displayedCaption?.promotionID
            )
            appendOverlayHistoryEntry(
                captionID: displayedCaption?.id,
                translatedText: currentCaption.translatedText,
                sourceText: currentCaption.sourceText
            )
        }
        cancelCommittedCaptionArchive()
        clearDraftOverlay()
        overlayState?.translatedText = ""
        overlayState?.sourceText = ""
        overlayState?.committedPromotionID = nil
        displayedCaption = nil
        displayedCaptionLastVisualUpdateAt = Date.distantPast
        displayedCaptionLastVisualUpdateWasLateTranslation = false
    }

    /// Archives the currently committed caption into the scrollback history before
    /// the next sentence replaces it.
    private func capturePreviousCaption() {
        guard let currentCaption = currentCommittedCaptionHistoryPayload() else { return }
        rememberArchivedCaption(
            sourceText: currentCaption.sourceText,
            promotionID: displayedCaption?.promotionID
        )
        appendOverlayHistoryEntry(
            captionID: displayedCaption?.id,
            translatedText: currentCaption.translatedText,
            sourceText: currentCaption.sourceText
        )
    }

    private func updateCommittedOverlay(
        translatedText: String,
        sourceText: String,
        promotionID: UUID? = nil,
        bumpEpoch: Bool = false,
        lateTranslation: Bool = false
    ) {
        if bumpEpoch {
            overlayState?.captionEpoch = (overlayState?.captionEpoch ?? 0) + 1
        }

        overlayState?.translatedText = translatedText
        overlayState?.sourceText = sourceText
        if let promotionID {
            overlayState?.committedPromotionID = promotionID
        }
        displayedCaptionLastVisualUpdateAt = Date()
        displayedCaptionLastVisualUpdateWasLateTranslation = lateTranslation
    }

    // MARK: - Settings sync

    private func syncOverlayPreviewIfNeeded() {
        guard liveTranscriptionSession == nil else {
            return
        }

        guard isOverlayVisible || sessionState == .running else {
            return
        }

        let source = selectedSource ?? previewInputSource
        overlayState = makePreviewState(for: source)
        overlayHistoryScrollOffset = 0
    }

    private func handleSubtitleDisplayModeChange() {
        guard liveTranscriptionSession != nil else {
            return
        }

        if showsTranslatedSubtitle {
            let draftText = sanitizedDisplayText(overlayState?.draftSourceText ?? "")
            guard draftText.isEmpty == false else {
                scheduleCommittedCaptionArchiveIfNeeded()
                return
            }

            if let activeDraftSourceLanguageID,
               let activeDraftTargetLanguageID,
               shouldReserveDraftTranslationSlot(
                   sourceLanguageID: activeDraftSourceLanguageID,
                   targetLanguageID: activeDraftTargetLanguageID
               ) {
                scheduleDraftTranslation(
                    for: draftText,
                    promotionID: overlayState?.draftPromotionID,
                    sourceLanguageID: activeDraftSourceLanguageID,
                    targetLanguageID: activeDraftTargetLanguageID
                )
            } else {
                draftTranslationTasks.values.forEach { $0.cancel() }
                draftTranslationTasks.removeAll()
                overlayState?.setDraftTranslation(
                    draftText,
                    sourceText: draftText,
                    promotionID: overlayState?.draftPromotionID
                )
            }
        } else {
            draftTranslationTasks.values.forEach { $0.cancel() }
            draftTranslationTasks.removeAll()
            overlayState?.clearDraftTranslation()
        }

        scheduleCommittedCaptionArchiveIfNeeded()
    }

    private func makePreviewState(for source: InputSource) -> OverlayPreviewState {
        let sourceLanguageID = languageID(for: source)
        let targetLanguageID = outputLanguageIDForSource(source)
        let sourceText = sampleText(for: sourceLanguageID)
        let translatedText: String

        if sourceLanguageID == targetLanguageID {
            translatedText = sourceText
        } else {
            translatedText = sampleText(for: targetLanguageID)
        }

        return OverlayPreviewState(
            translatedText: translatedText,
            sourceText: sourceText,
            sourceName: source.name
        )
    }

    // MARK: - Caption queue

    private func enqueueRecognizedSentence(
        _ sentence: RecognizedSentence,
        source: InputSource,
        sourceLanguageID: String,
        targetLanguageID: String
    ) {
        guard sessionLifecycle.currentID != nil else { return }
        let sourceText = sanitizedDisplayText(sentence.text)
        guard sourceText.isEmpty == false else {
            return
        }

        if let promotionID = sentence.promotionSegmentID {
            guard isFinalizedDraftPromotionID(promotionID) == false else {
                return
            }

            let promotedDraftTranslation = promotedDraftTranslationSnapshot(for: sentence.promotionSegmentID)
            markDraftPromotionFinalized(promotionID)
            cancelCommittedCaptionArchive()

            guard shouldEnqueueRecognizedSentence(sourceText, sourceID: source.id, promotionID: promotionID) else {
                return
            }

            let caption = QueuedCaption(
                id: UUID(),
                promotionID: promotionID,
                sourceText: sourceText,
                sourceName: source.name,
                sourceID: source.id,
                sourceLanguageID: sourceLanguageID,
                targetLanguageID: targetLanguageID,
                promotedDraftTranslation: promotedDraftTranslation
            )

            rememberRecognizedSentence(sourceText, sourceID: source.id)
            transcriptStore.upsert(TranscriptEntry(
                id: caption.id, sourceText: sourceText,
                translatedText: sourceLanguageID == targetLanguageID ? sourceText : "",
                sourceID: source.id, sourceName: source.name,
                sourceLanguageID: sourceLanguageID, targetLanguageID: targetLanguageID
            ))
            pendingCaptions.append(caption)
            translateCaption(caption)
        } else {
            cancelCommittedCaptionArchive()

            guard shouldEnqueueRecognizedSentence(sourceText, sourceID: source.id) else {
                return
            }

            let caption = QueuedCaption(
                id: UUID(),
                promotionID: UUID(),
                sourceText: sourceText,
                sourceName: source.name,
                sourceID: source.id,
                sourceLanguageID: sourceLanguageID,
                targetLanguageID: targetLanguageID,
                promotedDraftTranslation: nil
            )

            rememberRecognizedSentence(sourceText, sourceID: source.id)
            transcriptStore.upsert(TranscriptEntry(
                id: caption.id, sourceText: sourceText,
                translatedText: sourceLanguageID == targetLanguageID ? sourceText : "",
                sourceID: source.id, sourceName: source.name,
                sourceLanguageID: sourceLanguageID, targetLanguageID: targetLanguageID
            ))
            pendingCaptions.append(caption)
            translateCaption(caption)
        }

        // Keep the currently displayed caption plus up to two fresh arrivals.
        // This avoids losing the first sentence when a single ASR result is split
        // into two back-to-back captions.
        while pendingCaptions.count > 3 {
            let dropped = pendingCaptions.remove(at: 1)
            // Only the live display skips this entry. Its record and translation continue.
            updateReadyCaptionTranslation(nil, for: dropped.id)
        }

        processCaptionQueueIfNeeded()

        setStatus(.running(sourceName: selectedSourceDisplayName))
    }

    func refreshCaptionTranslations() {
        guard liveTranscriptionSession != nil else {
            return
        }

        cancelCaptionTranslations()
        readyCaptionTranslations.removeAll()

        for caption in pendingCaptions {
            translateCaption(caption)
        }

        if let displayedCaption {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                let translatedText = await translatedText(for: displayedCaption)
                guard liveTranscriptionSession != nil,
                      self.displayedCaption?.id == displayedCaption.id else {
                    return
                }

                let translationExpected = displayedCaption.sourceLanguageID != displayedCaption.targetLanguageID
                let resolvedTranslation = translationExpected
                    ? (translatedText ?? "")
                    : displayedCaption.sourceText

                updateCommittedOverlay(
                    translatedText: resolvedTranslation,
                    sourceText: displayedCaption.sourceText,
                    lateTranslation: translationExpected && resolvedTranslation.isEmpty == false
                )
                upsertTranscriptEntry(
                    id: displayedCaption.id,
                    sourceText: displayedCaption.sourceText,
                    translatedText: resolvedTranslation
                )
            }
        }
    }

    private func shouldReserveDraftTranslationSlot(
        sourceLanguageID: String,
        targetLanguageID: String
    ) -> Bool {
        showsTranslatedSubtitle && sourceLanguageID != targetLanguageID
    }

    var shouldReserveDraftTranslationSlot: Bool {
        guard let activeDraftSourceLanguageID,
              let activeDraftTargetLanguageID else {
            return false
        }
        return shouldReserveDraftTranslationSlot(
            sourceLanguageID: activeDraftSourceLanguageID,
            targetLanguageID: activeDraftTargetLanguageID
        )
    }

    var transcriptSourceLanguageID: String {
        transcriptInputLanguageID ?? inputLanguageID
    }

    var transcriptTargetLanguageID: String {
        transcriptOutputLanguageID ?? outputLanguageID
    }

    var hasTranscript: Bool {
        transcriptEntries.isEmpty == false
    }

    func transcriptText(isTranslation: Bool) -> String {
        transcriptEntries
            .map { isTranslation ? $0.translatedText : $0.sourceText }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }

    func clearTranscript() {
        transcriptStore.clear()
        transcriptGeneration &+= 1
    }

    var shouldReserveCommittedCaptionSlot: Bool {
        guard sessionState == .running else {
            return false
        }

        return displayedCaption != nil
            || pendingCaptions.isEmpty == false
            || hasActiveDraftOverlay
            || overlayState?.draftPromotionID != nil
            || overlayState?.history.isEmpty == false
    }

    private func resetLiveTextPipeline() {
        captionPipelineID = UUID()
        sourceDrafts.clear()
        captionDisplayTask?.cancel()
        captionDisplayTask = nil
        draftClearTask?.cancel()
        draftClearTask = nil
        draftTranslationTasks.values.forEach { $0.cancel() }
        draftTranslationTasks.removeAll()
        committedCaptionArchiveTask?.cancel()
        committedCaptionArchiveTask = nil
        activeDraftSourceLanguageID = nil
        activeDraftTargetLanguageID = nil
        lastDraftSourceID = nil
        draftClearGeneration &+= 1
        cancelCaptionTranslations()
        resumeAllCaptionTranslationWaiters()
        pendingCaptions.removeAll()
        readyCaptionTranslations.removeAll()
        translationRevisions.removeAll()
        recentRecognizedCaptionTexts.removeAll()
        recentArchivedCaption = nil
        finalizedDraftPromotionIDs.removeAll()
        displayedCaption = nil
        overlayHistoryScrollOffset = 0
        displayedCaptionLastVisualUpdateAt = Date.distantPast
        displayedCaptionLastVisualUpdateWasLateTranslation = false

        translationCoordinator.invalidateSession()
        translationCoordinator.reset()

    }

    private func processCaptionQueueIfNeeded() {
        guard captionDisplayTask == nil else {
            return
        }

        captionDisplayTask = Task { @MainActor [weak self] in
            await self?.processCaptionQueue()
        }
    }

    private func processCaptionQueue() async {
        let pipelineID = captionPipelineID
        defer {
            if captionPipelineID == pipelineID {
                captionDisplayTask = nil
                scheduleCommittedCaptionArchiveIfNeeded()
            }
        }

        while Task.isCancelled == false {
            guard !Task.isCancelled, captionPipelineID == pipelineID,
                  liveTranscriptionSession != nil else { break }
            guard let caption = pendingCaptions.first else {
                // Keep the most recent committed caption in the primary white slot
                // until a newer caption arrives and replaces it.
                break
            }

            // Caption cleanup runs on every exit from this iteration: normal
            // completion, break, or sleep cancellation. This prevents captions from
            // getting stuck in pendingCaptions and replaying on the next queue start.
            defer {
                if captionPipelineID == pipelineID {
                    pendingCaptions.removeAll(where: { $0.id == caption.id })
                    updateReadyCaptionTranslation(nil, for: caption.id)
                }
            }

            // Archive the current caption before the next sentence replaces it.
            capturePreviousCaption()

            // Use the best available translation for the initial committed display:
            // 1. Pre-computed caption translation (if ready)
            // 2. Draft translation captured at the promotion moment
            // 3. Leave the translated slot empty until the final translation arrives
            let earlyTranslation = readyCaptionTranslations[caption.id]
            let initialTranslation = earlyTranslation
                ?? (caption.promotedDraftTranslation?.isEmpty == false ? caption.promotedDraftTranslation : nil)
            let translationExpected = caption.sourceLanguageID != caption.targetLanguageID

            cancelCommittedCaptionArchive()
            displayedCaption = caption

            // If a draft translation was visible, skip the fade-in so the committed
            // text replaces the draft seamlessly instead of flashing.
            let hadDraftTranslation = initialTranslation?.isEmpty == false

            overlayState?.skipCommittedFadeIn = hadDraftTranslation
            updateCommittedOverlay(
                translatedText: initialTranslation ?? (translationExpected ? "" : caption.sourceText),
                sourceText: caption.sourceText,
                promotionID: caption.promotionID,
                bumpEpoch: true
            )
            upsertTranscriptEntry(
                id: caption.id,
                sourceText: caption.sourceText,
                translatedText: initialTranslation ?? (translationExpected ? "" : caption.sourceText)
            )
            overlayState?.sourceName = caption.sourceName
            finishSourceDraft(sourceID: caption.sourceID, promotionID: caption.promotionID)

            let finalTranslation: String?
            if let earlyTranslation {
                finalTranslation = earlyTranslation
            } else {
                // Dynamic wait: base 3s + 1s per 30 chars, capped at 15s
                let captionCharCount = caption.sourceText.count
                let waitTimeout = min(max(3.0, 3.0 + Double(captionCharCount / 30) * 1.0), 15.0)
                let waited = await waitForTranslatedCaption(id: caption.id, timeout: waitTimeout)
                // Race fallback: the timeout may have resumed our waiter with nil at the
                // same moment the translation finished and ran applyLateCaptionTranslation.
                // Re-read the ready map so we don't clobber a just-applied backfill below.
                finalTranslation = waited ?? readyCaptionTranslations[caption.id]
            }

            guard !Task.isCancelled, captionPipelineID == pipelineID,
                  liveTranscriptionSession != nil else { break }

            let resolvedTranslation = resolvedCommittedTranslationText(
                finalTranslation: finalTranslation,
                initialTranslation: initialTranslation,
                translationExpected: translationExpected,
                sourceText: caption.sourceText
            )

            // If nothing translated for a translation-expected caption, the session may be stuck.
            let translationFailed = translationExpected
                && resolvedTranslation.isEmpty
                && initialTranslation == nil

            if translationFailed {
                translationCoordinator.consecutiveTimeouts += 1
            } else {
                translationCoordinator.consecutiveTimeouts = 0
            }

            // After 2 consecutive failed captions, recover the session and reissue
            // affected translations so late backfill still has work to complete.
            if translationCoordinator.consecutiveTimeouts >= 2 {
                translationCoordinator.recoverSession(
                    source: caption.sourceLanguageID,
                    target: caption.targetLanguageID
                )

                let captionsToRetry = [caption] + pendingCaptions.filter { $0.id != caption.id }
                for captionToRetry in captionsToRetry {
                    translateCaption(captionToRetry)
                }
            }

            updateCommittedOverlay(
                translatedText: resolvedTranslation,
                sourceText: caption.sourceText,
                lateTranslation: translationExpected && resolvedTranslation.isEmpty == false
            )
            upsertTranscriptEntry(
                id: caption.id,
                sourceText: caption.sourceText,
                translatedText: resolvedTranslation
            )
            if resolvedTranslation.isEmpty == false {
                translationRevisions[caption.id] = (text: resolvedTranslation, committedAt: Date(), count: 0)
            } else {
                translationRevisions.removeValue(forKey: caption.id)
            }

            let holdDuration = computeDisplayDuration(
                sourceText: caption.sourceText,
                translatedText: resolvedTranslation
            )

            let completedHold = await holdDisplayedCaption(
                caption,
                initialHoldDuration: holdDuration
            )
            if completedHold == false {
                break
            }
            // defer runs here: removes caption from pendingCaptions + readyCaptionTranslations
        }
        // defer runs here: captionDisplayTask = nil
    }

    private func normalizedCaptionText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    private func comparableCaptionText(_ text: String) -> String {
        normalizedCaptionText(text)
            .trimmingCharacters(in: Self.captionComparisonTrimCharacterSet)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func relaxedComparableCaptionText(_ text: String) -> String {
        comparableCaptionText(text)
            .replacingOccurrences(
                of: "[ー〜～]+$",
                with: "",
                options: .regularExpression
            )
    }

    private func isNearDuplicateCaptionText(_ lhs: String, _ rhs: String) -> Bool {
        let lhsComparable = comparableCaptionText(lhs)
        let rhsComparable = comparableCaptionText(rhs)
        guard lhsComparable.isEmpty == false,
              rhsComparable.isEmpty == false else {
            return false
        }

        if lhsComparable == rhsComparable {
            return true
        }

        if relaxedComparableCaptionText(lhs) == relaxedComparableCaptionText(rhs) {
            return true
        }

        let maxLength = max(lhsComparable.count, rhsComparable.count)
        guard maxLength >= Self.recentRecognizedNearDuplicateMinimumLength else {
            return false
        }

        let distanceRatio = levenshteinDistanceRatio(lhsComparable, rhsComparable)
        return distanceRatio <= Self.recentRecognizedNearDuplicateSimilarityThreshold
    }

    private func sanitizedDisplayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return ""
        }

        return containsSubtitleContent(trimmed) ? trimmed : ""
    }

    private func containsSubtitleContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) == false
                && CharacterSet.punctuationCharacters.contains(scalar) == false
                && CharacterSet.symbols.contains(scalar) == false
        }
    }

    private func shouldEnqueueRecognizedSentence(_ text: String, sourceID: String, promotionID: UUID? = nil) -> Bool {
        let now = Date()
        let comparable = comparableCaptionText(text)
        recentRecognizedCaptionTexts.removeAll { now.timeIntervalSince($0.time) > 6.0 }

        if comparable.isEmpty {
            return false
        }

        if let displayedCaption, displayedCaption.sourceID == sourceID,
           comparableCaptionText(displayedCaption.sourceText) == comparable {
            return false
        }

        if let displayedCaption, displayedCaption.sourceID == sourceID,
           isNearDuplicateCaptionText(displayedCaption.sourceText, text) {
            return false
        }

        if pendingCaptions.contains(where: { $0.sourceID == sourceID && comparableCaptionText($0.sourceText) == comparable }) {
            return false
        }

        if pendingCaptions.contains(where: { $0.sourceID == sourceID && isNearDuplicateCaptionText($0.sourceText, text) }) {
            return false
        }

        if shouldSuppressArchivedCaptionReplay(
            comparableText: comparable,
            sourceID: sourceID,
            promotionID: promotionID,
            now: now
        ) {
            return false
        }

        return recentRecognizedCaptionTexts.contains(where: {
            $0.sourceID == sourceID && ($0.comparableText == comparable || isNearDuplicateCaptionText($0.rawText, text))
        }) == false
    }

    private func rememberRecognizedSentence(_ text: String, sourceID: String) {
        let now = Date()
        recentRecognizedCaptionTexts.removeAll { now.timeIntervalSince($0.time) > 6.0 }
        recentRecognizedCaptionTexts.append(
            RecentRecognizedCaption(
                rawText: text,
                sourceID: sourceID,
                comparableText: comparableCaptionText(text),
                time: now
            )
        )
    }

    private func rememberArchivedCaption(sourceText: String, promotionID: UUID?) {
        let comparable = comparableCaptionText(sourceText)
        guard comparable.isEmpty == false else {
            recentArchivedCaption = nil
            return
        }

        recentArchivedCaption = RecentArchivedCaption(
            comparableText: comparable,
            sourceID: displayedCaption?.sourceID,
            time: Date(),
            promotionID: promotionID
        )
    }

    private func promotedDraftTranslationSnapshot(for promotionID: UUID?) -> String? {
        guard let promotionID else { return nil }
        return sourceDrafts.snapshots.values.first { $0.draft.segmentId == promotionID }?.translatedText
    }

    private func markDraftPromotionFinalized(_ id: UUID) {
        let now = Date()
        pruneFinalizedDraftPromotionIDs(now: now)
        finalizedDraftPromotionIDs.removeAll { $0.id == id }
        finalizedDraftPromotionIDs.append((id: id, time: now))
    }

    private func isFinalizedDraftPromotionID(_ id: UUID) -> Bool {
        let now = Date()
        pruneFinalizedDraftPromotionIDs(now: now)
        return finalizedDraftPromotionIDs.contains { $0.id == id }
    }

    private func pruneFinalizedDraftPromotionIDs(now: Date) {
        finalizedDraftPromotionIDs.removeAll { now.timeIntervalSince($0.time) > 12.0 }

        if finalizedDraftPromotionIDs.count > Self.finalizedDraftPromotionLimit {
            finalizedDraftPromotionIDs.removeFirst(
                finalizedDraftPromotionIDs.count - Self.finalizedDraftPromotionLimit
            )
        }
    }

    private func isDraftPromotionPending() -> Bool {
        guard let draftPromotionID = overlayState?.draftPromotionID else {
            return false
        }

        if displayedCaption?.promotionID == draftPromotionID {
            return true
        }

        return pendingCaptions.contains { $0.promotionID == draftPromotionID }
    }

    private func shouldSuppressArchivedCaptionReplay(
        comparableText: String,
        sourceID: String,
        promotionID: UUID?,
        now: Date
    ) -> Bool {
        guard comparableText.isEmpty == false,
              displayedCaption == nil,
              pendingCaptions.isEmpty,
              hasActiveDraftOverlay == false,
              overlayState?.draftPromotionID == nil,
              let recentArchivedCaption, recentArchivedCaption.sourceID == sourceID,
              now.timeIntervalSince(recentArchivedCaption.time) <= Self.archivedCaptionReplaySuppressionWindow else {
            return false
        }

        if let promotionID,
           recentArchivedCaption.promotionID == promotionID {
            return true
        }

        if recentArchivedCaption.comparableText == comparableText {
            return true
        }

        let maxLength = max(recentArchivedCaption.comparableText.count, comparableText.count)
        guard maxLength >= Self.archivedCaptionNearDuplicateMinimumLength else {
            return false
        }

        let distanceRatio = levenshteinDistanceRatio(
            recentArchivedCaption.comparableText,
            comparableText
        )

        // Suppress only very close revisions of the just-archived sentence.
        return distanceRatio <= Self.archivedCaptionReplaySimilarityThreshold
    }

    private func waitForTranslatedCaption(id: UUID, timeout: Double = 1.5) async -> String? {
        if let translatedText = readyCaptionTranslations[id] {
            return translatedText
        }

        guard liveTranscriptionSession != nil else {
            return nil
        }

        let waiterID = UUID()
        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let timeoutTask = Task { @MainActor [weak self] in
            if timeoutNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
            }

            self?.resumeCaptionTranslationWaiter(
                captionID: id,
                waiterID: waiterID,
                translatedText: nil
            )
        }

        return await withTaskCancellationHandler {
            let translatedText = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                if let translatedText = readyCaptionTranslations[id] {
                    continuation.resume(returning: translatedText)
                    return
                }

                guard liveTranscriptionSession != nil else {
                    continuation.resume(returning: nil)
                    return
                }

                captionTranslationWaiters[id, default: [:]][waiterID] = continuation
            }

            timeoutTask.cancel()
            return translatedText
        } onCancel: {
            timeoutTask.cancel()
            Task { @MainActor [weak self] in
                self?.resumeCaptionTranslationWaiter(
                    captionID: id,
                    waiterID: waiterID,
                    translatedText: nil
                )
            }
        }
    }

    private func translateCaption(_ caption: QueuedCaption) {
        captionTranslationTasks[caption.id]?.cancel()

        let pipelineID = captionPipelineID
        captionTranslationTasks[caption.id] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let translatedText = await translatedText(for: caption)
            guard Task.isCancelled == false,
                  captionPipelineID == pipelineID else {
                return
            }

            updateReadyCaptionTranslation(translatedText, for: caption.id)
            captionTranslationTasks[caption.id] = nil
        }
    }

    private func updateReadyCaptionTranslation(_ translatedText: String?, for captionID: UUID) {
        if let translatedText {
            if shouldCacheReadyCaptionTranslation(for: captionID) {
                readyCaptionTranslations[captionID] = translatedText
            } else {
                readyCaptionTranslations.removeValue(forKey: captionID)
            }
        } else {
            readyCaptionTranslations.removeValue(forKey: captionID)
        }

        resumeCaptionTranslationWaiters(for: captionID, translatedText: translatedText)

        if let translatedText, translatedText.isEmpty == false {
            applyLateCaptionTranslation(translatedText, for: captionID)
        }
    }

    /// shouldCacheReadyCaptionTranslation
    /// Returns true when a completed translation still belongs to the active caption flow.
    private func shouldCacheReadyCaptionTranslation(for captionID: UUID) -> Bool {
        displayedCaption?.id == captionID
            || pendingCaptions.contains(where: { $0.id == captionID })
            || captionTranslationWaiters[captionID]?.isEmpty == false
    }

    /// Backfills a translation that finished after `processCaptionQueue` already moved on.
    /// Without this, captions whose translation arrived after the wait timeout would stay
    /// permanently untranslated in the live overlay, scrollback history, and transcript.
    private func applyLateCaptionTranslation(_ translatedText: String, for captionID: UUID) {
        var didApplyTranslation = false
        var didApplyDisplayedTranslation = false

        if displayedCaption?.id == captionID,
           let state = overlayState,
           shouldReplaceCommittedTranslation(state.translatedText, for: captionID),
           state.sourceText.isEmpty == false {
            updateCommittedOverlay(
                translatedText: translatedText,
                sourceText: state.sourceText,
                lateTranslation: true
            )
            didApplyTranslation = true
            didApplyDisplayedTranslation = true
        }

        if let index = overlayState?.history.lastIndex(where: { $0.id == captionID }),
           shouldReplaceCommittedTranslation(overlayState?.history[index].translatedText ?? "", for: captionID) {
            overlayState?.history[index].translatedText = translatedText
            didApplyTranslation = true
        }

        if let entry = transcriptStore.entry(id: captionID),
           shouldReplaceCommittedTranslation(entry.translatedText, for: captionID) {
            transcriptStore.updateTranslation(id: captionID, text: translatedText)
            didApplyTranslation = true
        }

        if didApplyTranslation {
            translationRevisions[captionID] = (text: translatedText, committedAt: Date(), count: 0)
        }

        if didApplyDisplayedTranslation {
            scheduleCommittedCaptionArchiveIfNeeded()
        }
    }

    /// holdDisplayedCaption
    /// Keeps the current caption visible, extending the hold if a late translation appears mid-display.
    private func holdDisplayedCaption(_ caption: QueuedCaption, initialHoldDuration: Double) async -> Bool {
        var targetDuration = initialHoldDuration
        var observedLateTranslationAt = Date.distantPast

        while Task.isCancelled == false {
            guard liveTranscriptionSession != nil,
                  displayedCaption?.id == caption.id else {
                return false
            }

            let elapsed = max(0, Date().timeIntervalSince(displayedCaptionLastVisualUpdateAt))
            let remainingDelay = max(0, targetDuration - elapsed)
            if remainingDelay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                } catch {
                    return false
                }
            }

            guard displayedCaption?.id == caption.id else {
                return false
            }

            if displayedCaptionLastVisualUpdateWasLateTranslation,
               displayedCaptionLastVisualUpdateAt > observedLateTranslationAt,
               let state = overlayState,
               state.translatedText.isEmpty == false {
                observedLateTranslationAt = displayedCaptionLastVisualUpdateAt
                targetDuration = computeDisplayDuration(
                    sourceText: state.sourceText,
                    translatedText: state.translatedText
                )
                continue
            }

            return true
        }

        return false
    }

    private func shouldReplaceCommittedTranslation(_ currentText: String, for captionID: UUID) -> Bool {
        if currentText.isEmpty {
            return true
        }

        return translationRevisions[captionID]?.text == currentText
    }

    private func resumeCaptionTranslationWaiter(
        captionID: UUID,
        waiterID: UUID,
        translatedText: String?
    ) {
        guard var waiters = captionTranslationWaiters[captionID],
              let continuation = waiters.removeValue(forKey: waiterID) else {
            return
        }

        if waiters.isEmpty {
            captionTranslationWaiters.removeValue(forKey: captionID)
        } else {
            captionTranslationWaiters[captionID] = waiters
        }

        continuation.resume(returning: translatedText)
    }

    private func resumeCaptionTranslationWaiters(for captionID: UUID, translatedText: String?) {
        guard let waiters = captionTranslationWaiters.removeValue(forKey: captionID) else {
            return
        }

        for continuation in waiters.values {
            continuation.resume(returning: translatedText)
        }
    }

    private func resumeAllCaptionTranslationWaiters(translatedText: String? = nil) {
        let waiters = captionTranslationWaiters
        captionTranslationWaiters.removeAll()

        for captionWaiters in waiters.values {
            for continuation in captionWaiters.values {
                continuation.resume(returning: translatedText)
            }
        }
    }

    private func translatedText(for caption: QueuedCaption) async -> String? {
        guard caption.sourceLanguageID != caption.targetLanguageID else {
            return caption.sourceText
        }

        // The committed caption display path has its own wait timeout. Keep this
        // request alive so a slow translation can still backfill overlay history
        // and transcript entries instead of being dropped permanently.
        let raw: String?
        do {
            raw = try await translationCoordinator.translate(
                caption.sourceText,
                from: caption.sourceLanguageID,
                to: caption.targetLanguageID
            )
        } catch {
            raw = nil
        }

        guard let raw else {
            return nil
        }

        // Apply user glossary on top of raw translation
        let currentGlossary = glossary
        let translated = sanitizedDisplayText(glossaryService.apply(to: raw, glossary: currentGlossary))
        guard translated.isEmpty == false,
              shouldTreatAsMissingTranslation(
                  translated,
                  sourceText: caption.sourceText,
                  sourceLanguageID: caption.sourceLanguageID,
                  targetLanguageID: caption.targetLanguageID
              ) == false else {
            return nil
        }
        return translated
    }

    private func resolvedCommittedTranslationText(
        finalTranslation: String?,
        initialTranslation: String?,
        translationExpected: Bool,
        sourceText: String
    ) -> String {
        guard translationExpected else {
            return sourceText
        }

        if let finalTranslation, finalTranslation.isEmpty == false {
            return finalTranslation
        }

        if let initialTranslation, initialTranslation.isEmpty == false {
            return initialTranslation
        }

        return ""
    }

    private func shouldTreatAsMissingTranslation(
        _ translatedText: String,
        sourceText: String,
        sourceLanguageID: String,
        targetLanguageID: String
    ) -> Bool {
        guard sourceLanguageID != targetLanguageID else {
            return false
        }

        let comparableSource = comparableCaptionText(sourceText)
        let comparableTranslation = comparableCaptionText(translatedText)
        guard comparableSource.isEmpty == false,
              comparableSource == comparableTranslation else {
            return false
        }

        return comparableSource.count >= Self.sameLanguageTranslationSuppressionMinimumLength
    }

    private func resetTranscript(sourceLanguageID: String, targetLanguageID: String) {
        transcriptStore.clear()
        transcriptInputLanguageID = sourceLanguageID
        transcriptOutputLanguageID = targetLanguageID
        transcriptGeneration &+= 1
    }

    private func restoreTranscript(
        entries: [TranscriptEntry],
        sourceLanguageID: String?,
        targetLanguageID: String?
    ) {
        transcriptStore.replace(entries)
        transcriptInputLanguageID = sourceLanguageID
        transcriptOutputLanguageID = targetLanguageID
        transcriptGeneration &+= 1
    }

    private func upsertTranscriptEntry(
        id: UUID,
        sourceText: String,
        translatedText: String
    ) {
        // Only ingress creates records. Display updates must not resurrect cleared records.
        guard var entry = transcriptStore.entry(id: id) else { return }
        entry.sourceText = sourceText
        if !translatedText.isEmpty { entry.translatedText = translatedText }
        transcriptStore.upsert(entry)
    }

    private func levenshteinDistanceRatio(_ a: String, _ b: String) -> Double {
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 0.0 }
        return Double(levenshteinDistance(Array(a), Array(b))) / Double(maxLen)
    }

    private func levenshteinDistance(_ a: [Character], _ b: [Character]) -> Int {
        let m = a.count
        let n = b.count
        guard m > 0 else { return n }
        guard n > 0 else { return m }

        var dp = Array(0...n)

        for i in 1...m {
            var prev = dp[0]
            dp[0] = i

            for j in 1...n {
                let temp = dp[j]
                dp[j] = a[i - 1] == b[j - 1] ? prev : 1 + min(prev, dp[j], dp[j - 1])
                prev = temp
            }
        }

        return dp[n]
    }

    private func cancelCaptionTranslations() {
        for task in captionTranslationTasks.values {
            task.cancel()
        }

        captionTranslationTasks.removeAll()
    }

    private func cancelCommittedCaptionArchive() {
        committedCaptionArchiveTask?.cancel()
        committedCaptionArchiveTask = nil
    }

    private func scheduleCommittedCaptionArchiveIfNeeded() {
        cancelCommittedCaptionArchive()

        guard liveTranscriptionSession != nil,
              pendingCaptions.isEmpty,
              hasActiveDraftOverlay == false,
              currentCommittedCaptionHistoryPayload() != nil else {
            return
        }

        let elapsed = max(0, Date().timeIntervalSince(displayedCaptionLastVisualUpdateAt))
        let remainingDelay = max(0, Self.committedCaptionIdleArchiveDelay - elapsed)

        committedCaptionArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if remainingDelay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  liveTranscriptionSession != nil,
                  pendingCaptions.isEmpty,
                  hasActiveDraftOverlay == false,
                  currentCommittedCaptionHistoryPayload() != nil else {
                return
            }

            clearOverlayText()
        }
    }

    private var hasActiveDraftOverlay: Bool {
        sanitizedDisplayText(overlayState?.draftSourceText ?? "").isEmpty == false
    }

    private func currentCommittedCaptionHistoryPayload() -> (translatedText: String, sourceText: String)? {
        guard let current = overlayState,
              displayedCaption != nil,
              current.translatedText.isEmpty == false || current.sourceText.isEmpty == false,
              current.translatedText != listeningPlaceholderText,
              current.translatedText != captureStoppedText,
              current.translatedText != unableToStartText else {
            return nil
        }

        return (current.translatedText, current.sourceText)
    }

    private var overlayHistoryCount: Int {
        overlayState?.history.count ?? 0
    }

    private var overlayHistoryMaxScrollOffset: Int {
        max(0, overlayHistoryCount - max(0, overlayHistoryVisibleCount))
    }

    private func clampOverlayHistoryScrollOffset() {
        overlayHistoryScrollOffset = min(max(overlayHistoryScrollOffset, 0), overlayHistoryMaxScrollOffset)
    }

    private func appendOverlayHistoryEntry(
        captionID: UUID? = nil,
        translatedText: String,
        sourceText: String
    ) {
        guard shouldStoreOverlayHistory(translatedText: translatedText, sourceText: sourceText) else {
            return
        }

        if let lastEntry = overlayState?.history.last,
           lastEntry.id == captionID {
            return
        }

        if overlayHistoryScrollOffset > 0 {
            overlayHistoryScrollOffset += 1
        }

        overlayState?.history.append(
            OverlayHistoryEntry(
                id: captionID ?? UUID(),
                translatedText: translatedText,
                sourceText: sourceText
            )
        )

        let overflow = max(0, (overlayState?.history.count ?? 0) - Self.overlayHistoryLimit)
        if overflow > 0 {
            overlayState?.history.removeFirst(overflow)
            if overlayHistoryScrollOffset > 0 {
                overlayHistoryScrollOffset = max(0, overlayHistoryScrollOffset - overflow)
            }
        }

        clampOverlayHistoryScrollOffset()
    }

    private func shouldStoreOverlayHistory(translatedText: String, sourceText: String) -> Bool {
        let normalizedTranslated = sanitizedDisplayText(translatedText)
        let normalizedSource = sanitizedDisplayText(sourceText)
        guard normalizedTranslated.isEmpty == false || normalizedSource.isEmpty == false else {
            return false
        }

        switch normalizedTranslated {
        case listeningPlaceholderText, captureStoppedText, unableToStartText:
            return false
        default:
            return true
        }
    }

    private func dismissListeningPlaceholderIfNeeded() {
        guard overlayState?.translatedText == listeningPlaceholderText else {
            return
        }

        overlayState?.translatedText = ""
        overlayState?.sourceText = ""
    }

    // MARK: - Display duration (strategy §10)

    /// max(min_hold, reading_time, audio_span × sync_factor), clamped to [1.2, adaptive_max] s
    private func computeDisplayDuration(sourceText: String, translatedText: String) -> Double {
        let displayText: String
        if showsTranslatedSubtitle {
            displayText = translatedText.isEmpty ? sourceText : translatedText
        } else {
            displayText = sourceText.isEmpty ? translatedText : sourceText
        }
        let charCount = Double(displayText.count)
        let isCJK = displayText.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)
                || (0x3040...0x30FF).contains($0.value)
                || (0xAC00...0xD7AF).contains($0.value)
        }

        let cps: Double = isCJK ? 7.0 : 13.5
        var readingTime = charCount / cps

        // Bilingual factor: both source and translation shown simultaneously
        if showsOriginalSubtitle && showsTranslatedSubtitle && inputLanguageID != outputLanguageID {
            readingTime *= 1.15
        }

        // Min hold based on length tier
        let minHold: Double
        switch charCount {
        case ..<10:   minHold = 1.2
        case 10..<21: minHold = 1.6
        default:      minHold = 2.0
        }

        let maxHold: Double
        if showsTranslatedSubtitle {
            if isCJK {
                switch charCount {
                case ..<24:  maxHold = 4.5
                case ..<36:  maxHold = 5.4
                default:     maxHold = 6.2
                }
            } else {
                switch charCount {
                case ..<48:  maxHold = 4.5
                case ..<72:  maxHold = 5.4
                default:     maxHold = 6.2
                }
            }
        } else {
            maxHold = 4.5
        }

        return min(max(minHold, readingTime), maxHold)
    }

    private func sampleText(for languageID: String) -> String {
        switch languageID {
        case "zh-Hans":
            return "欢迎使用 v2s，顶部字幕条已经准备好了。"
        case "es":
            return "Bienvenido a v2s. La barra de subtitulos ya esta lista."
        case "de":
            return "Willkommen bei v2s. Die Untertitel-Leiste ist bereit."
        case "ja":
            return "v2s へようこそ。字幕バーの準備ができました。"
        case "fr":
            return "Bienvenue dans v2s. La barre de sous-titres est prete."
        case "it":
            return "Benvenuto in v2s. La barra dei sottotitoli e pronta."
        case "ko":
            return "v2s에 오신 것을 환영합니다. 자막 바가 준비되었습니다."
        case "yue":
            return "歡迎使用 v2s，字幕列已經準備好。"
        case "ar":
            return "مرحبا بك في v2s. شريط الترجمة جاهز."
        case "pt":
            return "Bem-vindo ao v2s. A barra de legendas esta pronta."
        case "ru":
            return "Добро пожаловать в v2s. Строка субтитров готова."
        default:
            return "Welcome to v2s. The subtitle bar is ready."
        }
    }

}

private enum StatusDescriptor: Equatable {
    case ready
    case noInputSourcesDetected
    case running(sourceName: String)
    case chooseInputSourceBeforeStarting
    case checkingLanguageResources
    case downloadLanguageResourcesInSystemSettings
    case preparing(sourceName: String)
    case showingOverlayPreview
    case custom(String)
}

private extension AppModel {
    static let overlayHistoryLimit = 120
    static let draftClearDelayNanoseconds: UInt64 = 150_000_000
    static let committedCaptionIdleArchiveDelay: TimeInterval = 0.9
    static let archivedCaptionReplaySuppressionWindow: TimeInterval = 1.8
    static let archivedCaptionReplaySimilarityThreshold = 0.18
    static let archivedCaptionNearDuplicateMinimumLength = 8
    static let recentRecognizedNearDuplicateMinimumLength = 4
    static let recentRecognizedNearDuplicateSimilarityThreshold = 0.22
    static let sameLanguageTranslationSuppressionMinimumLength = 8
    static let finalizedDraftPromotionLimit = 32
    static let captionComparisonTrimCharacterSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
}

private struct RecentRecognizedCaption {
    let rawText: String
    let sourceID: String
    let comparableText: String
    let time: Date
}

private struct RecentArchivedCaption {
    let comparableText: String
    let sourceID: String?
    let time: Date
    let promotionID: UUID?
}

struct LanguagePairRequirement: Hashable {
    let sourceLanguageID: String
    let targetLanguageID: String
}

private struct QueuedCaption: Identifiable, Equatable {
    let id: UUID
    let promotionID: UUID
    let sourceText: String
    let sourceName: String
    let sourceID: String
    let sourceLanguageID: String
    let targetLanguageID: String
    let promotedDraftTranslation: String?
}

struct LanguageResourceStatus: Identifiable, Equatable {
    enum Kind: Int {
        case speech = 0
        case translation = 1
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let progress: Double?
    let isError: Bool
}

extension View {
    @ViewBuilder
    func v2sTranslationHost(model: AppModel) -> some View {
        if #available(macOS 15.0, *) {
            self.translationTask(model.translationHostConfiguration) { session in
                await model.runTranslationHost(using: session)
            }
        } else {
            self
        }
    }
}
