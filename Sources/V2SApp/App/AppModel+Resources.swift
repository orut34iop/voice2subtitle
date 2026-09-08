import AppKit
import Foundation
import Speech
import Translation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Resource discovery, preparation and system-managed downloads are isolated here.
// ResourcePreparationCoordinator owns cancellation and update generations.
extension AppModel {
    func refreshLanguageResources() {
        scheduleSelectedLanguageResourcePreparation()
    }

    func refreshModelResourcesIfNeeded() {
        if modelResources.isEmpty {
            refreshModelResources()
        }
    }

    func refreshModelResources() {
        refreshModelResources(showCheckingState: true)
    }

    private func refreshModelResources(showCheckingState: Bool) {
        modelResourceRefreshTask?.cancel()
        if showCheckingState {
            modelResources = checkingModelResourceItems()
        }

        modelResourceRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let resources = await self.loadModelResources()
            guard Task.isCancelled == false else {
                return
            }

            self.modelResources = self.sortedModelResources(resources)
            self.modelResourceRefreshTask = nil
        }
    }

    func refreshModelResourcesAfterExternalChange() {
        guard modelResources.isEmpty == false,
              modelResourceRefreshTask == nil else {
            return
        }

        refreshModelResources(showCheckingState: false)
    }

    private func startExternalModelResourceRefreshMonitor() {
        guard modelResources.isEmpty == false else {
            return
        }

        externalModelResourceRefreshTask?.cancel()
        let deadline = Date().addingTimeInterval(Self.externalModelResourceRefreshDuration)
        externalModelResourceRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while Task.isCancelled == false, Date() < deadline {
                do {
                    try await Task.sleep(nanoseconds: Self.externalModelResourceRefreshIntervalNanoseconds)
                } catch {
                    return
                }

                self.refreshModelResourcesAfterExternalChange()
            }

            self.externalModelResourceRefreshTask = nil
        }
    }

    func performModelResourceAction(_ action: ModelResourceAction, for item: ModelResourceItem) {
        guard item.availableActions.contains(action) else {
            return
        }

        switch action {
        case .download:
            startModelResourceDownload(item)
        case .pause:
            pauseModelResourceDownload(item)
        case .remove:
            startModelResourceRemoval(item)
        case .openSystemSettings:
            openModelResourceSettings(for: item)
        }
    }

    private func checkingModelResourceItems() -> [ModelResourceItem] {
        let supportedLanguageIDs = Set(
            (LanguageCatalog.speechInput + LanguageCatalog.common)
                .map { ModelResourceCatalog.normalizedLanguageID($0.id) }
        )
        let descriptors = speechModelResourceDescriptors()
            + translationModelResourceDescriptors(supportedLanguageIDs: supportedLanguageIDs)
            + [foundationModelResourceDescriptor()]

        return sortedModelResources(
            descriptors.map { descriptor in
                if let activeItem = activeModelResourceItem(for: descriptor.id) {
                    return activeItem
                }

                return modelResourceItem(
                    for: descriptor,
                    detail: localized(.modelResourceCheckingDetail),
                    state: .checking
                )
            }
        )
    }

    private func loadModelResources() async -> [ModelResourceItem] {
        var resources: [ModelResourceItem] = []
        let speechInventory = await speechModelResourceInventory()

        for descriptor in speechModelResourceDescriptors() {
            resources.append(await speechModelResourceItem(for: descriptor, inventory: speechInventory))
        }

        let supportedTranslationLanguageIDs = await supportedTranslationLanguageIDs()
        for descriptor in translationModelResourceDescriptors(
            supportedLanguageIDs: supportedTranslationLanguageIDs
        ) {
            resources.append(await translationModelResourceItem(for: descriptor))
        }

        resources.append(foundationModelResourceItem())
        return resources
    }

    private func speechModelResourceDescriptors() -> [ModelResourceDescriptor] {
        ModelResourceCatalog.speechDescriptors(
            options: LanguageCatalog.speechInput,
            localizedName: languageName(for:)
        )
    }

    private func translationModelResourceDescriptors(
        supportedLanguageIDs: Set<String>
    ) -> [ModelResourceDescriptor] {
        ModelResourceCatalog.translationDescriptors(
            sourceOptions: LanguageCatalog.speechInput,
            targetOptions: LanguageCatalog.common,
            supportedLanguageIDs: supportedLanguageIDs,
            localizedName: languageName(for:)
        )
    }

    private func foundationModelResourceDescriptor() -> ModelResourceDescriptor {
        ModelResourceCatalog.foundationModelDescriptor(
            title: localized(.modelResourceFoundationTitle)
        )
    }

    private func activeModelResourceItem(for id: String) -> ModelResourceItem? {
        guard modelResourceDownloadTasks[id] != nil || modelResourceRemovalTasks[id] != nil else {
            return nil
        }

        return modelResources.first(where: { $0.id == id })
    }

    private func speechModelResourceInventory() async -> SpeechModelResourceInventory? {
        guard #available(macOS 26.0, *) else {
            return nil
        }

        async let supportedLocales = SpeechTranscriber.supportedLocales
        async let installedLocales = SpeechTranscriber.installedLocales
        async let reservedLocales = AssetInventory.reservedLocales

        let supportedLocaleIDs = Set((await supportedLocales).map {
            canonicalLocaleIdentifier($0.identifier)
        })
        let installedLocaleIDs = Set((await installedLocales).map {
            canonicalLocaleIdentifier($0.identifier)
        })
        let reservedLocaleIDs = Set((await reservedLocales).map {
            canonicalLocaleIdentifier($0.identifier)
        })

        return SpeechModelResourceInventory(
            supportedLocaleIDs: supportedLocaleIDs,
            installedLocaleIDs: installedLocaleIDs,
            reservedLocaleIDs: reservedLocaleIDs
        )
    }

    private func speechModelResourceItem(
        for descriptor: ModelResourceDescriptor,
        inventory: SpeechModelResourceInventory?
    ) async -> ModelResourceItem {
        if let activeItem = activeModelResourceItem(for: descriptor.id) {
            return activeItem
        }

        guard #available(macOS 26.0, *) else {
            return modelResourceItem(
                for: descriptor,
                detail: localized(.modelResourceSpeechRequiresMacOS26),
                state: .unsupported
            )
        }

        guard let languageID = descriptor.sourceLanguageID,
              let inventory else {
            return modelResourceItem(
                for: descriptor,
                detail: localized(.modelResourceUnavailableDetail),
                state: .error
            )
        }

        let localeID = canonicalLocaleIdentifier(LanguageCatalog.speechLocaleIdentifier(for: languageID))
        guard inventory.supportedLocaleIDs.contains(localeID) else {
            return modelResourceItem(
                for: descriptor,
                detail: localized(.speechNotAvailableOnMacOS),
                state: .unsupported
            )
        }

        if inventory.installedLocaleIDs.contains(localeID) {
            if inventory.reservedLocaleIDs.contains(localeID) {
                clearReleasedSpeechResourceID(descriptor.id)
            } else if releasedSpeechResourceIDs.contains(descriptor.id) {
                return modelResourceItem(
                    for: descriptor,
                    detail: localized(.modelResourceSpeechReleaseStartedDetail),
                    state: .systemManaged,
                    availableActions: [.openSystemSettings]
                )
            }

            return modelResourceItem(
                for: descriptor,
                detail: localized(.modelResourceSpeechInstalledDetail),
                state: .installed
            )
        }

        clearReleasedSpeechResourceID(descriptor.id)
        return modelResourceItem(
            for: descriptor,
            detail: localized(.modelResourceSpeechDownloadableDetail),
            state: .downloadable
        )
    }

    private func supportedTranslationLanguageIDs() async -> Set<String> {
        guard #available(macOS 15.0, *) else {
            return []
        }

        let availability = LanguageAvailability()
        let languages = await availability.supportedLanguages
        return Set(languages.map {
            ModelResourceCatalog.normalizedLanguageID($0.minimalIdentifier)
        })
    }

    private func translationModelResourceItem(
        for descriptor: ModelResourceDescriptor
    ) async -> ModelResourceItem {
        if let activeItem = activeModelResourceItem(for: descriptor.id) {
            return activeItem
        }

        guard #available(macOS 15.0, *),
              let sourceLanguageID = descriptor.sourceLanguageID,
              let targetLanguageID = descriptor.targetLanguageID else {
            return modelResourceItem(
                for: descriptor,
                detail: localized(.translationRequiresMacOS15OrNewer),
                state: .unsupported
            )
        }

        switch await translationAvailabilityStatus(from: sourceLanguageID, to: targetLanguageID) {
        case .installed:
            return modelResourceItem(
                for: descriptor,
                detail: localized(.modelResourceTranslationInstalledDetail),
                state: .installed
            )
        case .supported:
            return modelResourceItem(
                for: descriptor,
                detail: localized(.modelResourceTranslationDownloadableDetail),
                state: .downloadable
            )
        case .unsupported:
            return modelResourceItem(
                for: descriptor,
                detail: localized(.translationNotSupportedPairOnMacOS),
                state: .unsupported
            )
        @unknown default:
            return modelResourceItem(
                for: descriptor,
                detail: localized(.modelResourceUnavailableDetail),
                state: .error
            )
        }
    }

    private func foundationModelResourceItem() -> ModelResourceItem {
        let descriptor = foundationModelResourceDescriptor()

        guard #available(macOS 26.0, *) else {
            return modelResourceItem(
                for: descriptor,
                detail: localized(.modelResourceFoundationRequiresMacOS26),
                state: .unsupported
            )
        }

