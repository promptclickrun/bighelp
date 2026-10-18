import SwiftUI

/// A run of agents messaging each other, drawn as one rail between the chat's
/// bubbles. It's part of the conversation rather than the agent's work, so it
/// never folds into a finished turn and shows whatever Show tool calls and
/// Show reasoning say.
struct ChatAgentTalk: Identifiable, Equatable {
    enum Piece: Identifiable, Equatable {
        /// This chat's agent wrote to another agent. `answer` is the later
        /// answer to a `message_agent` message.
        case call(ChatActivityEvent, answer: ChatAgentTalkAnswer?)
        /// Another agent wrote into this chat; `reply` is how this chat's agent answered.
        case incoming(TimelineItem, AgentTalkIncomingMessage, reply: TimelineItem?)
        /// The answer to a `message_agent` message, where it came in, with the call that sent it.
        case answer(TimelineItem, ChatAgentTalkAnswer, call: ChatActivityEvent?)

        var id: String {
            switch self {
            case .call(let event, _): "call:\(event.id)"
            case .incoming(let item, _, _): "incoming:\(item.id)"
            case .answer(let item, _, _): "answer:\(item.id)"
            }
        }
    }

    /// The first piece's: the rail keeps its place as later messages join it.
    let id: String
    private(set) var pieces: [Piece]

    init(_ piece: Piece) {
        id = piece.id
        pieces = [piece]
    }

    mutating func append(_ other: ChatAgentTalk) {
        pieces += other.pieces
    }

    /// Calls still waiting on the other agent.
    var runningCalls: [ChatActivityEvent] {
        pieces.compactMap { piece in
            guard case .call(let event, _) = piece, event.lifecycle == .running else { return nil }
            return event
        }
    }

    var isLive: Bool { !runningCalls.isEmpty }

    /// The conversation in order. Each call is the message sent and the answer;
    /// an answer that arrived later replaces its placeholder.
    func messages(chatAgentID: String) -> [ChatAgentTalkMessage] {
        var ordered: [ChatAgentTalkMessage] = []
        var positions: [String: Int] = [:]
        func put(_ message: ChatAgentTalkMessage) {
            guard let index = positions[message.id] else {
                positions[message.id] = ordered.count
                ordered.append(message)
                return
            }
            if ordered[index].state.isPlaceholder || !message.state.isPlaceholder { ordered[index] = message }
        }
        func sent(_ event: ChatActivityEvent, _ call: AgentTalkCall) {
            // The bubble already names who wrote it; a "Message from …:" signature would say it twice.
            let words = call.message.map { AgentTalkIncomingMessage.parse($0)?.body ?? $0 }
            put(ChatAgentTalkMessage(id: "sent:\(event.id)", agentID: chatAgentID, fallbackName: nil,
                                     state: words.map(ChatAgentTalkMessage.State.said) ?? .sentFromFile,
                                     date: nil))
        }
        for piece in pieces {
            switch piece {
            case .call(let event, let answer):
                guard let call = event.agentTalkCall else { continue }
                sent(event, call)
                let state: ChatAgentTalkMessage.State?
                if event.lifecycle == .running {
                    state = .working
                } else {
                    switch event.agentTalkReply?.outcome {
                    case .answered: state = event.agentTalkReply?.text.map(ChatAgentTalkMessage.State.said)
                    case .failed: state = .noAnswer
                    case .queued: state = answer.map { $0.text.map(ChatAgentTalkMessage.State.said) ?? .noAnswer }
                        ?? .waiting
                    case nil: state = nil
                    }
                }
                if let state {
                    put(ChatAgentTalkMessage(id: "reply:\(event.id)", agentID: answer?.agentID ?? call.targetID,
                                             fallbackName: call.fallbackTargetName, state: state, date: answer?.date))
                }
            case .incoming(let item, let message, let reply):
                put(ChatAgentTalkMessage(id: "incoming:\(item.id)", agentID: message.senderID,
                                         fallbackName: message.senderName, state: .said(message.body),
                                         date: item.metadata.timestamp))
                if let reply, case .message(let text) = reply.content {
                    let prose = ReferenceCodec.decode(text).prose.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !prose.isEmpty {
                        put(ChatAgentTalkMessage(id: "answer:\(item.id)", agentID: chatAgentID, fallbackName: nil,
                                                 state: .said(prose), date: reply.metadata.timestamp))
                    }
                }
            case .answer(let item, let answer, let event):
                let state: ChatAgentTalkMessage.State = answer.text.map(ChatAgentTalkMessage.State.said) ?? .noAnswer
                if let event, let call = event.agentTalkCall {
                    sent(event, call)
                    put(ChatAgentTalkMessage(id: "reply:\(event.id)", agentID: answer.agentID ?? call.targetID,
                                             fallbackName: answer.fallbackName ?? call.fallbackTargetName,
                                             state: state, date: item.metadata.timestamp))
                } else {
                    let target = answer.agentID ?? "agent"
                    put(ChatAgentTalkMessage(id: "answer:\(item.id)", agentID: target,
                                             fallbackName: answer.fallbackName
                                                ?? AgentTalkCall(targetID: target, message: nil,
                                                                 route: .message).fallbackTargetName,
                                             state: state, date: item.metadata.timestamp))
                }
            }
        }
        return ordered
    }

