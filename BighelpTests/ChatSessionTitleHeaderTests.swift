import Foundation
import Testing
@testable import Bighelp

/// Settings › Chat › Session title: off by default, and only a title the chat really has
/// shows under the agent's name.
@MainActor
struct ChatSessionTitleHeaderTests {
    @Test func itIsOffUntilChosen() {
        let suite = "session-title-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(defaults.object(forKey: ChatLayoutPreferences.showsSessionTitleKey) == nil)
        #expect(ChatLayoutPreferences.showsSessionTitleByDefault == false)
    }

    @Test func aRealTitleShows() {
        #expect(ChatModel.headerSessionTitle(from: "Trip planning") == "Trip planning")
        #expect(ChatModel.headerSessionTitle(from: "  Budget for October \n") == "Budget for October")
        #expect(ChatModel.headerSessionTitle(from: "Bot Chat · Oct 18") == "Bot Chat · Oct 18")
    }

    /// An untitled chat holds the placeholder "New chat", and an agent's home chat is "Bot Chat":
    /// neither says which chat this is, so the header shows only the agent's name.
    @Test func placeholdersAndBlanksShowNothing() {
        for title in ["", "   ", "New chat", "Bot Chat"] {
            #expect(ChatModel.headerSessionTitle(from: title) == nil, "\(title)")
        }
    }

    @Test func theModelsTitleFollowsRenames() {
        let model = ChatModel(conversationID: "c", client: ConversationFixtureClient(), initialItems: [])
        #expect(model.headerSessionTitle == nil, "A new chat has no title yet")
        model.sessionTitle = "Packing list"
        #expect(model.headerSessionTitle == "Packing list")
    }
}
