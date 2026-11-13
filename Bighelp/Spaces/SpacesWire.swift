import CryptoKit
import Foundation

/// Spaces (plugin feature `native-spaces-v1`, the plugin's docs/SPACES.md): live panels on Today
/// that a bot makes on the person's computer. Each is a native card the app draws, an HTML app
/// opened from it, and a routine on the computer that updates both. The computer is the truth;
/// the phone keeps a copy so Today draws at once.
enum SpacesWire {
    static let feature = "native-spaces-v1"
    /// The chat card element a bot's `bighelp_draft_space` makes, with Add to Today.
    static let type = "space_draft"
    /// What the speaker note adds to `renders` when the plugin lists the feature.
    static let renders = [type]

    static let maximumTitleLength = 60
    static let maximumDescriptionLength = 240
    static let maximumUpdatesLength = 60
    /// Live spaces one bot can have; the plugin refuses more (`spaces_full`).
    static let maximumLiveSpacesPerBot = 24
    /// Bots one `spaces/list` names, and card hashes it carries.
    static let maximumAgentsPerList = 64
    static let maximumKnownCards = 512
    /// Spaces read from one answer; more are left out.
    static let maximumSpacesPerAnswer = maximumAgentsPerList * maximumLiveSpacesPerBot
    /// Today's order is by `position`; a reorder places spaces this far apart.
    static let positionStep: Double = 1_024
    /// The plugin refuses positions further from zero.
    static let maximumPositionMagnitude: Double = 1e12
    /// Spaces whose cards a list left out (`cardOmitted`) read with `get` in one refresh.
    static let maximumCardReadsPerLoad = 24
    /// The phone's copy of one computer's spaces; cards are left out of a bigger copy.
    static let maximumCacheBytes = 6 * 1_024 * 1_024
    /// Today reads its computers at most this often while it shows.
    static let refreshInterval: Duration = .seconds(60)
    /// `routine.problem` when the bot changed the script after the person added the space.
    static let scriptChangedProblem = "script_changed"

    /// `s_` and 32 lowercase hex digits, as the plugin makes them.
    static func isSpaceID(_ value: String) -> Bool {
        let digits = value.utf8.dropFirst(2)
        return value.hasPrefix("s_") && digits.count == 32
            && digits.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// A bot's id as the routes take it: `^[a-z0-9][a-z0-9_-]{0,63}$`.
    static func isAgentID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, (1...64).contains(bytes.count),
              (48...57).contains(first) || (97...122).contains(first) else { return false }
        return bytes.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    /// A mutation's retry key: one per request. Sent again only with the very same request (the
    /// client's one retry, a change or delete the computer hasn't confirmed); the plugin refuses an
    /// `operationId` it saw with another operation, space or body (`invalid_request`).
    static func newOperationID() -> String { UUID().uuidString.lowercased() }

    /// RFC 3339, with or without fractions of a second; nil for anything else.
    static func date(_ value: BighelpJSONValue?) -> Date? {
        guard let text = value?.string else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// With milliseconds, so the phone's copy keeps the computer's times exactly.
    static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The plugin's six routes (`POST /native/spaces/{operation}`).
enum SpacesOperation: String, CaseIterable, Sendable {
    case list, get, add, update, refresh, delete

    var workspaceOperation: WorkspaceOperation {
        switch self {
        case .list: .spacesList
        case .get: .spacesGet
        case .add: .spacesAdd
        case .update: .spacesUpdate
        case .refresh: .spacesRefresh
        case .delete: .spacesDelete
        }
    }

    /// Mutations carry an `operationId`, so a retry after a lost answer is never done twice.
    var isMutation: Bool { self != .list && self != .get }
}
