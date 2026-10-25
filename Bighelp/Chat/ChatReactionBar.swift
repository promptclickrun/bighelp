import SwiftUI
import UIKit

/// The quick reactions in a held message's menu: the six
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

/// Emoji drawn as pictures for the native menu's reaction palette.
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
