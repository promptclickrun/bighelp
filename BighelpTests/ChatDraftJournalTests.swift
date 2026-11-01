import Foundation
import Testing
@testable import Bighelp

/// Typing keeps the draft in its own small file, never in the chat list, and a draft typed
/// before the app went away comes back in its chat (#738).
@Suite(.serialized)
@MainActor
struct ChatDraftJournalTests {
    @Test func aPauseInTypingWritesTheJournalNotTheChat() async {
        var saved: [String] = []
        var journaled: [String] = []
        let model = ChatModel(conversationID: "journal-pause", client: ConversationFixtureClient(), initialItems: [],
                              persistenceCheckpointDelay: .milliseconds(20),
                              onSessionChange: { draft, _, _, _ in saved.append(draft) },
                              onDraftJournal: { journaled.append($0) }, draftJournalDelay: .milliseconds(20))
        for count in 1...6 {
            model.draft = String(repeating: "a", count: count)
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(saved.isEmpty, "Typing alone never saves the chat")
        #expect(journaled.last == "aaaaaa")

        // Leaving the chat, the app going away: the chat saves its draft with the rest of it.
        model.flushPersistence()
        #expect(saved == ["aaaaaa"])
    }

    @Test func aMessageArrivingStillSavesTheDraftWithTheChat() async {
        var saved: [String] = []
        let model = ChatModel(conversationID: "journal-message", client: ConversationFixtureClient(), initialItems: [],
                              persistenceCheckpointDelay: .milliseconds(20),
                              onSessionChange: { draft, _, _, _ in saved.append(draft) },
                              onDraftJournal: { _ in }, draftJournalDelay: .milliseconds(20))
        model.draft = "Half a thought"
        model.acceptExternal([TimelineItem(id: "answer", role: .assistant,
                                           sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                                           content: .message("Here it is"), metadata: .init(delivery: "Delivered"))])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(saved.last == "Half a thought")
    }

    @Test func aChatWithReferencesKeepsItsOwnCheckpoint() async {
        var saved: [String] = []
        var journaled: [String] = []
        let model = ChatModel(conversationID: "journal-references", client: ConversationFixtureClient(),
                              initialItems: [], persistenceCheckpointDelay: .milliseconds(20),
                              onSessionChange: { draft, _, _, _ in saved.append(draft) },
                              onDraftJournal: { journaled.append($0) }, draftJournalDelay: .milliseconds(20))
        model.referencePersistenceNeeded = true
        #expect(!model.journalsDraft)
        model.draft = "Exact bytes"
        try? await Task.sleep(for: .milliseconds(100))
        #expect(journaled.isEmpty)
        #expect(saved == ["Exact bytes"])
    }

    @Test func aChatOpensWithItsJournalDraftWhileItsSavedDraftIsUnchanged() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ChatDraftJournal(repository: Self.repository(in: directory))
        journal.write("Hello there", over: "Hel", for: "chat")
        journal.flush()

        let relaunched = ChatDraftJournal(repository: Self.repository(in: directory))
        #expect(relaunched.openingDraft(for: Self.record("chat", draft: "Hel")) == "Hello there")
        #expect(relaunched.openingDraft(for: Self.record("other", draft: "Its own")) == "Its own")
    }

    @Test func anythingElseThatWroteTheChatSinceWins() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ChatDraftJournal(repository: Self.repository(in: directory))
        journal.write("Hello there", over: "Hel", for: "chat")
        journal.flush()

        let relaunched = ChatDraftJournal(repository: Self.repository(in: directory))
        #expect(relaunched.openingDraft(for: Self.record("chat", draft: "Written by a Shortcut")) == "Written by a Shortcut")
        relaunched.flush()
        // The stale draft is gone, so it never comes back over the chat's own.
        let again = ChatDraftJournal(repository: Self.repository(in: directory))
        #expect(again.openingDraft(for: Self.record("chat", draft: "Hel")) == "Hel")
    }

    /// The chat saved one draft (maybe not on disk yet) and then took more typing: either saved
    /// copy opens with the newest.
    @Test func aChatThatSavedSinceStillOpensWithTheNewestDraft() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ChatDraftJournal(repository: Self.repository(in: directory))
        journal.write("A", over: "", for: "chat")
        journal.write("AB", over: "A", for: "chat")
        journal.flush()

        let relaunched = ChatDraftJournal(repository: Self.repository(in: directory))
        #expect(relaunched.openingDraft(for: Self.record("chat", draft: "")) == "AB")
        #expect(relaunched.openingDraft(for: Self.record("chat", draft: "A")) == "AB")
    }

    @Test func referenceDraftsNeverComeFromTheJournal() {
        let journal = ChatDraftJournal(repository: nil)
        journal.write("Plain text", over: "Canonical", for: "chat")
        var record = Self.record("chat", draft: "Canonical")
        record.hasDeferredReferenceState = true
        #expect(journal.openingDraft(for: record) == "Canonical")
    }

    @Test func anAccountBoundaryForgetsEveryDraftOnDiskToo() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ChatDraftJournal(repository: Self.repository(in: directory))
        journal.write("Private words", over: "", for: "chat")
        journal.flush()
        journal.removeAll()

        let relaunched = ChatDraftJournal(repository: Self.repository(in: directory))
        #expect(relaunched.openingDraft(for: Self.record("chat", draft: "")) == "")
    }

    /// The whole path: typing in a chat, the app killed before the chat saved, the chat opened
    /// again from the same chat list and journal.
    @Test func aDraftTypedBeforeTheAppWentAwayComesBackInItsChat() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionRecord(id: "journal-relaunch", kind: .direct, agentIDs: ["default"], title: "Draft",
                                    draft: "Saved")
        func open() -> (store: ShellFeatureStore, catalog: SessionCatalogStore, model: ChatModel?) {
            let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient(), records: [session])
            let store = ShellFeatureStore(timing: .immediate, catalog: catalog,
                                          draftJournal: ChatDraftJournal(repository: Self.repository(in: directory),
                                                                         saveDelay: .zero))
            guard store.prepare(.chat(conversationID: session.id)),
                  case .chat(let model)? = store.preparedModel(for: .chat(conversationID: session.id)) else {
                return (store, catalog, nil)
            }
            return (store, catalog, model)
        }

        let first = open()
        let model = try #require(first.model)
        #expect(model.draft == "Saved")
        model.draft = "Saved, and then some"
        try await Task.sleep(for: .milliseconds(600))
        #expect(first.catalog.session(id: session.id)?.draft == "Saved", "Typing never touches the chat list")

        let second = open()
        let reopened = try #require(second.model)
        #expect(reopened.draft == "Saved, and then some")
        // Its next save puts the draft in the chat itself.
        second.store.flushChatPersistence()
        #expect(second.catalog.session(id: session.id)?.draft == "Saved, and then some")
    }

    private static func record(_ id: String, draft: String) -> SessionRecord {
        SessionRecord(id: id, kind: .direct, agentIDs: ["default"], title: "Chat", draft: draft)
    }

    private static func repository(in directory: URL) -> DemoRepository<[String: ChatDraftJournal.Entry]> {
        DemoRepository<[String: ChatDraftJournal.Entry]>(directory: directory, name: "chat-drafts", seed: [:])
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "chat-draft-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
