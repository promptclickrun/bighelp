import SwiftUI
import UIKit

private struct ChatBubbleWidthLayout: Layout {
    let maximumWidthFraction: CGFloat
    let contentFitsWidth: Bool

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let availableWidth = proposal.width ?? ChatBubbleLayoutMetrics.maximumAbsoluteWidth
        let maximumWidth = ChatBubbleLayoutMetrics.maximumWidth(
            containerWidth: availableWidth,
            maximumWidthFraction: maximumWidthFraction
        )
        let resolvedWidth: CGFloat
        if contentFitsWidth {
            let ideal = subview.sizeThatFits(ProposedViewSize(
                width: nil,
                height: proposal.height
            ))
            resolvedWidth = ChatBubbleLayoutMetrics.resolvedWidth(
                idealWidth: ideal.width,
                containerWidth: availableWidth,
                maximumWidthFraction: maximumWidthFraction
            )
        } else {
            resolvedWidth = maximumWidth
        }
        let size = subview.sizeThatFits(ProposedViewSize(
            width: resolvedWidth,
            height: proposal.height
        ))
        return CGSize(
            width: contentFitsWidth ? min(size.width, resolvedWidth) : resolvedWidth,
            height: size.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

@MainActor
final class ChatMessageContentCache {
    final class Projection {
        let source: String
        /// The message a person's message answers, drawn above it instead of its quote line.
        let reply: ChatReplyQuote?
        let references: ReferenceDecodedMessage
        let document: MarkdownDocument
        let cardProjection: ChatCardMessageProjection
        let role: TimelineRole
        /// The first web link, for the preview under the message.
        private(set) lazy var linkPreviewURL: URL? = LinkPreviewCandidate.firstURL(in: document)

        let isStreaming: Bool

        init(_ source: String, role: TimelineRole, isStreaming: Bool = false) {
            self.source = source
            let reply = role == .human ? ChatReplyQuote.split(source) : nil
            self.reply = reply?.quote
            references = ReferenceCodec.decode(reply?.body ?? source)
            document = MarkdownDocument(references.prose)
            cardProjection = ChatCardMessageProjection(source: references.prose, role: role, isStreaming: isStreaming)
            self.role = role
            self.isStreaming = isStreaming
        }
    }

    private var current: Projection?

    func project(_ source: String, role: TimelineRole = .assistant, isStreaming: Bool = false) -> Projection {
        if let current, current.role == role, current.isStreaming == isStreaming,
           current.source.utf8.elementsEqual(source.utf8) {
            return current
        }
        let projection = Projection(source, role: role, isStreaming: isStreaming)
        current = projection
        return projection
    }
}

struct MessageBubble: View {
    let messageID: String
    let role: TimelineRole
    let speakerName: String
    let text: String
    let delivery: String?
    let isPendingSubmission: Bool
    let onFork: (() -> Void)?
    let contentReference: CanonicalContentReference?
    let metadata: TimelineMetadata?
    let reactionPresentation: NativeMessageReactionPresentation?
    let onReaction: ((String?) -> Void)?
    let mentionIdentities: [ChatMentionIdentity]
    /// Long-press › Reply: quotes this message in the composer.
    let onReply: (() -> Void)?
    /// Who "your previous message" is in a reply drawn above this message.
    let replyAgentName: String

    @State private var isSelectingText = false
    @State private var isCopied = false
    @State private var isReactionPickerPresented = false
    @State private var contentCache = ChatMessageContentCache()
    @State private var cardCopyContext = ChatCardCopyContext()
    @AppStorage(ChatLayoutPreferences.textSizeKey) private var chatTextSize: ChatTextSize = .standard
    @AppStorage(LinkPreviewPreferences.enabledKey) private var showsLinkPreviews = true

    init(
        messageID: String = "",
        role: TimelineRole,
        speakerName: String,
        text: String,
        delivery: String? = nil,
        isPendingSubmission: Bool = false,
        onFork: (() -> Void)? = nil,
        contentReference: CanonicalContentReference? = nil,
        metadata: TimelineMetadata? = nil,
        reactionPresentation: NativeMessageReactionPresentation? = nil,
        onReaction: ((String?) -> Void)? = nil,
        mentionIdentities: [ChatMentionIdentity] = [],
        onReply: (() -> Void)? = nil,
        replyAgentName: String = ""
    ) {
        self.messageID = messageID
        self.role = role
        self.speakerName = speakerName
        self.text = text
        self.delivery = delivery
        self.isPendingSubmission = isPendingSubmission
        self.onFork = onFork
        self.contentReference = contentReference
        self.metadata = metadata
        self.reactionPresentation = reactionPresentation
        self.onReaction = onReaction
        self.mentionIdentities = mentionIdentities
        self.onReply = onReply
        self.replyAgentName = replyAgentName
    }

    private var isStreaming: Bool {
        delivery?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Streaming") == .orderedSame
    }

    /// Written on the way to the answer: shown quieter, like thinking.
    private var isInterimReply: Bool { role == .assistant && metadata?.isInterimReply == true }

    /// A finished message's first web link. A reply still being written waits,
    /// so a half-typed link never loads.
    private func linkPreviewURL(_ projection: ChatMessageContentCache.Projection) -> URL? {
        guard showsLinkPreviews, !isInterimReply, !projection.cardProjection.hasRichContent,
              delivery?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Streaming") != .orderedSame else { return nil }
        return projection.linkPreviewURL
    }

    var body: some View {
        let projection = contentCache.project(text, role: role, isStreaming: isStreaming)
        let references = projection.references
        let document = projection.document
        let interaction = ChatBubbleInteraction(document: document, canFork: onFork != nil,
            canReact: canReact,
            canonicalSource: references.hasValidAppendix || references.failure != nil
                || projection.cardProjection.hasRichContent ? text : nil)
        let presentation = ChatMessagePresentation.resolve(role: role, delivery: delivery)
        VStack(alignment: role == .human ? .trailing : .leading,
               spacing: uiV3Enabled ? BighelpTokens.space4 : 0) {
            if let reply = projection.reply {
                ChatReplyQuoteView(quote: reply, agentName: replyAgentName, alignsTrailing: role == .human)
            }
            messageInteractionSurface(
                ChatBubbleWidthLayout(
                    maximumWidthFraction: uiV3Enabled
                        ? BighelpV3MessagePresentation.maximumWidthFraction(
                            role: role,
                            hasRichContent: projection.cardProjection.hasRichContent
                        )
                        : presentation.maximumWidthFraction,
                    contentFitsWidth: uiV3Enabled
                        ? !projection.cardProjection.hasRichContent
                        : presentation.contentFitsWidth
                ) {
                    messageContent(
                        cardProjection: projection.cardProjection,
                        document: document,
                        presentation: presentation,
                        interaction: interaction
                    )
                        .opacity(presentation.contentOpacity)
                },
                document: document,
                interaction: interaction
            )
            .overlay(alignment: role == .human ? .bottomTrailing : .bottomLeading) {
                if let reactionPresentation,
                   !reactionPresentation.reactions.isEmpty,
                   let onReaction {
                    NativeMessageReactionBar(
                        presentation: reactionPresentation,
                        onSelection: onReaction
                    )
                    .offset(
                        x: role == .human
                            ? -NativeMessageReactionLayoutMetrics.edgeInset
                            : NativeMessageReactionLayoutMetrics.edgeInset,
                        y: NativeMessageReactionLayoutMetrics.attachmentOverlap
                    )
                }
            }
            .padding(
                .bottom,
                hasVisibleReactions ? NativeMessageReactionLayoutMetrics.attachmentOverlap : 0
            )
            .overlay(alignment: .topTrailing) {
                if isCopied && !uiV3Enabled {
                    Label("Copied", systemImage: "checkmark")
                        .bighelpFont(.metadata, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, BighelpTokens.space8)
                        .padding(.vertical, BighelpTokens.space4)
                        .background(.regularMaterial, in: .capsule)
                        .padding(BighelpTokens.space8)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityIdentifier("chat.message.copied")
                }
            }
            .bighelpSheet(isPresented: $isSelectingText) {
                NativeTextSelectionSheet(
                    text: interaction.copyText
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
            }
            #if targetEnvironment(macCatalyst)
            // On the Mac reactions are a small choice, so they pop over the message.
            .popover(isPresented: $isReactionPickerPresented) {
                reactionPicker
                    .frame(width: 360, height: 380)
                    .presentationCompactAdaptation(.popover)
                    .bighelpPopoverDismissal(isPresented: $isReactionPickerPresented)
            }
            #else
            .bighelpSheet(isPresented: $isReactionPickerPresented) {
                reactionPicker
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            #endif
            if let previewURL = linkPreviewURL(projection) {
                LinkPreviewCard(url: previewURL)
                    .frame(maxWidth: YouTubeVideo(url: previewURL) == nil
                        ? BighelpV3MessagePresentation.linkPreviewMaximumWidth
                        : BighelpV3MessagePresentation.videoPreviewMaximumWidth)
            }
            if !references.references.isEmpty {
                ReferenceHistoryView(snapshots: references.references)
            }
            if let errorMessage = reactionPresentation?.errorMessage {
                Text(errorMessage)
                    .bighelpMessageFont(.metadata)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if uiV3Enabled, !isPendingSubmission, !isInterimReply {
                if let metadata {
                    TimelineMetadataView(metadata: metadata)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: uiV3Enabled ? .infinity : nil,
               alignment: role == .human ? .trailing : .leading)
    }

    private var reactionPicker: some View {
        NativeMessageReactionPicker(
            currentReaction: reactionPresentation?.reactions.first {
                $0.author == .user
            }?.emoji,
            onSelection: { emoji in
                isReactionPickerPresented = false
                onReaction?(emoji)
            }
        )
    }

    @ViewBuilder
    private func messageInteractionSurface<Content: View>(
        _ content: Content,
        document: MarkdownDocument,
        interaction: ChatBubbleInteraction
    ) -> some View {
        if ChatMessageInteractionPolicy.usesInlineNativeSelection(
            role: role,
            uiV3Enabled: uiV3Enabled
        ) {
            // Text hits remain owned by UITextView's native selection menu.
            // Padding and gaps need a separate full-message action surface.
            content
                .overlay {
                    // Match BighelpV3MessageSurface's sixteen-point padding.
                    // The center stays hit-transparent for native selection,
                    // links, and any interactive card inside the message.
                    VStack(spacing: 0) {
                        messagePaddingActions(interaction).frame(height: BighelpTokens.space16)
                        HStack(spacing: 0) {
                            messagePaddingActions(interaction).frame(width: BighelpTokens.space16)
                            Color.clear.allowsHitTesting(false)
                            messagePaddingActions(interaction).frame(width: BighelpTokens.space16)
                        }
                        messagePaddingActions(interaction).frame(height: BighelpTokens.space16)
                    }
                }
        } else {
            content
                .accessibilityLabel("\(speakerName): \(document.visiblePlainText)")
                .accessibilityHint("Links open in your chosen browser. \(BighelpPlatform.isMac ? "Right-click" : "Long press") shows message actions.")
                .accessibilityAction(named: copyActionLabel) {
                    copyMessage(interaction)
                }
                .accessibilityAction(named: "Reply") {
                    onReply?()
                }
                #if !targetEnvironment(macCatalyst)
                .accessibilityAction(named: "Select text") {
                    isSelectingText = true
                }
                #endif
                .accessibilityAction(named: "Fork from here") {
                    onFork?()
                }
                .contextMenu { messageActions(interaction) }
        }
    }

    @ViewBuilder
    private func messagePaddingActions(_ interaction: ChatBubbleInteraction) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .contextMenu { messageActions(interaction) }
    }

    @ViewBuilder
    private func messageActions(_ interaction: ChatBubbleInteraction) -> some View {
        if interaction.menuActions.contains(.react) {
            Button {
                isReactionPickerPresented = true
            } label: {
                Label("React", systemImage: "face.smiling")
            }
        }
        if let onReply {
            Button(action: onReply) {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
        }
        Button {
            copyMessage(interaction)
        } label: {
            Label(copyActionLabel, systemImage: "doc.on.doc")
        }
        // The Mac selects message text with the mouse; no separate sheet.
        if !BighelpPlatform.isMac {
            Button {
                isSelectingText = true
            } label: {
                Label("Select text", systemImage: "selection.pin.in.out")
            }
        }
        if let onFork {
            Button(action: onFork) {
                Label("Fork from here", systemImage: "arrow.triangle.branch")
            }
        }
    }

    @ViewBuilder
    private func messageContent(
        cardProjection: ChatCardMessageProjection,
        document: MarkdownDocument,
        presentation: ChatMessagePresentation,
        interaction: ChatBubbleInteraction
    ) -> some View {
        if role == .assistant, cardProjection.hasRichContent {
            if uiV3Enabled {
                mixedAssistantContent(cardProjection, interaction: interaction, proseLineSpacing: 5)
                    .modifier(BighelpV3MessageSurface(
                        role: role,
                        theme: theme,
                        increasedContrast: colorSchemeContrast == .increased
                    ))
            } else {
                switch presentation.chrome {
                case .accentBubble:
                    mixedAssistantContent(
                        cardProjection,
                        interaction: interaction,
                        proseLineSpacing: presentation.proseLineSpacing
                    )
                    .padding(.horizontal, BighelpTokens.space16)
                    .padding(.vertical, BighelpTokens.space12)
                    .bighelpSurface(.selected)
                case .openProse:
                    mixedAssistantContent(
                        cardProjection,
                        interaction: interaction,
                        proseLineSpacing: presentation.proseLineSpacing
                    )
                    .padding(.horizontal, BighelpTokens.space4)
                    .padding(.vertical, BighelpTokens.space4)
                }
            }
        } else if uiV3Enabled {
            // One text view for both looks: becoming interim restyles it in place.
            NativeInlineSelectableMarkdownTextView(
                document: document,
                speakerName: speakerName,
                proseLineSpacing: role == .human ? 2 : isInterimReply ? 4 : 5,
                primaryText: isInterimReply ? theme.secondaryText : nativePrimaryText,
                secondaryText: role == .human ? nativePrimaryText.opacity(0.82)
                    : isInterimReply ? theme.tertiaryText : theme.secondaryText,
                accent: role == .human ? nativePrimaryText : theme.action,
                codeBackground: role == .human
                    ? nativePrimaryText.opacity(0.14)
                    : theme.primaryText.opacity(0.07),
                openURL: openURL,
                theme: theme,
                copyActionLabel: copyActionLabel,
                onCopy: { copyMessage(interaction) },
                onSelect: { isSelectingText = true },
                onFork: onFork,
                onReact: canReact ? { isReactionPickerPresented = true } : nil,
                onReply: onReply,
                textScale: (isInterimReply ? ChatInterimReplyStyle.textScale : 1) * chatTextSize.scale,
                mentionIdentities: mentionIdentities
            )
            .modifier(BighelpV3MessageSurface(
                role: role,
                theme: theme,
                increasedContrast: colorSchemeContrast == .increased,
                isInterim: isInterimReply
            ))
        } else {
            switch presentation.chrome {
            case .accentBubble:
                MarkdownMessageView(
                    document: document,
                    proseLineSpacing: presentation.proseLineSpacing
                )
                    .foregroundStyle(isPendingSubmission ? theme.secondaryText : theme.primaryText)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, BighelpTokens.space16)
                    .padding(.vertical, BighelpTokens.space12)
                    .bighelpSurface(.selected)
            case .openProse where isInterimReply:
                MarkdownMessageView(
                    document: document,
                    proseLineSpacing: presentation.proseLineSpacing
                )
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.leading)
                    .modifier(ChatInterimReplyStyle(theme: theme))
            case .openProse:
                MarkdownMessageView(
                    document: document,
                    proseLineSpacing: presentation.proseLineSpacing
                )
                    .foregroundStyle(isPendingSubmission ? theme.secondaryText : theme.primaryText)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, BighelpTokens.space4)
                    .padding(.vertical, BighelpTokens.space4)
            }
        }
    }

    private func mixedAssistantContent(
        _ projection: ChatCardMessageProjection,
        interaction: ChatBubbleInteraction,
        proseLineSpacing: CGFloat
    ) -> some View {
        mixedAssistantSegments(projection, interaction: interaction, proseLineSpacing: proseLineSpacing)
            .modifier(ChatCardCopyContextReader(context: cardCopyContext))
    }

    private func mixedAssistantSegments(
        _ projection: ChatCardMessageProjection,
        interaction: ChatBubbleInteraction,
        proseLineSpacing: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            ForEach(Array(projection.segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let document):
                    if uiV3Enabled {
                        NativeInlineSelectableMarkdownTextView(
                            document: document,
                            speakerName: speakerName,
                            proseLineSpacing: proseLineSpacing,
                            primaryText: isPendingSubmission
                                ? theme.secondaryText
                                : theme.primaryText,
                            secondaryText: theme.secondaryText,
                            accent: theme.action,
                            codeBackground: theme.primaryText.opacity(0.07),
                            openURL: openURL,
                            theme: theme,
                            copyActionLabel: copyActionLabel,
                            onCopy: { copyMessage(interaction) },
                            onSelect: { isSelectingText = true },
                            onFork: onFork,
                            onReact: canReact ? { isReactionPickerPresented = true } : nil,
                            onReply: onReply,
                            mentionIdentities: mentionIdentities
                        )
                    } else {
                        MarkdownMessageView(document: document, proseLineSpacing: proseLineSpacing)
                            .foregroundStyle(isPendingSubmission ? theme.secondaryText : theme.primaryText)
                            .multilineTextAlignment(.leading)
                    }
                case .card(let envelope):
                    switch envelope {
                    case .legacy(let card):
                        GenerativeUICardView(card: card, messageID: messageID)
                            .cardImageCopy(GenerativeUICardView(card: card, messageID: messageID))
                    case .card(let card):
                        BighelpCardView(card: card)
                            .cardImageCopy(BighelpCardView(card: card))
                    }
                case .table(let table):
                    ChatMarkdownTableView(table: table,
                                          textColor: isPendingSubmission ? theme.secondaryText : theme.primaryText)
                case .rule:
                    ChatMarkdownRuleView()
                case .pendingCard(let kind):
                    ChatPendingCardView(kind: kind)
                case .unavailableCard:
                    Label("This card couldn't be shown.", systemImage: "rectangle.on.rectangle.slash")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("chat.card.unavailable")
                }
            }
        }
    }

    private var canReact: Bool {
        ChatMessageInteractionPolicy.canReact(
            role: role,
            presentation: reactionPresentation,
            hasMutationHandler: onReaction != nil
        )
    }

    private var hasVisibleReactions: Bool {
        reactionPresentation?.reactions.isEmpty == false && onReaction != nil
    }

    private var nativePrimaryText: Color {
        if role == .human {
            return isPendingSubmission
                ? theme.outgoingMessageForeground.opacity(0.7)
                : theme.outgoingMessageForeground
        }
        return isPendingSubmission ? theme.secondaryText : theme.primaryText
    }

    private var copyActionLabel: String {
        contentReference == nil ? "Copy to clipboard" : "Copy preview"
    }

    /// A message with cards copies its words and a picture of each card, in
    /// order, instead of the cards' code; any other message copies its text.
    private func copyMessage(_ interaction: ChatBubbleInteraction) {
        let cards = contentCache.project(text, role: role, isStreaming: isStreaming).cardProjection
        guard cards.segments.contains(where: { if case .card = $0 { true } else { false } }) else {
            copy(interaction.copyText)
            return
        }
        let context = cardCopyContext
        let parts = ChatMessageCopy.parts(cards) { envelope in
            switch envelope {
            case .legacy(let card):
                context.png(GenerativeUICardView(card: card, messageID: messageID), background: theme.canvas)
            case .card(let card):
                context.png(BighelpCardView(card: card), background: theme.canvas)
            }
        }
        UIPasteboard.general.setItems(ChatMessageCopy.items(parts))
        confirmCopied()
    }

    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        confirmCopied()
    }

    private func confirmCopied() {
        BighelpHaptics.success()
        if uiV3Enabled {
            // The native menu path has no visible badge; confirm for VoiceOver too.
            UIAccessibility.post(notification: .announcement, argument: "Copied")
        }
        withAnimation(.easeInOut(duration: BighelpTokens.stateDuration)) {
            isCopied = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeInOut(duration: BighelpTokens.stateDuration)) {
                isCopied = false
            }
        }
    }

    @BighelpThemeReader private var theme: BighelpTheme

    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.openURL) private var openURL
}