#if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return modelResourceItem(
                for: descriptor,
                detail: localized(.modelResourceFoundationAvailableDetail),
                state: .installed
            )
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return modelResourceItem(
                    for: descriptor,
                    detail: localized(.modelResourceFoundationDeviceNotEligibleDetail),
                    state: .unsupported
                )
            case .appleIntelligenceNotEnabled:
                return modelResourceItem(
                    for: descriptor,
                    detail: localized(.modelResourceFoundationAppleIntelligenceOffDetail),
                    state: .systemManaged
                )
            case .modelNotReady:
                return modelResourceItem(
                    for: descriptor,
                    detail: localized(.modelResourceFoundationModelNotReadyDetail),
                    state: .systemManaged
                )
            @unknown default:
                return modelResourceItem(
                    for: descriptor,
                    detail: localized(.modelResourceUnavailableDetail),
                    state: .systemManaged
                )
            }
        @unknown default:
            return modelResourceItem(
                for: descriptor,
                detail: localized(.modelResourceUnavailableDetail),
                state: .systemManaged
            )
        }
#else
        return modelResourceItem(
            for: descriptor,
            detail: localized(.modelResourceFoundationRequiresMacOS26),
            state: .unsupported
        )
#endif
    }

    private func startModelResourceDownload(_ item: ModelResourceItem) {
        switch item.kind {
        case .speech:
            startSpeechModelResourceDownload(item)
        case .translation:
            startTranslationModelResourceDownload(item)
        case .foundationModel:
            openSystemSettings(for: .appleIntelligence)
        }
    }

    private func startSpeechModelResourceDownload(_ item: ModelResourceItem) {
        guard let languageID = item.sourceLanguageID,
              modelResourceDownloadTasks[item.id] == nil else {
            return
        }

        clearReleasedSpeechResourceID(item.id)
        updateModelResource(
            id: item.id,
            detail: localized(.modelResourceSpeechDownloadingDetail),
            state: .downloading,
            availableActions: [.pause]
        )

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                if #available(macOS 26.0, *) {
                    try await self.downloadSpeechModelResource(languageID: languageID, resourceID: item.id)
                } else {
                    throw LanguageResourcePreparationError.unsupportedSpeechLanguage
                }
                self.modelResourceDownloadTasks.removeValue(forKey: item.id)
                self.refreshModelResources()
            } catch is CancellationError {
                self.modelResourceDownloadTasks.removeValue(forKey: item.id)
                self.refreshModelResources()
            } catch {
                self.modelResourceDownloadTasks.removeValue(forKey: item.id)
                self.updateModelResource(
                    id: item.id,
                    detail: self.localizedErrorDescription(error),
                    state: .error
                )
            }
        }

        modelResourceDownloadTasks[item.id] = task
    }

    @available(macOS 26.0, *)
    private func downloadSpeechModelResource(
        languageID: String,
        resourceID: String
    ) async throws {
        let requestedLocale = Locale(identifier: LanguageCatalog.speechLocaleIdentifier(for: languageID))
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw LanguageResourcePreparationError.unsupportedSpeechLanguage
        }

        let transcriber = makeSpeechTranscriber(locale: resolvedLocale)
        if await AssetInventory.status(forModules: [transcriber]) == .installed {
            return
        }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }

        let progressTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while Task.isCancelled == false {
                self.updateModelResource(
                    id: resourceID,
                    detail: self.localized(.modelResourceSpeechDownloadingDetail),
                    state: .downloading,
                    progress: self.normalizedProgressValue(request.progress.fractionCompleted),
                    availableActions: [.pause]
                )

                do {
                    try await Task.sleep(nanoseconds: 120_000_000)
                } catch {
                    return
                }
            }
        }

        defer { progressTask.cancel() }
        try await request.downloadAndInstall()
        try Task.checkCancellation()
    }

    private func startTranslationModelResourceDownload(_ item: ModelResourceItem) {
        guard let sourceLanguageID = item.sourceLanguageID,
              let targetLanguageID = item.targetLanguageID,
              modelResourceDownloadTasks[item.id] == nil else {
            return
        }

        updateModelResource(
            id: item.id,
            detail: localized(.modelResourceTranslationPreparingDetail),
            state: .downloading,
            availableActions: [.openSystemSettings]
        )

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.downloadTranslationModelResource(
                    from: sourceLanguageID,
                    to: targetLanguageID,
                    resourceID: item.id
                )
                self.modelResourceDownloadTasks.removeValue(forKey: item.id)
                self.refreshModelResources()
            } catch is CancellationError {
                self.modelResourceDownloadTasks.removeValue(forKey: item.id)
                self.refreshModelResources()
            } catch {
                self.modelResourceDownloadTasks.removeValue(forKey: item.id)
                self.updateModelResource(
                    id: item.id,
                    detail: self.localizedErrorDescription(error),
                    state: .error
                )
            }
        }

        modelResourceDownloadTasks[item.id] = task
    }

    private func downloadTranslationModelResource(
        from sourceLanguageID: String,
        to targetLanguageID: String,
        resourceID: String
    ) async throws {
        try Task.checkCancellation()

        if await translationAvailabilityStatus(from: sourceLanguageID, to: targetLanguageID) == .installed {
            return
        }

        do {
            try await prepareTranslationResourceWithTimeout(
                from: sourceLanguageID,
                to: targetLanguageID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let refreshedStatus = await translationAvailabilityStatus(
                from: sourceLanguageID,
                to: targetLanguageID
            )
            guard refreshedStatus != .unsupported else {
                throw error
            }
        }

        try await monitorTranslationModelResourceInstallation(
            from: sourceLanguageID,
            to: targetLanguageID,
            resourceID: resourceID
        )
    }

    private func monitorTranslationModelResourceInstallation(
        from sourceLanguageID: String,
        to targetLanguageID: String,
        resourceID: String
    ) async throws {
        let deadline = Date().addingTimeInterval(Self.translationModelResourceMonitoringTimeout)

        while true {
            try Task.checkCancellation()

            switch await translationAvailabilityStatus(from: sourceLanguageID, to: targetLanguageID) {
            case .installed:
                return
            case .unsupported:
                throw TranslationCoordinator.ServiceError.unsupportedPair(sourceLanguageID, targetLanguageID)
            case .supported:
                updateModelResource(
                    id: resourceID,
                    detail: localized(.downloadingTranslationResources),
                    state: .downloading,
                    progress: nil,
                    availableActions: [.openSystemSettings]
                )
            @unknown default:
                updateModelResource(
                    id: resourceID,
                    detail: localized(.waitingTranslationResourcesInstalling),
                    state: .downloading,
                    progress: nil,
                    availableActions: [.openSystemSettings]
                )
            }

            guard Date() < deadline else {
                throw LanguageResourcePreparationError.translationDownloadTimedOut
            }

            try await Task.sleep(nanoseconds: Self.translationModelResourcePollingIntervalNanoseconds)
        }
    }

    private func startModelResourceRemoval(_ item: ModelResourceItem) {
        switch item.kind {
        case .speech:
            startSpeechModelResourceRemoval(item)
        case .translation, .foundationModel:
            openSystemManagedRemovalSettings(for: item)
        }
    }

    private func startSpeechModelResourceRemoval(_ item: ModelResourceItem) {
        guard let languageID = item.sourceLanguageID,
              modelResourceRemovalTasks[item.id] == nil else {
            return
        }

        guard #available(macOS 26.0, *) else {
            openSystemManagedRemovalSettings(for: item)
            return
        }

        updateModelResource(
            id: item.id,
            detail: localized(.modelResourceSpeechRemovingDetail),
            state: .removing,
            availableActions: []
        )

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let released = try await self.releaseSpeechModelResource(languageID: languageID)
                self.modelResourceRemovalTasks.removeValue(forKey: item.id)

                if released {
                    self.markSpeechResourceIDReleased(item.id)
                    self.updateModelResource(
                        id: item.id,
                        detail: self.localized(.modelResourceSpeechReleaseStartedDetail),
                        state: .systemManaged,
                        availableActions: [.openSystemSettings]
                    )
                    self.refreshModelResources()
                } else {
                    let opened = self.openSystemSettings(for: .dictation)
                    self.updateModelResource(
                        id: item.id,
                        detail: self.localized(
                            opened
                                ? .modelResourceSpeechReleaseUnavailableDetail
                                : .modelResourceSystemSettingsOpenFailedDetail
                        ),
                        state: .systemManaged,
                        availableActions: [.openSystemSettings]
                    )
                }
            } catch {
                self.modelResourceRemovalTasks.removeValue(forKey: item.id)
                self.updateModelResource(
                    id: item.id,
                    detail: self.localizedErrorDescription(error),
                    state: .error
                )
            }
        }

        modelResourceRemovalTasks[item.id] = task
    }

    @available(macOS 26.0, *)
    private func releaseSpeechModelResource(languageID: String) async throws -> Bool {
        let requestedLocale = Locale(identifier: LanguageCatalog.speechLocaleIdentifier(for: languageID))
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw LanguageResourcePreparationError.unsupportedSpeechLanguage
        }

        let resolvedLocaleID = canonicalLocaleIdentifier(resolvedLocale.identifier)
        let reservedLocales = await AssetInventory.reservedLocales
        let reservedLocale = reservedLocales.first {
            canonicalLocaleIdentifier($0.identifier) == resolvedLocaleID
        }

        guard let reservedLocale else {
            return false
        }

        return await AssetInventory.release(reservedLocale: reservedLocale)
    }

    private func openModelResourceSettings(for item: ModelResourceItem) {
        guard openSystemSettings(for: systemSettingsDestination(for: item)) == false else {
            return
        }

        updateModelResource(
            id: item.id,
            detail: localized(.modelResourceSystemSettingsOpenFailedDetail),
            state: item.state,
            availableActions: item.availableActions
        )
    }

    @discardableResult
    private func openSystemManagedRemovalSettings(for item: ModelResourceItem) -> Bool {
        let opened = openSystemSettings(for: systemSettingsDestination(for: item))
        updateModelResource(
            id: item.id,
            detail: localized(opened ? .modelResourceSystemSettingsOpenedDetail : .modelResourceSystemSettingsOpenFailedDetail),
            state: .systemManaged,
            availableActions: [.openSystemSettings]
        )
        return opened
    }

    private func pauseModelResourceDownload(_ item: ModelResourceItem) {
        modelResourceDownloadTasks[item.id]?.cancel()
        modelResourceDownloadTasks.removeValue(forKey: item.id)
        refreshModelResources()
    }

    private func modelResourceItem(
        for descriptor: ModelResourceDescriptor,
        detail: String,
        state: ModelResourceState,
        progress: Double? = nil,
        availableActions: Set<ModelResourceAction>? = nil
    ) -> ModelResourceItem {
        ModelResourceItem(
            id: descriptor.id,
            kind: descriptor.kind,
            title: title(for: descriptor),
            detail: detail,
            state: state,
            progress: progress,
            availableActions: availableActions ?? ModelResourceItem.availableActions(
                for: descriptor.kind,
                state: state,
                isUserInitiatedDownload: modelResourceDownloadTasks[descriptor.id] != nil
            ),
            sourceLanguageID: descriptor.sourceLanguageID,
            targetLanguageID: descriptor.targetLanguageID
        )
    }

    func title(for descriptor: ModelResourceDescriptor) -> String {
        switch descriptor.kind {
        case .speech:
            return localized(.modelResourceSpeechTitleFormat, descriptor.title)
        case .translation:
            return localized(.modelResourceTranslationTitleFormat, descriptor.title)
        case .foundationModel:
            return descriptor.title
        }
    }

    private func updateModelResource(
        id: String,
        detail: String,
        state: ModelResourceState,
        progress: Double? = nil,
        availableActions: Set<ModelResourceAction>? = nil
    ) {
        guard let index = modelResources.firstIndex(where: { $0.id == id }) else {
            return
        }

        var updatedResources = modelResources
        updatedResources[index] = updatedResources[index].updating(
            detail: detail,
            state: state,
            progress: progress,
            availableActions: availableActions
        )
        modelResources = updatedResources
    }

    private func markSpeechResourceIDReleased(_ id: String) {
        guard releasedSpeechResourceIDs.insert(id).inserted else {
            return
        }

        persistSettings()
    }

    private func clearReleasedSpeechResourceID(_ id: String) {
        guard releasedSpeechResourceIDs.remove(id) != nil else {
            return
        }

        persistSettings()
    }

    private func sortedModelResources(_ resources: [ModelResourceItem]) -> [ModelResourceItem] {
        resources.sorted { lhs, rhs in
            if lhs.kind.rawValue == rhs.kind.rawValue {
                let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if titleComparison == .orderedSame {
                    return lhs.id < rhs.id
                }
                return titleComparison == .orderedAscending
            }

            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private func systemSettingsDestination(
        for item: ModelResourceItem
    ) -> LanguageResourceSystemSettingsDestination {
        switch item.kind {
        case .speech:
            return .dictation
        case .translation:
            return .translationLanguages
        case .foundationModel:
            return .appleIntelligence
        }
    }

    func scheduleSelectedLanguageResourcePreparation(
        refreshTranslations: Bool = false,
        openSystemSettingsIfNeeded: Bool = false
    ) {
        guard isBootstrapping == false else {
            return
        }

        let requirements = selectedResourcePreparationRequirements()

        resourcePreparation.cancel()
        languageResourceStatuses = []

        resourcePreparation.replace { [weak self] in
            guard let self else {
                return
            }

            await self.prepareSelectedLanguageResources(
                speechLanguageIDs: requirements.speechLanguageIDs,
                translationPairs: requirements.translationPairs,
                openSystemSettingsIfNeeded: openSystemSettingsIfNeeded
            )

            guard Task.isCancelled == false,
                  refreshTranslations,
                  self.hasBlockingLanguageResourceStatuses == false else {
                return
            }

            self.refreshCaptionTranslations()
        }
    }

    func awaitSelectedLanguageResourcePreparationIfNeeded() async {
        if !resourcePreparation.isRunning {
            scheduleSelectedLanguageResourcePreparation()
        }

        await resourcePreparation.waitForCurrent()
    }

    var isPreparingSelectedLanguageResources: Bool {
        resourcePreparation.isRunning
            || languageResourceStatuses.contains(where: { $0.isError == false })
    }

    var hasBlockingLanguageResourceStatuses: Bool {
        languageResourceStatuses.contains(where: \.isError)
    }

    private func prepareSelectedLanguageResources(
        speechLanguageIDs: [String],
        translationPairs: [LanguagePairRequirement],
        openSystemSettingsIfNeeded: Bool
    ) async {
        var destinationsToOpen = Set<LanguageResourceSystemSettingsDestination>()
        await withTaskGroup(of: LanguageResourceSystemSettingsDestination?.self) { group in
            for speechLanguageID in speechLanguageIDs {
                group.addTask { [weak self] in
                    guard let self else {
                        return nil
                    }

                    return await self.prepareSpeechRecognitionResourceIfNeeded(for: speechLanguageID)
                }
            }

            for translationPair in translationPairs {
                group.addTask { [weak self] in
                    guard let self else {
                        return nil
                    }

                    return await self.prepareTranslationResourceIfNeeded(
                        from: translationPair.sourceLanguageID,
                        to: translationPair.targetLanguageID
                    )
                }
            }

            for await destination in group {
                if let destination {
                    destinationsToOpen.insert(destination)
                }
            }
        }

        guard resourcePreparation.acceptsUpdates, openSystemSettingsIfNeeded else {
            return
        }

        if destinationsToOpen.contains(.translationLanguages) {
            openSystemSettings(for: .translationLanguages)
        } else if let destination = destinationsToOpen.first {
            openSystemSettings(for: destination)
        }
    }

    private func prepareSpeechRecognitionResourceIfNeeded(
        for languageID: String
    ) async -> LanguageResourceSystemSettingsDestination? {
        guard #available(macOS 26.0, *) else {
            return nil
        }

        let title = localized(.speechTitleFormat, languageName(for: languageID))
        let statusID = "speech:\(languageID)"
        let requestedLocale = Locale(identifier: LanguageCatalog.speechLocaleIdentifier(for: languageID))

        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            upsertLanguageResourceStatus(
                LanguageResourceStatus(
                    id: statusID,
                    kind: .speech,
                    title: title,
                    detail: localized(.speechNotAvailableOnMacOS),
                    progress: nil,
                    isError: true
                )
            )
            return nil
        }

        let transcriber = makeSpeechTranscriber(locale: resolvedLocale)

        do {
            try await ensureSpeechAssetsReady(
                for: [transcriber],
                statusID: statusID,
                title: title
            )
            removeLanguageResourceStatus(id: statusID)
        } catch is CancellationError {
            removeLanguageResourceStatus(id: statusID)
        } catch {
            upsertLanguageResourceStatus(
                LanguageResourceStatus(
                    id: statusID,
                    kind: .speech,
                    title: title,
                    detail: localizedErrorDescription(error),
                    progress: nil,
                    isError: true
                )
            )
        }

        return nil
    }

    @available(macOS 26.0, *)
    private func ensureSpeechAssetsReady(
        for modules: [any SpeechModule],
        statusID: String,
        title: String
    ) async throws {
        let detail = localized(.downloadingSpeechResources)
        let maxPollingRetries = 150 // ~30 seconds at 200ms intervals
        var pollingRetryCount = 0

        while true {
            try Task.checkCancellation()

            switch await AssetInventory.status(forModules: modules) {
            case .installed:
                return
            case .unsupported:
                throw LanguageResourcePreparationError.unsupportedSpeechLanguage
            case .supported:
                if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    try await installSpeechAssets(
                        request,
                        statusID: statusID,
                        title: title,
                        detail: detail
                    )
                    return
                }

                pollingRetryCount += 1
                if pollingRetryCount > maxPollingRetries {
                    throw LanguageResourcePreparationError.speechDownloadTimedOut
                }

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .speech,
                        title: title,
                        detail: detail,
                        progress: nil,
                        isError: false
                    )
                )
            case .downloading:
                // Reset polling count — an active download is making progress
                pollingRetryCount = 0

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .speech,
                        title: title,
                        detail: detail,
                        progress: nil,
                        isError: false
                    )
                )
            @unknown default:
                pollingRetryCount += 1
                if pollingRetryCount > maxPollingRetries {
                    throw LanguageResourcePreparationError.speechDownloadTimedOut
                }

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .speech,
                        title: title,
                        detail: detail,
                        progress: nil,
                        isError: false
                    )
                )
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    @available(macOS 26.0, *)
    private func installSpeechAssets(
        _ request: AssetInstallationRequest,
        statusID: String,
        title: String,
        detail: String
    ) async throws {
        let progressTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while Task.isCancelled == false {
                let progress = normalizedProgressValue(request.progress.fractionCompleted)
                self.upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .speech,
                        title: title,
                        detail: detail,
                        progress: progress,
                        isError: false
                    )
                )

                do {
                    try await Task.sleep(nanoseconds: 120_000_000)
                } catch {
                    return
                }
            }
        }

        defer { progressTask.cancel() }

        try await request.downloadAndInstall()
    }

    private func prepareTranslationResourceIfNeeded(
        from sourceLanguageID: String,
        to targetLanguageID: String
    ) async -> LanguageResourceSystemSettingsDestination? {
        let title = localized(
            .translationTitleFormat,
            languageName(for: sourceLanguageID),
            languageName(for: targetLanguageID)
        )
        let statusID = "translation:\(sourceLanguageID)->\(targetLanguageID)"
        let downloadingDetail = localized(.downloadingTranslationResources)
        let waitingDetail = localized(.waitingTranslationResourcesInstalling)
        let manualDownloadDetail = localized(.manualTranslationDownloadDetail)
        let maxAttempts = 3
        var attemptCount = 0

        while Task.isCancelled == false {
            let availabilityStatus = await translationAvailabilityStatus(
                from: sourceLanguageID,
                to: targetLanguageID
            )

            switch availabilityStatus {
            case .unsupported:
                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                    id: statusID,
                    kind: .translation,
                    title: title,
                    detail: localized(.translationNotSupportedPairOnMacOS),
                    progress: nil,
                    isError: true
                )
                )
                return nil
            case .supported, .installed:
                attemptCount += 1
                if attemptCount > maxAttempts {
                    upsertLanguageResourceStatus(
                        LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: manualDownloadDetail,
                            progress: nil,
                            isError: true
                        )
                    )
                    return .translationLanguages
                }

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .translation,
                        title: title,
                        detail: availabilityStatus == .supported ? downloadingDetail : waitingDetail,
                        progress: nil,
                        isError: false
                    )
                )

                do {
                    try await prepareTranslationResourceWithTimeout(
                        from: sourceLanguageID,
                        to: targetLanguageID
                    )
                    removeLanguageResourceStatus(id: statusID)
                    return nil
                } catch is CancellationError {
                    removeLanguageResourceStatus(id: statusID)
                    return nil
                } catch {
                    if let error = error as? LanguageResourcePreparationError,
                       error == .translationDownloadTimedOut {
                        upsertLanguageResourceStatus(
                            LanguageResourceStatus(
                                id: statusID,
                                kind: .translation,
                                title: title,
                                detail: manualDownloadDetail,
                                progress: nil,
                                isError: true
                            )
                        )
                        return .translationLanguages
                    }

                    if let serviceError = error as? TranslationCoordinator.ServiceError {
                        upsertLanguageResourceStatus(
                            LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: serviceError.localizedDescription(languageID: resolvedInterfaceLanguageID),
                            progress: nil,
                            isError: true
                        )
                        )
                        return nil
                    }

                    let nsError = error as NSError
                    if nsError.domain == "TranslationErrorDomain", nsError.code == 14 {
                        upsertLanguageResourceStatus(
                            LanguageResourceStatus(
                                id: statusID,
                                kind: .translation,
                                title: title,
                                detail: manualDownloadDetail,
                                progress: nil,
                                isError: true
                            )
                        )
                        return .translationLanguages
                    }

                    let refreshedStatus = await translationAvailabilityStatus(
                        from: sourceLanguageID,
                        to: targetLanguageID
                    )

                    if refreshedStatus == .supported || refreshedStatus == .installed {
                        upsertLanguageResourceStatus(
                            LanguageResourceStatus(
                                id: statusID,
                                kind: .translation,
                                title: title,
                                detail: waitingDetail,
                                progress: nil,
                                isError: false
                            )
                        )

                        do {
                            try await Task.sleep(nanoseconds: 800_000_000)
                        } catch {
                            removeLanguageResourceStatus(id: statusID)
                            return nil
                        }

                        continue
                    }

                    upsertLanguageResourceStatus(
                        LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: localizedErrorDescription(error),
                            progress: nil,
                            isError: true
                        )
                    )
                    return nil
                }
            @unknown default:
                attemptCount += 1
                if attemptCount > maxAttempts {
                    upsertLanguageResourceStatus(
                        LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: manualDownloadDetail,
                            progress: nil,
                            isError: true
                        )
                    )
                    return .translationLanguages
                }

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .translation,
                        title: title,
                        detail: waitingDetail,
                        progress: nil,
                        isError: false
                    )
                )

                do {
                    try await Task.sleep(nanoseconds: 800_000_000)
                } catch {
                    removeLanguageResourceStatus(id: statusID)
                    return nil
                }
            }
        }

        removeLanguageResourceStatus(id: statusID)
        return nil
    }

    private func prepareTranslationResourceWithTimeout(
        from sourceLanguageID: String,
        to targetLanguageID: String
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [translationCoordinator] in
                try await translationCoordinator.prepareIfNeeded(
                    from: sourceLanguageID,
                    to: targetLanguageID
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw LanguageResourcePreparationError.translationDownloadTimedOut
            }

            let result: Void? = try await group.next()
            group.cancelAll()
            _ = result
        }
    }

    @available(macOS 26.0, *)
    private func makeSpeechTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    private func normalizedProgressValue(_ fractionCompleted: Double) -> Double? {
        guard fractionCompleted.isFinite, fractionCompleted >= 0 else {
            return nil
        }

        return min(max(fractionCompleted, 0), 1)
    }

    private func canonicalLocaleIdentifier(_ identifier: String) -> String {
        Locale(identifier: identifier).identifier.replacingOccurrences(of: "_", with: "-")
    }

    private func translationAvailabilityStatus(
        from sourceLanguageID: String,
        to targetLanguageID: String
    ) async -> LanguageAvailability.Status {
        guard #available(macOS 15.0, *) else {
            return .unsupported
        }

        let sourceLanguage = Locale.Language(identifier: sourceLanguageID)
        let targetLanguage = Locale.Language(identifier: targetLanguageID)
        let availability = LanguageAvailability()
        return await availability.status(from: sourceLanguage, to: targetLanguage)
    }

    private func upsertLanguageResourceStatus(_ status: LanguageResourceStatus) {
        guard resourcePreparation.acceptsUpdates else { return }
        if let existingIndex = languageResourceStatuses.firstIndex(where: { $0.id == status.id }) {
            languageResourceStatuses[existingIndex] = status
        } else {
            languageResourceStatuses.append(status)
        }

        languageResourceStatuses.sort { lhs, rhs in
            if lhs.kind.rawValue == rhs.kind.rawValue {
                return lhs.title < rhs.title
            }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private func removeLanguageResourceStatus(id: String) {
        guard resourcePreparation.acceptsUpdates else { return }
        languageResourceStatuses.removeAll { $0.id == id }
    }

    @discardableResult
    private func openSystemSettings(for destination: LanguageResourceSystemSettingsDestination) -> Bool {
        guard let url = URL(string: destination.urlString) else {
            return false
        }

        if NSWorkspace.shared.open(url) {
            activateSystemSettings()
            startExternalModelResourceRefreshMonitor()
            return true
        }

        guard let fallbackURL = URL(string: "x-apple.systempreferences:"),
              NSWorkspace.shared.open(fallbackURL) else {
            return false
        }

        activateSystemSettings()
        startExternalModelResourceRefreshMonitor()
        return true
    }

    private func activateSystemSettings() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .first?
                .activate(options: [.activateAllWindows])
        }
    }

    // MARK: - Draft handler

}

