import SwiftUI

@MainActor
struct TimelineSenderDisplay: Equatable {
    let name: String
    let imageURL: URL?
}

@MainActor
struct TimelineSenderResolver {
    let userIdentity: UserIdentityStore?
    let agents: AgentDirectoryStore?

    init(userIdentity: UserIdentityStore? = nil, agents: AgentDirectoryStore? = nil) {
        self.userIdentity = userIdentity
        self.agents = agents
    }

    func display(for sender: TimelineSender) -> TimelineSenderDisplay {
        switch sender.kind {
        case .user:
            if sender.id == UserIdentity.stableID, let userIdentity {
                return TimelineSenderDisplay(
                    name: userIdentity.identity.displayName,
                    imageURL: userIdentity.avatarURL()
                )
            }
        case .agent:
            if let agent = agents?.profiles.first(where: { $0.id == sender.id }) {
                return TimelineSenderDisplay(name: agent.name, imageURL: agents?.avatarURL(for: agent))
            }
        case .system:
            break
        }
        return TimelineSenderDisplay(
            name: sender.snapshot.name,
            imageURL: AvatarFileURL.resolve(
                fileName: sender.snapshot.avatarFileName,
                in: agents?.avatarDirectory
            )
        )
    }

    func display(forAgentID id: String) -> TimelineSenderDisplay {
        let fallback = id == "default"
            ? "Agent"
            : id.replacingOccurrences(of: "_", with: " ").capitalized
        return display(for: .agent(id: id, snapshot: .init(name: fallback)))
    }

    func accessibilityDescription(for item: TimelineItem) -> String {
        let description: String
        if item.role == .assistant, case .message(let text) = item.content {
            let prose = ReferenceCodec.decode(text).prose
            let projection = ChatCardMessageProjection(source: prose, role: .assistant)
            let hasOnlyText = projection.segments.allSatisfy { if case .markdown = $0 { true } else { false } }
            description = hasOnlyText ? text : projection.segments.map { segment in
                switch segment {
                case .markdown(let document): document.visiblePlainText
                case .card(let card): card.title
                case .table(let table): MarkdownDocument(blocks: [.table(table)]).visiblePlainText
                case .rule: ""
                case .pendingCard: "Making a card"
                case .unavailableCard: "This card couldn't be shown"
                }
            }.filter { !$0.isEmpty }.joined(separator: ". ")
        } else {
            description = contentDescription(for: item.content)
        }
        return "\(display(for: item.sender).name): \(description)"
    }

    private func contentDescription(for content: TimelineContent) -> String {
        switch content {
        case .message(let text): text
        case .budgetSummary: "Budget and plan"
        case .weatherAndTasks: "Weather and priority tasks"
        case .approvalRequest: "Approval request"
        case .generativeUI(let card): card.title
        case .bighelpCard(let card): card.title
        }
    }
}

private enum MessageContentBottomAlignment: AlignmentID {
    static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[.bottom] }
}
private extension VerticalAlignment {
    static let messageContentBottom = VerticalAlignment(MessageContentBottomAlignment.self)
}

@MainActor
struct TimelineItemView: View {
    let item: TimelineItem
    let onApprovalTap: (ApprovalRequest) -> Void
    let onFork: ((String) -> Void)?
    let pendingMidSessionBehavior: MidSessionChatBehavior?
    let senderResolver: TimelineSenderResolver
    let showsSenderName: Bool
    let messageReaction: NativeMessageReactionPresentation?
    let onMessageReaction: ((String?) -> Void)?
    let mentionIdentities: [ChatMentionIdentity]

