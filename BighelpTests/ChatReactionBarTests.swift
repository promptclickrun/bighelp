import CoreGraphics
import Testing
import UIKit
import SwiftUI
@testable import Bighelp

@MainActor
struct ChatReactionBarTests {
    @Test func moreReactionsStaysVisibleBeyondTheSixQuickChoices() throws {
        let driver = ChatMessageMenuDriver()
        driver.actions = ChatMessageMenuActions(
            copyActionLabel: "Copy to clipboard", onCopy: {}, onSelect: {}, onFork: {}, onReply: {},
            reactions: ChatMessageReactionActions(selectedEmoji: "🦊", onSelect: { _ in }, onMore: {}))
        let menu = try #require(driver.menu())
        let rows = menu.children.compactMap { $0 as? UIAction }
        #expect(rows.contains { $0.title == "More reactions" }, "A seventh palette item is clipped by UIKit")
        #expect(rows.contains { $0.title == "React with 🦊" && $0.state == .on })
    }

    @Test func moreReactionsStartsWithTheSystemEmojiKeyboard() async throws {
        var selected: [String?] = []
        let host = UIHostingController(rootView: NativeMessageReactionPicker(currentReaction: nil, onSelection: { selected.append($0) }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func textField(in view: UIView) -> UITextField? {
            if let field = view as? UITextField { return field }
            return view.subviews.lazy.compactMap { textField(in: $0) }.first
        }
        let field = try #require(textField(in: host.view))
        #expect(field.textInputMode?.primaryLanguage == "emoji")
        let range = NSRange(location: 0, length: 0)
        #expect(field.delegate?.textField?(field, shouldChangeCharactersIn: range, replacementString: "hello") == false)
        #expect(selected.isEmpty)
        #expect(field.delegate?.textField?(field, shouldChangeCharactersIn: range, replacementString: "👩🏽‍💻") == false)
        #expect(selected == ["👩🏽‍💻"], "A single emoji selection reacts immediately, including joined skin-tone emoji")
        _ = field.delegate?.textField?(field, shouldChangeCharactersIn: range, replacementString: "😀")
        #expect(selected.count == 1, "A second tap while the picker closes cannot send twice")
    }

    @Test func reactionsAndActionsShareTheSystemMenuLayout() {
        let driver = ChatMessageMenuDriver()
        driver.actions = ChatMessageMenuActions(
            copyActionLabel: "Copy to clipboard", onCopy: {}, onSelect: {}, onFork: {}, onReply: {},
            reactions: ChatMessageReactionActions(selectedEmoji: nil, onSelect: { _ in }, onMore: {}))
        let menu = driver.menu()
        let palette = menu?.children.first as? UIMenu
        #expect(palette?.options.contains(.displayAsPalette) == true,
                "UIKit must reserve space for reactions alongside its actions, including for screen-height messages")
    }

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

    @Test func menuRowOffersEachReactionByNameWithTheChosenOneOn() {
        let palette = ChatMessageMenuDriver.reactionPalette(ChatMessageReactionActions(
            selectedEmoji: "👍", onSelect: { _ in }, onMore: {}))
        #expect(palette.options.contains(.displayAsPalette))
        let actions = palette.children.compactMap { $0 as? UIAction }
        #expect(actions.map(\.title) == [
            "React with heart", "React with thumbs up", "React with thumbs down",
            "React with laughing", "React with party", "React with thinking",
        ])
        #expect(actions.filter { $0.state == .on }.map(\.title) == ["React with thumbs up"])
    }
}
