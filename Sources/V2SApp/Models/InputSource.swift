import Foundation

enum InputSourceCategory: String, CaseIterable, Codable {
    case application
    case microphone

    func displayName(in languageID: String) -> String {
        switch self {
        case .application:
            return AppLocalization.string(.application, languageID: languageID)
        case .microphone:
            return AppLocalization.string(.microphone, languageID: languageID)
        }
    }
}

struct InputSource: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let detail: String
    let category: InputSourceCategory

    static let allInternalSourcesID = "app:all-internal-sources"

    static let allInternalSources = InputSource(
        id: allInternalSourcesID,
        name: "All Internal Sources",
        detail: "all-internal-sources",
        category: .application
    )

    static let preview = InputSource(
        id: "preview",
        name: AppLocalization.string(.previewSource, languageID: "en"),
        detail: "preview",
        category: .microphone
    )

    var isAllInternalSources: Bool {
        id == Self.allInternalSourcesID
    }

    func displayName(in languageID: String) -> String {
        if isAllInternalSources {
            return AppLocalization.string(.allInternalSources, languageID: languageID)
        }

        return name
    }

    static func migratingLegacyApplicationSourceIDs(_ sourceIDs: Set<String>) -> Set<String> {
        let legacyApplicationSourceIDs = sourceIDs.filter {
            $0.hasPrefix("app:") && $0 != allInternalSourcesID
        }
        guard legacyApplicationSourceIDs.isEmpty == false else {
            return sourceIDs
        }

        var migratedSourceIDs = sourceIDs.subtracting(legacyApplicationSourceIDs)
        migratedSourceIDs.insert(allInternalSourcesID)
        return migratedSourceIDs
    }

    static func migratingLegacyApplicationSourceID(_ sourceID: String?) -> String? {
        guard let sourceID,
              sourceID.hasPrefix("app:"),
              sourceID != allInternalSourcesID else {
            return sourceID
        }

        return allInternalSourcesID
    }

    static func migratingLegacyApplicationSourceValues<Value>(
        _ values: [String: Value],
        preferredSourceID: String?
    ) -> [String: Value] {
        let legacySourceIDs = values.keys
            .filter { $0.hasPrefix("app:") && $0 != allInternalSourcesID }
            .sorted()
        guard legacySourceIDs.isEmpty == false else {
            return values
        }

        let migratedValue = values[allInternalSourcesID]
            ?? preferredSourceID.flatMap { values[$0] }
            ?? legacySourceIDs.compactMap { values[$0] }.first
        var migratedValues = values
        for sourceID in legacySourceIDs {
            migratedValues.removeValue(forKey: sourceID)
        }
        if let migratedValue {
            migratedValues[allInternalSourcesID] = migratedValue
        }
        return migratedValues
    }
}
