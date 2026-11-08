import CoreGraphics
import Testing
@testable import Bighelp

@Suite
struct IMessageChatPresentationTests {
    /// Tapbacks sit on the time line under the message (`ChatReactionBarUITests`), small but easy to hit.
    @Test func reactionBadgesStayCompact() {
        #expect(NativeMessageReactionLayoutMetrics.visualHeight < BighelpTokens.hitTarget)
        #expect(NativeMessageReactionLayoutMetrics.visualHeight >= 20)
    }

    @Test func proseBubblesUseConversationalWidths() {
        #expect(
            BighelpV3MessagePresentation.maximumWidthFraction(
                role: .human,
                hasRichContent: false
            ) == 0.84
        )
        #expect(
            BighelpV3MessagePresentation.maximumWidthFraction(
                role: .assistant,
                hasRichContent: false
            ) == 0.92
        )
    }

    @Test func richCardsRetainTheWiderChatCanvas() {
        #expect(
            BighelpV3MessagePresentation.maximumWidthFraction(
                role: .assistant,
                hasRichContent: true
            ) == 0.94
        )
    }

    @Test func bubbleGeometryKeepsOnlyTheSpeakerSideTight() {
        #expect(BighelpV3MessagePresentation.bubbleRadius > BighelpV3MessagePresentation.tailRadius)
        #expect(BighelpV3MessagePresentation.tailRadius >= 6)
    }

    @Test func iPadMessageWidthRemainsReadable() {
        let outgoing = ChatBubbleLayoutMetrics.maximumWidth(
            containerWidth: 1_024,
            maximumWidthFraction: BighelpV3MessagePresentation.outgoingMaximumWidthFraction
        )
        let incoming = ChatBubbleLayoutMetrics.maximumWidth(
            containerWidth: 1_024,
            maximumWidthFraction: BighelpV3MessagePresentation.incomingMaximumWidthFraction
        )
        let rich = ChatBubbleLayoutMetrics.maximumWidth(
            containerWidth: 1_024,
            maximumWidthFraction: BighelpV3MessagePresentation.richContentMaximumWidthFraction
        )

        #expect(outgoing <= ChatBubbleLayoutMetrics.maximumAbsoluteWidth)
        #expect(incoming <= ChatBubbleLayoutMetrics.maximumAbsoluteWidth)
        #expect(rich <= ChatBubbleLayoutMetrics.maximumAbsoluteWidth)
        #expect(outgoing <= incoming)
        #expect(incoming <= rich)
    }
}