    /// Who took part, this chat's agent first, then in order of appearance.
    func participants(chatAgentID: String) -> [ChatAgentTalkMessage] {
        var seen: Set<String> = [chatAgentID]
        var result = [ChatAgentTalkMessage(id: chatAgentID, agentID: chatAgentID, fallbackName: nil,
                                           state: .working, date: nil)]
        for message in messages(chatAgentID: chatAgentID) where seen.insert(message.agentID).inserted {
            result.append(message)
        }
        return result
    }
}

/// How a `message_agent` message was answered, later in the chat: the other
/// agent's own message back (Hermes 0.22 and later), or the notice that its
/// delivery ended, which carries the answer on older Hermes.
struct ChatAgentTalkAnswer: Equatable {
    /// The agent that answered, when the chat says.
    let agentID: String?
    let fallbackName: String?
    /// The other agent's words; nil when it didn't answer.
    let text: String?
    let date: Date?
}

/// Links across the chat for agent messages: a `message_agent` call and the
/// answer that comes in later, and each message another agent sent in with
/// the answer this chat's agent gave it.
@MainActor
struct ChatAgentTalkIndex {
    private var answersByCall: [String: ChatAgentTalkAnswer] = [:]
    private var piecesByItem: [String: ChatAgentTalk.Piece] = [:]
    private var hiddenItems: Set<String> = []

