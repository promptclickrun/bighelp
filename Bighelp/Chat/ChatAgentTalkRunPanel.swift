import SwiftUI

/// What the rail's open view needs from its chat: the other agent's turn as its gateway runs it, Stop, and
/// the way into the agent's own chat.
struct AgentTalkRunAccess {
    let frames: @MainActor (_ agentID: String, _ sessionID: String, _ after: Int?, _ epoch: String?) async
        -> AgentLiveFrames?
    let stop: @MainActor (_ agentID: String, _ sessionID: String) async -> Bool
    var openChat: @MainActor (_ agentID: String) -> Void = { agentID in
        BighelpIncomingLinkCenter.shared.open(BighelpShortcutLinks.agentHome(agentID))
    }
}

/// The other agent's turn, folded from its gateway's frames into what the rail shows: its steps, the
/// newest thing it thought, and whether it still runs.
@MainActor
@Observable
final class AgentTalkRunFeed {
    struct Step: Identifiable, Equatable {
        let id: String
        var phrase: ChatToolPhrase
        var isDone: Bool
    }

    private(set) var steps: [Step] = []
    private(set) var thinking: String?
    private(set) var isRunning = false
    /// The plugin follows the agent's gateway; false without one, or before the first answer.
    private(set) var isAttached = false

    static let thinkingLimit = 160

    func fold(_ frames: [AgentLiveFrames.Frame]) {
        for frame in frames {
            let payload = frame.payload
            switch frame.type {
            case "message.start":
                isRunning = true
            case "message.complete":
                isRunning = false
            case "tool.start":
                let id = payload["tool_id"]?.string ?? payload["tool_call_id"]?.string ?? "frame-\(frame.sequence)"
                let phrase = ChatToolPhrase.phrase(forTool: payload["name"]?.string, arguments: Self.arguments(payload["args"]))
                if let index = steps.firstIndex(where: { $0.id == id }) { steps[index].phrase = phrase }
                else { steps.append(Step(id: id, phrase: phrase, isDone: false)) }
                thinking = nil
            case "tool.complete":
                let id = payload["tool_id"]?.string ?? payload["tool_call_id"]?.string
                if let index = steps.lastIndex(where: { $0.id == id || (id == nil && !$0.isDone) }) {
                    steps[index].isDone = true
                }
            case "reasoning.delta", "thinking.delta":
                guard let text = payload["text"]?.string, !SubagentCanvasState.isHermesSpinner(text) else { continue }
                let joined = (frame.type == "reasoning.delta" ? (thinking ?? "") : "") + text
                let line = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                thinking = line.isEmpty ? thinking : String(line.suffix(Self.thinkingLimit))
            case "session.info":
                if let running = payload["running"]?.boolean { isRunning = running }
            default:
                continue
            }
        }
    }

    /// Follows the turn while the view shows, a frame batch at a time.
    func follow(agentID: String, sessionID: String, access: AgentTalkRunAccess) async {
        var after: Int?
        var epoch: String?
        while !Task.isCancelled {
            guard let feed = await access.frames(agentID, sessionID, after, epoch), !Task.isCancelled else { return }
            isAttached = feed.isAttached
            guard feed.isAttached else { return }
            if feed.reset { steps = []; thinking = nil }
            isRunning = feed.isRunning
            fold(feed.frames)
            epoch = feed.epoch ?? epoch
            after = feed.last ?? after
            if !feed.isRunning { return }
        }
    }

    private static func arguments(_ value: BighelpJSONValue?) -> String? {
        guard let value else { return nil }
        if case .string(let text) = value { return text }
        return (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// The rail opened in place (Option C): the other agent's steps as it works, then its answer, with the way
/// into its own chat and, while it works, Stop.
@MainActor
struct ChatAgentTalkRunPanel: View {
    let agentID: String
    let name: String
    let delivery: AgentDelivery
    let access: AgentTalkRunAccess

    @State private var feed = AgentTalkRunFeed()
    @State private var isStopping = false
    @BighelpThemeReader private var theme

    static let visibleSteps = 4

    private var working: Bool { delivery.state == .working || delivery.state == .queued }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if working {
                steps
                if let thinking = feed.thinking {
                    Text(thinking)
                        .bighelpFont(.metadata)
                        .italic()
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(3)
                        .accessibilityLabel("\(name) is thinking: \(thinking)")
                }
            } else if let reply = delivery.reply {
                MarkdownMessageView(document: MarkdownDocument(reply))
                    .textSelection(.enabled)
            }
            buttons
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.incomingMessageBackground.opacity(0.6), in: .rect(cornerRadius: BighelpTokens.radius16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.agent-talk.run")
        .task(id: delivery.sessionID.map { "\($0)|\(working)" }) {
            guard working, let session = delivery.sessionID else { return }
            await feed.follow(agentID: agentID, sessionID: session, access: access)
        }
    }

    @ViewBuilder
    private var steps: some View {
        let shown = feed.steps.suffix(Self.visibleSteps)
        if feed.steps.isEmpty {
            Text(delivery.state == .queued ? "\(name) has your message and will start on it next."
                 : "\(name) is getting started…")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                if feed.steps.count > shown.count {
                    Text("\(feed.steps.count - shown.count) earlier steps")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.tertiaryText)
                }
                ForEach(shown) { step in
                    Label(step.isDone ? step.phrase.past : step.phrase.live,
                          systemImage: step.isDone ? "checkmark" : "circle.fill")
                        .bighelpFont(.metadata, weight: step.isDone ? .regular : .semibold)
                        .foregroundStyle(step.isDone ? theme.secondaryText : theme.primaryText)
                        .labelStyle(ChatAgentTalkStepLabelStyle(isDone: step.isDone))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.agent-talk.run.steps")
        }
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BighelpTokens.space8) { openButton; stopButton }
            VStack(alignment: .leading, spacing: BighelpTokens.space8) { openButton; stopButton }
        }
    }

    private var openButton: some View {
        Button(working ? "Watch in \(name)'s chat" : "Open \(name)'s chat") { access.openChat(agentID) }
            .bighelpFont(.metadata, weight: .semibold)
            .buttonStyle(.bordered)
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("chat.agent-talk.run.open")
    }

    @ViewBuilder
    private var stopButton: some View {
        if delivery.state == .working, let session = delivery.sessionID {
            Button("Stop", role: .destructive) {
                isStopping = true
                Task {
                    _ = await access.stop(agentID, session)
                    isStopping = false
                }
            }
            .bighelpFont(.metadata, weight: .semibold)
            .buttonStyle(.bordered)
            .frame(minHeight: BighelpTokens.hitTarget)
            .disabled(isStopping)
            .accessibilityIdentifier("chat.agent-talk.run.stop")
        }
    }
}

/// A step's mark: a check once done, a small dot while it runs.
private struct ChatAgentTalkStepLabelStyle: LabelStyle {
    let isDone: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
            configuration.icon
                .font(.bighelp(.caption2))
                .frame(width: BighelpTokens.scaled(14))
                .accessibilityHidden(true)
            configuration.title
        }
    }
}