    init(
        item: TimelineItem,
        onApprovalTap: @escaping (ApprovalRequest) -> Void,
        onFork: ((String) -> Void)? = nil,
        pendingMidSessionBehavior: MidSessionChatBehavior? = nil,
        senderResolver: TimelineSenderResolver = TimelineSenderResolver(),
        showsSenderName: Bool = false,
        messageReaction: NativeMessageReactionPresentation? = nil,
        onMessageReaction: ((String?) -> Void)? = nil,
        mentionIdentities: [ChatMentionIdentity] = []
    ) {
        self.item = item
        self.onApprovalTap = onApprovalTap
        self.onFork = onFork
        self.pendingMidSessionBehavior = pendingMidSessionBehavior
        self.senderResolver = senderResolver
        self.showsSenderName = showsSenderName
        self.messageReaction = messageReaction
        self.onMessageReaction = onMessageReaction
        self.mentionIdentities = mentionIdentities
    }

    var body: some View {
        Group {
            if uiV3Enabled, showsSenderName, item.role == .assistant {
                groupAssistantMessage
            } else {
                messageColumn
            }
        }
        .frame(maxWidth: .infinity, alignment: item.role == .human ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(senderResolver.accessibilityDescription(for: item))
        .accessibilityValue(pendingMidSessionBehavior.map(PendingMidSessionPresentation.label) ?? "")
        .accessibilityIdentifier("chat.message.\(item.id)")
    }

    private var messageColumn: some View {
        VStack(alignment: item.role == .human ? .trailing : .leading,
               spacing: uiV3Enabled ? BighelpTokens.space12 : BighelpTokens.space8) {
            let pendingFiles = pendingFileState
            if !uiV3Enabled { senderBadge }
            if !item.attachments.isEmpty {
                if case .message(let text) = item.content, text.isEmpty {
                    attachmentGallery.alignmentGuide(.messageContentBottom) { $0[.bottom] }
                } else {
                    attachmentGallery
                }
            } else if !pendingFiles.fileNames.isEmpty {
                if pendingFiles.text.isEmpty {
                    PendingAgentFilesView(fileNames: pendingFiles.fileNames)
                        .alignmentGuide(.messageContentBottom) { $0[.bottom] }
                } else {
                    PendingAgentFilesView(fileNames: pendingFiles.fileNames)
                }
            }
            switch item.content {
            case .message(let text):
                if (!text.isEmpty || item.attachments.isEmpty)
                    && (pendingFiles.fileNames.isEmpty || !pendingFiles.text.isEmpty) {
                    MessageBubble(
                        messageID: item.id,
                        role: item.role,
                        speakerName: sender.name,
                        text: pendingFiles.fileNames.isEmpty
                            ? DirectHermesGeneratedMediaClient.unresolvedMessageText(text, role: item.role)
                            : pendingFiles.text,
                        delivery: item.metadata.delivery,
                        isPendingSubmission: pendingMidSessionBehavior != nil,
                        onFork: onFork.map { callback in { callback(item.id) } },
                        contentReference: item.metadata.contentReference,
                        metadata: item.metadata,
                        reactionPresentation: messageReaction,
                        onReaction: onMessageReaction,
                        mentionIdentities: mentionIdentities
                    )
                }
            case .budgetSummary(let summary):
                BudgetAndPlanView(summary: summary)
                    .alignmentGuide(.messageContentBottom) { $0[.bottom] }
            case .weatherAndTasks(let content):
                WeatherAndTasksView(content: content)
                    .alignmentGuide(.messageContentBottom) { $0[.bottom] }
            case .approvalRequest(let request):
                ApprovalRequestPreview(request: request, onOpen: onApprovalTap)
                    .alignmentGuide(.messageContentBottom) { $0[.bottom] }
            case .generativeUI(let card):
                GenerativeUICardView(card: card, messageID: item.id)
                    .cardImageCopy(GenerativeUICardView(card: card, messageID: item.id))
                    .alignmentGuide(.messageContentBottom) { $0[.bottom] }
            case .bighelpCard(let card):
                BighelpCardView(card: card)
                    .cardImageCopy(BighelpCardView(card: card))
                    .alignmentGuide(.messageContentBottom) { $0[.bottom] }
            }

            if let reference = item.metadata.contentReference {
                Text("Preview — complete content is stored on Hermes.")
                    .font(.bighelp(.caption))
                    .foregroundStyle(.secondary)
                BighelpSessionContentDisclosure(sessionID: reference.sessionID, rowID: reference.rowID)
            }

            if let pendingMidSessionBehavior {
                PendingMidSessionStatusView(behavior: pendingMidSessionBehavior)
            } else if !uiV3Enabled {
                TimelineMetadataView(metadata: item.metadata)
            } else if case .message(let text) = item.content,
                      !text.isEmpty || item.attachments.isEmpty {
                EmptyView()
            } else {
                TimelineMetadataView(metadata: item.metadata)
            }
        }
    }

    /// An agent's files still loading show as tiles, not as their file lines.
    private var pendingFileState: (text: String, fileNames: [String]) {
        guard item.attachments.isEmpty, case .message(let text) = item.content else { return ("", []) }
        return DirectHermesGeneratedMediaClient.pendingFiles(text, role: item.role)
    }

    private var attachmentGallery: some View {
        ChatAttachmentGallery(attachments: item.attachments, alignsTrailing: item.role == .human)
            .opacity(pendingMidSessionBehavior == nil ? 1 : 0.62)
    }

    /// Group chats: the sender's name heads each run and a small avatar perches
    /// beside the run's last bubble, next to its tail.
    private var groupAssistantMessage: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            if !continuesPrevious {
                Text(sender.name)
                    .bighelpMessageFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.leading, ChatMessageGrouping.perchedAvatarSize + BighelpTokens.space8
                        + BighelpV3MessagePresentation.horizontalContentPadding)
                    .accessibilityHidden(true)
            }

