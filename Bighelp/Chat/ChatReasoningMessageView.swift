import SwiftUI

@MainActor
extension ChatReasoningMessage {
    var phase: BighelpActivityPhase { ChatActivityPresentation.thinkingPhase(for: events) }

    /// "Reasoning…" while the agent thinks, then "Thought for 12s" from its recorded time.
    var title: String {
        phase == .thinking ? String(localized: "Reasoning…") : BighelpActivitySummary.label(for: phase)
    }

    /// Every thought the agent shared, each its own paragraph. Nil when it shared none
    /// (some models' thinking is saved blank).
    var text: String? { ChatActivityPresentation.thinkingNote(for: events) }

    /// How much of a thought shows while the agent is still thinking.
    static let liveExcerptLength = 320
    /// A finished message shows this many lines before Show more.
    static let foldedLineCount = 6

    /// The end of the thinking so far, which is what's new: from a line's start when one is
    /// near, else a word's, so it never opens in the middle of either.
    static func newestWords(of text: String) -> String {
        guard text.count > liveExcerptLength else { return text }
        let tail = text.suffix(liveExcerptLength)
        let half = tail.index(tail.startIndex, offsetBy: liveExcerptLength / 2)
        let start = tail[..<half].firstIndex(where: \.isNewline)
            ?? tail.firstIndex(where: \.isWhitespace) ?? tail.startIndex
        return "…" + tail[start...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A turn's reasoning as its own message (#943), above the turn's work. It's outlined, never
/// filled, so it doesn't read as the answer. While the agent thinks it says "Reasoning…" over
/// the newest words; once it's done, "Thought for 12s" over all of them, cut at six lines (Show
/// more). With Settings › Chat › Keep reasoning open off, finished reasoning is one line. A tap
/// on the heading opens or closes it, and the reader's choice holds.
struct ChatReasoningMessageView: View {
    let message: ChatReasoningMessage
    let onDisclosureChange: () -> Void

    @Environment(\.chatActivityDisclosureStore) private var disclosures
    @Environment(\.bighelpActivityLoaderFocus) private var loaderFocus
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(ChatReasoningPlacement.staysOpenKey) private var staysOpen = ChatReasoningPlacement.staysOpenByDefault
    @State private var localExpanded: Bool?
    @State private var localShowsAll = false
    @BighelpThemeReader private var theme
    @BighelpLoaderMotionReader private var motion
    @BighelpLoaderScaled(relativeTo: .footnote) private var glyphSide: CGFloat = BighelpActivityMetrics.stepGlyphSide

    private var isExpanded: Bool {
        let choice = disclosures.map { $0.reasoningChoice(message.events) } ?? localExpanded
        return choice ?? (message.isRunning || staysOpen)
    }

    /// Show more's own ID in the store, beside the folds'.
    private var showsAllID: String { "\(message.id):all" }
    private var showsAll: Bool { disclosures?.isWorkExpanded(showsAllID) ?? localShowsAll }

    /// The chat plays one loader at a time; elsewhere a running message plays its own.
    private var playsLoader: Bool { message.isRunning && (loaderFocus?.allows(message.id) ?? true) }

    var body: some View {
        let text = message.text
        let showsWords = text != nil && isExpanded
        // Show more's own touch height already spaces it from the outline.
        let endsWithButton = text.map { showsAll || isLong($0) } == true
        VStack(alignment: .leading, spacing: 0) {
            heading(opens: text != nil)
            if let text, showsWords { words(text) }
        }
        .padding(.horizontal, showsWords ? BighelpTokens.space12 : BighelpTokens.space4)
        .padding(.bottom, showsWords ? (endsWithButton ? BighelpTokens.space4 : BighelpTokens.space12) : 0)
        .overlay {
            if showsWords {
                RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func heading(opens: Bool) -> some View {
        Button {
            guard opens else { return }
            onDisclosureChange()
            let next = !isExpanded
            withAnimation(motion.moves ? BighelpLoaderCurve.site.animation(duration: BighelpTokens.transitionDuration)
                                       : .easeOut(duration: BighelpTokens.stateDuration)) {
                if let disclosures { disclosures.setExpanded(next, reasoning: message.events) }
                else { localExpanded = next }
            }
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                Group {
                    if playsLoader {
                        BighelpNoodleView(motion: .thinking, size: glyphSide)
                    } else {
                        BighelpActivityGlyphView(glyph: BighelpActivitySummary.glyph(for: message.phase), side: glyphSide)
                            .foregroundStyle(message.phase == .failed ? theme.danger : theme.tertiaryText)
                    }
                }
                .frame(width: glyphSide, height: glyphSide)
                .accessibilityHidden(true)
                Text(message.title)
                    .monospacedDigit()
                    .lineLimit(1)
                    .bighelpShimmer(isActive: playsLoader)
                if opens {
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.caption2, weight: .bold))
                        .foregroundStyle(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .font(.bighelp(.footnote, weight: .semibold))
            .foregroundStyle(message.phase == .failed ? theme.danger : theme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(BighelpActivityHeaderPressStyle())
        .accessibilityLabel(message.title)
        .accessibilityValue(opens ? ChatActivityDisclosureAccessibility.value(isExpanded: isExpanded) : "")
        .accessibilityHint(opens ? (isExpanded ? "Hides the thinking." : "Shows the thinking.") : "")
        // With no words to open it's a line of status, not a button.
        .accessibilityRemoveTraits(opens ? [] : .isButton)
        .accessibilityAddTraits(opens ? [] : .isStaticText)
        .accessibilityIdentifier("chat.\(message.id)")
    }

    @ViewBuilder
    private func words(_ text: String) -> some View {
        // While it thinks, the newest words are the news; Show more brings all of them.
        let shown = message.isRunning && !showsAll ? ChatReasoningMessage.newestWords(of: text) : text
        Text(BighelpActivitySummary.note(shown))
            .font(.bighelp(.footnote))
            .foregroundStyle(theme.secondaryText)
            .lineSpacing(3)
            .lineLimit(showsAll ? nil : ChatReasoningMessage.foldedLineCount)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("chat.\(message.id).words")
        if showsAll || isLong(text) {
            Button(showsAll ? "Show less" : "Show more") {
                onDisclosureChange()
                let next = !showsAll
                if let disclosures { disclosures.setWorkExpanded(next, id: showsAllID) } else { localShowsAll = next }
            }
            .font(.bighelp(.caption, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
            .frame(minHeight: minimumHeight)
            .contentShape(.rect)
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier("chat.\(message.id).show-more")
        }
    }

    /// More than the folded lines hold, by the same estimate the timeline sizes rows with.
    private func isLong(_ text: String) -> Bool {
        let columns: CGFloat = horizontalSizeClass == .regular ? 80 : 40
        return text.count > ChatReasoningMessage.liveExcerptLength
            || ChatCanvasTranscriptProjection.wrappedLineCount(text, columns: columns)
                > CGFloat(ChatReasoningMessage.foldedLineCount)
    }

    /// Touch needs a full target; the Mac's pointer keeps the stack compact.
    private var minimumHeight: CGFloat {
        BighelpPlatform.isMac ? BighelpTokens.scaled(32) : BighelpTokens.hitTarget
    }
}
