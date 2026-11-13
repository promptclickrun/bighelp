import Foundation
import Testing
@testable import Bighelp

/// New chat's To row and the blank chat under it must agree, and what the person typed goes where
/// the pick goes or stays where it is.
@MainActor
struct NewChatPickTests {
    private static let home = UUID()
    private static let studio = UUID()

    private func bot(_ id: String, on hostID: UUID? = nil) -> SimpleBotsBot {
        SimpleBotsBot(id: hostID.map { "\($0)/\(id)" } ?? id, profileID: id, hostID: hostID,
                      name: id.capitalized, role: "")
    }

    private func pick(_ recipients: [SimpleBotsBot], blank: [String]?, hasFleet: Bool = false,
                      hostInUse: UUID? = nil) -> NewChatPick {
        NewChatPick.decide(recipients: recipients, blankMembers: blank, hasFleet: hasFleet, hostInUse: hostInUse)
    }

    @Test func oneBotMakesTheBlankChatThatBots() {
        #expect(pick([], blank: ["primary"]) == .keep, "Nobody picked: the blank chat stays the primary bot's")
        #expect(pick([bot("mina")], blank: ["primary"]) == .start(profileID: "mina"))
        #expect(pick([bot("mina")], blank: ["mina"]) == .keep)
        #expect(pick([bot("mina"), bot("otto")], blank: ["primary"]) == .keep, "A group chat is made at Send")
        #expect(pick([bot("mina")], blank: nil) == .start(profileID: "mina"))
    }

