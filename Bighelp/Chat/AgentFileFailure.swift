import Foundation
import OSLog

/// Why files an agent sent didn't reach this device. The message shows it in
/// plain words, with Try again, in place of the loading tiles: a tile never
/// stays on its loader after the app has stopped trying.
enum AgentFileFailure: String, Codable, Equatable, Sendable {
    /// The computer didn't answer, after a few tries.
    case unreachable
    /// The computer's bighelp plugin has no attachment route, and Hermes' own
    /// reads only reach its caches and the working folder.
    case updatePlugin
    /// The file isn't on the computer anymore.
    case missing
    /// The computer won't share it: its delivery rules, or this chat never sent it.
    case refused
    /// Bigger than this device keeps for a message.
    case tooBig
    /// The bytes came, but they aren't the picture or file they say they are.
    case unreadable
    /// Nothing finished the load in time (`AgentFileLoad.stallAfter`).
    case stalled
    case unknown

    var reason: String {
        switch self {
        case .unreachable: String(localized: "Your computer didn't answer.")
        case .updatePlugin: String(localized: "Update the bighelp plugin on your computer to see it.")
        case .missing: String(localized: "It's no longer on your computer.")
        case .refused: String(localized: "Your computer didn't share it.")
        case .tooBig: String(localized: "It's too big to show here.")
        case .unreadable: String(localized: "bighelp can't open it.")
        case .stalled: String(localized: "It's taking too long.")
        case .unknown: String(localized: "Something went wrong.")
        }
    }

    /// The plugin's word for a file it didn't send (`attachments/resolve`, `unavailable`).
    init(pluginReason: String) {
        switch pluginReason {
        case "missing": self = .missing
        case "refused": self = .refused
        case "too_large": self = .tooBig
        default: self = .unknown
        }
    }

    /// What a failed load says, from the error that ended it.
    init(_ error: any Error) {
        switch error {
        case let error as AgentFileLoadError: self = error.failure
        case is URLError: self = .unreachable
        case ChatAttachmentError.invalidSize: self = .tooBig
        case let error as WorkspaceClientError:
            switch error {
            case .transportUnavailable, .ownerChanged: self = .unreachable
            case .unavailable: self = .updatePlugin
            case .capacityExceeded: self = .tooBig
            case .rejected(let code, _) where code == "attachment_unavailable": self = .missing
            case .rejected(let code, _) where code == "attachments_unavailable": self = .updatePlugin
            case .rejected(let code, _) where code == "profile_not_found": self = .refused
            default: self = .unknown
            }
        case let error as DirectHermesError:
            switch error {
            case .notConnected, .disconnected, .timedOut, .connectionFailed, .serverUnavailable: self = .unreachable
            case .messageTooLarge: self = .tooBig
            default: self = .unknown
            }
        default: self = .unknown
        }
    }
}

/// A file load that ended without the file, and why.
struct AgentFileLoadError: Error, Equatable {
    let failure: AgentFileFailure
}

enum AgentFileLoad {
    /// A loading tile with nothing finishing it this long shows that it stalled, with Try
    /// again. Longer than the retries of a chat that keeps its connection.
    static let stallAfter: Duration = .seconds(90)
    /// Counts and reasons only: never a path, a file name or a chat.
    static let log = Logger(subsystem: "app.loopdy.mobile", category: "ChatFiles")
}
