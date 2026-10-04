import Foundation
import Observation

/// A verified open (managed notification, Live Activity) resolves a durable
/// Hermes coordinate on the host workspace. The visible shell navigates by its
/// own catalog, so the coordinate is handed across here and consumed once.
struct BighelpExternalSessionOpen: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// A durable Hermes coordinate verified by a native host.
        case stored(profileID: String, storedSessionID: String)
        /// A shell catalog session ID (bighelp Link notifications).
        case catalog(sessionID: String)
        /// A notification's chat by its reference, found in the saved chat list.
        case reference(profileID: String, sessionReference: String)
    }
    let id = UUID()
    let target: Target
}

@MainActor
@Observable
final class BighelpExternalSessionOpenCenter {
    static let shared = BighelpExternalSessionOpenCenter()
    init() {}
    private(set) var pending: BighelpExternalSessionOpen?

    func request(profileID: String, storedSessionID: String) {
        pending = BighelpExternalSessionOpen(target: .stored(profileID: profileID, storedSessionID: storedSessionID))
    }

    func request(profileID: String, sessionReference: String) {
        pending = BighelpExternalSessionOpen(target: .reference(profileID: profileID, sessionReference: sessionReference))
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
