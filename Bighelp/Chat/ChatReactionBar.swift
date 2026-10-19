import SwiftUI
import UIKit

/// The quick reactions over a held message, like Messages' tapback: the six
/// common ones, then the person's own reaction when it is another emoji.
struct ChatReactionBarProjection: Equatable, Sendable {
    struct Reaction: Equatable, Sendable {
        let emoji: String
        let name: String
    }

    struct Choice: Equatable, Sendable, Identifiable {
        let emoji: String
        let name: String
        let isSelected: Bool
        var id: String { emoji }
        var accessibilityLabel: String { "React with \(name)" }
        var accessibilityIdentifier: String {
            "chat.reaction-bar.\(name.replacingOccurrences(of: " ", with: "-"))"
        }
    }

    static let common: [Reaction] = [
        Reaction(emoji: "❤️", name: "heart"),
        Reaction(emoji: "👍", name: "thumbs up"),
        Reaction(emoji: "👎", name: "thumbs down"),
        Reaction(emoji: "😂", name: "laughing"),
        Reaction(emoji: "🎉", name: "party"),
        Reaction(emoji: "🤔", name: "thinking"),
    ]

    let choices: [Choice]
    /// The person's reaction as Hermes has it; agents' reactions never count.
    let selectedEmoji: String?

    init(selectedEmoji: String?) {
        // Hermes' copy is the truth, so a heart saved without its emoji style
        // mark still counts; anything longer than one character never does.
        let trimmed = selectedEmoji?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = trimmed.flatMap { $0.count == 1 ? $0 : nil }
        var choices = Self.common.map { reaction in
            Choice(emoji: reaction.emoji, name: reaction.name,
                   isSelected: selected.map { Self.sameEmoji($0, reaction.emoji) } ?? false)
        }
        if let selected, !choices.contains(where: \.isSelected) {
            choices.append(Choice(emoji: selected, name: selected, isSelected: true))
        }
        self.choices = choices
        self.selectedEmoji = selected
    }

    init(presentation: NativeMessageReactionPresentation?) {
        self.init(selectedEmoji: presentation?.reactions.first { $0.author == .user }?.emoji)
    }

    /// What to send for a tap: the person's own reaction again takes it away.
    func selection(afterTapping emoji: String) -> String? {
        guard let selectedEmoji, Self.sameEmoji(selectedEmoji, emoji) else { return emoji }
        return nil
    }

    /// Hermes may keep a heart with or without its emoji style mark (U+FE0F).
    static func sameEmoji(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.filter { $0.value != 0xFE0F }
            .elementsEqual(rhs.unicodeScalars.filter { $0.value != 0xFE0F })
    }
}

enum ChatReactionBarMetrics {
    static let preferredSlot: CGFloat = 44
    static let minimumSlot: CGFloat = 36
    static let inset: CGFloat = 4
    /// Space between the bar and the message it sits over.
    static let gap: CGFloat = 8
    static let edgeMargin: CGFloat = 12

    /// The slot that fits every choice and the "+" in the width there is.
    static func slot(choiceCount: Int, availableWidth: CGFloat) -> CGFloat {
        let slots = CGFloat(choiceCount + 1)
        let fitting = (availableWidth - 2 * edgeMargin - 2 * inset) / slots
        return max(minimumSlot, min(preferredSlot, fitting.rounded(.down)))
    }

    static func barSize(choiceCount: Int, slot: CGFloat) -> CGSize {
        CGSize(width: CGFloat(choiceCount + 1) * slot + 2 * inset, height: slot + 2 * inset)
    }

    /// The bar's frame: over the message, on its side of the chat, kept inside
    /// the visible area.
    static func frame(barSize: CGSize, over bubble: CGRect, alignsTrailing: Bool, within bounds: CGRect) -> CGRect {
        var frame = liftedFrame(barSize: barSize, over: bubble, alignsTrailing: alignsTrailing,
                                minX: bounds.minX, maxX: bounds.maxX)
        frame.origin.y = max(frame.minY, bounds.minY)
        return frame
    }

    /// The bar's place in the lifted message: never pushed down onto the
    /// message, since the system moves the whole lifted copy onto the screen.
    static func liftedFrame(barSize: CGSize, over bubble: CGRect, alignsTrailing: Bool,
                            minX: CGFloat, maxX: CGFloat) -> CGRect {
        var x = alignsTrailing ? bubble.maxX - barSize.width : bubble.minX
        x = min(max(x, minX + edgeMargin), maxX - edgeMargin - barSize.width)
        return CGRect(x: x, y: bubble.minY - gap - barSize.height, width: barSize.width, height: barSize.height)
    }
}

struct ChatReactionBarView: View {
    let projection: ChatReactionBarProjection
    let theme: BighelpTheme
    let slot: CGFloat
    let onSelect: (String?) -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(projection.choices) { choice in
                Button {
                    onSelect(projection.selection(afterTapping: choice.emoji))
                } label: {
                    Text(choice.emoji)
                        .font(.system(size: slot * 0.6))
                        .frame(width: slot, height: slot)
                        .background {
                            if choice.isSelected {
                                Circle().fill(theme.action.opacity(0.24))
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(ChatReactionBarButtonStyle())
                .accessibilityLabel(choice.accessibilityLabel)
                .accessibilityAddTraits(choice.isSelected ? .isSelected : [])
                .accessibilityHint(choice.isSelected ? "Removes your reaction" : "")
                .accessibilityIdentifier(choice.accessibilityIdentifier)
            }
            Button(action: onMore) {
                Image(systemName: "plus")
                    .font(.system(size: slot * 0.4, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: slot * 0.8, height: slot * 0.8)
                    .background(Circle().fill(theme.primaryText.opacity(0.08)))
                    .frame(width: slot, height: slot)
                    .contentShape(Circle())
            }
            .buttonStyle(ChatReactionBarButtonStyle())
            .accessibilityLabel("More reactions")
            .accessibilityIdentifier("chat.reaction-bar.more")
        }
        .padding(ChatReactionBarMetrics.inset)
        // A solid pill, like Messages' tapback: nothing under it shows through.
        .background(Capsule().fill(theme.raisedSurface))
        .overlay(Capsule().strokeBorder(theme.separator.opacity(0.6), lineWidth: BighelpTokens.hairline))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.reaction-bar")
    }
}

private struct ChatReactionBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.25 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.4), value: configuration.isPressed)
    }
}

/// Emoji drawn as pictures, for menus that show a row of icons (Mac, Vision Pro, VoiceOver).
@MainActor
enum ChatReactionEmojiImage {
    private static var cache: [String: UIImage] = [:]

    static func image(_ emoji: String) -> UIImage {
        if let cached = cache[emoji] { return cached }
        let text = NSAttributedString(string: emoji, attributes: [.font: UIFont.systemFont(ofSize: 24)])
        let size = text.size()
        let image = UIGraphicsImageRenderer(size: CGSize(width: ceil(size.width), height: ceil(size.height)))
            .image { _ in text.draw(at: .zero) }
            .withRenderingMode(.alwaysOriginal)
        if cache.count > 64 { cache.removeAll() }
        cache[emoji] = image
        return image
    }
}