            HStack(alignment: .messageContentBottom, spacing: BighelpTokens.space8) {
                Group {
                    if continuesGroup {
                        Color.clear
                    } else {
                        AvatarView(
                            stableID: item.sender.id,
                            displayName: sender.name,
                            imageURL: sender.imageURL,
                            size: ChatMessageGrouping.perchedAvatarSize,
                            kind: item.sender.kind == .agent ? .agent : .person
                        )
                    }
                }
                .frame(width: ChatMessageGrouping.perchedAvatarSize, height: ChatMessageGrouping.perchedAvatarSize)
                .alignmentGuide(.messageContentBottom) { $0[.bottom] }
                .accessibilityHidden(true)

                messageColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var sender: TimelineSenderDisplay {
        senderResolver.display(for: item.sender)
    }

    private var senderBadge: some View {
        HStack(spacing: BighelpTokens.space8) {
            if item.role == .human { Spacer(minLength: 0) }
            Text(sender.name)
                .bighelpMessageFont(.metadata, weight: .semibold)
                .foregroundStyle(theme.secondaryText)
                .accessibilityHidden(true)
            if item.role == .assistant { Spacer(minLength: 0) }
        }
        .frame(maxWidth: 560, alignment: item.role == .human ? .trailing : .leading)
    }

    @BighelpThemeReader private var theme: BighelpTheme

    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.chatMessageContinuesGroup) private var continuesGroup
    @Environment(\.chatMessageContinuesPrevious) private var continuesPrevious
}

private struct PendingMidSessionStatusView: View {
    let behavior: MidSessionChatBehavior

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            BighelpThinkingOrb(scenario: .working, scale: .inline)
                .accessibilityHidden(true)
            Text(PendingMidSessionPresentation.label(for: behavior))
                .bighelpFont(.metadata, weight: .semibold)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: 560, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme: BighelpTheme

}

/// Message time, printed once under the last bubble of a run:
/// a muted caption with the day in bold, e.g. "**Today** 9:38 AM".
struct TimelineMetadataView: View {
    let metadata: TimelineMetadata

    var body: some View {
        if !continuesGroup, let timestamp = TimelineMetadataPresentation.timestampLabel(for: metadata) {
            Group {
                if let parts = displayParts {
                    Text("\(Text(parts.day).fontWeight(.semibold)) \(parts.time)")
                } else {
                    Text(timestamp)
                }
            }
            .bighelpMessageFont(.metadata)
            .foregroundStyle(theme.secondaryText)
            .accessibilityLabel("Sent \(timestamp)")
            .accessibilityIdentifier("timeline-message-timestamp")
        }
    }

