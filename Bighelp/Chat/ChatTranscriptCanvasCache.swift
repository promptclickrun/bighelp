import Foundation

/// The chat's transcript as canvas rows, kept between redraws. `ChatView` redraws for
/// many reasons that leave the transcript alone (the keyboard, the message box growing,
/// the header, scrolling away from the bottom), and rebuilding every row of a long chat
/// for each of them made it stutter. The rows are built again only when something they
/// are made from changes; the key reads each of those, so the chat still redraws for them.
///
/// When the transcript does change, it's almost always in its last turn (a growing answer,
/// a new tool). The rows are kept a turn at a time (`ChatTranscriptTurn`), so a streaming
/// answer folds and lays out only its own turn, however long the chat is.
@MainActor
final class ChatTranscriptCanvasCache {
    struct Key: Equatable {
        /// Bumped by every change to `ChatModel.transcriptEntries`, including a turn's events.
        let transcriptRevision: UInt64
        let ledgerRevision: UInt64
        let disclosureRevision: UInt64
        let isSending: Bool
        let isBotMode: Bool
        let foldsCompletedTurns: Bool
        let isSimpleBots: Bool
        let visibility: ChatActivityVisibility
        let agentName: String
    }

    struct Canvas {
        let rows: [ChatCanvasRow]
        /// Message rows followed, or preceded, by a message from the same sender.
        let groupedIDs: Set<String>
        let continuedIDs: Set<String>
    }

    /// What the rows are made from besides the transcript and the reader's folder choices.
    struct DisplayContext: Equatable {
        let ledgerRevision: UInt64
        let isSending: Bool
        let isBotMode: Bool
        let foldsCompletedTurns: Bool
        let interimReplies: ChatInterimReplyPlacement
        /// Simple Bot mode: interim messages go under the bot's reasoning folder.
        let simpleBotsReasoning: SimpleBotsReasoning?
    }

    struct SimpleBotsReasoning: Equatable {
        let agentName: String
        let showsReasoning: Bool
    }

    private var key: Key?
    private var canvas: Canvas?
    /// How many times the rows were built, and how many turns were folded again, for tests.
    private(set) var buildCount = 0
    private(set) var turnBuildCount = 0
    /// The rows last built.
    var rows: [ChatCanvasRow] { canvas?.rows ?? [] }

    func canvas(for key: Key, build: () -> Canvas) -> Canvas {
        if let canvas, self.key == key { return canvas }
        let canvas = build()
        buildCount += 1
        self.key = key
        self.canvas = canvas
        return canvas
    }

    // MARK: Turns

    /// A turn's entries by value: the model updates a turn's events in place, so the
    /// entries alone can't tell a kept turn from a changed one.
    private enum TurnEntry: Equatable {
        case message(TimelineItem)
        case activity(id: String, events: [ChatActivityEvent])

        init(_ entry: ChatTranscriptEntry) {
            switch entry {
            case .message(let item): self = .message(item)
            case .activity(let turn): self = .activity(id: turn.id, events: turn.events)
            }
        }
    }

    private struct TurnKey: Equatable {
        let entries: [TurnEntry]
        let nextQuestionOrder: Int?
        let isLast: Bool
    }

    private struct KeptTurn {
        let key: TurnKey
        /// The cards the turn's answers carry, which hide the same cards shown live anywhere.
        let durableCardIDs: Set<String>
        /// A question that is itself a card: hiding it would join two turns.
        let asksWithCard: Bool
        var displayRows: [ChatTurnDisplayRow]?
        /// The ledger events the display rows were made with (`ledgerEvents(for:…)`).
        var ledgerEvents: [ChatActivityEvent] = []
        /// The display rows hold a call to another agent, or a message one sent in.
        var linksAgentTalk = false
        var canvas: Canvas?
    }

    /// Everything but the ledger, which changes with each tool and is checked turn by turn.
    private struct TurnContext: Equatable {
        let isSending: Bool
        let isBotMode: Bool
        let foldsCompletedTurns: Bool
        let interimReplies: ChatInterimReplyPlacement
        let simpleBotsReasoning: SimpleBotsReasoning?
        let durableCardIDs: Set<String>

        init(_ display: DisplayContext, durableCardIDs: Set<String>) {
            isSending = display.isSending
            isBotMode = display.isBotMode
            foldsCompletedTurns = display.foldsCompletedTurns
            interimReplies = display.interimReplies
            simpleBotsReasoning = display.simpleBotsReasoning
            self.durableCardIDs = durableCardIDs
        }
    }

    private struct CanvasContext: Equatable {
        let disclosureRevision: UInt64
        let isSending: Bool
    }

    private var turns: [String: KeptTurn] = [:]
    private var turnContext: TurnContext?
    private var canvasContext: CanvasContext?
    /// The ledger, sorted out once for the turns folded while it stays the same.
    private var ledger: (workOrders: [Int], folds: ChatCompletedTurnProjection.Ledger, all: ChatLedgerIndex)?
    private var ledgerRevision: UInt64?

