import SwiftUI
import UIKit

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

    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var inputHeight: CGFloat = 60

    var body: some View {
        NavigationStack {
            VStack(spacing: BighelpTokens.space16) {
                Text("Choose a reaction")
                    .bighelpFont(.sectionTitle, weight: .semibold)
                NativeReactionEmojiInput(onSelection: { select($0) })
                    .frame(height: inputHeight)
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
        }
        .accessibilityIdentifier("chat.reaction-picker")
        .presentationDetents([.height(inputHeight + (currentReaction == nil ? 150 : 190))])
    }

    private func select(_ emoji: String?) {
        onSelection(emoji)
        dismiss()
    }
}

/// Public text-input APIs give the reaction picker Apple's searchable emoji
/// keyboard, including the person's recent emoji and skin-tone choices.
struct NativeReactionEmojiInput: UIViewRepresentable {
    let onSelection: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeUIView(context: Context) -> UITextField {
        let field = EmojiTextField()
        field.delegate = context.coordinator
        field.placeholder = "Choose an emoji"
        field.font = .bighelp(.largeTitle)
        field.adjustsFontForContentSizeCategory = true
        field.textAlignment = .center
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.accessibilityLabel = "Choose an emoji"
        field.accessibilityIdentifier = "chat.reaction-picker.any-emoji"
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.onSelection = onSelection
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onSelection: (String) -> Void
        private var didSelect = false

        init(onSelection: @escaping (String) -> Void) { self.onSelection = onSelection }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            guard !didSelect else { return false }
            let candidate = ((textField.text ?? "") as NSString).replacingCharacters(in: range, with: string)
            if let emoji = NativeMessageReactionEmoji.normalized(candidate) {
                didSelect = true
                onSelection(emoji)
            }
            return false
        }
    }

    final class EmojiTextField: UITextField {
        override var textInputMode: UITextInputMode? {
            #if os(iOS) && !targetEnvironment(macCatalyst)
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
            #else
            super.textInputMode
            #endif
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.window != nil, !self.isFirstResponder else { return }
                self.becomeFirstResponder()
            }
        }
    }
}
