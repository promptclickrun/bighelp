import SwiftUI

enum ChatCollaborationMotionPolicy {
    static func animates(lifecycle: ChatActivityLifecycle, reduceMotion: Bool) -> Bool {
        lifecycle == .running && !reduceMotion
    }
}

enum ChatCollaborationTranscriptPresentation {
    static func resultLabel(
        for event: ChatActivityEvent,
        fromName: String,
        toName: String
    ) -> String {
        event.arguments == nil ? "Reply excerpt from \(fromName)" : "From \(toName)"
    }
}

@MainActor
struct ChatActivityTurnPresentation {
    enum Segment: Identifiable {
        case collaboration(ChatActivityEvent)
        case generatedMedia(ChatActivityEvent)
        /// Back-to-back reasoning shares one Thinking/Thought process row.
        case thinking([ChatActivityEvent])
        case workTrail(ChatActivityTurn)

        var id: String {
            switch self {
            case .collaboration(let event): "collaboration:\(event.id)"
            case .generatedMedia(let event): "generated-media:\(event.id)"
            case .thinking(let events): "thinking:\(events.first?.id ?? "")"
            case .workTrail(let turn): "work-trail:\(turn.id)"
            }
        }
    }

    let segments: [Segment]
    let collaborations: [ChatActivityEvent]
    let workTrail: ChatActivityTurn?

    init(turn: ChatActivityTurn) {
        collaborations = turn.events.filter { $0.kind == .botHandoff }
        let ordinaryEvents = turn.events.filter {
            $0.kind != .botHandoff && $0.kind != .reasoning && GeneratedMediaProjection.kind(for: $0) == nil
        }
        workTrail = ordinaryEvents.isEmpty
            ? nil
            : ChatActivityTurn(id: turn.id, events: ordinaryEvents)

        var projected: [Segment] = []
        var pendingWork: [ChatActivityEvent] = []
        var workSegmentCount = 0
        func flushWork() {
            guard let first = pendingWork.first else { return }
            let segmentID = workSegmentCount == 0
                ? turn.id
                : "\(turn.id):segment:\(first.id)"
            projected.append(.workTrail(ChatActivityTurn(
                id: segmentID,
                events: pendingWork
            )))
            workSegmentCount += 1
            pendingWork.removeAll(keepingCapacity: true)
        }
        for event in turn.events {
            if event.kind == .botHandoff {
                flushWork()
                projected.append(.collaboration(event))
            } else if GeneratedMediaProjection.kind(for: event) != nil {
                flushWork()
                projected.append(.generatedMedia(event))
            } else if event.kind == .reasoning {
                flushWork()
                if case .thinking(let group)? = projected.last {
                    projected[projected.count - 1] = .thinking(group + [event])
                } else {
                    projected.append(.thinking([event]))
                }
            } else {
                pendingWork.append(event)
            }
        }
        flushWork()
        segments = projected
    }
}

@MainActor
struct ChatActivityTurnView: View {
    let turn: ChatActivityTurn
    let senderResolver: TimelineSenderResolver
    /// This is the newest work of a turn still running: its last folder is live.
    let isLive: Bool
    let onDisclosureChange: () -> Void
    @Environment(\.chatActivityDisclosureStore) private var inheritedDisclosures
    @State private var localDisclosures = ChatActivityDisclosureStore()

    init(
        turn: ChatActivityTurn,
        senderResolver: TimelineSenderResolver = TimelineSenderResolver(),
        isLive: Bool = false,
        onDisclosureChange: @escaping () -> Void = {}
    ) {
        self.turn = turn
        self.senderResolver = senderResolver
        self.isLive = isLive
        self.onDisclosureChange = onDisclosureChange
    }

