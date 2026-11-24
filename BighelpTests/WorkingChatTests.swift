import CoreGraphics
import Testing
@testable import Bighelp

/// Who a place says is working, and where "go to the working chat" leads: the Dynamic Island's
/// touch and hold, and the pill in a chat's side column on the iPhone Duo.
struct WorkingChatTests {
    private let budget = WorkingChat(conversationID: "budget", agentID: "avery", kind: .coding)
    private let taxes = WorkingChat(conversationID: "taxes", agentID: "avery", kind: .thinking)
    private let trip = WorkingChat(conversationID: "trip", agentID: "mina", kind: .web)

    // MARK: Where a tap leads

    @Test func workInAnotherChatOfTheSameAgentOpensThatChat() {
        // One agent, two chats: the work is in the one that isn't on screen. Comparing agents
        // called this "already there" and the tap did nothing.
        #expect(WorkingChatDestination.resolve(workingConversationID: "budget", agentID: "avery",
                                               openConversationID: "taxes", openAgentID: "avery")
            == .chat(conversationID: "budget"))
    }

    @Test func theChatOnScreenStaysWhereItIs() {
        #expect(WorkingChatDestination.resolve(workingConversationID: "budget", agentID: "avery",
                                               openConversationID: "budget", openAgentID: "avery") == .stay)
    }

    @Test func workInAnotherAgentsChatOpensThatChatFromAnyScreen() {
        #expect(WorkingChatDestination.resolve(workingConversationID: "trip", agentID: "mina",
                                               openConversationID: "budget", openAgentID: "avery")
            == .chat(conversationID: "trip"))
        // From a list, with no chat on screen.
        #expect(WorkingChatDestination.resolve(workingConversationID: "trip", agentID: "mina",
                                               openConversationID: nil, openAgentID: nil)
            == .chat(conversationID: "trip"))
    }

    @Test func workThatNamesNoChatGoesToTheAgentsOwnChat() {
        #expect(WorkingChatDestination.resolve(workingConversationID: nil, agentID: "avery",
                                               openConversationID: "trip", openAgentID: "mina")
            == .agentChat(agentID: "avery"))
        #expect(WorkingChatDestination.resolve(workingConversationID: nil, agentID: "avery",
                                               openConversationID: "budget", openAgentID: "avery") == .stay)
    }

    // MARK: The Duo's column

    @Test func theColumnShowsWorkInAChatThatIsNotThisOne() {
        // The newest first, whichever agent's it is.
        #expect(WorkingChatPick.elsewhere(than: "taxes", working: [trip, budget, taxes]) == trip)
        #expect(WorkingChatPick.elsewhere(than: "trip", working: [trip, budget, taxes]) == budget)
        // The same agent's other chat counts: it is another chat.
        #expect(WorkingChatPick.elsewhere(than: "taxes", working: [taxes, budget]) == budget)
    }

    @Test func theColumnIsEmptyWhileOnlyThisChatWorksOrNobodyDoes() {
        #expect(WorkingChatPick.elsewhere(than: "budget", working: [budget]) == nil)
        #expect(WorkingChatPick.elsewhere(than: "budget", working: []) == nil)
        // A turn that ended is not work.
        let ended = WorkingChat(conversationID: "trip", agentID: "mina", kind: .done)
        #expect(WorkingChatPick.elsewhere(than: "budget", working: [ended]) == nil)
    }

    @Test func thePillShowsOnlyWhereTheColumnIsThereAnyway() {
        var cover = BighelpScreenGeometry()
        cover.posture = .cover
        cover.sideColumnWidth = 84
        // The Duo's cover screen has the system's column, with or without the switcher.
        #expect(WorkingChatPill.isShown(screen: cover, hasSwitcher: false))
        #expect(WorkingChatPill.isShown(screen: cover, hasSwitcher: true))
        // Half of the open screen in Split View has the cover layout and no column of the system's:
        // the pill shows in the room the switcher keeps, and never makes room of its own.
        var half = cover
        half.sideColumnWidth = 0
        #expect(WorkingChatPill.isShown(screen: half, hasSwitcher: true))
        #expect(!WorkingChatPill.isShown(screen: half, hasSwitcher: false))
        // Every other screen: the list beside the chat, a big phone, an iPhone with an island, iPad.
        for posture in [BighelpScreenPosture.open, .openUpright, .standard] {
            var other = cover
            other.posture = posture
            #expect(!WorkingChatPill.isShown(screen: other, hasSwitcher: true))
        }
    }

    // MARK: The Dynamic Island

    @Test func theIslandShowsTheChatOnScreenThenTheHomeAgentsNewestWork() {
        #expect(WorkingChatPick.island(openConversationID: "trip", working: [budget, trip], homeAgentID: "avery") == trip)
        #expect(WorkingChatPick.island(openConversationID: "taxes", working: [budget], homeAgentID: "avery") == budget)
        #expect(WorkingChatPick.island(openConversationID: nil, working: [taxes, budget], homeAgentID: "avery") == taxes)
        // Another agent's chat that isn't on screen stays off the island, as before.
        #expect(WorkingChatPick.island(openConversationID: nil, working: [trip], homeAgentID: "avery") == nil)
        #expect(WorkingChatPick.island(openConversationID: nil, working: [], homeAgentID: "avery") == nil)
    }
}
