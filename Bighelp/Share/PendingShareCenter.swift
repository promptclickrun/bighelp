import Foundation
import Observation

/// The shares other apps saved for bighelp (`PendingShareInbox`), as the app sees them: which to
/// offer for review, which a chat holds now, and where each one is on its way.
///
/// A share leaves the inbox only when Hermes takes the message carrying it
/// (`PendingShareLedger.Effect.accepted`, marked spent before it's deleted) or the person deletes it.
/// Each other step a chat's ledger reports is saved to its placement, a step to sending before the
/// message may go, so after closing bighelp or a crash it's offered again, saying whether it may
/// have been sent.
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
    /// Hermes took these; their saved copies are on their way out and never listed again.
    @ObservationIgnored private var spent: Set<String> = []

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
        let spent = spent
        let (listed, left) = await Task.detached(priority: .utility) { () -> ([PendingShareInbox.Entry], [String]) in
            inbox.removeAbandonedStaging()
            // Delivered shares whose deletion didn't go through before.
            let left = inbox.removeDelivered()
            for id in spent where FileManager.default.fileExists(atPath: inbox.folder(id).path) {
                _ = try? inbox.remove(id)
            }
            return (inbox.entries(), left)
        }.value
        self.spent = self.spent.filter { FileManager.default.fileExists(atPath: inbox.folder($0).path) }
            .union(left)
        let read = listed.filter { !self.spent.contains($0.id) }
        // Compared with what was listed before: a share that wasn't there is new.
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

    /// In a chat's message box, or on its way in a message from there. Asks the chat itself.
    func isHeld(_ id: String) -> Bool { holders[id]?.model?.holdsShare(id) == true }

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

    func apply(_ effects: [PendingShareLedger.Effect], from model: ChatModel) throws {
        for effect in effects {
            switch effect {
            case .inBox(let id):
                holders[id] = WeakHolder(model: model)
                handedOff[id] = nil
                record(id, nil)
            case .submission(let id, let submission):
                holders[id] = WeakHolder(model: model)
                if submission.state == .sending {
                    // The message goes to Hermes only once this is saved.
                    guard let inbox else { throw PendingShareError.storageUnavailable }
                    try inbox.recordSubmission(id, submission)
                    update(id) { placement in
                        var placement = placement
                        placement?.submission = submission
                        return placement
                    }
                } else {
                    record(id, submission)
                }
                // In the list, saying it may have arrived; never offered as unsent.
                if submission.state == .unconfirmed {
                    holders[id] = nil
                    deferred.insert(id)
                }
            case .accepted(let id, let submission):
                holders[id] = nil
                delivered(id, submission)
            case .released(let id, let reason):
                holders[id] = nil
                record(id, nil)
                if reason != .retired { deferred.insert(id) }
            }
        }
    }

    /// Read from the inbox itself, so a chat that opens before the first `refresh` finds them too.
    func sharesPlaced(in conversationID: String, scope: String) -> [PendingShare] {
        guard let inbox else { return [] }
        return inbox.entries().compactMap { entry in
            guard case .share(let share, let placement?) = entry, placement.submission == nil,
                  placement.destination.scope == scope, placement.destination.isTaken(by: conversationID),
                  !spent.contains(share.id), !isHeld(share.id) else { return nil }
            return share
        }
    }

    func messageDelivered(conversationID: String, messageID: String) {
        guard let inbox else { return }
        for id in inbox.markDelivered(conversationID: conversationID, messageID: messageID, at: .now) {
            forget(id)
        }
    }

    /// Spent: never listed again in this run whatever the disk says, marked spent on disk so a
    /// fresh start never lists it either, and deleted now or on a later refresh.
    private func delivered(_ id: String, _ submission: PendingShareSubmission) {
        spent.insert(id)
        forget(id)
        guard let inbox else { return }
        if (try? inbox.markDelivered(id, submission)) == true { spent.remove(id) }
    }

    /// Best effort: a step that isn't saved leaves the last saved one, which a relaunch reads as
    /// no more sent than it was.
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
        _ = try? draft.addFile(copying: notes, suggestedName: "Made-up notes.txt", kind: .file,
                               typeIdentifier: "public.plain-text", mimeType: "text/plain", preferredExtension: "txt")
        _ = try? draft.commit(note: "Can you sum this up?")
    }
    #endif
}
