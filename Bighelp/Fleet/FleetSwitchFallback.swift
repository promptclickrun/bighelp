import Foundation

/// When an agent tapped on another computer can't be opened because that computer doesn't
/// answer: the app goes back to the computer that worked instead of staying on the dead one.
enum FleetSwitchFallback {
    /// Long enough for a slow network to connect; a computer that's off fails sooner.
    static let timeout: Duration = .seconds(20)

    /// Still the tap being waited for: nothing else was tapped or picked since.
    static func isWaiting(for hostID: UUID, pending: UUID?, selected: UUID?) -> Bool {
        pending == hostID && selected == hostID
    }

    static func shouldReturn(ready: Bool, waitingFor hostID: UUID, pending: UUID?, selected: UUID?) -> Bool {
        !ready && isWaiting(for: hostID, pending: pending, selected: selected)
    }

    static func message(unreachable: String, stillOn: String) -> String {
        "Couldn't reach \(unreachable). You're still on \(stillOn)."
    }
}
