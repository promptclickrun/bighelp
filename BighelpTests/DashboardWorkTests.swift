import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DashboardWorkTests {
    @Test func activeWorkReplacesOneHighLevelLineAndKeepsItsTitleAndPosition() async {
        let source = WorkDashboardSource()
        var sessions = [session("one", title: "Improve the Home screen"), session("two", title: "Prepare release notes")]
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 1_000) })
        model.configureWorkSessions { sessions }
        await model.load()
        let initialIDs = model.workInFlightItems.map(\.sessionID)
        #expect(Set(initialIDs) == ["one", "two"])
        #expect(model.workInFlightItems.first(where: { $0.sessionID == "one" })?.subtitle == "Working")
        for (kind, expected) in [(ChatActivityKind.reasoning, "Reasoning"), (.tool, "Making tool calls"), (.subagent, "Calling subagents")] {
            sessions[0].activityEvents = [activity(sessionID: "one", kind: kind)]
            let rows = model.workInFlightItems
            #expect(rows.map(\.sessionID) == initialIDs)
            #expect(rows.count == 2)
            #expect(rows.first(where: { $0.sessionID == "one" })?.title == "Improve the Home screen")
            #expect(rows.first(where: { $0.sessionID == "one" })?.subtitle == expected)
            #expect(!rows.map(\.subtitle).joined().contains("PRIVATE"))
        }
    }

    @Test func completedToolDoesNotCompleteItsStillRunningSession() async {
        let source = WorkDashboardSource()
        var record = session("one", title: "A running conversation")
        record.activityEvents = [activity(sessionID: "one", kind: .tool, lifecycle: .succeeded)]
        let model = DashboardModel(source: source)
        model.configureWorkSessions { [record] }
        await model.load()
        #expect(model.workInFlightItems.map(\.sessionID) == ["one"])
        #expect(model.workInFlightItems.first?.subtitle != "Making tool calls")
        #expect(model.presentedCompletedItems.isEmpty)
    }

    @Test func clarifyPromotesOnlyItsOwnerAndClearingReturnsTheActiveSession() async {
        let source = WorkDashboardSource(attention: [attention("ask", sessionID: "stored-one")])
        let one = session("one", title: "Plan the release", storedID: "stored-one")
        let two = session("two", title: "Review the changes")
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 1_000) })
        model.configureWorkSessions { [one, two] }
        await model.load()
        #expect(model.workInFlightItems.map(\.sessionID) == ["two"])
        await model.dismissAttention(id: "ask")
        #expect(Set(model.workInFlightItems.map(\.sessionID)) == ["one", "two"])
        #expect(source.responses.isEmpty)
    }

    @Test func aSecondClarifyKeepsSessionInNeedsYouUntilBothAreAnswered() async {
        let source = WorkDashboardSource(attention: [attention("first", sessionID: "one"), attention("second", sessionID: "one")])
        let record = session("one", title: "Choose release settings")
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 1_000) })
        model.configureWorkSessions { [record] }
        await model.load()
        await model.respondToClarification(itemID: "first", response: "Use the first option")
        #expect(model.workInFlightItems.isEmpty)
        #expect(model.snapshot?.attentionItems.map(\.id) == ["second"])
        await model.respondToClarification(itemID: "second", response: "Use the second option")
        #expect(model.workInFlightItems.map(\.sessionID) == ["one"])
        #expect(source.responses.count == 2)
    }

    @Test func expirationAndFinishedSessionDoNotFabricateAnActiveRow() async {
        let source = WorkDashboardSource(attention: [attention("expired", sessionID: "one", expiresAt: 999)])
        var record = session("one", title: "A finished conversation")
        record.isActive = false
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 1_000) })
        model.configureWorkSessions { [record] }
        await model.load()
        #expect(model.snapshot?.attentionItems.isEmpty == true)
        #expect(model.workInFlightItems.isEmpty)
        #expect(source.responses.isEmpty)
    }

    @Test func otherProfileClarifyDoesNotHideTheWrongSession() async {
        let source = WorkDashboardSource(attention: [attention("other", sessionID: "stored-one", agentID: "other")])
        let record = session("one", title: "My conversation", storedID: "stored-one")
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 1_000) })
        model.configureWorkSessions { [record] }
        await model.load()
        #expect(model.workInFlightItems.map(\.sessionID) == ["one"])
    }

    @Test func aSessionAppearsInOnlyItsCurrentHomeSectionEvenWithDifferentWireTurnIDs() async {
        let source = WorkDashboardSource(attention: [attention("ask", sessionID: "one")])
        var record = session("one", title: "Current work")
        record.activityEvents = [activity(sessionID: "one", kind: .reasoning)]
        source.completed = [DashboardCompletion(id: "completion", title: "Current work", detail: "Finished",
            status: "session.completed", completedAt: Date(timeIntervalSince1970: 940), completedLabel: "Just now",
            sessionID: "one", agentID: "default", turnID: "raw-host-turn")]
        let model = DashboardModel(source: source, now: { Date(timeIntervalSince1970: 1_000) })
        model.configureWorkSessions { [record] }
        await model.load()
        #expect(model.workInFlightItems.isEmpty)
        #expect(model.presentedCompletedItems.isEmpty)
    }

    @Test func remoteAndLocalHandoffTimestampsRepresentTheSameInstant() {
        func event(_ timestamp: Int) -> ChatActivityEvent {
            ChatActivityEvent(eventID: "handoff", sessionID: "one", turnID: "turn", kind: .botHandoff,
                lifecycle: .running, title: "Working with an agent", summary: nil, detail: nil, occurredAt: timestamp)
        }
        let expected = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(DashboardWorkProjection.activityDate(for: event(1_800_000_000)) == expected)
        #expect(DashboardWorkProjection.activityDate(for: event(1_800_000_000_000)) == expected)
    }

    @Test func streamedReplyUsesDraftingLabelWithoutLeakingItsText() async {
        let source = WorkDashboardSource()
        var record = session("one", title: "Current work")
        record.items = [TimelineItem(id: "reply", role: .assistant, sender: .agent(id: "default", snapshot: .init(name: "Agent")),
            content: .message("PRIVATE streamed reply"), metadata: .init(delivery: "Streaming", timestamp: Date(timeIntervalSince1970: 980)))]
        record.activityEvents = [activity(sessionID: "one", kind: .reasoning)]
        let model = DashboardModel(source: source)
        model.configureWorkSessions { [record] }
        await model.load()
        #expect(model.workInFlightItems.first?.subtitle == "Drafting a reply")
    }

    @Test func primaryCompletionTitlesPreferNamesOverSummaries() {
        for (event, details, title) in [
            ("session.completed", ["title": "Home improvements", "summary": "Finished a substantial set of changes"], "Home improvements"),
            ("job.completed", ["job_title": "Morning briefing", "summary": "Today's news is ready"], "Morning briefing"),
            ("delegation.completed", ["title": "Review accessibility", "summary": "Everything passed"], "Review accessibility"),
        ] {
            let item = DashboardCompletionProjection.make(id: event, eventType: event, detail: details,
                agentName: "Test agent", createdAt: .now, completedLabel: "Just now",
                fallbackTitle: "Generic completion", fallbackDetail: "Finished")
            #expect(item.title == title)
        }
    }

    private func session(_ id: String, title: String, storedID: String? = nil) -> SessionRecord {
        SessionRecord(id: id, kind: .direct, agentIDs: ["default"], title: title,
            remoteStoredID: storedID, isActive: true,
            createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 900))
    }

    private func activity(sessionID: String, kind: ChatActivityKind, lifecycle: ChatActivityLifecycle = .running) -> ChatActivityEvent {
        ChatActivityEvent(eventID: "event-\(kind.rawValue)", sessionID: sessionID, turnID: "turn-current",
            kind: kind, lifecycle: lifecycle, title: "PRIVATE tool or thought",
            summary: "PRIVATE summary", detail: "PRIVATE detail", occurredAt: 950,
            toolCallID: kind == .tool ? "tool-current" : nil,
            toolName: kind == .tool ? "terminal" : nil,
            subagentID: kind == .subagent ? "child-current" : nil)
    }

    private func attention(_ id: String, sessionID: String, agentID: String = "default", expiresAt: TimeInterval = 2_000) -> DashboardAttentionItem {
        let request = DashboardClarificationRequest(eventID: id, requestID: "request-\(id)", sessionID: sessionID,
            question: "Which option?", choices: ["First", "Second"], allowsCustomResponse: true,
            isMultiSelect: false, expiresAt: Date(timeIntervalSince1970: expiresAt))
        return DashboardAttentionItem(id: id, title: "Question", detail: request.question, urgency: .important,
            sessionID: sessionID, agentID: agentID, interaction: .clarification(request), createdAt: Date(timeIntervalSince1970: 900))
    }
}

@MainActor
private final class WorkDashboardSource: DashboardDataSource, DashboardClarificationClient {
    var attention: [DashboardAttentionItem]
    var completed: [DashboardCompletion] = []
    var responses: [String] = []
    init(attention: [DashboardAttentionItem] = []) { self.attention = attention }
    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(inbox: [], attentionItems: attention, completedItems: completed, agents: [])
    }
    func dismissDashboardEvent(id: String) async throws { attention.removeAll { $0.id == id } }
    func respond(to request: DashboardClarificationRequest, response: String) async throws -> DashboardClarificationReceipt {
        responses.append(response)
        attention.removeAll { $0.id == request.eventID }
        return DashboardClarificationReceipt(eventID: request.eventID, requestID: request.requestID)
    }
}
