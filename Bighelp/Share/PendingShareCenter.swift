import Foundation
import Observation

/// The shares other apps saved for bighelp (`PendingShareInbox`), as the app sees them: which to
/// offer for review, which a chat's message box holds now, and which were sent or deleted.
///
/// A share leaves the inbox only when its chat's message box empties after holding it (it was
/// sent, or the person removed it there: `ChatModel.placeShare`) or when the person deletes it.
/// Until then it survives closing bighelp, a crash and a relaunch.
@MainActor
@Observable
final class PendingShareCenter {
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
    /// Closed with Not now: offered again on the next launch, or when another share arrives.
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

    /// The share to review now: not put off, not in a chat's message box, not on its way to one.
    func next(now: Date = .now) -> PendingShareInbox.Entry? {
        guard !isPaused else { return nil }
        return entries.first { entry in
            !deferred.contains(entry.id) && !isHeld(entry.id)
                && !(handedOff[entry.id].map { now.timeIntervalSince($0) < Self.handOffLifetime } ?? false)
        }
    }

    var waitingCount: Int { entries.count }

    func isHeld(_ id: String) -> Bool { holders[id]?.model != nil }

    func later(_ id: String) { deferred.insert(id) }

    /// Records where the person put the share, before any chat opens: a share they leave there
    /// unsent says so after a relaunch.
    func place(_ share: PendingShare, at destination: PendingShareDestination, agentName: String,
               now: Date = .now) async throws {
        guard let inbox else { throw PendingShareError.storageUnavailable }
        let placement = PendingSharePlacement(destination: destination, agentName: agentName, placedAt: now)
        let id = share.id
        try await Task.detached(priority: .userInitiated) { try inbox.place(id, placement) }.value
        handedOff[id] = now
        isPaused = true
        entries = entries.map { entry in
            guard entry.id == id, case .share(let share, _) = entry else { return entry }
            return .share(share, placement: placement)
        }
    }

    /// A chat's message box took the share.
    func hold(_ id: String, by model: ChatModel) {
        holders[id] = WeakHolder(model: model)
        handedOff[id] = nil
    }

    /// The chat couldn't take it after all; it's offered again.
    func release(_ id: String) {
        holders[id] = nil
        handedOff[id] = nil
        isPaused = false
    }

    /// Its chat's message box emptied after holding it: sent, or removed by the person there.
    func settled(_ id: String) {
        holders[id] = nil
        handedOff[id] = nil
        Task { try? await remove(id) }
    }

    /// The person deleted it.
    func delete(_ id: String) async throws {
        try await remove(id)
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

    private func remove(_ id: String) async throws {
        guard let inbox else { return }
        try await Task.detached(priority: .userInitiated) { _ = try inbox.remove(id) }.value
        entries.removeAll { $0.id == id }
        deferred.remove(id)
    }
}
