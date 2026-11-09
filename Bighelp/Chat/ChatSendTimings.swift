#if DEBUG
import Foundation
import UIKit

/// Times each message from Send to its answer's first words on screen, in phases, for the chat speed
/// checks (`ChatPerformanceRecorder`, `-test-chat-performance-probe`). Times are seconds on the
/// monotonic media clock. Row IDs are held only while a message is timed; a reading carries times
/// and counts, never text or IDs.
///
/// An answer counts for a message only when where it came from says so, never by its place in the
/// chat: on Hermes, the live (not replayed) turn of the very prompt the message was sent as
/// (`native`); with other clients, the reply the message's own send call delivered (`client_stream`,
/// demo fixtures). When that can't be told, the message ends with an outcome that says so instead
/// of a time. Hermes can send a turn's words before it answers `prompt.submit`, and a turn that won
/// the race may be someone else's: those times are kept as they happened, and the message counts as
/// answered only once Hermes' answer says it started exactly one turn for this prompt.
struct ChatSendTimings {
    enum Outcome: String, CaseIterable {
        /// Its answer's first words were laid out on screen.
        case answered
        /// The turn ended with nothing to read: a silent reply, only tools, or an error.
        case noAnswer = "no_answer"
        /// It went into a running turn (a steer): what follows belongs to that turn too.
        case joinedTurn = "joined_turn"
        /// Hermes queued it, steered it into another turn, or started more than one turn for it, so no
        /// answer can be tied to it.
        case unattributed
    }

    enum Provenance: String, CaseIterable {
        case native
        case clientStream = "client_stream"
    }

    struct Message {
        let conversationID: String
        let tappedAt: Double
        var rowID: String
        var stagedAt: Double?
        var unstagedAt: Double?
        var handedOffAt: Double?
        var submissionID: UUID?
        var dispatchedAt: Double?
        /// Hermes' answer to the prompt said it started one turn for it; until then its words may be another's.
        var admitted = true
        var answerID: String?
        var provenance: Provenance?
        var receivedAt: Double?
        var visibleAt: Double?
    }

    private var taps: [String: Double] = [:]
    private(set) var open: [Message] = []
    private(set) var finished: [(message: Message, outcome: Outcome)] = []

    /// The person tapped Send. A message is timed from here once it becomes a row.
    mutating func tapped(conversationID: String, at time: Double) {
        taps[conversationID] = time
    }

    /// The message became a row: waiting in the chat (`staged`), or sent. A staged row that goes out
    /// later reports here again and ends its wait. Only a row from the message box is timed from the
    /// tap; another (a card's answer) is timed from itself, never from a tap that made no row.
    mutating func row(_ id: String, conversationID: String, staged: Bool, fromComposer: Bool = true,
                      at time: Double) {
        if let index = open.firstIndex(where: { $0.rowID == id }) {
            if open[index].stagedAt != nil, open[index].unstagedAt == nil { open[index].unstagedAt = time }
            return
        }
        let tapped = fromComposer ? taps.removeValue(forKey: conversationID) ?? time : time
        open.append(Message(conversationID: conversationID, tappedAt: tapped, rowID: id,
                            stagedAt: staged ? time : nil))
    }

    /// The chat handed the message to its conversation client.
    mutating func handedOff(rowID: String, at time: Double) {
        guard let index = open.firstIndex(where: { $0.rowID == rowID && $0.handedOffAt == nil }) else { return }
        open[index].handedOffAt = time
    }

    /// Hermes' client wrote `prompt.submit` as `submissionID`. A chat admits one prompt at a time, so
    /// that's its one handed-off message not yet sent; with none or several, none is timed.
    mutating func dispatched(conversationID: String, submissionID: UUID, at time: Double) {
        let waiting = open.indices.filter {
            open[$0].conversationID == conversationID && open[$0].handedOffAt != nil && open[$0].submissionID == nil
        }
        guard waiting.count == 1, let index = waiting.first else {
            for index in waiting.reversed() { finished.append((open.remove(at: index), .unattributed)) }
            return
        }
        open[index].submissionID = submissionID
        open[index].dispatchedAt = time
        open[index].admitted = false
    }

    /// Hermes answered prompt `submissionID` with the one turn it started for it (`streaming`).
    mutating func admitted(submissionID: UUID) {
        guard let index = open.firstIndex(where: { $0.submissionID == submissionID }) else { return }
        open[index].admitted = true
        finishIfShown(index)
    }

    /// No answer can be tied to prompt `submissionID` (queued, steered into another turn, or more than one turn).
    mutating func unattributed(submissionID: UUID) {
        guard let index = open.firstIndex(where: { $0.submissionID == submissionID }) else { return }
        finished.append((open.remove(at: index), .unattributed))
    }

    /// The message went into a running turn. Without a row of its own yet, the chat's last tap is it.
    mutating func joinedTurn(conversationID: String, rowID: String?) {
        if let rowID, let index = open.firstIndex(where: { $0.rowID == rowID }) {
            finished.append((open.remove(at: index), .joinedTurn))
        } else if rowID == nil, let tapped = taps.removeValue(forKey: conversationID) {
            finished.append((Message(conversationID: conversationID, tappedAt: tapped, rowID: ""), .joinedTurn))
        }
    }

    /// Words of the live turn Hermes started for prompt `submissionID`.
    mutating func received(answerID: String, submissionID: UUID, at time: Double) {
        receive(answerID, .native, at: time) { $0.submissionID == submissionID }
    }

