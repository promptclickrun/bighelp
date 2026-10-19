import CoreGraphics
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct ChatReactionBarTests {
    @Test func barOffersTheSixCommonReactionsWithNoneChosen() {
        let bar = ChatReactionBarProjection(selectedEmoji: nil)
        #expect(bar.choices.map(\.emoji) == ["❤️", "👍", "👎", "😂", "🎉", "🤔"])
        #expect(bar.choices.allSatisfy { !$0.isSelected })
        #expect(bar.choices.first?.accessibilityLabel == "React with heart")
        #expect(bar.choices.first?.accessibilityIdentifier == "chat.reaction-bar.heart")
        #expect(bar.choices[1].accessibilityIdentifier == "chat.reaction-bar.thumbs-up")
    }

    @Test func thePersonsReactionIsHighlightedAndAnAgentsIsNot() {
        let presentation = NativeMessageReactionPresentation(
            rowID: 7,
            reactions: [
                NativeMessageReaction(emoji: "❤️", author: .agent, occurredAt: nil, isSeen: nil),
                NativeMessageReaction(emoji: "😂", author: .user, occurredAt: nil, isSeen: nil),
            ],
            availability: .available, isUpdating: false, errorMessage: nil
        )
        let bar = ChatReactionBarProjection(presentation: presentation)
        #expect(bar.selectedEmoji == "😂")
        #expect(bar.choices.filter(\.isSelected).map(\.emoji) == ["😂"])

        let agentOnly = NativeMessageReactionPresentation(
            rowID: 7,
            reactions: [NativeMessageReaction(emoji: "❤️", author: .agent, occurredAt: nil, isSeen: nil)],
            availability: .available, isUpdating: false, errorMessage: nil
        )
        #expect(ChatReactionBarProjection(presentation: agentOnly).selectedEmoji == nil)
    }

    @Test func aHeartWithoutItsEmojiStyleMarkStillMatches() {
        let bar = ChatReactionBarProjection(selectedEmoji: "\u{2764}")
        #expect(bar.choices.count == 6)
        #expect(bar.choices.first?.isSelected == true)
        #expect(bar.selection(afterTapping: "❤️") == nil)
    }

    @Test func anotherEmojiShowsHighlightedAfterTheCommonSix() {
        let bar = ChatReactionBarProjection(selectedEmoji: "🦊")
        #expect(bar.choices.count == 7)
        #expect(bar.choices.last == .init(emoji: "🦊", name: "🦊", isSelected: true))
        #expect(bar.choices.filter(\.isSelected).count == 1)
    }

    @Test func textThatIsNotOneEmojiIsNeverShownAsChosen() {
        #expect(ChatReactionBarProjection(selectedEmoji: "ok").selectedEmoji == nil)
        #expect(ChatReactionBarProjection(selectedEmoji: "ok").choices.count == 6)
    }

    @Test func tappingTheChosenReactionTakesItAwayAndAnotherReplacesIt() {
        let bar = ChatReactionBarProjection(selectedEmoji: "👍")
        #expect(bar.selection(afterTapping: "👍") == nil)
        #expect(bar.selection(afterTapping: "🎉") == "🎉")
        #expect(ChatReactionBarProjection(selectedEmoji: nil).selection(afterTapping: "👍") == "👍")
    }

    @Test func barSitsOverTheMessageOnItsSideAndStaysOnScreen() {
        let bounds = CGRect(x: 0, y: 59, width: 393, height: 759)
        let size = CGSize(width: 316, height: 52)
        let reply = CGRect(x: 16, y: 400, width: 120, height: 60)
        let left = ChatReactionBarMetrics.frame(barSize: size, over: reply, alignsTrailing: false, within: bounds)
        #expect(left.minX == 16)
        #expect(left.maxY == reply.minY - ChatReactionBarMetrics.gap)

        let sent = CGRect(x: 300, y: 400, width: 77, height: 44)
        let right = ChatReactionBarMetrics.frame(barSize: size, over: sent, alignsTrailing: true, within: bounds)
        #expect(right.maxX == 377)

        let wide = CGRect(x: 0, y: 400, width: 393, height: 44)
        let clamped = ChatReactionBarMetrics.frame(barSize: size, over: wide, alignsTrailing: true, within: bounds)
        #expect(clamped.maxX == bounds.maxX - ChatReactionBarMetrics.edgeMargin)

        let high = CGRect(x: 16, y: 70, width: 120, height: 60)
        let top = ChatReactionBarMetrics.frame(barSize: size, over: high, alignsTrailing: false, within: bounds)
        #expect(top.minY == bounds.minY)
    }

    @Test func liftedPillStaysOverTheMessageForTheSystemToFitOnScreen() {
        let size = ChatReactionBarMetrics.barSize(choiceCount: 6, slot: 44)
        #expect(size == CGSize(width: 7 * 44 + 2 * ChatReactionBarMetrics.inset, height: 44 + 2 * ChatReactionBarMetrics.inset))
        let high = CGRect(x: 16, y: 20, width: 120, height: 60)
        let lifted = ChatReactionBarMetrics.liftedFrame(barSize: size, over: high, alignsTrailing: false, minX: 0, maxX: 393)
        #expect(lifted.maxY == high.minY - ChatReactionBarMetrics.gap, "Never pushed down onto the message")
        #expect(lifted.minX == 16)
    }

    @Test func slotsShrinkToFitANarrowScreenButKeepATouchableSize() {
        #expect(ChatReactionBarMetrics.slot(choiceCount: 6, availableWidth: 393) == 44)
        let narrow = ChatReactionBarMetrics.slot(choiceCount: 7, availableWidth: 320)
        #expect(narrow < 44 && narrow >= ChatReactionBarMetrics.minimumSlot)
        #expect(8 * narrow + 2 * ChatReactionBarMetrics.inset <= 320 - 2 * ChatReactionBarMetrics.edgeMargin)
        #expect(ChatReactionBarMetrics.slot(choiceCount: 7, availableWidth: 200) == ChatReactionBarMetrics.minimumSlot)
    }

    @Test func menuRowOffersEachReactionByNameWithTheChosenOneOn() {
        let palette = ChatMessageMenuDriver.reactionPalette(ChatMessageReactionActions(
            selectedEmoji: "👍", onSelect: { _ in }, onMore: {}))
        #expect(palette.options.contains(.displayAsPalette))
        let actions = palette.children.compactMap { $0 as? UIAction }
        #expect(actions.map(\.title) == [
            "React with heart", "React with thumbs up", "React with thumbs down",
            "React with laughing", "React with party", "React with thinking", "More reactions",
        ])
        #expect(actions.filter { $0.state == .on }.map(\.title) == ["React with thumbs up"])
    }
}