    init(_ rows: [ChatTurnDisplayRow], readsAgentMessages: Bool) {
        var entries: [ChatTranscriptEntry] = []
        for row in rows {
            switch row {
            case .entry(let entry): entries.append(entry)
            case .completed(let turn): entries += turn.entries
            }
        }
        var incoming: [(TimelineItem, AgentTalkIncomingMessage)] = []
        var answers: [(TimelineItem, ChatAgentTalkAnswer, ChatActivityEvent?)] = []
        var replies: [String: TimelineItem] = [:]
        var open: TimelineItem?
        var lastAnswer: TimelineItem?
        func close() {
            if let open, let lastAnswer { replies[open.id] = lastAnswer }
            open = nil
            lastAnswer = nil
        }
        // Queued `message_agent` messages: by their delivery process, and those still without an answer.
        var callsByProcess: [String: ChatActivityEvent] = [:]
        var unanswered: [ChatActivityEvent] = []
        var answeredByMessage: Set<String> = []
        for entry in entries {
            switch entry {
            case .activity(let turn):
                for event in turn.events where event.agentTalkCall?.route == .message
                    && event.agentTalkReply?.outcome == .queued {
                    if let process = event.agentTalkReply?.processID { callsByProcess[process] = event }
                    unanswered.append(event)
                }
            case .message(let item):
                guard readsAgentMessages else { continue }
                if item.role == .human {
                    close()
                    guard case .message(let text) = item.content else { continue }
                    if let delivery = AgentTalkDelivery.parse(text) {
                        let call = callsByProcess[delivery.processID]
                        if let call, answeredByMessage.contains(call.id) {
                            // The answer came in as the agent's own message; the notice only repeats it.
                            hiddenItems.insert(item.id)
                            continue
                        }
                        let answer = ChatAgentTalkAnswer(
                            agentID: delivery.targetID ?? call?.agentTalkCall?.targetID, fallbackName: nil,
                            text: delivery.reply, date: item.metadata.timestamp)
                        if let call {
                            answersByCall[call.id] = answer
                            unanswered.removeAll { $0.id == call.id }
                        }
                        answers.append((item, answer, call))
                    } else if let message = AgentTalkIncomingMessage.parse(text) {
                        // A message from an agent this chat's agent is waiting on is its answer, not a new
                        // request: what this chat's agent says next is for the person.
                        if let index = unanswered.firstIndex(where: { $0.agentTalkCall?.targetID == message.senderID }) {
                            let call = unanswered.remove(at: index)
                            let answer = ChatAgentTalkAnswer(agentID: message.senderID, fallbackName: message.senderName,
                                                             text: message.body, date: item.metadata.timestamp)
                            answersByCall[call.id] = answer
                            answeredByMessage.insert(call.id)
                            answers.append((item, answer, call))
                        } else {
                            incoming.append((item, message))
                            open = item
                        }
                    }
                } else if open != nil, !item.metadata.isInterimReply, item.metadata.delivery != "Streaming",
                          item.sender.kind != .system {
                    // The turn's last answer went back to the agent that wrote.
                    lastAnswer = item
                }
            }
        }
        close()
        for (item, message) in incoming {
            piecesByItem[item.id] = .incoming(item, message, reply: replies[item.id])
        }
        for (item, answer, call) in answers {
            piecesByItem[item.id] = .answer(item, answer, call: call)
        }
    }

    /// The rail piece a message is, when another agent wrote it.
    func piece(for item: TimelineItem) -> ChatAgentTalk.Piece? { piecesByItem[item.id] }

    /// A delivery notice whose answer already showed: it stays out of the chat.
    func hides(_ item: TimelineItem) -> Bool { hiddenItems.contains(item.id) }

    /// The later answer to a `message_agent` call.
    func answer(for event: ChatActivityEvent) -> ChatAgentTalkAnswer? { answersByCall[event.id] }
}

struct ChatAgentTalkMessage: Identifiable, Equatable {
    enum State: Equatable {
        case said(String)
        /// The words went in a file (`--query-file`), so the call doesn't show them.
        case sentFromFile
        /// The other agent is still on it.
        case working
        /// `message_agent` queued it; the answer comes back as its own message.
        case waiting
        case noAnswer

        var isPlaceholder: Bool { self == .working || self == .waiting }
    }

    let id: String
    let agentID: String
    /// The name to show when this computer's agent list doesn't have the agent
    /// (an agent on another computer, or one since removed).
    let fallbackName: String?
    let state: State
    let date: Date?

    /// Counts toward "3 messages": something was actually said.
    var isMessage: Bool {
        switch state {
        case .said, .sentFromFile: true
        case .working, .waiting, .noAnswer: false
        }
    }
}

/// What a running call's other agent is doing now, from the plugin's
/// `native-agent-talk-v1` feed. Nothing here is guessed: without the plugin
/// the rail just says who it's asking.
struct AgentTalkLiveActivity: Equatable, Sendable {
    /// The other agent's own chat for this exchange.
    let sessionID: String?
    /// The Hermes tool the other agent is running, if any.
    let toolName: String?
    let isWorking: Bool
}

/// Words for the rail, apart from the view so they can be tested.
@MainActor
enum ChatAgentTalkPresentation {
    static func name(for agentID: String, fallback: String?, resolver: TimelineSenderResolver) -> String {
        if let profile = resolver.agents?.profiles.first(where: { $0.id == agentID }) { return profile.name }
        return fallback ?? resolver.display(forAgentID: agentID).name
    }