    @Test func aBotOnAnotherComputerSwitchesThereFirst() {
        let onStudio = bot("mina", on: Self.studio)
        #expect(pick([onStudio], blank: ["mina"], hasFleet: true, hostInUse: Self.home)
            == .switchComputer(Self.studio, profileID: "mina"), "The same profile name there is another bot")
        #expect(pick([onStudio], blank: ["primary"], hasFleet: true, hostInUse: Self.studio) == .start(profileID: "mina"))
        #expect(pick([onStudio], blank: ["primary"], hasFleet: false, hostInUse: nil) == .start(profileID: "mina"),
                "Without other computers to switch to, every bot is on this one")
    }

    /// One chat starts at a time, and the first start runs from the blank canvas until the computer
    /// has made the chat. A pick in that time was dropped: the To row said Otto and the chat was
    /// Mina's. It waits, and when the start ends the To row as it is then gets the chat.
    @Test func thePickMadeWhileAChatStartsIsTheOneThatGetsTheChat() {
        let session = NewChatSession()
        session.start(conversationID: "canvas")
        var gate = NewChatPickGate()
        let rules = NewChatGroupRules()

        session.toggle(bot("mina"), rules: rules)
        #expect(pick(session.recipients, blank: ["primary"]) == .start(profileID: "mina"))
        // Mina's chat is starting. The person changes their mind twice.
        session.remove(bot("mina"))
        session.toggle(bot("otto"), rules: rules)
        gate.hold()
        session.remove(bot("otto"))
        session.toggle(bot("juno"), rules: rules)
        gate.hold()

        // Mina's chat arrived: the To row is read again, once.
        let readsAgain = gate.release()
        #expect(readsAgain)
        #expect(pick(session.recipients, blank: ["mina"]) == .start(profileID: "juno"))
        let readsOnceMore = gate.release()
        #expect(!readsOnceMore, "A start with no pick behind it starts nothing more")
    }

    @Test func aStartWithNoPickBehindItStartsNothingMore() {
        var gate = NewChatPickGate()
        let readsAgain = gate.release()
        #expect(!readsAgain)
    }

    // MARK: A pick on another computer

    private func model(_ draft: String) -> ChatModel {
        let model = ChatModel(conversationID: "blank", client: ConversationFixtureClient(), initialItems: [])
        model.draft = draft
        return model
    }

    /// New chat's text and To row go with the switch. A switch that doesn't open must leave none
    /// of it behind: a later New chat on that computer started with the old message and To row.
    @Test(arguments: [FleetOpenEnd.refused, .cancelled, .unanswered])
    func aSwitchThatDoesNotOpenDropsWhatNewChatHandedOver(_ end: FleetOpenEnd) {
        let home = HomeSelection()
        let blank = model("hello")
        home.newChat.start(with: [bot("mina", on: Self.studio), bot("otto", on: Self.studio)])
        home.newChat.ask(.startGroup)
        home.handOffNewChat(NewChatHandoff(text: "hello", followsPick: true, source: blank))

        #expect(home.takeNewChatHandoff(after: end) == nil)

        #expect(home.newChatHandoff == nil)
        #expect(home.takeNewChatHandoff(after: .opened) == nil, "Nothing is left for the next switch")
        #expect(blank.draft == "hello", "The box still has the text")
        #expect(!home.newChat.isStartingGroup, "Send is free again")
    }

    @Test func aSwitchThatOpensTakesTheTextAndTheBoxLetsItGoOnceItArrives() throws {
        let home = HomeSelection()
        let blank = model("hello")
        home.handOffNewChat(NewChatHandoff(text: "hello", followsPick: true, source: blank))

        let handoff = try #require(home.takeNewChatHandoff(after: .opened))
        #expect(handoff.text == "hello")
        #expect(handoff.followsPick)
        #expect(home.newChatHandoff == nil)
        #expect(blank.draft == "hello", "Not before the other computer has it")

        handoff.delivered()
        #expect(blank.draft.isEmpty)
    }

    @Test func textChangedSinceTheSwitchStaysInItsBox() {
        let blank = model("hello")
        let handoff = NewChatHandoff(text: "hello", followsPick: false, source: blank)
        blank.draft = "hello again"

        handoff.delivered()

        #expect(blank.draft == "hello again")
    }

    // MARK: The blank chat under a chat that takes its place

    /// New chat's blank chat goes when a group chat takes its place. A chat that was New chat's and
    /// has a message is an ordinary chat: a group chat opened over it later (an alert, a link) must
    /// leave it for Back.
    @Test func aChatWithAMessageStaysUnderTheChatThatOpensOverIt() {
        let state = AppState()
        state.activateConversation(id: "mina-chat", source: .newChat)
        state.activateConversation(id: "group", source: .sessions)

        state.dropBlankChat("mina-chat", under: "group", isBlank: false)
        #expect(state.path == [.chat(conversationID: "mina-chat"), .chat(conversationID: "group")])

        state.dropBlankChat("mina-chat", under: "group", isBlank: true)
        #expect(state.path == [.chat(conversationID: "group")])
    }

    @Test func theBlankChatStaysUntilTheChatThatTakesItsPlaceIsOpen() {
        let state = AppState()
        state.activateConversation(id: "blank", source: .newChat)

        state.dropBlankChat("blank", under: "group", isBlank: true)
        #expect(state.path == [.chat(conversationID: "blank")], "The group chat didn't open")
        state.dropBlankChat("blank", under: "blank", isBlank: true)
        #expect(state.path == [.chat(conversationID: "blank")])
    }

    @Test func aChatIsBlankForNewChatOnlyUntilSomethingIsSentOrFails() {
        let blank = ChatModel(conversationID: "blank", client: ConversationFixtureClient(), initialItems: [])
        #expect(blank.isBlankForNewChat)
        blank.draft = "Typing doesn't count"
        #expect(blank.isBlankForNewChat)

        let sent = ChatModel(conversationID: "sent", client: ConversationFixtureClient(), initialItems: [
            TimelineItem(id: "first", role: .human, sender: .user(snapshot: .init(name: "You")),
                         content: .message("Hello"), metadata: .init(delivery: "Sent")),
        ])
        #expect(!sent.isBlankForNewChat)

        blank.failureMessage = "This chat couldn't start."
        #expect(!blank.isBlankForNewChat)
    }

    // MARK: The chat that is open

    /// Back, a tab or a computer's pages closing take a chat off the stack: it isn't the open chat
    /// any more, whatever was opened last.
    @Test func aChatThatLeftTheStackIsNotTheOpenChat() {
        let state = AppState()
        state.activateConversation(id: "mina-chat", source: .sessions)
        #expect(state.activeConversationID == "mina-chat")

        state.open(.simpleBotProfile(agentID: "mina"))
        #expect(state.activeConversationID == "mina-chat", "A page over the chat leaves it open")

        state.path.removeLast(2)
        #expect(state.activeConversationID == nil)
        #expect(state.chatOnScreen == nil)

        state.activateConversation(id: "otto-chat", source: .sessions)
        state.select(.today)
        #expect(state.activeConversationID == nil)
    }

    /// Every computer has its own `AppState`. The alert's tap reaches the app's first one; the shell
    /// on screen reads the computer in use's.
    @Test func anAlertWithoutAChatReachesWhicheverStateTheShellReads() {
        let home = HomeSelection()
        let first = AppState(home: home), computers = AppState(home: home)

        first.openNeedsYou()
        #expect(computers.isNeedsYouRequested)

        computers.isNeedsYouRequested = false
        #expect(!first.isNeedsYouRequested)
    }
}
