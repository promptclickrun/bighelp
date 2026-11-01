import CryptoKit
import Foundation

/// Drafts typed since their chat last saved, in a small file of their own, so a pause in typing
/// never touches the chat list (`SessionCatalogStore.records`): saving a draft there redrew every
/// screen that lists chats, a stall of tens of milliseconds right when typing resumed. The chat
/// still saves its draft with the rest of it when it next saves (leaving the chat, the app going
/// to the background, a message arriving). T3 Code's phone app keeps drafts apart from its threads
/// the same way (github.com/pingdotgg/t3code, apps/mobile, `use-composer-drafts.ts`).
///
/// After a relaunch, a chat opens with its journal draft only while its saved draft is still one
/// the journal saw when it wrote (`Entry.bases`): anything else that wrote the chat since wins.
/// Reference drafts never come from here; they keep their own checkpoint, byte for byte.
@MainActor
final class ChatDraftJournal {
    struct Entry: Codable, Equatable, Sendable {
        var draft: String
        /// SHA-256 of each saved draft this one is newer than, newest last.
        var bases: [String]
        var savedAt: Date
    }

    static let maximumEntries = 64
    static let maximumBases = 4

    private let repository: DemoRepository<[String: Entry]>?
    private let saveDelay: Duration
    private var entries: [String: Entry] = [:]
    /// False until the file has been read: a write before then (the phone still locked) would
    /// replace drafts it never saw.
    private var isLoaded = false
    private var saveTask: Task<Void, Never>?

    /// `repository` nil keeps the journal in memory only (demo mode, tests).
    init(repository: DemoRepository<[String: Entry]>?, saveDelay: Duration = .milliseconds(100)) {
        self.repository = repository
        self.saveDelay = saveDelay
        loadIfNeeded()
    }

    /// The draft `record` opens with.
    func openingDraft(for record: SessionRecord) -> String {
        loadIfNeeded()
        guard let entry = entries[record.id] else { return record.draft }
        guard record.referenceState == nil, !record.hasDeferredReferenceState,
              entry.bases.contains(Self.digest(record.draft)),
              !entry.draft.utf8.elementsEqual(record.draft.utf8) else {
            // Saved with the chat already, or something else wrote the chat since.
            discard(record.id)
            return record.draft
        }
        return entry.draft
    }

    /// Keeps `draft` for the chat whose saved draft is `savedDraft` right now.
    func write(_ draft: String, over savedDraft: String, for sessionID: String) {
        loadIfNeeded()
        let base = Self.digest(savedDraft)
        var bases = entries[sessionID]?.bases ?? []
        if bases.last != base {
            bases.removeAll { $0 == base }
            bases = Array((bases + [base]).suffix(Self.maximumBases))
        }
        if let entry = entries[sessionID], entry.draft.utf8.elementsEqual(draft.utf8), entry.bases == bases { return }
        entries[sessionID] = Entry(draft: draft, bases: bases, savedAt: .now)
        if entries.count > Self.maximumEntries,
           let oldest = entries.min(by: { $0.value.savedAt < $1.value.savedAt })?.key {
            entries[oldest] = nil
        }
        scheduleSave()
    }

    /// Forgets drafts of chats that are gone.
    func retain(sessionIDs: Set<String>) {
        loadIfNeeded()
        let kept = entries.filter { sessionIDs.contains($0.key) }
        guard kept.count != entries.count else { return }
        entries = kept
        scheduleSave()
    }

    /// An account or host boundary: every draft goes, on disk too.
    func removeAll() {
        saveTask?.cancel()
        saveTask = nil
        entries.removeAll()
        guard let repository else { return }
        do {
            try repository.save([:])
            isLoaded = true
        } catch {
            // Read again (and so never overwrite) once the file opens.
            isLoaded = false
        }
    }

    /// Writes now what is waiting for its delay.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private func discard(_ sessionID: String) {
        guard entries.removeValue(forKey: sessionID) != nil else { return }
        scheduleSave()
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        guard let repository else {
            isLoaded = true
            return
        }
        guard let saved = try? repository.load() else { return }
        // Anything written in memory before the file opened is newer.
        entries = saved.merging(entries) { _, written in written }
        isLoaded = true
    }

    private func scheduleSave() {
        guard repository != nil, saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.saveTask = nil
            self.save()
        }
    }

    private func save() {
        guard let repository else { return }
        loadIfNeeded()
        guard isLoaded else { return }
        try? repository.save(entries)
    }

    static func digest(_ draft: String) -> String {
        SHA256.hash(data: Data(draft.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