    /// The transcript's canvas rows, as `Self.wholeCanvas` makes them, with every turn that
    /// didn't change since the last call kept as it was.
    func buildCanvas(
        from transcript: [ChatTranscriptEntry],
        activityEvents: () -> [ChatActivityEvent],
        context display: DisplayContext,
        disclosures: ChatActivityDisclosureStore,
        readsAgentMessages: Bool
    ) -> Canvas {
        let split = ChatTranscriptTurn.split(transcript)
        var current: [(id: String, turn: ChatTranscriptTurn, kept: KeptTurn)] = []
        current.reserveCapacity(split.count)
        var durableCardIDs = Set<String>()
        var asksWithCard = false
        for turn in split {
            let slice = transcript[turn.range]
            let key = TurnKey(entries: slice.map(TurnEntry.init), nextQuestionOrder: turn.nextQuestionOrder,
                              isLast: turn.isLast)
            let id = slice[slice.startIndex].id
            let kept = turns[id].flatMap { $0.key == key ? $0 : nil } ?? KeptTurn(
                key: key, durableCardIDs: ChatCardTranscriptProjection.durableCardIDs(in: Array(slice)),
                asksWithCard: Self.asksWithCard(slice))
            durableCardIDs.formUnion(kept.durableCardIDs)
            asksWithCard = asksWithCard || kept.asksWithCard
            current.append((id, turn, kept))
        }
        let turnContext = TurnContext(display, durableCardIDs: durableCardIDs)
        if turnContext != self.turnContext {
            for index in current.indices { current[index].kept.displayRows = nil }
            self.turnContext = turnContext
        }
        if display.ledgerRevision != ledgerRevision {
            ledger = nil
            ledgerRevision = display.ledgerRevision
            // A tool or thought belongs to one turn: the others keep their rows when the
            // ledger events they were made with are still the same.
            for index in current.indices where current[index].kept.displayRows != nil {
                let (_, turn, kept) = current[index]
                if ledgerEvents(for: transcript[turn.range], turn: turn, activityEvents: activityEvents)
                    != kept.ledgerEvents {
                    current[index].kept.displayRows = nil
                }
            }
        }
        let canvasContext = CanvasContext(disclosureRevision: disclosures.revision, isSending: display.isSending)
        if canvasContext != self.canvasContext {
            for index in current.indices { current[index].kept.canvas = nil }
            self.canvasContext = canvasContext
        }
        guard !(asksWithCard && !durableCardIDs.isEmpty) else {
            turns.removeAll()
            return Self.wholeCanvas(from: transcript, activityEvents: activityEvents(), context: display,
                                    disclosures: disclosures, readsAgentMessages: readsAgentMessages)
        }
        for index in current.indices where current[index].kept.displayRows == nil {
            let (_, turn, _) = current[index]
            let entries = ChatCardTranscriptProjection.removingLiveCards(
                durableCardIDs, from: Array(transcript[turn.range]))
            let displayRows = displayRows(of: entries[...], turn: turn, context: display, activityEvents: activityEvents)
            current[index].kept.displayRows = displayRows
            current[index].kept.ledgerEvents = ledgerEvents(for: transcript[turn.range], turn: turn,
                                                            activityEvents: activityEvents)
            current[index].kept.linksAgentTalk = ChatAgentTalkIndex.mayLink(displayRows)
            current[index].kept.canvas = nil
            turnBuildCount += 1
        }
        defer { turns = Dictionary(current.map { ($0.id, $0.kept) }, uniquingKeysWith: { _, last in last }) }
        // Agents talking to each other link rows across turns; such chats are projected whole.
        if current.contains(where: { $0.kept.linksAgentTalk }) {
            let displayRows = current.flatMap { $0.kept.displayRows ?? [] }
            let rows = ChatCanvasTranscriptProjection.rows(from: displayRows, disclosures: disclosures,
                                                            isSending: display.isSending,
                                                            readsAgentMessages: readsAgentMessages)
            for index in current.indices { current[index].kept.canvas = nil }
            return Canvas(rows: rows, groupedIDs: ChatView.groupedMessageRowIDs(rows),
                          continuedIDs: ChatView.continuedMessageRowIDs(rows))
        }
        let noTalk = ChatAgentTalkIndex([], readsAgentMessages: false)
        var rows: [ChatCanvasRow] = []
        var groupedIDs = Set<String>()
        var continuedIDs = Set<String>()
        for index in current.indices {
            let canvas = current[index].kept.canvas ?? {
                let displayRows = current[index].kept.displayRows ?? []
                let tail = current[index].turn.isLast
                    ? ChatCanvasTranscriptProjection.tailEntryID(of: displayRows[...], isSending: display.isSending)
                    : nil
                let rows = ChatCanvasTranscriptProjection.rows(from: displayRows[...], disclosures: disclosures,
                                                                isSending: display.isSending, tailEntryID: tail,
                                                                talk: noTalk)
                return Canvas(rows: rows, groupedIDs: ChatView.groupedMessageRowIDs(rows),
                              continuedIDs: ChatView.continuedMessageRowIDs(rows))
            }()
            current[index].kept.canvas = canvas
            // A message can group with the one that ends the turn before it.
            if case .transcript(.entry(let last))? = rows.last, case .transcript(.entry(let first))? = canvas.rows.first,
               ChatMessageGrouping.continuesGroup(last, next: first) {
                groupedIDs.insert(rows[rows.count - 1].id)
                continuedIDs.insert(canvas.rows[0].id)
            }
            rows += canvas.rows
            groupedIDs.formUnion(canvas.groupedIDs)
            continuedIDs.formUnion(canvas.continuedIDs)
        }
        return Canvas(rows: rows, groupedIDs: groupedIDs, continuedIDs: continuedIDs)
    }