    static func label(for talk: ChatAgentTalk, chatAgentID: String, resolver: TimelineSenderResolver,
                      live: [String: AgentTalkLiveActivity] = [:]) -> String {
        let messages = talk.messages(chatAgentID: chatAgentID)
        if let running = talk.runningCalls.last, let call = running.agentTalkCall {
            let name = name(for: call.targetID, fallback: call.fallbackTargetName, resolver: resolver)
            return working(name, live[running.id]) ?? "Asking \(name)…"
        }
        // A `message_agent` message comes back later; the plugin can still say what's happening.
        for piece in talk.pieces.reversed() {
            guard case .call(let event, .none) = piece, let call = event.agentTalkCall, call.route == .message,
                  let activity = live[event.id], activity.isWorking else { continue }
            let name = name(for: call.targetID, fallback: call.fallbackTargetName, resolver: resolver)
            return working(name, activity) ?? "\(name) is working on it…"
        }
        // A `message_agent` message and its answer are two rows, each where it happened: say which.
        if talk.pieces.count == 1 {
            switch talk.pieces[0] {
            case .call(let event, let answer?):
                if event.agentTalkReply?.outcome == .queued, let call = event.agentTalkCall {
                    return "Asked \(name(for: answer.agentID ?? call.targetID, fallback: call.fallbackTargetName, resolver: resolver))"
                }
            case .answer(_, let answer, let event):
                let call = event?.agentTalkCall
                let who = name(for: answer.agentID ?? call?.targetID ?? "agent",
                               fallback: answer.fallbackName ?? call?.fallbackTargetName, resolver: resolver)
                return answer.text == nil ? "\(who) didn't answer" : "\(who) answered"
            default:
                break
            }
        }
        if let last = messages.last, last.agentID != chatAgentID {
            let name = name(for: last.agentID, fallback: last.fallbackName, resolver: resolver)
            switch last.state {
            case .noAnswer: return "\(name) didn't answer"
            case .waiting: return "Waiting for \(name)"
            default: break
            }
        }
        let others = talk.participants(chatAgentID: chatAgentID).dropFirst()
            .map { name(for: $0.agentID, fallback: $0.fallbackName, resolver: resolver) }
        let names = others.isEmpty
            ? [name(for: chatAgentID, fallback: nil, resolver: resolver)]
            : Array(others)
        let count = messages.filter(\.isMessage).count
        let noun = count == 1 ? "1 message" : "\(count) messages"
        return "\(noun) with \(list(names))"
    }

    /// "Nova is searching the web…", from the tool the plugin saw it running.
    static func working(_ name: String, _ activity: AgentTalkLiveActivity?) -> String? {
        guard let tool = activity?.toolName else { return nil }
        let phrase = ChatToolPhrase.phrase(forTool: tool, arguments: nil).live
        return "\(name) is \(phrase.prefix(1).lowercased() + phrase.dropFirst())"
    }

    /// "Nova", "Nova and Havok", "Nova, Havok and Sage", "Nova, Havok and 2 more".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    static func title(for talk: ChatAgentTalk, chatAgentID: String, resolver: TimelineSenderResolver) -> String {
        list(talk.participants(chatAgentID: chatAgentID)
            .map { name(for: $0.agentID, fallback: $0.fallbackName, resolver: resolver) })
    }
}

/// The rail itself: the agents' faces stacked, what passed between them, and
/// a tap to read it.
@MainActor
struct ChatAgentTalkRail: View {
    let talk: ChatAgentTalk
    let chatAgentID: String
    let senderResolver: TimelineSenderResolver
    var live: [String: AgentTalkLiveActivity] = [:]
    var loadSteps: AgentTalkStepsLoader?

    @State private var isPresented = false
    @Environment(\.bighelpActivityLoaderFocus) private var loaderFocus
    @BighelpThemeReader private var theme

    static func loaderID(_ talk: ChatAgentTalk) -> String { "agent-talk:\(talk.id)" }

    private var playsLoader: Bool { talk.isLive && (loaderFocus?.allows(Self.loaderID(talk)) ?? true) }

