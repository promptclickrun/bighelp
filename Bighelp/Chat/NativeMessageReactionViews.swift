import SwiftUI

enum NativeMessageReactionLayoutMetrics {
    static let visualHeight: CGFloat = 26
    static let attachmentOverlap: CGFloat = 13
    static let edgeInset: CGFloat = 8
    static var hitPadding: CGFloat { (BighelpTokens.hitTarget - visualHeight) / 2 }
}

struct NativeMessageReactionBar: View {
    static let maximumVisibleReactions = 5

    let presentation: NativeMessageReactionPresentation
    let onSelection: (String?) -> Void

    var body: some View {
        if !presentation.reactions.isEmpty {
            HStack(spacing: BighelpTokens.space4) {
                ForEach(Array(visibleReactions.enumerated()), id: \.offset) { _, reaction in
                    Button {
                        onSelection(reaction.author == .user ? nil : reaction.emoji)
                    } label: {
                        Text(reaction.emoji)
                            .font(.bighelp(.body))
                            .frame(
                                minWidth: NativeMessageReactionLayoutMetrics.visualHeight,
                                minHeight: NativeMessageReactionLayoutMetrics.visualHeight
                            )
                            .padding(.horizontal, 2)
                            .background(
                                reaction.author == .user
                                    ? theme.action.opacity(0.14)
                                    : Color(uiColor: .secondarySystemBackground),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().stroke(
                                    Color(uiColor: .separator),
                                    lineWidth: BighelpTokens.hairline
                                )
                            }
                            // Preserve a 44-point interaction target without
                            // turning the visible badge into a 44-point pill.
                            .padding(NativeMessageReactionLayoutMetrics.hitPadding)
                    }
                    .buttonStyle(.plain)
                    .padding(-NativeMessageReactionLayoutMetrics.hitPadding)
                    .disabled(!presentation.availability.allowsMutation || presentation.isUpdating)
                    .accessibilityLabel(accessibilityLabel(for: reaction))
                    .accessibilityHint(
                        reaction.author == .user
                            ? "Removes your reaction"
                            : "Adds this reaction"
                    )
                }
                if hiddenReactionCount > 0 {
                    Text("+\(hiddenReactionCount)")
                        .bighelpMessageFont(.metadata, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                        .frame(minHeight: NativeMessageReactionLayoutMetrics.visualHeight)
                        .padding(.horizontal, BighelpTokens.space4)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityLabel("\(hiddenReactionCount) more reactions")
                }
            }
            .accessibilityIdentifier(presentation.rowID.map { "chat.message-reactions.row-\($0)" }
                ?? "chat.message-reactions.unavailable")
        }
    }

    private var visibleReactions: ArraySlice<NativeMessageReaction> {
        presentation.reactions.prefix(Self.maximumVisibleReactions)
    }

    private var hiddenReactionCount: Int {
        max(0, presentation.reactions.count - Self.maximumVisibleReactions)
    }

    private func accessibilityLabel(for reaction: NativeMessageReaction) -> String {
        switch reaction.author {
        case .user: "Your reaction, \(reaction.emoji)"
        case .agent: "Agent reaction, \(reaction.emoji)"
        }
    }

    @BighelpThemeReader private var theme

}

enum NativeMessageReactionEmoji {
    static func normalized(_ source: String) -> String? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 1, let character = value.first else { return nil }
        let scalars = character.unicodeScalars
        let isEmoji = scalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || scalar.value == 0xFE0F
                || scalar.value == 0x20E3
                || scalar.value >= 0x1F000
        }
        return isEmoji ? value : nil
    }
}

struct NativeMessageReactionPicker: View {
    let currentReaction: String?
    let onSelection: (String?) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            VStack(spacing: BighelpTokens.space16) {
                Text("Choose a reaction")
                    .bighelpFont(.sectionTitle, weight: .semibold)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: BighelpTokens.hitTarget), spacing: BighelpTokens.space8)],
                    spacing: BighelpTokens.space8
                ) {
                    ForEach(ChatReactionBarProjection(selectedEmoji: currentReaction).choices) { choice in
                        Button(choice.emoji) { select(choice.emoji) }
                            .font(.bighelp(.title2))
                            .frame(minWidth: BighelpTokens.hitTarget,
                                   minHeight: BighelpTokens.hitTarget)
                            .buttonStyle(.bordered)
                            .tint(choice.isSelected ? theme.action : nil)
                            .accessibilityLabel(choice.accessibilityLabel)
                            .accessibilityAddTraits(choice.isSelected ? .isSelected : [])
                    }
                }
                TextField("Any emoji", text: $draft)
                    .font(.bighelp(.largeTitle))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { submitDraft() }
                    .accessibilityIdentifier("chat.reaction-picker.any-emoji")
                Button("Add reaction") { submitDraft() }
                    .bighelpProminentButtonStyle()
                    .disabled(NativeMessageReactionEmoji.normalized(draft) == nil)
                if currentReaction != nil {
                    Button("Remove reaction", role: .destructive) { select(nil) }
                }
                Spacer(minLength: 0)
            }
            .padding(BighelpTokens.space16)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { isFocused = true }
        }
        .accessibilityIdentifier("chat.reaction-picker")
    }

    private func submitDraft() {
        guard let emoji = NativeMessageReactionEmoji.normalized(draft) else { return }
        select(emoji)
    }

    private func select(_ emoji: String?) {
        onSelection(emoji)
        dismiss()
    }
}
