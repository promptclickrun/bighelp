import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

/// The chat speed checks time each message from Send to its answer's first words on screen
/// (`ChatSendTimings`). Only an answer whose source ties it to that message ends the timing, and a
/// message whose answer can't be tied to it ends with an outcome that says so, never a made-up time.
@MainActor
struct ChatSendTimingsTests {
    @Test func aMessageIsTimedFromSendToItsFirstWordsOnScreen() throws {
        var timings = ChatSendTimings()
        let submission = UUID()
        timings.tapped(conversationID: "chat", at: 10)
        timings.row("q1", conversationID: "chat", staged: false, at: 10.01)
        timings.handedOff(rowID: "q1", at: 10.02)
        timings.dispatched(conversationID: "chat", submissionID: submission, at: 10.05)
        // The agent's work and the spinner lay out first; with no words yet they don't end it.
        timings.laidOut(conversationID: "chat", showsText: { _ in true }, at: 10.3)
        #expect(timings.finished.isEmpty)
        timings.received(answerID: "a1", submissionID: submission, at: 10.6)
        timings.laidOut(conversationID: "chat", showsText: { _ in false }, at: 10.61)
        #expect(timings.finished.isEmpty, "Its words reached the chat, not the screen")
        timings.laidOut(conversationID: "chat", showsText: { $0 == "a1" }, at: 10.62)
        #expect(timings.finished.isEmpty, "Until Hermes answers the prompt, the words may be another turn's")
        timings.admitted(submissionID: submission)

        let (message, outcome) = try #require(timings.finished.first)
        #expect(outcome == .answered && message.provenance == .native)
        #expect(message.dispatchedAt == 10.05 && message.receivedAt == 10.6 && message.visibleAt == 10.62)
        let phases = try #require(timings.reading()["phases_ms"] as? [String: [String: Any]])
        #expect((phases["to_on_screen"]?["max"] as? Double).map { abs($0 - 620) < 0.001 } == true)
        #expect((phases["words_to_screen"]?["max"] as? Double).map { abs($0 - 20) < 0.001 } == true)
    }

    /// Words from another prompt's turn, a background task's result or a replay arrive under another
    /// source (or none) and never end this message's timing; neither do words in another chat.
    @Test func wordsFromAnotherTurnOrChatDontCount() {
        var timings = ChatSendTimings()
        let submission = UUID()
        timings.row("q1", conversationID: "chat", staged: false, at: 1)
        timings.handedOff(rowID: "q1", at: 1)
        timings.dispatched(conversationID: "chat", submissionID: submission, at: 1)
        timings.received(answerID: "background", submissionID: UUID(), at: 2)
        timings.received(answerID: "other-row", rowID: "q0", at: 2)
        timings.row("x1", conversationID: "other", staged: false, at: 2)
        timings.received(answerID: "other-chat", rowID: "x1", at: 2)
        #expect(timings.open.first?.answerID == nil)
        timings.turnEnded(conversationID: "chat")
        #expect(timings.finished.map(\.outcome) == [.noAnswer])
    }

    /// Words of a turn that won the race before Hermes answered `prompt.submit` count only once that
    /// answer says the turn was this prompt's; their times stay as they happened.
    @Test func wordsBeforeHermesAnswersThePromptWaitForThatAnswer() {
        var timings = ChatSendTimings()
        let submission = UUID()
        timings.row("q1", conversationID: "chat", staged: false, at: 1)
        timings.handedOff(rowID: "q1", at: 1)
        timings.dispatched(conversationID: "chat", submissionID: submission, at: 1.1)
        timings.received(answerID: "a1", submissionID: submission, at: 1.4)
        timings.laidOut(conversationID: "chat", showsText: { _ in true }, at: 1.42)
        #expect(timings.finished.isEmpty)
        #expect(timings.awaitedAnswers(conversationID: "chat").isEmpty, "Already seen: layout stops looking")
        timings.admitted(submissionID: submission)
        #expect(timings.finished.map(\.outcome) == [.answered])
        #expect(timings.finished.first?.message.receivedAt == 1.4)
        #expect(timings.finished.first?.message.visibleAt == 1.42)
    }

    /// The turn that won the race was someone else's: Hermes queued this prompt, or started more than
    /// one turn with it. Words already seen on screen don't make it answered.
    @Test func aTurnThatWonTheRaceIsNotThisPromptsAnswer() {
        for _ in ["queued", "overlapped"] {
            var timings = ChatSendTimings()
            let submission = UUID()
            timings.row("q1", conversationID: "chat", staged: false, at: 1)
            timings.handedOff(rowID: "q1", at: 1)
            timings.dispatched(conversationID: "chat", submissionID: submission, at: 1.1)
            timings.received(answerID: "foreign", submissionID: submission, at: 1.3)
            timings.laidOut(conversationID: "chat", showsText: { _ in true }, at: 1.32)
            timings.unattributed(submissionID: submission)
            timings.admitted(submissionID: submission)
            #expect(timings.finished.map(\.outcome) == [.unattributed])
            #expect(timings.open.isEmpty)
        }
    }