    var body: some View {
        let label = ChatAgentTalkPresentation.label(for: talk, chatAgentID: chatAgentID,
                                                    resolver: senderResolver, live: live)
        Button {
            isPresented = true
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                ChatAgentFaceStack(agents: talk.participants(chatAgentID: chatAgentID), resolver: senderResolver,
                                   size: BighelpTokens.scaled(24))
                Text(label)
                    .bighelpFont(.metadata, weight: .medium)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .bighelpShimmer(isActive: playsLoader)
                Image(systemName: "chevron.right")
                    .font(.bighelp(.caption).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, BighelpTokens.space12)
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityHint("Shows what the agents said to each other.")
        .accessibilityIdentifier("chat.agent-talk.\(talk.id)")
        .accessibilityAction { isPresented = true }
        .contextMenu {
            Button("Show conversation", systemImage: "bubble.left.and.bubble.right") { isPresented = true }
        }
        .bighelpSheet(isPresented: $isPresented) {
            ChatAgentTalkSheet(talk: talk, chatAgentID: chatAgentID, senderResolver: senderResolver, live: live,
                               loadSteps: loadSteps)
                .bighelpSheetSize(.large)
        }
    }
}

/// The agents' faces, overlapping a little, each as the rest of the app draws it.
struct ChatAgentFaceStack: View {
    let agents: [ChatAgentTalkMessage]
    let resolver: TimelineSenderResolver
    let size: CGFloat

    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(agents.prefix(4).enumerated()), id: \.element.agentID) { index, agent in
                ChatAgentTalkFace(agentID: agent.agentID,
                                  name: ChatAgentTalkPresentation.name(for: agent.agentID, fallback: agent.fallbackName,
                                                                       resolver: resolver),
                                  imageURL: resolver.display(forAgentID: agent.agentID).imageURL, size: size)
                    .padding(1.5)
                    .background(Circle().fill(theme.canvas))
                    .zIndex(Double(agents.count - index))
            }
        }
        .accessibilityHidden(true)
    }
}

/// One agent's face: its Simple Bot mode mark while that mode is on, else the
/// face the rest of the app draws (character, pet or picture).
struct ChatAgentTalkFace: View {
    let agentID: String
    let name: String
    let imageURL: URL?
    let size: CGFloat

    @Environment(\.appAppearance) private var appearance

    var body: some View {
        Group {
            if appearance.simpleBots {
                SimpleBotFace(agentID: agentID, name: name, imageURL: imageURL, size: size)
            } else {
                AgentLiveAvatar(agentID: agentID, displayName: name, imageURL: imageURL, size: size, showsBadge: false)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Reads the other agent's own chat for an exchange: what it did, in plain
/// words ("Checked your calendars"). Nil when the host can't say.
typealias AgentTalkStepsLoader = @MainActor (_ agentID: String, _ sessionID: String) async -> [String]?

/// What the agents said to each other, as a short chat between them.
@MainActor
struct ChatAgentTalkSheet: View {
    let talk: ChatAgentTalk
    let chatAgentID: String
    let senderResolver: TimelineSenderResolver
    let live: [String: AgentTalkLiveActivity]
    let loadSteps: AgentTalkStepsLoader?

    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    ForEach(talk.messages(chatAgentID: chatAgentID)) { message in
                        ChatAgentTalkBubble(message: message, isChatAgent: message.agentID == chatAgentID,
                                            resolver: senderResolver, liveLine: liveLine(for: message))
                    }
                    ForEach(otherSessions, id: \.sessionID) { session in
                        ChatAgentTalkSteps(agentName: ChatAgentTalkPresentation.name(
                            for: session.agentID, fallback: session.fallbackName, resolver: senderResolver),
                            agentID: session.agentID, sessionID: session.sessionID, loadSteps: loadSteps)
                    }
                }
                .padding(BighelpTokens.space16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(ChatAgentTalkPresentation.title(for: talk, chatAgentID: chatAgentID,
                                                             resolver: senderResolver))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("chat.agent-talk.done")
                }
            }
        }
        .accessibilityIdentifier("chat.agent-talk.sheet")
    }