    var body: some View {
        let presentation = ChatActivityTurnPresentation(turn: turn)
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            ForEach(presentation.segments) { segment in
                switch segment {
                case .collaboration(let event):
                    AgentCollaborationCard(
                        event: event,
                        senderResolver: senderResolver,
                        onDisclosureChange: onDisclosureChange
                    )
                case .generatedMedia(let event):
                    GeneratedMediaCard(event: event)
                case .thinking(let events):
                    // Quiet, like interim messages: the answer is what stands out.
                    ChatThinkingRow(events: events, onDisclosureChange: onDisclosureChange)
                case .workTrail(let workTrail):
                    ChatWorkTrailCard(
                        turn: workTrail,
                        isLive: isLive && (segment.id == presentation.segments.last?.id
                            || workTrail.events.contains { $0.lifecycle == .running }),
                        onDisclosureChange: onDisclosureChange
                    )
                }
            }
        }
        .environment(\.chatActivityDisclosureStore, inheritedDisclosures ?? localDisclosures)
    }
}

@MainActor
private struct AgentCollaborationCard: View {
    let event: ChatActivityEvent
    let senderResolver: TimelineSenderResolver
    let onDisclosureChange: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatActivityDisclosureStore) private var disclosures
    @State private var localExpanded = false
    private var isExpanded: Bool { disclosures?.isExpanded(event) ?? localExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Button {
                onDisclosureChange()
                let expanded = !isExpanded
                if let disclosures { disclosures.setExpanded(expanded, for: event) }
                else { localExpanded = expanded }
            } label: {
                HStack(alignment: .top, spacing: BighelpTokens.space12) {
                    AvatarView(
                        stableID: toID,
                        displayName: to.name,
                        imageURL: to.imageURL,
                        size: 36
                    )
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text(to.name)
                            .bighelpFont(.body, weight: .semibold)
                            .foregroundStyle(.primary)
                        Text(event.collapsedPresentationSummary ?? "Delegated by \(from.name)")
                            .bighelpFont(.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    Label(statusLabel, systemImage: statusImage)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(statusColor)
                        .accessibilityLabel(statusLabel)
                    Image(systemName: "chevron.right")
                        .bighelpFont(.metadata, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Agent collaboration from \(from.name) to \(to.name). \(statusLabel).")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses the collaboration transcript." : "Expands the collaboration transcript.")
            .accessibilityIdentifier("chat.collaboration.\(event.eventID)")

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                        transcriptSection(label: "From \(from.name)", text: event.arguments)
                        transcriptSection(
                            label: ChatCollaborationTranscriptPresentation.resultLabel(
                                for: event,
                                fromName: from.name,
                                toName: to.name
                            ),
                            text: event.result
                        )
                        if event.arguments == nil, event.result == nil {
                            transcriptSection(label: "Activity", text: event.summary ?? event.detail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .accessibilityIdentifier("chat.collaboration.\(event.eventID).transcript")
            }
        }
        .padding(BighelpTokens.space16)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                .stroke(Color(uiColor: .separator), lineWidth: BighelpTokens.hairline)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func transcriptSection(label: String, text: String?) -> some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(label)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                MarkdownMessageView(document: MarkdownDocument(text))
                    .textSelection(.enabled)
            }
        }
    }

    private var fromID: String { event.fromMemberID ?? "default" }
    private var toID: String { event.memberID ?? "agent" }
    private var from: TimelineSenderDisplay { senderResolver.display(forAgentID: fromID) }
    private var to: TimelineSenderDisplay { senderResolver.display(forAgentID: toID) }

    private var statusLabel: String {
        switch event.lifecycle {
        case .running: "Connecting"
        case .succeeded: "Complete"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .recorded: "Recorded"
        }
    }

    private var statusImage: String {
        switch event.lifecycle {
        case .running: "wave.3.right"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle.fill"
        case .recorded: "clock.arrow.circlepath"
        }
    }

    private var statusColor: Color {
        switch ChatActivityVisualState(lifecycle: event.lifecycle).tone {
        case .neutral: theme.action
        case .success: theme.success
        case .failure: theme.danger
        case .secondary: theme.secondaryText
        }
    }

    @BighelpThemeReader private var theme: BighelpTheme
}