private enum LanguageResourcePreparationError: LocalizedError, AppLocalizableError {
    case unsupportedSpeechLanguage
    case speechDownloadTimedOut
    case translationDownloadTimedOut

    func localizedDescription(languageID: String) -> String {
        switch self {
        case .unsupportedSpeechLanguage:
            return AppLocalization.string(.speechResourcesNotSupportedOnMacOS, languageID: languageID)
        case .speechDownloadTimedOut:
            return AppLocalization.string(.speechResourceDownloadTimedOut, languageID: languageID)
        case .translationDownloadTimedOut:
            return AppLocalization.string(.translationResourceDownloadTimedOut, languageID: languageID)
        }
    }

    var errorDescription: String? {
        localizedDescription(languageID: "en")
    }
}

private enum LanguageResourceSystemSettingsDestination: Hashable {
    case dictation
    case translationLanguages
    case appleIntelligence

    var urlString: String {
        switch self {
        case .dictation:
            return "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation"
        case .translationLanguages:
            return "x-apple.systempreferences:com.apple.Localization-Settings.extension?translation"
        case .appleIntelligence:
            return "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        }
    }
}

private struct SpeechModelResourceInventory {
    let supportedLocaleIDs: Set<String>
    let installedLocaleIDs: Set<String>
    let reservedLocaleIDs: Set<String>
}


