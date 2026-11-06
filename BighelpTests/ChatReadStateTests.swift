import Foundation
import Testing
@testable import Bighelp

/// Hermes' read state in the Chats list and Bots mode (#862). Hermes counts a chat unread once
/// anything happens after its read watermark, and a chat no client ever marked counts as read, so
/// the app marks a chat read each time the person reads it, and only then.
@Suite(.serialized)
@MainActor
struct ChatReadStateTests {
    /// Keeps read state as Hermes does: a mark sets the row's `unread`.
    @MainActor
    private final class ReadMarkClient: SessionCatalogClient {
        var records: [SessionRecord]
        private(set) var marks: [Bool] = []

        init(records: [SessionRecord]) { self.records = records }

        func list() async throws -> [SessionRecord] { records }

        func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
            throw SessionCatalogError.invalidSession
        }

        func setUnread(_ record: SessionRecord, unread: Bool) async throws {
            marks.append(unread)
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index].isUnread = unread }
        }
    }

    private struct OpenChat {
        let client: ReadMarkClient
        let catalog: SessionCatalogStore
        let features: ShellFeatureStore
        let model: ChatModel
    }

    private static func chat(id: String = "read-chat", unread: Bool?) -> SessionRecord {
        SessionRecord(id: id, kind: .direct, agentIDs: ["default"], title: "Weekend plans",
                      remoteStoredID: "stored-" + id, remoteSource: "bighelp",
                      items: [TimelineItem(id: id + "-answer", role: .assistant,
                                           sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                                           content: .message("Here's the plan."), metadata: .init(delivery: "Delivered"))],
                      isUnread: unread, hasAcceptedMessage: true)
    }

    /// A chat made the way the shell makes it, so its read hook is the shell's own.
    private func open(_ record: SessionRecord) throws -> OpenChat {
        let client = ReadMarkClient(records: [record])
        let catalog = SessionCatalogStore(client: client, records: [record])
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let route = AppRoute.chat(conversationID: record.id)
        #expect(features.prepare(route))
        guard case .chat(let model)? = features.preparedModel(for: route) else {
            throw ReadStateTestError.noChat
        }
        model.readSettleDelay = .milliseconds(30)
        return OpenChat(client: client, catalog: catalog, features: features, model: model)
    }

    private enum ReadStateTestError: Error { case noChat }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func withAppInFront(_ isActive: Bool = true, _ body: () async throws -> Void) async rethrows {
        let visible = BighelpVisibleChats.shared
        let original = visible.appIsActive
        visible.appIsActive = { isActive }
        defer { visible.appIsActive = original }
        try await body()
    }

    @Test func readingAChatMarksItReadWhateverHermesListedIt() async throws {
        // Hermes lists a chat no client ever marked as read: only a mark starts its tracking.
        let chat = try open(Self.chat(unread: false))
        try await withAppInFront {
            BighelpVisibleChats.shared.appeared(chat.model)
            defer { BighelpVisibleChats.shared.disappeared(chat.model) }
            await settle()
            #expect(chat.client.marks == [false])
        }
    }

    @Test func aTurnThatEndsOnScreenMarksTheChatReadOnceItSettles() async throws {
        let chat = try open(Self.chat(unread: false))
        try await withAppInFront {
            BighelpVisibleChats.shared.appeared(chat.model)
            defer { BighelpVisibleChats.shared.disappeared(chat.model) }
            await settle()
            // The person's message and the reply move Hermes' activity past the first mark.
            chat.model.isSending = true
            chat.model.isSending = false
            chat.model.isSending = true
            chat.model.isSending = false
            #expect(chat.client.marks == [false], "Nothing goes before the turn's last rows are saved")
            await settle()
            #expect(chat.client.marks == [false, false], "Turns that end close together send one mark")
        }
    }

    @Test func readingAgainWithNothingNewSendsNothing() async throws {
        let chat = try open(Self.chat(unread: false))
        try await withAppInFront {
            BighelpVisibleChats.shared.appeared(chat.model)
            await settle()
            BighelpVisibleChats.shared.disappeared(chat.model)
            BighelpVisibleChats.shared.appeared(chat.model)
            await settle()
            #expect(chat.client.marks == [false])

            // A message arrived while it showed: leaving marks the chat read up to there.
            chat.model.acceptExternal([TimelineItem(
                id: "later", role: .assistant, sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                content: .message("One more thing."), metadata: .init(delivery: "Delivered"))])
            BighelpVisibleChats.shared.disappeared(chat.model)
            await settle()
            #expect(chat.client.marks == [false, false])
        }
    }

    @Test func aChatHermesListsUnreadIsMarkedEvenWithNothingNewHere() async throws {
        let chat = try open(Self.chat(unread: true))
        try await withAppInFront {
            BighelpVisibleChats.shared.appeared(chat.model)
            defer { BighelpVisibleChats.shared.disappeared(chat.model) }
            await settle()
            #expect(chat.client.marks == [false])
            #expect(chat.catalog.session(id: chat.model.conversationID)?.isUnread == false)
            #expect(chat.catalog.session(id: chat.model.conversationID)?.summary.isUnread == false)
        }
    }

    @Test func aChatThatIsNotOnScreenIsNeverMarked() async throws {
        let chat = try open(Self.chat(unread: true))
        try await withAppInFront {
            // Kept for later, or working while another screen shows: a turn ending there isn't read.
            chat.model.isSending = true
            chat.model.isSending = false
            await settle()
            #expect(chat.client.marks.isEmpty)
        }
        try await withAppInFront(false) {
            // On screen while the app is away: nothing is read until the person comes back.
            BighelpVisibleChats.shared.appeared(chat.model)
            chat.model.isSending = true
            chat.model.isSending = false
            await settle()
            #expect(chat.client.marks.isEmpty)
        }
        try await withAppInFront {
            BighelpVisibleChats.shared.appActivityChanged(isActive: true)
            await settle()
            #expect(chat.client.marks == [false])
            BighelpVisibleChats.shared.disappeared(chat.model)
        }
    }

    @Test func aListThatSaysTheChatOnScreenIsUnreadKeepsItRead() async throws {
        let chat = try open(Self.chat(unread: false))
        try await withAppInFront {
            BighelpVisibleChats.shared.appeared(chat.model)
            await settle()
            // A reply landed on Hermes while the person read it; the list says so before the chat is marked.
            chat.client.records[0].isUnread = true
            try await chat.catalog.load()
            #expect(chat.catalog.session(id: chat.model.conversationID)?.isUnread == false)

            // Leaving marks it, though nothing new showed here.
            BighelpVisibleChats.shared.disappeared(chat.model)
            await settle()
            #expect(chat.client.marks == [false, false])
            #expect(chat.client.records[0].isUnread == false)
        }
    }

    @Test func aComputerWithoutReadStateGetsNoMarksAndNoControls() async throws {
        // Rows without `unread`: Hermes keeps no read state there.
        let chat = try open(Self.chat(unread: nil))
        try await withAppInFront {
            BighelpVisibleChats.shared.appeared(chat.model)
            chat.model.isSending = true
            chat.model.isSending = false
            await settle()
            BighelpVisibleChats.shared.disappeared(chat.model)
            await settle()
        }
        #expect(chat.client.marks.isEmpty)
        let summary = try #require(chat.catalog.session(id: chat.model.conversationID)?.summary)
        #expect(!summary.tracksUnread, "Mark Read and Mark Unread stay hidden")
        #expect(!summary.isUnread)
        #expect(Self.chat(unread: false).summary.tracksUnread)
    }

    @Test func aRowWithoutUnreadKeepsWhatTheLastRowSaid() {
        let listed = Self.chat(unread: true)
        var page = listed
        page.isUnread = nil
        #expect(SessionCatalogReconciliation.merged(local: listed, incoming: page).isUnread == true)
        var read = listed
        read.isUnread = false
        #expect(SessionCatalogReconciliation.merged(local: listed, incoming: read).isUnread == false)
    }
}
