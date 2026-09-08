import Foundation

enum SessionState: String, Codable {
    case starting
    case stopping
    case idle
    case running
    case error

    func displayName(in languageID: String) -> String {
        switch self {
        case .starting, .stopping:
            return AppLocalization.string(.wait, languageID: languageID)
        case .idle:
            return AppLocalization.string(.idle, languageID: languageID)
        case .running:
            return AppLocalization.string(.running, languageID: languageID)
        case .error:
            return AppLocalization.string(.error, languageID: languageID)
        }
    }
}