    /// Hermes queued the prompt (or steered it into another turn), so no turn names it: it ends
    /// unattributed, even when words arrive after it.
    @Test func aQueuedPromptEndsUnattributed() {
        var timings = ChatSendTimings()
        let submission = UUID()
        timings.row("q1", conversationID: "chat", staged: false, at: 1)
        timings.handedOff(rowID: "q1", at: 1)
        timings.dispatched(conversationID: "chat", submissionID: submission, at: 1.1)
        timings.unattributed(submissionID: submission)
        timings.received(answerID: "a1", submissionID: submission, at: 3)
        timings.laidOut(conversationID: "chat", showsText: { _ in true }, at: 3.1)
        #expect(timings.finished.map(\.outcome) == [.unattributed])
        #expect(timings.reading()["outcomes"] as? [String: Int] == ["answered": 0, "no_answer": 0, "joined_turn": 0,
                                                                     "unattributed": 1, "open": 0])
    }

    /// Two messages handed over that Hermes' client then sends as one prompt can't be told apart.
    @Test func aPromptThatCouldBeEitherOfTwoMessagesTimesNeither() {
        var timings = ChatSendTimings()
        for row in ["q1", "q2"] {
            timings.row(row, conversationID: "chat", staged: false, at: 1)
            timings.handedOff(rowID: row, at: 1)
        }
        timings.dispatched(conversationID: "chat", submissionID: UUID(), at: 2)
        #expect(timings.finished.map(\.outcome) == [.unattributed, .unattributed])
    }

    /// A reply that only arrives as the turn's final answer is timed the same way.
    @Test func aFinalOnlyReplyIsTimedWhenItShows() {
        var timings = ChatSendTimings()
        timings.row("q1", conversationID: "chat", staged: false, at: 1)
        timings.handedOff(rowID: "q1", at: 1)
        timings.received(answerID: "a1", rowID: "q1", at: 4)
        timings.turnEnded(conversationID: "chat")
        #expect(timings.finished.isEmpty, "Its answer isn't on screen yet")
        timings.laidOut(conversationID: "chat", showsText: { $0 == "a1" }, at: 4.05)
        #expect(timings.finished.map(\.outcome) == [.answered])
        #expect(timings.reading()["provenance"] as? [String: Int] == ["native": 0, "client_stream": 1])
    }

    /// The first words end it; later notes and replies in the same turn don't move it.
    @Test func interimRepliesKeepTheFirstAnswer() {
        var timings = ChatSendTimings()
        timings.row("q1", conversationID: "chat", staged: false, at: 1)
        timings.handedOff(rowID: "q1", at: 1)
        timings.received(answerID: "note", rowID: "q1", at: 2)
        timings.received(answerID: "final", rowID: "q1", at: 5)
        #expect(timings.open.first?.answerID == "note")
        #expect(timings.open.first?.receivedAt == 2)
    }

    /// A row that isn't from the message box (a card's answer) is timed from itself, not from a tap
    /// that made no row (a goal command, say).
    @Test func onlyAMessageBoxRowIsTimedFromTheTap() {
        var timings = ChatSendTimings()
        timings.tapped(conversationID: "chat", at: 1)
        timings.row("card-answer", conversationID: "chat", staged: false, fromComposer: false, at: 9)
        #expect(timings.open.first?.tappedAt == 9)
        timings.row("q1", conversationID: "chat", staged: false, at: 10)
        #expect(timings.open.last?.tappedAt == 1, "The message box's tap still times its own row")
    }

    @Test func aSteerSaysItJoinedTheRunningTurn() {
        var timings = ChatSendTimings()
        timings.tapped(conversationID: "chat", at: 1)
        timings.joinedTurn(conversationID: "chat", rowID: nil)
        timings.row("q1", conversationID: "chat", staged: true, at: 2)
        timings.joinedTurn(conversationID: "chat", rowID: "q1")
        #expect(timings.finished.map(\.outcome) == [.joinedTurn, .joinedTurn])
    }

    /// A message that waited in the chat for its connection has that wait as its own phase.
    @Test func aWaitingMessageHasItsWaitTimed() throws {
        var timings = ChatSendTimings()
        timings.tapped(conversationID: "chat", at: 1)
        timings.row("q1", conversationID: "chat", staged: true, at: 1.01)
        timings.row("q1", conversationID: "chat", staged: false, at: 1.51)
        timings.handedOff(rowID: "q1", at: 1.52)
        timings.received(answerID: "a1", rowID: "q1", at: 2)
        timings.laidOut(conversationID: "chat", showsText: { _ in true }, at: 2.01)
        let phases = try #require(timings.reading()["phases_ms"] as? [String: [String: Any]])
        #expect((phases["staged_wait"]?["max"] as? Double).map { abs($0 - 500) < 0.001 } == true)
    }

    /// A reading holds times and counts only: no row or message IDs.
    @Test func aReadingCarriesNoIdentifiers() throws {
        var timings = ChatSendTimings()
        timings.row("row-secret", conversationID: "chat-secret", staged: false, at: 1)
        timings.handedOff(rowID: "row-secret", at: 1)
        timings.received(answerID: "answer-secret", rowID: "row-secret", at: 2)
        timings.laidOut(conversationID: "chat-secret", showsText: { _ in true }, at: 2.1)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: timings.reading()), as: UTF8.self)
        #expect(!text.contains("secret"))
    }

    /// What counts as an answer is what the chat shows: silent markers and empty pieces don't.
    @Test func onlyAnAnswerWithWordsInItCounts() {
        let model = ChatModel(conversationID: "chat", client: ConversationFixtureClient(), initialItems: [])
        let generation = model.beginOwnerGeneration()
        func draft(_ id: String, _ text: String) -> TimelineItem {
            TimelineItem(id: id, role: .assistant, sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                         content: .message(text), metadata: .init(delivery: "Streaming"))
        }
        model.acceptStreamingDraft(draft("silent", "NO_REP"), ownerGeneration: generation)
        model.acceptStreamingDraft(draft("blank", "  \n"), ownerGeneration: generation)
        model.acceptStreamingDraft(draft("words", "Sure"), ownerGeneration: generation)
        #expect(!model.showsReadableAnswer("silent"))
        #expect(!model.showsReadableAnswer("blank"))
        #expect(model.showsReadableAnswer("words"))
    }

    /// On Hermes, words are timed only from the live turn of the prompt being sent: not before a prompt
    /// is pending (a turn another surface started), not while the chat replays what it missed, and not
    /// after the prompt settled.
    @Test func onlyThePromptsOwnLiveTurnIsTimed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = TimingRPC()
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        try await client.recover(epoch: "epoch")
        var sequence = 0
        func emit(_ type: String, _ payload: [String: BighelpJSONValue] = [:]) {
            sequence += 1
            client.receive(.init(type: type, sessionID: "runtime", payload: payload, sequence: sequence))
        }
        emit("message.start")
        #expect(client.liveTurnSubmission == nil, "A turn no prompt of this chat started")
        emit("message.complete", ["text": .string("Done"), "status": .string("complete")])
        emit("session.info", ["running": .boolean(false)])
        for _ in 0..<500 where model.isSending || !model.directTransportIsReady { try await Task.sleep(for: .milliseconds(2)) }

        model.draft = "Hello"
        let turn = Task { await model.send() }
        defer { turn.cancel() }
        for _ in 0..<500 where !rpc.submitted { try await Task.sleep(for: .milliseconds(2)) }
        emit("message.start")
        let submission = try #require(client.liveTurnSubmission)
        #expect(client.pendingID == submission)
        #expect(!client.admissionOverlapped)
        client.isReplayingActivity = true
        #expect(client.liveTurnSubmission == nil)
        client.isReplayingActivity = false
        emit("message.complete", ["text": .string("Hi"), "status": .string("complete")])
        emit("session.info", ["running": .boolean(false)])
        for _ in 0..<500 where client.pendingID != nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(client.liveTurnSubmission == nil)
    }

    /// Two turns started before Hermes answered the prompt: which one is its own can't be told, so neither
    /// is timed as its answer.
    @Test func twoTurnsBeforeHermesAnswersTimeNeither() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = TimingRPC()
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        try await client.recover(epoch: "epoch")
        var sequence = 0
        func emit(_ type: String) {
            sequence += 1
            client.receive(.init(type: type, sessionID: "runtime", payload: [:], sequence: sequence))
        }
        rpc.holdsSubmit = true
        model.draft = "Hello"
        let turn = Task { await model.send() }
        defer { turn.cancel() }
        for _ in 0..<500 where !rpc.submitted { try await Task.sleep(for: .milliseconds(2)) }
        emit("message.start")
        #expect(client.liveTurnSubmission != nil, "Provisional: Hermes hasn't answered yet")
        emit("message.start")
        #expect(client.liveTurnSubmission == nil)
        rpc.releaseSubmit()
        for _ in 0..<500 where !client.admitted { try await Task.sleep(for: .milliseconds(2)) }
        #expect(client.admissionOverlapped)
        #expect(client.liveTurnSubmission == nil)
    }

    /// On screen means the answer's own words, where the reader sees them: not under the header or
    /// the message box, not hidden or squashed, not off screen, not in a window that isn't showing.
    @Test func onScreenMeansItsWordsAreWhereTheReaderSeesThem() async throws {
        let owner = NSObject()
        let timeline = ChatTimelineController()
        let answer = TimelineItem(id: "answer", role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Juno")),
            content: .message("The first words of the answer."), metadata: .init(delivery: "Streaming"))
        let rows = [ChatCanvasRow.transcript(.entry(.message(answer)))]
            + (0..<30).map { ChatCanvasRow.divider("Row \($0)") } + [.bottom]
        func view(_ insets: UIEdgeInsets) -> some View {
            NativeChatTimeline(conversationID: "on-screen", ownerID: ObjectIdentifier(owner), rows: rows,
                               controller: timeline, entryCount: rows.count, contentInsets: insets) { row in
                if case .transcript(.entry(.message(let message))) = row {
                    TimelineItemView(item: message, onApprovalTap: { _ in })
                } else {
                    Text(row.id).frame(maxWidth: .infinity, minHeight: 100)
                }
            }
            .environment(\.bighelpUIV3Enabled, true)
        }
        let host = UIHostingController(rootView: view(UIEdgeInsets(top: 200, left: 0, bottom: 0, right: 0)))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(400))
        func tables(_ view: UIView) -> [ChatTimelineTableView] {
            (view as? ChatTimelineTableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        let table = try #require(tables(host.view).first)
        timeline.beginReview()
        table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
        table.layoutIfNeeded()
        #expect(table.showsWords(ofMessage: "answer"))
        #expect(!table.showsWords(ofMessage: "another"))

        // Scrolled up under the header: its row is still among the table's cells, its words aren't seen.
        let cell = try #require(table.visibleCells.first { $0.accessibilityIdentifier == "message:answer" })
        table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top + cell.frame.maxY - 1), animated: false)
        table.layoutIfNeeded()
        #expect(table.visibleCells.contains(cell))
        #expect(!table.showsWords(ofMessage: "answer"))

        // Hidden or squashed words.
        table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
        table.layoutIfNeeded()
        let text = try #require(descendants(cell, of: UITextView.self).first { $0.textStorage.length > 0 })
        text.isHidden = true
        #expect(!table.showsWords(ofMessage: "answer"))
        text.isHidden = false
        text.superview?.alpha = 0
        #expect(!table.showsWords(ofMessage: "answer"))
        text.superview?.alpha = 1
        #expect(table.showsWords(ofMessage: "answer"))

        // Scrolled far away, and a window that isn't showing.
        table.setContentOffset(CGPoint(x: 0, y: table.bottomOffset), animated: false)
        table.layoutIfNeeded()
        #expect(!table.showsWords(ofMessage: "answer"))
        table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
        table.layoutIfNeeded()
        window.isHidden = true
        #expect(!table.showsWords(ofMessage: "answer"))
    }

    private func descendants<T: UIView>(_ root: UIView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }
}

@MainActor
private final class TimingRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    private(set) var submitted = false
    /// `prompt.submit` waits for `releaseSubmit()`, so the turn's events arrive before Hermes answers it.
    var holdsSubmit = false
    private var heldSubmit: CheckedContinuation<Void, Never>?

    func releaseSubmit() {
        holdsSubmit = false
        heldSubmit?.resume()
        heldSubmit = nil
    }

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        switch method {
        case "session.events.since":
            return .object(["epoch": .string("epoch"), "latest_seq": .integer(0), "truncated": .boolean(false),
                            "events": .array([]), "count": .integer(0)])
        case "session.activate":
            return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"),
                            "running": .boolean(false), "messages": .array([])])
        case "prompt.submit":
            submitted = true
            if holdsSubmit { await withCheckedContinuation { heldSubmit = $0 } }
            return .object(["status": .string("streaming")])
        case "subagent.list": return .object(["subagents": .array([])])
        case "session.control.read":
            return .object(["control": .object(["goal": .null, "loop": .null, "heartbeat": .null,
                                                "revision": .string("fixture"), "updated_at": .integer(0)])])
        default: throw DirectHermesError.invalidResponse
        }
    }

    func disconnect() async {}
}
