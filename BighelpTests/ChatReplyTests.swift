import Foundation
import Testing
@testable import Bighelp

/// Replying to a message: the quote line the agent reads, its bounds, the
/// draft it rides with, and the bubble a reloaded chat draws from the host's text.
@MainActor
struct ChatReplyTests {
    @Test func everyAuthorRoundTripsThroughTheSentText() throws {
        let bodies = ["Sounds good", "Two lines\nof reply", "", "Quote \"marks\"] and [brackets]"]
        let authors: [ChatReplyQuote.Author] = [.agent, .me, .named("Avery Park"), .unnamed]
        for author in authors {
            for body in bodies {
                let quote = ChatReplyQuote(author: author, quoting: "He said \"ship it\"] today")
                let sent = quote.prefixing(body)
                let read = try #require(ChatReplyQuote.split(sent), "\(author) \(body)")
                #expect(read.quote == quote)
                #expect(read.body == body)
            }
        }
    }

    @Test func theAgentReadsHermesOwnReplyLine() {
        let quote = ChatReplyQuote(author: .agent, quoting: "The invoice is due Friday.")
        #expect(quote.prefixing("Can we pay it today?")
            == "[Replying to your previous message: \"The invoice is due Friday.\"]\n\nCan we pay it today?")
        #expect(ChatReplyQuote(author: .me, quoting: "Remind me").header
            == "[Replying to my previous message: \"Remind me\"]")
        #expect(ChatReplyQuote(author: .named("Rivet"), quoting: "Done").header == "[Replying to Rivet: \"Done\"]")
        // Hermes' form for other platforms' chats reads back too.
        #expect(ChatReplyQuote.split("[Replying to: \"Lunch?\"]\n\nYes")?.quote.author == .unnamed)
    }

    @Test func theSnippetIsOneBoundedLine() {
        let long = String(repeating: "word ", count: 400)
        let quote = ChatReplyQuote(author: .agent, quoting: "  First line\n\n- second\tline  ")
        #expect(quote.snippet == "First line - second line")
        let bounded = ChatReplyQuote(author: .agent, quoting: long)
        #expect(bounded.snippet.count <= ChatReplyQuote.maximumSnippetLength + 1)
        #expect(bounded.snippet.hasSuffix("…"))
        #expect(!bounded.header.contains("\n"))
        #expect(ChatReplyQuote.split(bounded.prefixing("ok"))?.quote == bounded)
        let exact = String(repeating: "a", count: ChatReplyQuote.maximumSnippetLength)
        #expect(ChatReplyQuote(author: .agent, quoting: exact).snippet == exact)
        #expect(ChatReplyQuote(author: .agent, quoting: " \n ").snippet == "…")
    }

    @Test func quotingAReplyQuotesOnlyItsMessage() {
        let first = ChatReplyQuote(author: .agent, quoting: "Original").prefixing("My answer")
        let second = ChatReplyQuote(author: .me, quoting: first)
        #expect(second.snippet == "My answer")
    }

    @Test func namesCantBreakTheLineOrMention() {
        let quote = ChatReplyQuote(author: .named("@Ava: \"the\"\n[bot]" + String(repeating: "x", count: 80)),
                                   quoting: "hi")
        guard case .named(let name) = quote.author else { Issue.record("named"); return }
        #expect(!name.contains(where: { "[]\":@\n".contains($0) }))
        #expect(name.count <= ChatReplyQuote.maximumNameLength)
        #expect(ChatReplyQuote.split(quote.prefixing("ok"))?.quote == quote)
        #expect(ChatReplyQuote(author: .named(" :@ "), quoting: "hi").author == .unnamed)
    }

    @Test func quotedHandlesDontRouteAGroupChat() throws {
        let quote = ChatReplyQuote(author: .named("Rivet"), quoting: "Ask @claude and @everyone")
        #expect(try MentionParser.tokens(in: quote.header).isEmpty)
        #expect(quote.displaySnippet == "Ask @claude and @everyone")
        #expect(try MentionParser.tokens(in: quote.prefixing("@claude go")).map(\.handle) == ["claude"])
    }

    @Test func ordinaryTextIsNotAReply() {
        for text in ["Hello", "[Replying to nothing", "[Replying to Avery: \"open\nended\"]",
                     "[Replying to Avery \"no colon\"]", "Note: [Replying to Avery: \"x\"]",
                     "[Replying to Avery: \"\"]",
                     "[Replying to Avery: \"" + String(repeating: "a", count: 900) + "\"]"] {
            #expect(ChatReplyQuote.split(text) == nil, "\(text)")
        }
    }

    @Test func sendingPutsTheQuoteBeforeTheMessageAndClearsIt() async {
        let client = RecordingClient()
        let model = ChatModel(conversationID: "reply-send", client: client, initialItems: [])
        let quote = ChatReplyQuote(author: .agent, quoting: "Your flight leaves at 9.")
        model.replyDraft = quote
        model.draft = "Can you book a taxi?"
        await model.send()
        #expect(client.messages == [quote.prefixing("Can you book a taxi?")])
        #expect(model.replyDraft == nil)
        #expect(model.draft.isEmpty)
        guard case .message(let text)? = model.items.first?.content else { Issue.record("sent row"); return }
        #expect(ChatReplyQuote.split(text)?.quote == quote)
    }

    @Test func commandsGoOutWithoutTheQuote() async {
        let client = RecordingClient()
        let model = ChatModel(conversationID: "reply-command", client: client, initialItems: [])
        model.replyDraft = ChatReplyQuote(author: .agent, quoting: "Earlier")
        model.draft = "/help"
        #expect(model.outgoingDraftText == "/help")
    }

    @Test func theReplyIsSavedAndRestoredWithTheDraft() {
        var saved = ""
        let model = ChatModel(conversationID: "reply-draft", client: RecordingClient(), initialItems: [],
                              onSessionChange: { draft, _, _, _ in saved = draft })
        let quote = ChatReplyQuote(author: .named("Avery Park"), quoting: "Budget is ready")
        model.draft = "Thanks, half done"
        model.replyDraft = quote
        model.flushPersistence()
        #expect(saved == quote.prefixing("Thanks, half done"))

        let reopened = ChatModel(conversationID: "reply-draft", client: RecordingClient(), initialItems: [],
                                 initialDraft: saved)
        #expect(reopened.replyDraft == quote)
        #expect(reopened.draft == "Thanks, half done")

        model.replyDraft = nil
        model.flushPersistence()
        #expect(saved == "Thanks, half done")
    }

    @Test func aMessagePutBackInTheComposerKeepsItsReply() {
        let model = ChatModel(conversationID: "reply-restore", client: RecordingClient(), initialItems: [])
        let quote = ChatReplyQuote(author: .agent, quoting: "Pick a time")
        // Failed and refused sends put the sent text back as the draft.
        model.draft = quote.prefixing("3 pm works")
        #expect(model.replyDraft == quote)
        #expect(model.draft == "3 pm works")
    }

    @Test func aReloadedChatStillDrawsTheReply() throws {
        let quote = ChatReplyQuote(author: .agent, quoting: "**Bold** plan")
        let hostText = quote.prefixing("Let's do it")
        // History from Hermes goes through the same display cleanup as any user row.
        let reloaded = HermesUserMessageDisplay.text(hostText)
        let projection = ChatMessageContentCache().project(reloaded, role: .human)
        #expect(projection.reply == quote)
        #expect(projection.document.visiblePlainText == "Let's do it")
        // Agents' own text is never read as a reply.
        #expect(ChatMessageContentCache().project(hostText, role: .assistant).reply == nil)
        #expect(HermesUserMessageDisplay.preview(hostText) == "Let's do it")
        let item = TimelineItem(id: "reloaded", role: .human, sender: .user(snapshot: .init(name: "You")),
                                content: .message(hostText), metadata: .init())
        #expect(!TimelineSenderResolver().accessibilityDescription(for: item).contains("Replying to"))
    }

    @Test func aQuoteNamesWhoItAnswers() {
        let agentMessage = TimelineItem(id: "a", role: .assistant,
                                        sender: .agent(id: "finance", snapshot: .init(name: "Avery Park")),
                                        content: .message("Here's the **plan**.\n\n- one\n- two"), metadata: .init())
        let mine = TimelineItem(id: "h", role: .human, sender: .user(snapshot: .init(name: "You")),
                                content: .message("Remind me at 5"), metadata: .init())
        let direct = ChatReplyQuote(replyingTo: agentMessage, senderName: "Avery Park", isGroup: false)
        #expect(direct.author == .agent)
        #expect(direct.snippet == "Here's the plan. one two")
        #expect(ChatReplyQuote(replyingTo: agentMessage, senderName: "Avery Park", isGroup: true).author
            == .named("Avery Park"))
        #expect(ChatReplyQuote(replyingTo: mine, senderName: "You", isGroup: true).author == .me)
        #expect(direct.title(agentName: "Avery Park") == "Replying to Avery Park")
        #expect(ChatReplyQuote(replyingTo: mine, senderName: "You", isGroup: false).title(agentName: "Avery")
            == "Replying to yourself")
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
