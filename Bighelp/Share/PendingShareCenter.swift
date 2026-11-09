import Foundation
import Observation

/// The shares other apps saved for bighelp (`PendingShareInbox`), as the app sees them: which to
/// offer for review, which a chat holds now, and where each one is on its way.
///
/// A share leaves the inbox only when Hermes takes the message carrying it (`ChatShareEvent.delivered`)
/// or the person deletes it. Each other step a chat reports is written to its placement at once, so
/// after closing bighelp or a crash it's offered again, saying whether it may have been sent.
@MainActor
@Observable
final class PendingShareCenter: ChatShareTracking {
    static let shared: PendingShareCenter = {
        let center = PendingShareCenter(inbox: PendingShareInbox.shared())
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-test-pending-share") { center.seedForTesting() }
        #endif
        return center
    }()

    /// How long a chat on its way gets to take a share before the share is offered again (its open
    /// failed, or the person went elsewhere).
    static let handOffLifetime: TimeInterval = 60

    let inbox: PendingShareInbox?
    private(set) var entries: [PendingShareInbox.Entry] = []
    /// Every share waiting, put off ones too (☰ › Shared with bighelp, or Bots mode's Settings).
    var isListShown = false
    /// Put off with Not now, taken out of a chat's message box, or unconfirmed: in the list, and
    /// offered on their own again only when another share arrives.
    private var deferred: Set<String> = []
    private var handedOff: [String: Date] = [:]
    /// After Open, the rest wait until bighelp next comes to the front, so the next review doesn't
    /// cover the chat the person just picked.
    private var isPaused = false
    @ObservationIgnored private var holders: [String: WeakHolder] = [:]

    private struct WeakHolder {
        weak var model: ChatModel?
    }

    init(inbox: PendingShareInbox?) {
        self.inbox = inbox
    }

    /// Reads the inbox again, off the main thread, each time bighelp comes to the front. A new share
    /// brings back the ones put off.
    func refresh() async {
        isPaused = false
        guard let inbox else { return }
        let read = await Task.detached(priority: .utility) { () -> [PendingShareInbox.Entry] in
            inbox.removeAbandonedStaging()
            return inbox.entries()
        }.value
        let known = Set(entries.map(\.id))
        if read.contains(where: { !known.contains($0.id) }) { deferred.removeAll() }
        let ids = Set(read.map(\.id))
        deferred.formIntersection(ids)
        handedOff = handedOff.filter { ids.contains($0.key) }
        holders = holders.filter { ids.contains($0.key) }
        if read != entries { entries = read }
    }

    /// The share to review on its own now: not put off, not in a chat, not on its way to one.
    func next(now: Date = .now) -> PendingShareInbox.Entry? {
        guard !isPaused else { return nil }
        return entries.first { entry in
            !deferred.contains(entry.id) && !isHeld(entry.id)
                && !(handedOff[entry.id].map { now.timeIntervalSince($0) < Self.handOffLifetime } ?? false)
        }
    }

    var waitingCount: Int { entries.count }

    func isHeld(_ id: String) -> Bool { holders[id]?.model != nil }

    func isDeferred(_ id: String) -> Bool { deferred.contains(id) }

    func later(_ id: String) { deferred.insert(id) }

    func showList() { isListShown = true }

    /// Records where the person put the share, before any chat opens: a share they leave there
    /// unsent says so after a relaunch.
    func place(_ share: PendingShare, at destination: PendingShareDestination, agentName: String,
               now: Date = .now) async throws {
        guard let inbox else { throw PendingShareError.storageUnavailable }
        let placement = PendingSharePlacement(destination: destination, agentName: agentName, placedAt: now)
        let id = share.id
        try await Task.detached(priority: .userInitiated) { try inbox.place(id, placement) }.value
        handedOff[id] = now
        deferred.remove(id)
        isPaused = true
        update(id) { _ in placement }
    }

    /// The new chat Hermes made for a share: its placement names that chat from now on.
    func bind(_ id: String, to sessionID: String) async throws {
        guard let inbox, case .share(_, let placement?)? = entries.first(where: { $0.id == id }) else {
            throw PendingShareError.gone
        }
        var bound = placement
        bound.destination = placement.destination.bound(to: sessionID)
        let saved = bound
        try await Task.detached(priority: .userInitiated) { try inbox.place(id, saved) }.value
        handedOff[id] = .now
        update(id) { _ in saved }
    }

    /// No chat took it after all; it's offered again.
    func release(_ id: String) {
        holders[id] = nil
        handedOff[id] = nil
        isPaused = false
    }

    /// The person deleted it.
    func delete(_ id: String) async throws {
        guard let inbox else { return }
        try await Task.detached(priority: .userInitiated) { _ = try inbox.remove(id) }.value
        holders[id] = nil
        forget(id)
    }

    // MARK: - ChatShareTracking

    func share(_ id: String, in model: ChatModel, _ event: ChatShareEvent) {
        switch event {
        case .inBox:
            holders[id] = WeakHolder(model: model)
            handedOff[id] = nil
            record(id, nil)
        case .staged(let messageID):
            holders[id] = WeakHolder(model: model)
            record(id, .init(conversationID: model.conversationID, messageID: messageID, state: .staged, at: .now))
        case .sending(let messageID):
            holders[id] = WeakHolder(model: model)
            record(id, .init(conversationID: model.conversationID, messageID: messageID, state: .sending, at: .now))
        case .unconfirmed(let messageID):
            // In the list, saying it may have arrived; never offered as unsent.
            holders[id] = nil
            deferred.insert(id)
            record(id, .init(conversationID: model.conversationID, messageID: messageID, state: .unconfirmed, at: .now))
        case .delivered:
            holders[id] = nil
            try? inbox?.remove(id)
            forget(id)
        case .removed:
            holders[id] = nil
            deferred.insert(id)
            record(id, nil)
        case .retired:
            holders[id] = nil
            record(id, nil)
        }
    }

    /// Written at once, on this thread: the message it describes may go out right after, and a
    /// relaunch must find what's true.
    private func record(_ id: String, _ submission: PendingShareSubmission?) {
        try? inbox?.recordSubmission(id, submission)
        update(id) { placement in
            var placement = placement
            placement?.submission = submission
            return placement
        }
    }

    private func update(_ id: String, _ change: (PendingSharePlacement?) -> PendingSharePlacement?) {
        entries = entries.map { entry in
            guard entry.id == id, case .share(let share, let placement) = entry else { return entry }
            return .share(share, placement: change(placement))
        }
    }

    private func forget(_ id: String) {
        entries.removeAll { $0.id == id }
        deferred.remove(id)
        handedOff[id] = nil
    }

    #if DEBUG
    /// `-test-pending-share`: one made-up share waiting, to see the review without the share sheet.
    private func seedForTesting() {
        guard let inbox, inbox.entries().isEmpty, let draft = try? inbox.begin() else { return }
        let notes = FileManager.default.temporaryDirectory.appendingPathComponent("Made-up notes.txt")
        try? Data("Three made-up points about the article.".utf8).write(to: notes)
        try? draft.addText("A made-up article about tidy kitchens.")
        try? draft.addLink("https://example.com/made-up-article")
        try? draft.addFile(copying: notes, suggestedName: "Made-up notes.txt", kind: .file,
                           typeIdentifier: "public.plain-text", mimeType: "text/plain", preferredExtension: "txt")
        _ = try? draft.commit(note: "Can you sum this up?")
    }
    #endif
}
