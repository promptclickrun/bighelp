import Foundation
import Testing
@testable import Bighelp

/// Blueprints in the message box, and what the Needs you deck lists.
@MainActor
struct NeedsYouBlueprintsModesTests {
    // MARK: Blueprints

    @Test func startersHaveBlanksAndCoverMoreThanOneTopic() throws {
        let catalog = try BoardBlueprintCatalog.bundled()
        for kind in [AgentBoardItem.Kind.feed, .idea, .goal] {
            let starters = catalog.starterBlueprints(for: kind, limit: 3)
            #expect(starters.count == 3)
            #expect(starters.allSatisfy { !BlueprintAdLib($0.text).blanks.isEmpty })
            #expect(Set(starters.map(\.category)).count >= 2)
        }
    }

    private func chat(_ id: String) -> ChatModel {
        ChatModel(conversationID: id, client: ConversationFixtureClient(), initialItems: [])
    }

    @Test func aBlueprintHoldsSendUntilItsBlanksAreFilled() async {
        let model = chat("blueprint-chips")
        #expect(model.beginBlueprintDraft(
            "Every morning, check mentions of [my brand] on my latest [videos / posts] under $[50]."
        ))
        let draft = model.blueprintDraft
        #expect(draft?.blanks.count == 3)
        // A choice starts on its first option and a number on its example; the typed blank is empty.
        #expect(draft?.activeBlankID == 0)
        #expect(draft?.hasValue(for: 1) == true)
        #expect(draft?.hasValue(for: 2) == true)
        #expect(!model.canSend)

        // "$" and "." stay on their blank, so no chip is left with a stray gap ("$ 50 .").
        if case .blank(let blank, let prefix, let suffix)? = draft?.tokens.last {
            #expect(blank.id == 2)
            #expect(prefix == "$")
            #expect(suffix == ".")
        } else {
            Issue.record("The last piece is the $[50]. blank")
        }

        model.updateBlueprintBlank(0, value: "Acme")
        #expect(model.draft == "Every morning, check mentions of Acme on my latest videos under $50.")
        #expect(model.canSend)

        await model.send()
        #expect(model.blueprintDraft == nil)
    }

    /// Brackets are blanks only in a blueprint. A post's title or text the person typed that has
    /// them ("About “[Weekly] roundup”: ") used to hide the message box and hold Send.
    @Test func onlyABlueprintsBracketsAreBlanks() {
        let state = AppState()
        state.leaveComposerText("About “[Weekly] roundup”: ")
        #expect(state.takeComposerText(isNewChat: true, isNamedBotChat: false)?.fillsBlanks == false)
        state.leaveComposerText("Track [habit] for [30] days.", fillsBlanks: true)
        #expect(state.takeComposerText(isNewChat: true, isNamedBotChat: false)?.fillsBlanks == true)
    }

    /// A new chat starts on a blank canvas that is thrown away when Hermes' chat arrives. The canvas
    /// took the board's text, and when its draft didn't get across in time the new chat opened empty.
    @Test func aBlankCanvasShowsTheTextAndTheChatThatReplacesItTakesIt() {
        let state = AppState()
        state.leaveComposerText("Track [habit] for [30] days.", fillsBlanks: true)
        #expect(state.showComposerText()?.text == "Track [habit] for [30] days.")
        #expect(state.pendingComposerText != nil, "Showing it doesn't take it")
        let taken = state.takeComposerText(isNewChat: true, isNamedBotChat: false)
        #expect(taken?.text == "Track [habit] for [30] days.")
        #expect(taken?.fillsBlanks == true)
        #expect(taken?.wasShown == true)
        #expect(state.pendingComposerText == nil)

        // A bot's Dashboard names its bot's own chat: no canvas shows that text.
        state.leaveComposerText("Run this", agentID: "kai")
        #expect(state.showComposerText() == nil)
        #expect(state.takeComposerText(isNewChat: false, isNamedBotChat: true)?.wasShown == false)
    }

    /// The chips are the draft. A send that takes the draft another way (a steer or queue into a
    /// running turn) left them behind over an empty box, and other text put in the box was
    /// written over by them at Send.
    @Test func theChipsGoWhenTheDraftBecomesAnythingElse() {
        let model = chat("blueprint-follows-draft")
        #expect(model.beginBlueprintDraft("Every Monday, check what [competitor] shipped."))
        model.updateBlueprintBlank(0, value: "Acme")
        model.draft = ""
        #expect(model.blueprintDraft == nil)

        #expect(model.beginBlueprintDraft("Every Monday, check what [competitor] shipped."))
        model.draft = "Something else"
        #expect(model.blueprintDraft == nil)
        #expect(model.draft == "Something else")
    }

    @Test func editingAsTextKeepsWhatWasFilledIn() {
        let model = chat("blueprint-as-text")
        #expect(model.beginBlueprintDraft("Every Monday, check what [competitor] shipped."))
        model.updateBlueprintBlank(0, value: "Acme")
        model.convertBlueprintToPlainText()
        #expect(model.blueprintDraft == nil)
        #expect(model.draft == "Every Monday, check what Acme shipped.")
        #expect(model.canSend)
    }

    /// A new chat's blank canvas is replaced by the chat Hermes made; the draft goes across as
    /// text, and the chips follow only onto that same text.
    @Test func chipsFollowTheSameTextIntoTheChatThatReplacesTheCanvas() throws {
        let canvas = chat("local-draft:canvas")
        #expect(canvas.beginBlueprintDraft("Track [habit] for [30] days."))
        let blueprint = try #require(canvas.blueprintDraft)

        let same = chat("session-same")
        same.draft = canvas.draft
        same.adoptBlueprintDraft(blueprint)
        #expect(same.blueprintDraft == blueprint)

        let other = chat("session-other")
        other.draft = "Something the person typed"
        other.adoptBlueprintDraft(blueprint)
        #expect(other.blueprintDraft == nil)
    }

    // MARK: Needs you

    /// On a real host one prompt reaches the app twice: on its chat's connection and as the
    /// Dashboard's item. Both name the prompt, so the deck lists it once.
    @Test func aDashboardItemNamesItsPrompt() {
        let approval = DashboardAttentionItem(
            id: "native.approval.p1", title: "git push", detail: "", urgency: .needsReview, approvalID: "p1",
            interaction: .approval(DashboardApprovalRequest(eventID: "native.approval.p1", approvalID: "p1",
                                                            allowedDecisions: [.once, .deny], expiresAt: .distantFuture)))
        #expect(approval.promptID == "p1")

        let question = DashboardAttentionItem(
            id: "native.clarification.p2", title: "Hermes has a question", detail: "Which one?", urgency: .important,
            interaction: .clarification(DashboardClarificationRequest(
                eventID: "native.clarification.p2", requestID: "p2", sessionID: "s", question: "Which one?",
                choices: ["A", "B"], allowsCustomResponse: true, isMultiSelect: false, expiresAt: nil)))
        #expect(question.promptID == "p2")

        #expect(DashboardAttentionItem(id: "note", title: "Read this", detail: "", urgency: .needsReview).promptID == nil)
    }

    @Test func aWaitingBotEntryShowsItsAgent() {
        let entry = NeedsYouEntry(id: "waiting-bot:finance", payload: .waitingBot(.init(
            agentID: "finance", agentName: "Avery Park", agentRole: "Finance agent", hostName: "Mac Studio")))
        #expect(entry.kind == .waiting)
        #expect(entry.agent?.id == "finance")
        #expect(entry.title == "Avery Park")
        #expect(entry.detail == "Mac Studio · Finance agent")
    }
}
