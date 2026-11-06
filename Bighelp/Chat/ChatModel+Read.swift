import Foundation

/// Marking the chat read on Hermes while the person reads it (#862, `SessionCatalogStore.noteRead`).
/// `BighelpVisibleChats` says when: the chat shows, the app comes back to it, or it stops showing.
extension ChatModel {
    /// What the chat shows now, so a chat read again with nothing new isn't marked twice.
    var readActivity: SessionReadActivity {
        SessionReadActivity(turnsEnded: turnsEnded, messageCount: items.count, lastMessageID: items.last?.id)
    }

    /// The person is reading the chat (`reading`), or just stopped.
    func noteRead(reading: Bool) {
        if !reading {
            readSettleTask?.cancel()
            readSettleTask = nil
        }
        onRead?(readActivity, reading)
    }

    /// A turn ended: once Hermes has saved its last rows, the chat on screen is read up to there.
    /// Turns that end close together send one mark.
    func readTurnEnded() {
        turnsEnded &+= 1
        guard onRead != nil, BighelpVisibleChats.shared.isReading(self) else { return }
        readSettleTask?.cancel()
        let delay = readSettleDelay
        readSettleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.readSettleTask = nil
            guard BighelpVisibleChats.shared.isReading(self) else { return }
            self.noteRead(reading: true)
        }
    }
}