    /// "Nova is checking your calendars…" under a working bubble, from the plugin's feed.
    private func liveLine(for message: ChatAgentTalkMessage) -> String? {
        guard message.state.isPlaceholder, message.id.hasPrefix("reply:") else { return nil }
        let eventID = String(message.id.dropFirst("reply:".count))
        let name = ChatAgentTalkPresentation.name(for: message.agentID, fallback: message.fallbackName,
                                                  resolver: senderResolver)
        return ChatAgentTalkPresentation.working(name, live[eventID])
    }

    /// The other agents' own chats for these exchanges, once they've finished.
    private var otherSessions: [(agentID: String, fallbackName: String, sessionID: String)] {
        guard loadSteps != nil else { return [] }
        var seen = Set<String>()
        return talk.pieces.compactMap { piece in
            guard case .call(let event, _) = piece, event.lifecycle != .running,
                  let call = event.agentTalkCall, call.route == .chat,
                  let session = event.agentTalkReply?.sessionID ?? live[event.id]?.sessionID,
                  seen.insert(session).inserted else { return nil }
            return (call.targetID, call.fallbackTargetName, session)
        }
    }
}

/// One message between the agents: this chat's agent on the trailing side,
/// the others leading, each with its face and name.
private struct ChatAgentTalkBubble: View {
    let message: ChatAgentTalkMessage
    let isChatAgent: Bool
    let resolver: TimelineSenderResolver
    let liveLine: String?

    @BighelpThemeReader private var theme

    private var name: String {
        ChatAgentTalkPresentation.name(for: message.agentID, fallback: message.fallbackName, resolver: resolver)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: BighelpTokens.space8) {
            if isChatAgent { Spacer(minLength: BighelpTokens.space32) } else { face }
            VStack(alignment: isChatAgent ? .trailing : .leading, spacing: BighelpTokens.space4) {
                Text(name)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                content
                if let liveLine {
                    Text(liveLine)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .bighelpShimmer(isActive: true)
                }
            }
            if isChatAgent { face } else { Spacer(minLength: BighelpTokens.space32) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.agent-talk.message.\(message.id)")
    }

    private var face: some View {
        ChatAgentTalkFace(agentID: message.agentID, name: name,
                          imageURL: resolver.display(forAgentID: message.agentID).imageURL,
                          size: ChatMessageGrouping.perchedAvatarSize)
    }

    @ViewBuilder
    private var content: some View {
        switch message.state {
        case .said(let text):
            MarkdownMessageView(document: MarkdownDocument(text))
                .textSelection(.enabled)
                .padding(.horizontal, BighelpTokens.space12)
                .padding(.vertical, BighelpTokens.space8)
                .background(isChatAgent ? theme.action.opacity(0.14) : theme.incomingMessageBackground,
                            in: .rect(cornerRadius: BighelpTokens.radius16))
        case .sentFromFile:
            note("Sent a message from a file")
        case .working:
            TypingBubble()
                .accessibilityLabel("\(name) is working on it")
        case .waiting:
            note("Waiting for \(name)'s answer")
        case .noAnswer:
            note("\(name) didn't answer")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .bighelpFont(.metadata)
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, BighelpTokens.space8)
            .background(theme.incomingMessageBackground.opacity(0.5),
                        in: .rect(cornerRadius: BighelpTokens.radius16))
    }
}

/// What the other agent did for this exchange, read from its own chat when
/// someone opens it.
private struct ChatAgentTalkSteps: View {
    let agentName: String
    let agentID: String
    let sessionID: String
    let loadSteps: AgentTalkStepsLoader?

    @State private var steps: [String]?
    @State private var isExpanded = false
    @BighelpThemeReader private var theme

    var body: some View {
        if let steps, !steps.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Label(step, systemImage: "checkmark")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(.top, BighelpTokens.space8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("What \(agentName) did")
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
            }
            .tint(theme.secondaryText)
            .accessibilityIdentifier("chat.agent-talk.steps.\(sessionID)")
        } else {
            Color.clear.frame(height: 0)
                .task(id: sessionID) {
                    guard steps == nil, let loadSteps else { return }
                    steps = await loadSteps(agentID, sessionID) ?? []
                }
        }
    }
}