    private var displayParts: (day: String, time: String)? {
        guard let timestamp = metadata.timestamp else { return nil }
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(timestamp) {
            day = String(localized: "Today")
        } else if calendar.isDateInYesterday(timestamp) {
            day = String(localized: "Yesterday")
        } else if calendar.isDate(timestamp, equalTo: .now, toGranularity: .year) {
            day = timestamp.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        } else {
            day = timestamp.formatted(date: .abbreviated, time: .omitted)
        }
        return (day, timestamp.formatted(date: .omitted, time: .shortened))
    }

    @BighelpThemeReader private var theme: BighelpTheme
    @Environment(\.chatMessageContinuesGroup) private var continuesGroup

}

struct PendingMessagePresentation: Equatable {
    /// The working indicator is a typing bubble on the incoming surface.
    static let showsContainer = true
    static let dotSize: CGFloat = 8
    static let restingDotOpacity = 0.4

    let visibleText: String
    let accessibilityLabel: String

    init(agentName: String, isGroup: Bool = false) {
        let normalizedName = agentName
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        if isGroup {
            visibleText = "Your agents are working…"
            accessibilityLabel = "Sending. Your agents are working."
        } else {
            // The default agent's name: "bighelp", or "Loopdy" on hosts set up before the rename.
            let isDefaultName = ["bighelp", "Loopdy"].contains { normalizedName.caseInsensitiveCompare($0) == .orderedSame }
            let name = normalizedName.isEmpty || isDefaultName
                ? "Your agent"
                : normalizedName
            visibleText = "\(name) is working…"
            accessibilityLabel = "Sending. \(name) is working."
        }
    }
}

/// Three dots in an incoming bubble while the agent works and has no text yet.
struct PendingMessageView: View {
    let agentName: String
    var isGroup = false

    var body: some View {
        let presentation = PendingMessagePresentation(
            agentName: agentName,
            isGroup: isGroup
        )
        HStack(alignment: .bottom, spacing: BighelpTokens.space8) {
            if isGroup {
                // Line up with the perched avatars of group-chat bubbles.
                Color.clear.frame(width: ChatMessageGrouping.perchedAvatarSize, height: 1)
            }
            typingDots
                .padding(.horizontal, BighelpV3MessagePresentation.horizontalContentPadding)
                .padding(.vertical, BighelpTokens.space12)
                .background(bubbleShape.fill(theme.incomingMessageBackground))
                .overlay {
                    if colorSchemeContrast == .increased {
                        bubbleShape.strokeBorder(theme.primaryText, lineWidth: 2)
                    }
                }
        }
        .padding(.vertical, BighelpTokens.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    /// The dots rise in turn on the shared loader clock, so every waiting bubble
    /// moves in step, and hold still (all lit) when loaders shouldn't move.
    private var typingDots: some View {
        let resting = PendingMessagePresentation.restingDotOpacity
        return BighelpLoaderClock(cadence: .smooth) { time in
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let lift = BighelpConnectionMotion.bounce(time, index: index)
                    Circle()
                        .fill(theme.secondaryText)
                        .frame(width: PendingMessagePresentation.dotSize, height: PendingMessagePresentation.dotSize)
                        .offset(y: -2 * lift)
                        .opacity(time.isStill ? 1 : resting + (1 - resting) * lift)
                }
            }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: BighelpV3MessagePresentation.bubbleRadius,
            bottomLeadingRadius: BighelpV3MessagePresentation.tailRadius,
            bottomTrailingRadius: BighelpV3MessagePresentation.bubbleRadius,
            topTrailingRadius: BighelpV3MessagePresentation.bubbleRadius,
            style: .continuous
        )
    }

    @BighelpThemeReader private var theme: BighelpTheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

}
