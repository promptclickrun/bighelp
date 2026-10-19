import SwiftUI

enum ChatBubbleMenuAction: Equatable, Sendable {
    case copy
    case selectText
    case forkFromHere
}

struct ChatBubbleInteraction: Equatable, Sendable {
    let copyText: String
    let menuActions: [ChatBubbleMenuAction]
    /// Holding the message floats the reaction bar over it, apart from the menu.
    let offersReactions: Bool

    init(markdown: String, canFork: Bool, canReact: Bool = false) {
        self.init(document: MarkdownDocument(markdown), canFork: canFork, canReact: canReact)
    }

    init(document: MarkdownDocument, canFork: Bool, canReact: Bool = false,
         canonicalSource: String? = nil) {
        copyText = canonicalSource ?? document.visiblePlainText
        menuActions = [.copy, .selectText] + (canFork ? [.forkFromHere] : [])
        offersReactions = canReact
    }
}

enum ChatMessageInteractionPolicy {
    static func usesInlineNativeSelection(role: TimelineRole, uiV3Enabled: Bool) -> Bool {
        switch role {
        case .human, .assistant:
            uiV3Enabled
        }
    }

    static func canReact(
        role: TimelineRole,
        presentation: NativeMessageReactionPresentation?,
        hasMutationHandler: Bool
    ) -> Bool {
        switch role {
        case .human, .assistant:
            presentation?.availability.allowsMutation == true
                && presentation?.isUpdating == false
                && hasMutationHandler
        }
    }
}

enum ChatMessageActionMetrics {
    static let symbolSize: CGFloat = 16
    static let spacing: CGFloat = 0
    static var hitTarget: CGFloat { BighelpTokens.hitTarget }
}

enum ChatBubbleLayoutMetrics {
    /// Bubbles follow the lane (ChatCanvasLayout.regularLaneMaximumWidth), so a
    /// landscape iPad gets wide replies; this only stops runaway widths.
    static let maximumAbsoluteWidth: CGFloat = 1_000
    static let maximumWidthFraction: CGFloat = 0.82

    static func maximumWidth(
        containerWidth: CGFloat,
        maximumWidthFraction: CGFloat = maximumWidthFraction
    ) -> CGFloat {
        min(maximumAbsoluteWidth, max(0, containerWidth) * maximumWidthFraction)
    }

    static func resolvedWidth(
        idealWidth: CGFloat,
        containerWidth: CGFloat,
        maximumWidthFraction: CGFloat
    ) -> CGFloat {
        min(
            max(0, idealWidth),
            maximumWidth(
                containerWidth: containerWidth,
                maximumWidthFraction: maximumWidthFraction
            )
        )
    }
}

enum ChatMessageAlignment: Equatable, Sendable {
    case leading
    case trailing
}

enum ChatMessageChrome: Equatable, Sendable {
    case accentBubble
    case openProse
}

enum ChatMessageTextTone: Equatable, Sendable {
    case primary
    case interim
}

struct ChatMessagePresentation: Equatable, Sendable {
    let alignment: ChatMessageAlignment
    let chrome: ChatMessageChrome
    let textTone: ChatMessageTextTone
    let maximumWidthFraction: CGFloat
    let contentFitsWidth: Bool

    var proseLineSpacing: CGFloat {
        chrome == .openProse ? 4 : 0
    }

    var contentOpacity: Double {
        textTone == .interim ? 0.68 : 1
    }

    static func resolve(role: TimelineRole, delivery: String?) -> ChatMessagePresentation {
        switch role {
        case .human:
            ChatMessagePresentation(
                alignment: .trailing,
                chrome: .accentBubble,
                textTone: .primary,
                maximumWidthFraction: 0.78,
                contentFitsWidth: true
            )
        case .assistant:
            ChatMessagePresentation(
                alignment: .leading,
                chrome: .openProse,
                textTone: delivery?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("Streaming") == .orderedSame ? .interim : .primary,
                maximumWidthFraction: 0.94,
                contentFitsWidth: false
            )
        }
    }
}
