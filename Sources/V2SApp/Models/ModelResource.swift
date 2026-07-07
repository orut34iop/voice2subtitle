import Foundation

enum ModelResourceKind: Int, CaseIterable {
    case speech = 0
    case translation = 1
    case foundationModel = 2
}

enum ModelResourceState: String {
    case checking
    case downloadable
    case downloading
    case removing
    case installed
    case systemManaged
    case unsupported
    case error
}

enum ModelResourceAction: String, CaseIterable {
    case download
    case pause
    case remove
    case openSystemSettings
}

struct ModelResourceItem: Identifiable, Equatable {
    let id: String
    let kind: ModelResourceKind
    let title: String
    let detail: String
    let state: ModelResourceState
    let progress: Double?
    let availableActions: Set<ModelResourceAction>
    let sourceLanguageID: String?
    let targetLanguageID: String?

    var showsIndeterminateProgress: Bool {
        progress == nil && state == .downloading && kind == .speech
    }

    func updating(
        detail: String,
        state: ModelResourceState,
        progress: Double? = nil,
        availableActions: Set<ModelResourceAction>? = nil
    ) -> ModelResourceItem {
        ModelResourceItem(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            state: state,
            progress: progress,
            availableActions: availableActions ?? Self.availableActions(
                for: kind,
                state: state,
                isUserInitiatedDownload: false
            ),
            sourceLanguageID: sourceLanguageID,
            targetLanguageID: targetLanguageID
        )
    }

    static func availableActions(
        for kind: ModelResourceKind,
        state: ModelResourceState,
        isUserInitiatedDownload: Bool
    ) -> Set<ModelResourceAction> {
        switch state {
        case .checking, .removing, .unsupported:
            return []
        case .installed:
            return [.remove]
        case .downloadable:
            return [.download]
        case .downloading:
            if kind == .speech, isUserInitiatedDownload {
                return [.pause]
            }
            return kind == .foundationModel ? [.openSystemSettings] : []
        case .systemManaged:
            return [.openSystemSettings]
        case .error:
            switch kind {
            case .speech:
                return [.download]
            case .translation, .foundationModel:
                return [.openSystemSettings]
            }
        }
    }
}

struct ModelResourceDescriptor: Identifiable, Equatable {
    let id: String
    let kind: ModelResourceKind
    let title: String
    let sourceLanguageID: String?
    let targetLanguageID: String?
}

enum ModelResourceCatalog {
    static let foundationModelResourceID = "foundation:system-language-model"

    static func speechDescriptors(
        options: [LanguageOption],
        localizedName: (String) -> String
    ) -> [ModelResourceDescriptor] {
        options
            .map { option in
                ModelResourceDescriptor(
                    id: speechResourceID(languageID: option.id),
                    kind: .speech,
                    title: localizedName(option.id),
                    sourceLanguageID: option.id,
                    targetLanguageID: nil
                )
            }
            .sorted { lhs, rhs in
                localizedDescriptorSort(lhs, rhs)
            }
    }

    static func translationDescriptors(
        sourceOptions: [LanguageOption],
        targetOptions: [LanguageOption],
        supportedLanguageIDs: Set<String>,
        localizedName: (String) -> String
    ) -> [ModelResourceDescriptor] {
        var descriptors: [ModelResourceDescriptor] = []
        for source in sourceOptions where supportedLanguageIDs.contains(normalizedLanguageID(source.id)) {
            for target in targetOptions where supportedLanguageIDs.contains(normalizedLanguageID(target.id)) {
                guard normalizedLanguageID(source.id) != normalizedLanguageID(target.id) else {
                    continue
                }

                descriptors.append(
                    ModelResourceDescriptor(
                        id: translationResourceID(sourceLanguageID: source.id, targetLanguageID: target.id),
                        kind: .translation,
                        title: "\(localizedName(source.id)) -> \(localizedName(target.id))",
                        sourceLanguageID: source.id,
                        targetLanguageID: target.id
                    )
                )
            }
        }

        return descriptors.sorted { lhs, rhs in
            localizedDescriptorSort(lhs, rhs)
        }
    }

    static func foundationModelDescriptor(title: String) -> ModelResourceDescriptor {
        ModelResourceDescriptor(
            id: foundationModelResourceID,
            kind: .foundationModel,
            title: title,
            sourceLanguageID: nil,
            targetLanguageID: nil
        )
    }

    static func speechResourceID(languageID: String) -> String {
        "speech:\(languageID)"
    }

    static func translationResourceID(sourceLanguageID: String, targetLanguageID: String) -> String {
        "translation:\(sourceLanguageID)->\(targetLanguageID)"
    }

    static func normalizedLanguageID(_ languageID: String) -> String {
        Locale.Language(identifier: languageID).minimalIdentifier
    }

    private static func localizedDescriptorSort(
        _ lhs: ModelResourceDescriptor,
        _ rhs: ModelResourceDescriptor
    ) -> Bool {
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
