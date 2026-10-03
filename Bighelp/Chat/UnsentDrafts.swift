import Foundation
import Observation

/// Text typed into a new chat that hasn't sent anything yet. Hermes saves a chat only on its
/// first message and drops an idle one about 20 seconds after the app disconnects, so leaving
/// bighelp could lose the chat and its draft. The text is kept here, on this device only.
struct UnsentDraft: Codable, Identifiable, Equatable, Sendable {
    /// The chat it was typed in.
    let id: String
    let hostID: UUID?
    let agentID: String
    let agentName: String
    let text: String
    let savedAt: Date
}

/// Drafts kept while bighelp is away, and the ones whose chat didn't survive, to offer back.
@MainActor
@Observable
final class UnsentDraftStore {
    static let shared = UnsentDraftStore()

    static let maximumCount = 10
    static let maximumCharacters = 8_000
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    private(set) var drafts: [UnsentDraft] = []
    /// Chats whose draft was lost; their drafts are offered back.
    private(set) var lostIDs: Set<String> = []

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let now: () -> Date

    init(fileURL: URL? = UnsentDraftStore.defaultFileURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        load()
    }

    /// Drafts to offer for this computer, newest first.
    func lostDrafts(hostID: UUID?) -> [UnsentDraft] {
        drafts.filter { lostIDs.contains($0.id) && $0.hostID == hostID }.sorted { $0.savedAt > $1.savedAt }
    }

    /// Leaving the app: what's unsent in new chats right now replaces this computer's earlier
    /// list. Drafts already waiting to be offered back stay until answered.
    func record(_ current: [UnsentDraft], hostID: UUID?) {
        var kept = drafts.filter { $0.hostID != hostID || lostIDs.contains($0.id) }
        for draft in current where !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kept.removeAll { $0.id == draft.id }
            kept.append(UnsentDraft(id: draft.id, hostID: draft.hostID, agentID: draft.agentID,
                                    agentName: draft.agentName,
                                    text: String(draft.text.prefix(Self.maximumCharacters)), savedAt: draft.savedAt))
        }
        drafts = kept
        prune()
        persist()
    }

    /// The chat is gone (Hermes dropped it, or bighelp closed): offer its draft back. `text`
    /// is the chat's latest draft when it's still known.
    func markLost(chatID: String, latestText: String? = nil) {
        guard let index = drafts.firstIndex(where: { $0.id == chatID }) else { return }
        if let latestText, !latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let old = drafts[index]
            drafts[index] = UnsentDraft(id: old.id, hostID: old.hostID, agentID: old.agentID,
                                        agentName: old.agentName,
                                        text: String(latestText.prefix(Self.maximumCharacters)), savedAt: old.savedAt)
        }
        lostIDs.insert(chatID)
        persist()
    }

    /// Coming back: a kept draft whose chat no longer exists here is lost.
    func markMissing(hostID: UUID?, chatExists: (String) -> Bool) {
        for draft in drafts where draft.hostID == hostID && !chatExists(draft.id) {
            lostIDs.insert(draft.id)
        }
    }

    func remove(_ id: String) {
        drafts.removeAll { $0.id == id }
        lostIDs.remove(id)
        persist()
    }

    /// "Not now": this computer's lost drafts are let go.
    func discardLost(hostID: UUID?) {
        let gone = Set(lostDrafts(hostID: hostID).map(\.id))
        drafts.removeAll { gone.contains($0.id) }
        lostIDs.subtract(gone)
        persist()
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.maximumAge)
        drafts = Array(drafts.filter { $0.savedAt >= cutoff }.sorted { $0.savedAt > $1.savedAt }
            .prefix(Self.maximumCount))
        lostIDs.formIntersection(drafts.map(\.id))
    }

    // MARK: On the device

    private struct Saved: Codable {
        var drafts: [UnsentDraft]
        var lostIDs: [String]
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        drafts = saved.drafts
        lostIDs = Set(saved.lostIDs)
        prune()
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            if drafts.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Saved(drafts: drafts, lostIDs: lostIDs.sorted()))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Losing the backup only means no offer to continue; the chat itself is unaffected.
        }
    }

    nonisolated static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Bighelp", isDirectory: true)
            .appendingPathComponent("UnsentDrafts.json")
    }
}
