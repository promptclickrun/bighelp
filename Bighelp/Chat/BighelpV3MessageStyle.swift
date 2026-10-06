import SwiftUI

/// iMessage-like presentation metrics kept separate from model and transport state.
/// Rich cards receive a wider lane while ordinary prose remains conversational on iPad.
enum BighelpV3MessagePresentation {
    // Replies use nearly the full lane on phone and iPad alike.
    static let outgoingMaximumWidthFraction: CGFloat = 0.84
    static let incomingMaximumWidthFraction: CGFloat = 0.92
    static let richContentMaximumWidthFraction: CGFloat = 0.94
    static let horizontalContentPadding: CGFloat = 14
    static let bubbleRadius: CGFloat = 20
    /// Link previews stay card-sized on iPad's wider lane.
    static let linkPreviewMaximumWidth: CGFloat = 300
    /// Videos get a little more room to watch in place.
    static let videoPreviewMaximumWidth: CGFloat = 360
    static let tailRadius: CGFloat = 6

    static func maximumWidthFraction(role: TimelineRole, hasRichContent: Bool) -> CGFloat {
        if hasRichContent { return richContentMaximumWidthFraction }
        return role == .human ? outgoingMaximumWidthFraction : incomingMaximumWidthFraction
    }
}

/// Message-local styling: incoming bubbles use the theme's warm neutral and
/// outgoing bubbles the accent, so the theme reads on both sides of a chat.
/// True when the next visible transcript row is another message from the same
/// sender. Like iMessage, only the last bubble in a run keeps its tail.
private struct ChatMessageContinuesGroupKey: EnvironmentKey {
    static let defaultValue = false
}

/// True when the previous visible transcript row is a message from the same
/// sender, so group chats print the sender's name once per run.
private struct ChatMessageContinuesPreviousKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatMessageContinuesGroup: Bool {
        get { self[ChatMessageContinuesGroupKey.self] }
        set { self[ChatMessageContinuesGroupKey.self] = newValue }
    }

    var chatMessageContinuesPrevious: Bool {
        get { self[ChatMessageContinuesPreviousKey.self] }
        set { self[ChatMessageContinuesPreviousKey.self] = newValue }
    }
}

enum ChatMessageGrouping {
    /// Spacing below a bubble followed by the same sender vs. a sender change.
    static let groupedSpacing: CGFloat = 2
    static let senderChangeSpacing: CGFloat = 12
    /// Group chats perch the sender's avatar beside the last bubble of a run.
    static let perchedAvatarSize: CGFloat = 30

    static func continuesGroup(_ current: ChatTranscriptEntry, next: ChatTranscriptEntry?) -> Bool {
        guard case .message(let item) = current, let next, case .message(let following) = next else { return false }
        // Two different agents in a group chat are separate runs.
        return item.role == following.role && item.sender.id == following.sender.id
    }
}

struct BighelpV3MessageSurface: ViewModifier {
    @Environment(\.chatMessageContinuesGroup) private var continuesGroup
    @AppStorage(ChatLayoutPreferences.densityKey) private var density: ChatDensity = .comfortable
    let role: TimelineRole
    let theme: BighelpTheme
    let increasedContrast: Bool
    /// Written on the way to the answer: no bubble, a thin line on the left.
    /// Same view structure either way, so switching keeps the text view.
    var isInterim = false

    func body(content: Content) -> some View {
        content
            .padding(.leading, isInterim ? BighelpTokens.space12 : 0)
            .padding(.horizontal, isInterim ? 0 : density.bubbleHorizontalPadding)
            .padding(.vertical, isInterim ? BighelpTokens.space4 : density.bubbleVerticalPadding)
            .background(shape.fill(isInterim ? Color.clear : fillColor))
            .overlay {
                if increasedContrast, !isInterim {
                    shape.strokeBorder(theme.primaryText, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(theme.secondaryText.opacity(0.28))
                    .frame(width: ChatInterimReplyStyle.ruleWidth)
                    .padding(.vertical, BighelpTokens.space4)
                    .opacity(isInterim ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.leading, isInterim ? BighelpTokens.space8 : 0)
    }

    var fillColor: Color {
        if role == .human { return theme.outgoingMessageBackground }
        return theme.incomingMessageBackground
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: BighelpV3MessagePresentation.bubbleRadius,
            bottomLeadingRadius: role == .assistant && !continuesGroup
                ? BighelpV3MessagePresentation.tailRadius
                : BighelpV3MessagePresentation.bubbleRadius,
            bottomTrailingRadius: role == .human && !continuesGroup
                ? BighelpV3MessagePresentation.tailRadius
                : BighelpV3MessagePresentation.bubbleRadius,
            topTrailingRadius: BighelpV3MessagePresentation.bubbleRadius,
            style: .continuous
        )
    }
}

/// Chat follows the chosen typeface, with native system type as the default.
private struct BighelpMessageFontModifier: ViewModifier {
    let role: BighelpFontRole
    let weight: Font.Weight?
    let italic: Bool

    func body(content: Content) -> some View {
        content.bighelpFont(role, weight: weight, italic: italic)
    }
}

extension View {
    func bighelpMessageFont(
        _ role: BighelpFontRole,
        weight: Font.Weight? = nil,
        italic: Bool = false
    ) -> some View {
        modifier(BighelpMessageFontModifier(role: role, weight: weight, italic: italic))
    }
}

/// A compact audio presentation using the existing attachment-preview route.
/// Playback and saving remain owned by that preview, not a second audio player.
struct BighelpV3MessageAudioView: View {
    let attachment: ChatAttachment
    let theme: BighelpTheme
    let onPreview: () -> Void

    var body: some View {
        Button(action: onPreview) {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: "play.fill")
                    .bighelpFont(.body, weight: .semibold)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .background(theme.action.opacity(0.12), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(attachment.fileName)
                        .bighelpFont(.label, weight: .medium)
                        .lineLimit(1)
                    Text("Audio preview")
                        .bighelpFont(.metadata)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)
            .padding(BighelpTokens.space8)
            .frame(width: 280)
            .background(theme.incomingMessageBackground, in: .rect(cornerRadius: BighelpTokens.radius20))
        }
        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius20))
        .accessibilityLabel("Preview \(attachment.fileName)")
        .accessibilityHint("Opens the existing audio preview with playback and save options")
    }
}