    /// The whole transcript projected in one go: what `buildCanvas` keeps a turn at a time.
    static func wholeCanvas(
        from transcript: [ChatTranscriptEntry],
        activityEvents: [ChatActivityEvent],
        context: DisplayContext,
        disclosures: ChatActivityDisclosureStore,
        readsAgentMessages: Bool
    ) -> Canvas {
        var displayRows = ChatCompletedTurnProjection.rows(
            from: ChatInterimReplies.marking(
                ChatCardTranscriptProjection.removingSupersededLiveCards(from: transcript),
                isSending: context.isSending, isBotMode: context.isBotMode, activityEvents: activityEvents),
            isSending: context.isSending, enabled: context.foldsCompletedTurns, activityEvents: activityEvents,
            interimReplies: context.interimReplies)
        if let simpleBots = context.simpleBotsReasoning {
            displayRows = ChatInterimReplies.groupingForSimpleBots(displayRows, agentName: simpleBots.agentName,
                                                                   showsReasoning: simpleBots.showsReasoning,
                                                                   isSending: context.isSending)
        }
        let rows = ChatCanvasTranscriptProjection.rows(from: displayRows, disclosures: disclosures,
                                                        isSending: context.isSending,
                                                        readsAgentMessages: readsAgentMessages)
        return Canvas(rows: rows, groupedIDs: ChatView.groupedMessageRowIDs(rows),
                      continuedIDs: ChatView.continuedMessageRowIDs(rows))
    }

    private static func asksWithCard(_ entries: ArraySlice<ChatTranscriptEntry>) -> Bool {
        guard case .message(let question)? = entries.first, question.role == .human else { return false }
        switch question.content {
        case .generativeUI, .bighelpCard: return true
        default: return false
        }
    }

    private func ledger(
        _ activityEvents: () -> [ChatActivityEvent]
    ) -> (workOrders: [Int], folds: ChatCompletedTurnProjection.Ledger, all: ChatLedgerIndex) {
        if let ledger { return ledger }
        let events = activityEvents()
        let ledger = (ChatInterimReplies.workOrders(in: events), ChatCompletedTurnProjection.Ledger(events),
                      ChatLedgerIndex(events))
        self.ledger = ledger
        return ledger
    }

    /// The ledger events a turn's rows can read: its own turns' events (steps, timed thinking)
    /// and anything ordered from its question to the next one (hidden work, steps by order).
    private func ledgerEvents(
        for entries: ArraySlice<ChatTranscriptEntry>, turn: ChatTranscriptTurn,
        activityEvents: () -> [ChatActivityEvent]
    ) -> [ChatActivityEvent] {
        var turnIDs = Set<String>()
        for case .activity(let activity) in entries { activity.events.forEach { turnIDs.insert($0.turnID) } }
        // A question without an order (or the start of the chat) reads work from the beginning.
        var startOrder = Int.min
        if case .message(let question)? = entries.first, question.role == .human {
            startOrder = question.metadata.sourceOrder ?? Int.min
        }
        let all = ledger(activityEvents).all
        return all.events(inTurns: turnIDs, startOrder: startOrder, endOrder: turn.nextQuestionOrder)
    }

    private func displayRows(
        of entries: ArraySlice<ChatTranscriptEntry>, turn: ChatTranscriptTurn, context: DisplayContext,
        activityEvents: () -> [ChatActivityEvent]
    ) -> [ChatTurnDisplayRow] {
        let ledger = ledger(activityEvents)
        let inFlight = turn.isLast && context.isSending
        let marked = context.isBotMode
            ? Array(entries)
            : ChatInterimReplies.marking(turn: entries, nextQuestionOrder: turn.nextQuestionOrder,
                                         inFlight: inFlight, workOrders: ledger.workOrders)
        let rows = ChatCompletedTurnProjection.rows(
            ofTurn: marked[...], endOrder: turn.nextQuestionOrder, isActive: inFlight,
            enabled: context.foldsCompletedTurns, ledger: ledger.folds, interimReplies: context.interimReplies)
        guard let simpleBots = context.simpleBotsReasoning else { return rows }
        return ChatInterimReplies.groupingForSimpleBots(rows, agentName: simpleBots.agentName,
                                                        showsReasoning: simpleBots.showsReasoning, isSending: inFlight)
    }
}