    /// Words the send call of row `rowID` delivered itself.
    mutating func received(answerID: String, rowID: String, at time: Double) {
        receive(answerID, .clientStream, at: time) { $0.rowID == rowID && $0.handedOffAt != nil }
    }

    private mutating func receive(_ answerID: String, _ provenance: Provenance, at time: Double,
                                  where matches: (Message) -> Bool) {
        guard let index = open.firstIndex(where: matches), open[index].answerID == nil else { return }
        open[index].answerID = answerID
        open[index].provenance = provenance
        open[index].receivedAt = time
    }

    /// The chat laid out; `showsText` says whether an answer's own words are on screen.
    mutating func laidOut(conversationID: String, showsText: (String) -> Bool, at time: Double) {
        for index in open.indices.reversed() {
            guard open[index].conversationID == conversationID, open[index].visibleAt == nil,
                  let answer = open[index].answerID, showsText(answer) else { continue }
            open[index].visibleAt = time
            finishIfShown(index)
        }
    }

    /// A message whose words showed and whose prompt Hermes took as its own is answered.
    private mutating func finishIfShown(_ index: Int) {
        guard open[index].admitted, open[index].visibleAt != nil else { return }
        finished.append((open.remove(at: index), .answered))
    }

    /// The chat's turn ended. A sent message that got no answer ends with none; one whose answer
    /// hasn't been laid out yet waits for that.
    mutating func turnEnded(conversationID: String) {
        for index in open.indices.reversed()
        where open[index].conversationID == conversationID && open[index].handedOffAt != nil && open[index].answerID == nil {
            finished.append((open.remove(at: index), .noAnswer))
        }
    }

    /// The answers of this chat waiting to be seen on screen.
    func awaitedAnswers(conversationID: String) -> [String] {
        open.compactMap { $0.conversationID == conversationID && $0.visibleAt == nil ? $0.answerID : nil }
    }

    mutating func clearFinished() { finished.removeAll() }

    /// Counts by outcome and where answers came from, and each phase in milliseconds from the tap
    /// (`words_to_screen` from the first words reaching the chat to their layout on screen).
    func reading() -> [String: Any] {
        var outcomes = Dictionary(uniqueKeysWithValues: Outcome.allCases.map { ($0.rawValue, 0) })
        for (_, outcome) in finished { outcomes[outcome.rawValue, default: 0] += 1 }
        outcomes["open"] = open.count
        let answered = finished.filter { $0.outcome == .answered }.map(\.message)
        let provenance = Dictionary(uniqueKeysWithValues: Provenance.allCases.map { kind in
            (kind.rawValue, answered.filter { $0.provenance == kind }.count)
        })
        func phase(_ value: (Message) -> Double?) -> [String: Any] {
            Self.summary(answered.compactMap(value).map { $0 * 1_000 })
        }
        return [
            "outcomes": outcomes,
            "provenance": provenance,
            "phases_ms": [
                "staged_wait": phase { m in m.stagedAt.flatMap { s in m.unstagedAt.map { $0 - s } } },
                "to_handoff": phase { m in m.handedOffAt.map { $0 - m.tappedAt } },
                "to_dispatch": phase { m in m.dispatchedAt.map { $0 - m.tappedAt } },
                "to_first_words": phase { m in m.receivedAt.map { $0 - m.tappedAt } },
                "to_on_screen": phase { m in m.visibleAt.map { $0 - m.tappedAt } },
                "words_to_screen": phase { m in m.receivedAt.flatMap { r in m.visibleAt.map { $0 - r } } },
            ],
        ]
    }

    static func summary(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        func at(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        return ["count": sorted.count, "min": sorted.first ?? 0, "median": at(0.5), "p95": at(0.95),
                "max": sorted.last ?? 0]
    }
}

extension ChatModel {
    /// Whether the chat shows message `id` as an answer with words in it, the way the timeline draws it:
    /// silent markers and empty pieces are left out (`ChatSilentReply`) before it gets here.
    func showsReadableAnswer(_ id: String) -> Bool {
        guard let index = transcriptMessageIndexByID[id], transcriptEntries.indices.contains(index),
              case .message(let item) = transcriptEntries[index], item.role == .assistant,
              case .message(let text) = item.content else { return false }
        return text.contains { !$0.isWhitespace }
    }
}

extension ChatTimelineTableView {
    /// Whether the words of message `id` are laid out where the reader sees them: its own message row,
    /// in the part of the chat between the header and the message box, with a text view holding words
    /// that isn't hidden or squashed, in a window of an app in front. A work block that only lists the
    /// message doesn't count.
    func showsWords(ofMessage id: String) -> Bool {
        guard let window, !window.isHidden, window.windowScene?.activationState == .foregroundActive,
              !isHidden, alpha > 0 else { return false }
        let rowID = "message:" + id // `ChatTranscriptEntry.message`'s row
        let viewport = bounds.inset(by: adjustedContentInset).intersection(convert(window.bounds, from: window))
        guard !viewport.isEmpty, let cell = visibleCells.first(where: { $0.accessibilityIdentifier == rowID }),
              !cell.isHidden, cell.alpha > 0 else { return false }
        func texts(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(texts)
        }
        return texts(cell).contains { text in
            guard text.textStorage.length > 0, text.window === window else { return false }
            var view: UIView? = text
            while let current = view, current !== cell {
                if current.isHidden || current.alpha == 0 { return false }
                view = current.superview
            }
            // Its first line, where the first words are, not only some line further down.
            let first = text.convert(text.caretRect(for: text.beginningOfDocument), to: self)
            return text.bounds.height > 0 && !first.isNull && first.height > 0 && first.intersects(viewport)
        }
    }
}
#endif
