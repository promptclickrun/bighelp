import BuzzKit
import Foundation
import Testing
import UserNotifications
@testable import Bighelp

/// Nothing for the chat you're looking at. Alerts for the open chat used to
/// show anyway: an alert without its chat reference couldn't be matched.
@MainActor
@Suite(.serialized)
struct ForegroundAlertTests {
    private final class QuietRPC: DirectHermesRPC {
        var onEvent: ((DirectHermesEvent) -> Void)?
        func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            throw DirectHermesError.invalidResponse
        }
        func disconnect() async {}
    }

    @MainActor private struct OpenChat {
        let model: ChatModel
        let client: DirectHermesConversationClient
        let root: URL

        func close() {
            BighelpVisibleChats.shared.disappeared(model)
            client.suspend()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func open(profile: String, stored: String) throws -> OpenChat {
        let root = FileManager.default.temporaryDirectory.appending(path: "foreground-alerts-" + UUID().uuidString)
        let client = try DirectHermesConversationClient(
            rpc: QuietRPC(), hostIdentity: "fixture-host", profile: profile, runtimeID: "runtime-" + stored,
            storedID: stored, title: "Chat", epoch: "epoch", drafts: .init(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client)
        BighelpVisibleChats.shared.appeared(model)
        return OpenChat(model: model, client: client, root: root)
    }

    @Test func theOpenChatsAlertsAreQuietAndOtherChatsStillShow() throws {
        let chat = try open(profile: "default", stored: "saved-a")
        defer { chat.close() }
        let open = ManagedNotificationValidation.sessionReference(profile: "default", session: "saved-a")
        let other = ManagedNotificationValidation.sessionReference(profile: "default", session: "saved-b")
        #expect(BighelpVisibleChats.shared.isShowing(chat: open, agent: "default"))
        #expect(!BighelpVisibleChats.shared.isShowing(chat: other, agent: "default"), "Another chat's reply still shows")
    }

    @Test func anAlertWithoutAChatIsQuietWhileItsAgentsChatIsBusy() throws {
        let chat = try open(profile: "default", stored: "saved-c")
        defer { chat.close() }
        let now = Date()
        #expect(!BighelpVisibleChats.shared.isShowing(chat: nil, agent: "default", now: now), "An idle chat claims nothing")

        chat.model.isSending = true
        #expect(BighelpVisibleChats.shared.isShowing(chat: nil, agent: "default", now: now))
        #expect(!BighelpVisibleChats.shared.isShowing(chat: nil, agent: "someone-else", now: now))

        chat.model.isSending = false
        #expect(BighelpVisibleChats.shared.isShowing(chat: nil, agent: "default", now: Date()), "The reply that just finished")
        #expect(!BighelpVisibleChats.shared.isShowing(
            chat: nil, agent: "default", now: Date().addingTimeInterval(BighelpVisibleChats.recentTurnWindow + 1)))
    }

    @Test func aClosedChatIsntOnScreen() throws {
        let chat = try open(profile: "default", stored: "saved-d")
        chat.close()
        let reference = ManagedNotificationValidation.sessionReference(profile: "default", session: "saved-d")
        #expect(!BighelpVisibleChats.shared.isShowing(chat: reference, agent: "default"))
    }

    @Test func theAgentComesFromSealedOrRichPushData() {
        let sealed: [String: JSONValue] = ["loopdy": .object(["agent": .object(["id": .string("default")])])]
        let rich: [String: JSONValue] = ["loopdy": .object(["profile": .string("juno")])]
        #expect(BighelpBuzzKitPresentation.agent(sealed) == "default")
        #expect(BighelpBuzzKitPresentation.agent(rich) == "juno")
        #expect(BighelpNotificationGrouping.agent(of: ["loopdy": ["agent": ["id": "default"]]]) == "default")
    }

    private func reference(_ stored: String, profile: String = "default") -> String {
        ManagedNotificationValidation.sessionReference(profile: profile, session: stored)
    }

    // MARK: A chat on screen stays on screen

    @Test func aChatViewMadeAgainStaysOnScreenUntilBothScreensLeave() throws {
        let chat = try open(profile: "default", stored: "saved-e")
        defer { chat.close() }
        let visible = BighelpVisibleChats.shared
        visible.disappeared(chat.model)
        #expect(!visible.isShowing(chat: reference("saved-e"), agent: "default"))

        // SwiftUI can show the new screen before the old one reports leaving.
        visible.appeared(chat.model, screen: "first")
        visible.appeared(chat.model, screen: "second")
        visible.disappeared(chat.model, screen: "first")
        #expect(visible.isShowing(chat: reference("saved-e"), agent: "default"), "The second screen is still showing it")
        visible.disappeared(chat.model, screen: "second")
        #expect(!visible.isShowing(chat: reference("saved-e"), agent: "default"))

        // One screen reporting twice is still one screen.
        visible.appeared(chat.model, screen: "only")
        visible.appeared(chat.model, screen: "only")
        visible.disappeared(chat.model, screen: "only")
        #expect(!visible.isShowing(chat: reference("saved-e"), agent: "default"))
    }

    // A screen that is handed another chat (New chat swaps the local draft for the durable session in place).
    @Test func aScreenHandedAnotherChatCountsForTheNewChatOnly() throws {
        let first = try open(profile: "default", stored: "saved-p")
        let second = try open(profile: "default", stored: "saved-q")
        defer { first.close(); second.close() }
        let visible = BighelpVisibleChats.shared
        visible.disappeared(first.model)
        visible.disappeared(second.model)

        let mount = ChatScreenMount()
        mount.mount(first.model)
        #expect(visible.isShowing(chat: reference("saved-p"), agent: "default"))
        #expect(first.model.nativeSessionResumeProgress.isMounted)

        mount.mount(second.model)
        #expect(visible.isShowing(chat: reference("saved-q"), agent: "default"), "The chat now in front of the person")
        #expect(!visible.isShowing(chat: reference("saved-p"), agent: "default"), "The one it left")
        #expect(!first.model.nativeSessionResumeProgress.isMounted)
        #expect(second.model.nativeSessionResumeProgress.isMounted)
        #expect(ChatPDFPagesDraftRegistry.owns(second.model, sessionID: second.model.conversationID))

        mount.unmount()
        #expect(!visible.isShowing(chat: reference("saved-q"), agent: "default"))
        #expect(!second.model.nativeSessionResumeProgress.isMounted)
        #expect(!ChatPDFPagesDraftRegistry.owns(second.model, sessionID: second.model.conversationID))
    }

    @Test func aChatStillOpeningIsKnownFromItsSavedRow() {
        let record = SessionRecord(id: "app-row-1", kind: .direct, agentIDs: ["default"], title: "Chat",
                                   remoteStoredID: "saved-h")
        let model = ChatModel(conversationID: "app-row-1", client: NativeWorkspaceUnavailableClient(),
                              sourceSession: record)
        let visible = BighelpVisibleChats.shared
        visible.appeared(model)
        defer { visible.disappeared(model) }
        #expect(model.nativeConversationClient == nil)
        #expect(visible.isShowing(chat: reference("saved-h"), agent: "default"))
        #expect(!visible.isShowing(chat: reference("saved-other"), agent: "default"))
    }

    @Test func aChatWhoseConnectionIsMadeAgainIsStillOnScreen() throws {
        let chat = try open(profile: "default", stored: "saved-i")
        defer { chat.close() }
        // Back from the background the chat's client can be swapped for a moment.
        chat.model.client = NativeWorkspaceUnavailableClient()
        #expect(BighelpVisibleChats.shared.isShowing(chat: reference("saved-i"), agent: "default"))
    }

    // MARK: A compacted chat

    @Test func aCompactedChatKeepsAnsweringToItsEarlierStoredIDs() throws {
        let chat = try open(profile: "default", stored: "saved-f")
        defer { chat.close() }
        chat.client.adoptStoredID("saved-f-next")
        let visible = BighelpVisibleChats.shared
        #expect(visible.isShowing(chat: reference("saved-f-next"), agent: "default"))
        #expect(visible.isShowing(chat: reference("saved-f"), agent: "default"), "A push sent before the move")
        #expect(!visible.isShowing(chat: reference("saved-elsewhere"), agent: "default"))
        #expect(chat.client.formerStoredIDs == ["saved-f"])
    }

    @Test func theTurnThatCompactedAChatIsQuietBeforeTheAppHearsOfTheNewID() throws {
        let chat = try open(profile: "default", stored: "saved-g")
        defer { chat.close() }
        let visible = BighelpVisibleChats.shared
        let successor = reference("saved-g-successor")
        chat.model.isSending = true
        #expect(!visible.isShowing(chat: successor, agent: "default"), "No compaction: it is another chat's")

        chat.model.confirmCompaction()
        #expect(visible.isShowing(chat: successor, agent: "default"))
        #expect(!visible.isShowing(chat: successor, agent: "someone-else"))
        #expect(!visible.isShowing(chat: successor, agent: nil))

        chat.model.isSending = false
        #expect(visible.isShowing(chat: successor, agent: "default", now: Date()), "The reply that just finished")
        #expect(!visible.isShowing(
            chat: successor, agent: "default", now: Date().addingTimeInterval(BighelpVisibleChats.recentTurnWindow + 1)))
    }

    // MARK: Foreground presentation

    private func facts(_ eventType: String, chat: String, agent: String = "default",
                       thread: String = "bighelp.agent.0123456789abcdef",
                       level: UNNotificationInterruptionLevel = .active) -> BighelpForegroundAlert.Facts {
        BighelpForegroundAlert.Facts(
            userInfo: ["loopdy": ["eventType": eventType, "sessionReference": chat, "agent": ["id": agent]]],
            thread: thread, interruptionLevel: level)
    }

    @Test func noAlertOfAnyKindShowsForTheOpenChat() throws {
        let chat = try open(profile: "default", stored: "saved-j")
        defer { chat.close() }
        let open = reference("saved-j"), other = reference("saved-k")
        for kind in ["session.completed", "session.failed", "approval.required", "clarification.required",
                     "scheduled.completed", "subagent.completed"] {
            #expect(BighelpForegroundAlert.options(facts(kind, chat: open)) == [], "\(kind) for the chat on screen")
            #expect(BighelpForegroundAlert.options(facts(kind, chat: other)) == [.banner, .list, .sound],
                    "\(kind) for another chat still shows")
        }
        #expect(BighelpForegroundAlert.options(facts("subagent.completed", chat: other, level: .passive)) == [.list])
    }

    @Test func aPushThatCarriesTheChatOnlyAsItsThreadIsQuietToo() throws {
        let chat = try open(profile: "default", stored: "saved-l")
        defer { chat.close() }
        let older = BighelpForegroundAlert.Facts(userInfo: ["loopdy": ["eventType": "session.completed"]],
                                                 thread: reference("saved-l"), interruptionLevel: .active)
        #expect(BighelpForegroundAlert.options(older) == [])
    }

    @Test func bighelpsOwnQuestionAndRetryAlertsAreQuietForTheOpenChat() throws {
        let model = ChatModel(conversationID: "app-chat-2", client: NativeWorkspaceUnavailableClient())
        BighelpVisibleChats.shared.appeared(model)
        defer { BighelpVisibleChats.shared.disappeared(model) }
        func ownAlert(for conversationID: String) throws -> BighelpForegroundAlert.Facts {
            let link = try #require(BighelpPromptAlertLink.url(conversationID: conversationID))
            return BighelpForegroundAlert.Facts(userInfo: [BighelpPromptAlertLink.userInfoKey: link.absoluteString],
                                                thread: "bighelp.agent.0123456789abcdef", interruptionLevel: .active)
        }
        let forOpenChat = try ownAlert(for: "app-chat-2"), forAnotherChat = try ownAlert(for: "another-chat")
        #expect(BighelpForegroundAlert.options(forOpenChat) == [])
        #expect(BighelpForegroundAlert.options(forAnotherChat) == [.banner, .list, .sound])
    }

    @Test func openingAChatClearsItsDeliveredAlertsHoweverTheyNameIt() throws {
        let chatRef = reference("saved-n")
        let link = try #require(BighelpPromptAlertLink.url(conversationID: "app-chat-1"))
        let chats: Set<String> = [chatRef], conversations: Set<String> = ["app-chat-1"]
        func read(_ userInfo: [AnyHashable: Any], thread: String = "bighelp.agent.0123456789abcdef") -> Bool {
            BighelpVisibleChats.isRead(userInfo: userInfo, thread: thread, chats: chats, conversations: conversations)
        }
        #expect(read(["loopdy": ["sessionReference": chatRef]]))
        #expect(!read(["loopdy": ["sessionReference": reference("saved-o")]]))
        #expect(read([BighelpPromptAlertLink.userInfoKey: link.absoluteString]))
        #expect(read([:], thread: chatRef), "An alert that carries the chat only as its thread")
        #expect(!read([:]))
    }
}
