import Foundation

/// The shares in one chat on their way from its message box to Hermes (#922).
///
/// A share is in the box (`inBox`), or in a message that left it (`messages`). Each such message
/// gets an id of its own when it leaves the box, never reused, and only an outcome naming that id,
/// or its row, moves it on: dispatched to Hermes, admitted, definitely refused, unknown, back in the
/// box, waiting to be tried again, or retired with its chat. Every step returns what to save
/// (`Effect`); nothing here deletes a share, and only `accepted` lets its saved copy go. A
/// `.sending` effect must be saved before the message goes to Hermes, or the message goes back in
/// the box instead. Foundation only: the app's chat drives it, and its tests run anywhere.
struct PendingShareLedger: Equatable, Sendable {
    struct Held: Equatable, Sendable {
        let share: PendingShare
        /// The draft attachment each of its files is now, by the file's index in the share: set as
        /// each file lands, a retry or a new big file copy too.
        var files: [Int: String] = [:]

        var id: String { share.id }
    }

    struct Message: Equatable, Sendable {
        let id: UUID
        var messageID: String
        var shares: [Held]
        var state: PendingShareSubmission.State
    }

    enum Release: Equatable, Sendable {
        /// The person took it out of the box, or removed its waiting message.
        case removed
        /// Hermes definitely didn't take it, and it isn't back in the box.
        case refused
        /// Its chat closed for another computer or account before it went.
        case retired
    }

    enum Effect: Equatable, Sendable {
        /// In the message box, not sent.
        case inBox(String)
        /// In this message. A `.sending` one is saved before the message goes, or it doesn't go.
        case submission(String, PendingShareSubmission)
        /// Hermes took the message: the saved copy is spent.
        case accepted(String, PendingShareSubmission)
        /// Out of this chat, not sent, kept.
        case released(String, Release)
    }

    let conversationID: String
    private(set) var inBox: [Held] = []
    /// Going into the box: its files are still being read in.
    private(set) var placing: [String: Held] = [:]
    private(set) var messages: [Message] = []

    init(conversationID: String) {
        self.conversationID = conversationID
    }

    func holds(_ shareID: String) -> Bool {
        placing[shareID] != nil || inBox.contains { $0.id == shareID }
            || messages.contains { $0.shares.contains { $0.id == shareID } }
    }

    var isEmpty: Bool { inBox.isEmpty && placing.isEmpty && messages.isEmpty }

    func message(_ id: UUID) -> Message? { messages.first { $0.id == id } }

    func message(row messageID: String) -> Message? { messages.first { $0.messageID == messageID } }

    // MARK: - Into the box

    /// False when this chat has it already.
    mutating func beginPlacing(_ share: PendingShare) -> Bool {
        guard !holds(share.id) else { return false }
        placing[share.id] = Held(share: share)
        return true
    }

    /// File `index` of the share is now draft attachment `attachmentID`: when it first lands, and
    /// again whenever Try again brings it in.
    mutating func fileLanded(shareID: String, index: Int, attachmentID: String) {
        if placing[shareID] != nil { placing[shareID]?.files[index] = attachmentID }
        if let at = inBox.firstIndex(where: { $0.id == shareID }) { inBox[at].files[index] = attachmentID }
    }

    /// Every file is in, or shows as didn't attach: it's in the box.
    mutating func finishPlacing(_ shareID: String) -> [Effect] {
        guard let held = placing.removeValue(forKey: shareID) else { return [] }
        inBox.append(held)
        return [.inBox(shareID)]
    }

    /// The chat moved on before every file was in; the share is still saved.
    mutating func cancelPlacing(_ shareID: String) {
        placing[shareID] = nil
    }

    /// After a change the person made in the box (not a send, a retry or an import): a share the
    /// box holds nothing of now leaves it, kept and put off. Never deletes.
    mutating func reviewBox(text: String, attachmentIDs: Set<String>, failedNames: Set<String>) -> [Effect] {
        var effects: [Effect] = []
        inBox.removeAll { held in
            let failed = held.share.files.contains { failedNames.contains($0.name) }
            guard !failed, !held.share.isCarried(byText: text, attachmentIDs: attachmentIDs,
                                                 landedIDs: Set(held.files.values)) else { return false }
            effects.append(.released(held.id, .removed))
            return true
        }
        return effects
    }

    // MARK: - Out in a message

    /// The box left as message `messageID`. A share it still holds any of goes with it, staged (in
    /// the chat, not yet with Hermes); the others were taken out by the person and stay saved.
    mutating func leaveBox(as messageID: String, text: String, attachmentIDs: Set<String>, now: Date,
                           id: UUID = UUID()) -> [Effect] {
        guard !inBox.isEmpty else { return [] }
        var effects: [Effect] = []
        var carried: [Held] = []
        for held in inBox {
            if held.share.isCarried(byText: text, attachmentIDs: attachmentIDs, landedIDs: Set(held.files.values)) {
                carried.append(held)
            } else {
                effects.append(.released(held.id, .removed))
            }
        }
        inBox = []
        guard !carried.isEmpty else { return effects }
        let message = Message(id: id, messageID: messageID, shares: carried, state: .staged)
        messages.append(message)
        return effects + carried.map { .submission($0.id, submission(message, now: now)) }
    }

