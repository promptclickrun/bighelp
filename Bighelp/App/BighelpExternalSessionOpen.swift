import Foundation
import Observation

/// A verified open (managed notification, Live Activity) resolves a durable
/// Hermes coordinate on the host workspace. The visible shell navigates by its
/// own catalog, so the coordinate is handed across here and consumed once.
struct BighelpExternalSessionOpen: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// A durable Hermes coordinate verified by a native host. A Live Activity names its
        /// computer too (`hostID`): only that computer's saved chats may answer for it.
        case stored(hostID: UUID?, profileID: String, storedSessionID: String)
        /// A shell catalog session ID (bighelp Link notifications).
        case catalog(sessionID: String)
        /// A notification's chat by its reference, found in the saved chat list. A scheduled run's
        /// alert can name its job's chat or the job instead (`BighelpScheduledAlertLinks`).
        case reference(profileID: String, sessionReference: String, isScheduledRun: Bool)
    }
    /// The tap changed the computer in use to reach this chat. `from` is the one it left, nil when
    /// none was selected.
    struct HostSwitch: Equatable, Sendable {
        let from: UUID?
    }
    let id = UUID()
    let target: Target
    var switchedHost: HostSwitch? = nil
}

/// A tap that switched computers has to wait for the new one before it opens anything. Opened
/// while that computer was still connecting, the chat could fail to prepare and "This session
/// could not be prepared" showed over the chat that then opened anyway.
enum ExternalOpenHostWait {
    enum Step: Equatable {
        case openNow
        case keepWaiting
        case giveUp
    }

    static func step(_ open: BighelpExternalSessionOpen, hostIsReady: Bool, timedOut: Bool) -> Step {
        guard open.switchedHost != nil, !hostIsReady else { return .openNow }
        return timedOut ? .giveUp : .keepWaiting
    }

    static func message(unreachable: String, stillOn: String?) -> String {
        guard let stillOn else { return "Couldn't reach \(unreachable). Check that it's on, then try again." }
        return FleetSwitchFallback.message(unreachable: unreachable, stillOn: stillOn)
    }
}

@MainActor
@Observable
final class BighelpExternalSessionOpenCenter {
    static let shared = BighelpExternalSessionOpenCenter()
    init() {}
    private(set) var pending: BighelpExternalSessionOpen?

    func request(hostID: UUID? = nil, profileID: String, storedSessionID: String,
                 switchedHost: BighelpExternalSessionOpen.HostSwitch? = nil) {
        pending = BighelpExternalSessionOpen(target: .stored(hostID: hostID, profileID: profileID,
                                                            storedSessionID: storedSessionID),
                                             switchedHost: switchedHost)
    }

    func request(profileID: String, sessionReference: String, isScheduledRun: Bool = false,
                 switchedHost: BighelpExternalSessionOpen.HostSwitch? = nil) {
        pending = BighelpExternalSessionOpen(target: .reference(profileID: profileID, sessionReference: sessionReference,
                                                               isScheduledRun: isScheduledRun),
                                             switchedHost: switchedHost)
    }

    func request(catalogSessionID: String) {
        pending = BighelpExternalSessionOpen(target: .catalog(sessionID: catalogSessionID))
    }

    func consume(_ open: BighelpExternalSessionOpen) -> Bool {
        guard pending == open else { return false }
        pending = nil
        return true
    }
}
