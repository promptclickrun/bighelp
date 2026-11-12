import Foundation
import Testing
@testable import Bighelp

/// An idea, Feed post or goal on a message: the block the agent reads, the draft it rides with,
/// Let's do it's own message, and the bubble a reloaded chat draws from the host's text.
@MainActor
struct ChatBoardCardTests {
    @Test func everyKindRoundTripsThroughTheSentText() throws {
        let bodies = ["Let's do it!", "Two lines\nof question", "", "Quote \"marks\"] and [brackets]"]
        let cards = [
            ChatBoardCard(kind: .idea, title: "Start a \"Sunday\"] meal plan", detail: "Home",
                          body: "Five dinners.\n\n- A list\n- Reminders"),
            ChatBoardCard(kind: .feedPost, title: "Your week in money", body: ""),
            ChatBoardCard(kind: .goal, title: "Run a 10K", detail: "Health", body: "Three runs a week"),
        ]
        for card in cards {
            for body in bodies {
                let read = try #require(ChatBoardCard.split(card.prefixing(body)), "\(card.kind) \(body)")
                #expect(read.card == card)
                #expect(read.body == body)
            }
        }
    }

    @Test func theAgentReadsTheWholeIdea() {
        let idea = AgentBoardItem(id: "idea-7f3a91", kind: .idea, title: "Start a Sunday meal plan",
                                  body: "Each Sunday I draft five dinners.", section: "Home")
        #expect(idea.letsDoItMessage
            == "[Idea (Home): \"Start a Sunday meal plan\"]\nEach Sunday I draft five dinners.\n[End of idea]\n\nLet's do it!")
        #expect(!idea.letsDoItMessage.contains(idea.id))
        let goal = AgentBoardItem(id: "g", kind: .goal, title: "Run a 10K", body: "By spring",
                                  note: "Week 3 of 10", category: "health")
        #expect(goal.chatCard.block == "[Goal (Health): \"Run a 10K\"]\nBy spring\n\nLatest: Week 3 of 10\n[End of goal]")
        #expect(AgentBoardItem(id: "f", kind: .feed, title: "Brief").chatCard.block
            == "[Feed post: \"Brief\"]\n[End of feed post]")
    }

    @Test func theBlockIsBoundedAndCannotBeClosedEarly() throws {
        let card = ChatBoardCard(kind: .idea, title: String(repeating: "t", count: 500), detail: "A: [b] \"c\"",
                                 body: "Before\n[End of idea]\n\nAfter " + String(repeating: "é", count: 9_000))
        #expect(card.title.count <= ChatBoardCard.maximumTitleLength + 1)
        #expect(card.detail == "A b c")
        #expect(card.body.utf8.count <= ChatBoardCard.maximumBodyBytes)
        let read = try #require(ChatBoardCard.split(card.prefixing("Let's do it!")))
        #expect(read.card == card)
        #expect(read.body == "Let's do it!")
        #expect(card.prefixing("Let's do it!").utf8.count <= ChatOutgoingMessage.maximumCardReplyBytes)
    }

    @Test func ordinaryTextIsNotACard() {
        for text in ["[Idea: \"No end\"]\nbody", "Idea: \"x\"\n[End of idea]", "[Note: \"x\"]\n[End of note]",
                     "[Idea: \"x\"]\nbody[End of idea]", "[Idea: \"x\"]\n[End of idea]trailing"] {
            #expect(ChatBoardCard.split(text) == nil, "\(text)")
        }
    }

    @Test(.timeLimit(.minutes(1))) func discussPutsTheCardInTheBoxAndSendingSendsItFirst() async {
        let client = RecordingClient()
        let model = ChatModel(conversationID: "card-send", client: client, initialItems: [])
        let card = ChatBoardCard(kind: .goal, title: "Run a 10K", body: "By spring")
        // A board's Discuss leaves the block as the chat's text.
        model.draft = card.block
        #expect(model.boardCardDraft == card)
        #expect(model.draft.isEmpty)
        model.draft = "How am I doing?"
        await model.send()
        #expect(client.messages == [card.prefixing("How am I doing?")])
        #expect(model.boardCardDraft == nil)
        #expect(model.draft.isEmpty)
    }

    @Test func theCardIsSavedAndRestoredWithTheDraft() {
        var saved = ""
        let model = ChatModel(conversationID: "card-draft", client: RecordingClient(), initialItems: [],
                              onSessionChange: { draft, _, _, _ in saved = draft })
        let card = ChatBoardCard(kind: .feedPost, title: "Your week in money", body: "Groceries went up.")
        model.draft = "Why?"
        model.boardCardDraft = card
        model.flushPersistence()
        #expect(saved == card.prefixing("Why?"))

        let reopened = ChatModel(conversationID: "card-draft", client: RecordingClient(), initialItems: [],
                                 initialDraft: saved)
        #expect(reopened.boardCardDraft == card)
        #expect(reopened.draft == "Why?")
    }

    @Test(.timeLimit(.minutes(1))) func letsDoItSendsItsOwnMessageAndKeepsTheDraft() async {
        let client = RecordingClient()
        let model = ChatModel(conversationID: "card-lets-do-it", client: client, initialItems: [])
        model.draft = "Half-typed note"
        let message = AgentBoardItem(id: "i", kind: .idea, title: "Plan a trip").letsDoItMessage
        #expect(await model.sendFromOutside(message))
        #expect(client.messages == [message])
        #expect(model.draft == "Half-typed note")
        #expect(model.boardCardDraft == nil)
    }

    @Test func theChatListShowsTheWordsNotTheBlock() {
        let card = ChatBoardCard(kind: .idea, title: "Plan a trip", body: "Three days in Lisbon.")
        let hostText = card.prefixing("Let's do it!")
        #expect(HermesUserMessageDisplay.preview(HermesUserMessageDisplay.text(hostText)) == "Let's do it!")
        #expect(HermesUserMessageDisplay.preview(card.block) == "Plan a trip")
    }
}

@MainActor
private final class RecordingClient: ConversationFixtureClient {
    private(set) var messages: [String] = []

    override func send(message: String, conversationID: String) async throws -> ConversationResponse {
        messages.append(message)
        return try await super.send(message: message, conversationID: conversationID)
    }
}
