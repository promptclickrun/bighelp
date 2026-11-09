import Foundation
import Observation

/// Sends Thinking levels one at a time, keeping only the newest. The chosen level shows at once
/// (`pendingLevel`) and gives way to what the chat holds once the computer answers; a refused level
/// clears the same way, so the control falls back with the reason beside it.
/// Adapted from hermex (MIT).
@MainActor @Observable
final class ThinkingLevelSender {
    private(set) var pendingLevel: String?
    private(set) var isSending = false

    /// A level asked for while another is out waits, and only the newest goes. `send` answers
    /// whether the computer took the level.
    func request(_ level: String, send: @escaping @MainActor (String) async -> Bool) {
        pendingLevel = level
        guard !isSending else { return }
        isSending = true
        Task {
            var sent: String?
            while let next = pendingLevel, next != sent {
                sent = next
                _ = await send(next)
            }
            isSending = false
            pendingLevel = nil
        }
    }
}
