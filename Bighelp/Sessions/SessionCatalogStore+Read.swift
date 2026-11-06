import Foundation

/// What a chat showed when it was marked read. A chat is marked again only once this changes.
struct SessionReadActivity: Equatable, Sendable {
    var turnsEnded = 0
    var messageCount = 0
    var lastMessageID: String?
}

/// The read marks a catalog keeps while chats are read (`SessionCatalogStore.noteRead`).
struct SessionReadStamps {
    /// What each chat showed at its last mark.
    var stamped: [String: SessionReadActivity] = [:]
    /// Chats on screen while the app is in front.
    var reading: Set<String> = []
    var inFlight: Set<String> = []
    /// A moment that came while the chat's mark was on its way: checked again after it.
    var waiting: [String: SessionReadActivity] = [:]
}

/// Hermes' read state (#862). Hermes counts a chat unread once anything happens in it after its
/// read watermark (`last_read_at`): the person's own messages and the agent's replies alike. Only a
/// client moves the watermark, and a chat no client ever marked counts as read, so it can't become
/// unread until one does. So the app marks a chat read each time the person reads it: when it
/// shows, when a turn ends while it shows, and when it stops showing (`BighelpVisibleChats`).
extension SessionCatalogStore {
    /// Whether this computer keeps read state: its chat rows say `unread`.
    var tracksReadState: Bool { records.contains { $0.isUnread != nil } }

    /// The person is reading the chat (`reading`), or just stopped. `activity` is what it showed:
    /// a mark goes to Hermes unless this chat was marked here at that same point and Hermes still
    /// lists it read, and one goes at a time.
    func noteRead(id: String, activity: SessionReadActivity, reading: Bool) {
        if reading { readStamps.reading.insert(id) } else { readStamps.reading.remove(id) }
        // A chat Hermes hasn't saved yet refuses the mark; its next moment tries again.
        guard let record = session(id: id), !record.isLocalPresentationDraft,
              record.isUnread != nil || tracksReadState else { return }
        guard record.isUnread == true || readStamps.stamped[id] != activity else { return }
        guard !readStamps.inFlight.contains(id) else {
            readStamps.waiting[id] = activity
            return
        }
        readStamps.inFlight.insert(id)
        let account = accountGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.setUnread(record, unread: false)
                guard account == self.accountGeneration else { return }
                self.readStamps.stamped[id] = activity
                self.showRead(id: id)
            } catch {
                // Not marked: the chat's next read moment tries again.
            }
            guard account == self.accountGeneration else { return }
            self.readStamps.inFlight.remove(id)
            if let next = self.readStamps.waiting.removeValue(forKey: id) {
                self.noteRead(id: id, activity: next, reading: self.readStamps.reading.contains(id))
            }
        }
    }

    /// A list that says a chat on screen is unread is about what the person is looking at: it shows
    /// read, and the chat's next read moment marks it so on Hermes.
    func applyingReadState(to incoming: [SessionRecord]) -> [SessionRecord] {
        guard !readStamps.reading.isEmpty else { return incoming }
        return incoming.map { record in
            guard record.isUnread == true, readStamps.reading.contains(record.id) else { return record }
            readStamps.stamped[record.id] = nil
            var read = record
            read.isUnread = false
            return read
        }
    }
}