    /// The message goes to Hermes now, under `newID` when it took a new row. Its `.sending` effects
    /// are saved before it goes; when they can't be, `returnToBox` instead of sending.
    mutating func dispatch(_ messageID: String, as newID: String? = nil, now: Date) -> [Effect] {
        guard let at = messages.firstIndex(where: { $0.messageID == messageID }),
              messages[at].state == .staged || messages[at].state == .sending else { return [] }
        if let newID { messages[at].messageID = newID }
        messages[at].state = .sending
        let message = messages[at]
        return message.shares.map { .submission($0.id, submission(message, now: now)) }
    }

    /// A staged message took a new row as it went (`ChatModel.takeStagedItem`).
    mutating func rename(_ messageID: String, to newID: String) {
        guard let at = messages.firstIndex(where: { $0.messageID == messageID }) else { return }
        messages[at].messageID = newID
    }

    /// Hermes took message `id`: named by the client's journal entry for it, or by the send that returned.
    mutating func admitted(_ id: UUID, now: Date) -> [Effect] {
        guard let at = messages.firstIndex(where: { $0.id == id }) else { return [] }
        let message = messages.remove(at: at)
        return message.shares.map { .accepted($0.id, submission(message, now: now).with(.accepted, at: now)) }
    }

    /// Hermes took the message with this row, found in its history (a reference's receipt).
    mutating func admitted(row messageID: String, now: Date) -> [Effect] {
        guard let id = message(row: messageID)?.id else { return [] }
        return admitted(id, now: now)
    }

    /// Hermes definitely didn't take it, and it isn't back in the box: kept, not sent.
    mutating func refused(row messageID: String) -> [Effect] {
        guard let at = messages.firstIndex(where: { $0.messageID == messageID }) else { return [] }
        return messages.remove(at: at).shares.map { .released($0.id, .refused) }
    }

    /// Its send ended without an answer either way. It stays known here by its id, so a later
    /// answer (the history of a reference message) still settles it.
    mutating func unknown(row messageID: String, now: Date) -> [Effect] {
        guard let at = messages.firstIndex(where: { $0.messageID == messageID }),
              messages[at].state == .sending else { return [] }
        messages[at].state = .unconfirmed
        let message = messages[at]
        return message.shares.map { .submission($0.id, submission(message, now: now)) }
    }

    /// It failed before Hermes had it and waits in the chat to be tried again (files over 8 MB).
    mutating func waits(row messageID: String, now: Date) -> [Effect] {
        guard let at = messages.firstIndex(where: { $0.messageID == messageID }),
              messages[at].state == .sending else { return [] }
        messages[at].state = .staged
        let message = messages[at]
        return message.shares.map { .submission($0.id, submission(message, now: now)) }
    }

    /// These messages are back in the box unsent, and their shares with them.
    mutating func returnToBox(_ messageIDs: [String]) -> [Effect] {
        var effects: [Effect] = []
        for messageID in messageIDs {
            guard let at = messages.firstIndex(where: { $0.messageID == messageID }),
                  messages[at].state != .unconfirmed else { continue }
            let message = messages.remove(at: at)
            inBox += message.shares
            effects += message.shares.map { .inBox($0.id) }
        }
        return effects
    }

    /// The person removed a waiting message.
    mutating func removed(row messageID: String) -> [Effect] {
        guard let at = messages.firstIndex(where: { $0.messageID == messageID }),
              messages[at].state == .staged else { return [] }
        return messages.remove(at: at).shares.map { .released($0.id, .removed) }
    }

    /// The chat closes for another computer or account. Nothing is deleted: a share not yet with
    /// Hermes is offered again, and one that may have reached it stays marked so.
    mutating func retire(now: Date) -> [Effect] {
        var effects = inBox.map { Effect.released($0.id, .retired) }
        for message in messages {
            switch message.state {
            case .staged:
                effects += message.shares.map { .released($0.id, .retired) }
            case .sending:
                let unconfirmed = Message(id: message.id, messageID: message.messageID, shares: message.shares,
                                          state: .unconfirmed)
                effects += message.shares.map { .submission($0.id, submission(unconfirmed, now: now)) }
            case .unconfirmed, .accepted:
                break
            }
        }
        inBox = []
        placing = [:]
        messages = []
        return effects
    }

    private func submission(_ message: Message, now: Date) -> PendingShareSubmission {
        PendingShareSubmission(id: message.id, conversationID: conversationID, messageID: message.messageID,
                               state: message.state, at: now)
    }
}

/// Carries a share message's id from the chat into the native client's journal entry for that same
/// message (`DirectHermesConversationClient.recordSubmission`), for that one send only: a task-local,
/// so a send running beside it never sees it.
enum PendingShareCorrelation {
    @TaskLocal static var submission: UUID?
}

/// A client's journal entries that carry shares, entry by entry. Bound when the entry is recorded,
/// taken only by the admission that names that entry, dropped when the entry ends any other way.
struct PendingShareCorrelations: Equatable, Sendable {
    private var byEntry: [UUID: UUID] = [:]

    mutating func bind(entry: UUID, to submission: UUID?) {
        guard let submission else { return }
        byEntry[entry] = submission
    }

    /// The share message that Hermes admitting `entry` settles, once.
    mutating func admit(entry: UUID) -> UUID? {
        byEntry.removeValue(forKey: entry)
    }

    mutating func drop(entry: UUID) {
        byEntry[entry] = nil
    }

    func submission(for entry: UUID) -> UUID? { byEntry[entry] }
}
