import Foundation
import OSLog

/// One Console capture should explain a card that vanished or never showed. Every line is a fixed code,
/// plus at most a count, an HTTP status or a system error's domain and code. Never an ID, a title or text.
enum BighelpLiveActivityLog {
    enum Code: String {
        case cardStarted = "card-started"
        case cardStartFailed = "card-start-failed"
        case cardRequestDisabled = "card-request-disabled"
        case cardRequestFailed = "card-request-failed"
        case cardEnded = "card-ended"
        case cardDismissed = "card-dismissed"
        case cardEnding = "card-ending"
        case cardInvalidated = "card-invalidated"
        case finishedCardsDismissed = "finished-cards-dismissed"
        case entryRepaired = "entry-repaired"
        case entryPruned = "entry-pruned"
        case driverRetired = "driver-retired"
        case ownerReaped = "owner-reaped"
        case registrationConfirmed = "registration-confirmed"
        case registrationFailed = "registration-failed"
        case registrationRefused = "registration-refused-local-control"
        case registrationUnfreezeNotSaved = "registration-unfreeze-not-saved"
        case revocationConfirmed = "revocation-confirmed"
        case revocationGone = "revocation-already-gone"
        case revocationFailed = "revocation-failed"
        case recoveryOwnerFailed = "recovery-owner-failed"
    }

    private static let logger = Logger(subsystem: "app.loopdy.mobile", category: "LiveActivity")

    static func note(_ code: Code) {
        logger.info("\(code.rawValue, privacy: .public)")
    }

    static func note(_ code: Code, count: Int) {
        logger.info("\(code.rawValue, privacy: .public) count=\(count, privacy: .public)")
    }

    static func failed(_ code: Code, _ error: Error) {
        logger.error("\(code.rawValue, privacy: .public) reason=\(reason(error), privacy: .public)")
    }

    /// `Activity.request` throws for reasons the user can fix (Live Activities off) and ones they can't
    /// (the system's limit). The error's domain and code tell them apart.
    static func requestFailed(_ error: Error) {
        let system = error as NSError
        logger.error("\(Code.cardRequestFailed.rawValue, privacy: .public) domain=\(system.domain, privacy: .public) code=\(system.code, privacy: .public)")
    }

    /// A fixed label for an error: never its message, which can carry IDs or paths.
    static func reason(_ error: Error) -> String {
        switch error {
        case is CancellationError: return "cancelled"
        case BighelpLinkAPIError.requestFailed(let status, _): return "http-\(status)"
        case is BighelpLinkAPIError: return "link-invalid"
        case let registration as BighelpManagedLiveActivityRegistrar.RegistrationError: return "registration-\(registration)"
        default:
            let system = error as NSError
            return "\(system.domain)/\(system.code)"
        }
    }
}
