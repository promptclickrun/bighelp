import SwiftUI

/// "Make a space", under Today's grid: what the person wants to see, which bot builds it, and a
/// few examples. Submitting hands the words to the shell, which leaves "Make me a space for Today:
/// <text>" in a new chat with that bot. Nothing is sent from here: the person taps Send.
struct TodayCreateBox: View {
    /// The bots on the computer in use.
    let bots: [SpacesBot]
    /// The bot picked until the person picks another (the primary bot).
    let primaryBotID: String?
    let onCreate: (_ agentID: String, _ text: String) -> Void

    @State private var text = ""
    @State private var pickedBotID: String?
    @FocusState private var isFocused: Bool
    @BighelpThemeReader private var theme

    private static let examples: [(id: String, text: LocalizedStringResource)] = [
        ("commute", "Time my commute"),
        ("workouts", "Track my workouts"),
        ("garden", "Watch my garden"),
    ]

    private var bot: SpacesBot? {
        bots.first { $0.id == pickedBotID } ?? bots.first { $0.id == primaryBotID } ?? bots.first
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { bot != nil && !trimmed.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BighelpTokens.space8) {
                    title
                    Spacer(minLength: BighelpTokens.space8)
                    botChip
                }
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    title
                    botChip
                }
            }
            HStack(spacing: BighelpTokens.space8) {
                field
                goButton
            }
            examples
            Text("Nothing runs until you add it.")
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bighelpSurface(.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.create")
    }

    private var title: some View {
        Text("Make a space")
            .font(.bighelp(.headline))
            .foregroundStyle(theme.primaryText)
    }

    @ViewBuilder
    private var botChip: some View {
        if let bot {
            Menu {
                ForEach(bots, id: \.id) { choice in
                    Button {
                        pickedBotID = choice.id
                    } label: {
                        if choice.id == bot.id {
                            Label { Text(verbatim: choice.name) } icon: { Image(systemName: "checkmark") }
                        } else {
                            Text(verbatim: choice.name)
                        }
                    }
                    .accessibilityIdentifier("today.create.bot.\(choice.id)")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: bot.name).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, BighelpTokens.space12)
                .frame(minHeight: BighelpTokens.scaled(34))
                .background(theme.canvas, in: .capsule)
                .overlay { Capsule().strokeBorder(theme.border) }
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Bot"))
            .accessibilityValue(Text(verbatim: bot.name))
            .accessibilityIdentifier("today.create.bot")
        }
    }

    private var field: some View {
        TextField("What do you want to see?", text: $text)
            .font(.bighelp(.body))
            .foregroundStyle(theme.primaryText)
            .focused($isFocused)
            .submitLabel(.go)
            .onSubmit(create)
            .padding(.horizontal, BighelpTokens.space12)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            .background(theme.canvas, in: .rect(cornerRadius: BighelpTokens.inputCornerRadius, style: .continuous))
            .accessibilityIdentifier("today.create.field")
    }

    private var goButton: some View {
        Button(action: create) {
            Image(systemName: "arrow.up")
                .font(.bighelp(.body, weight: .semibold))
                .foregroundStyle(theme.actionForeground)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .background(theme.action.opacity(canCreate ? 1 : 0.4), in: .circle)
                .contentShape(.circle)
        }
        .bighelpPlainButtonStyle(.circle)
        .disabled(!canCreate)
        .accessibilityLabel(Text("Make space"))
        .accessibilityIdentifier("today.create.go")
    }

    private var examples: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(Self.examples, id: \.id) { example in
                    SpacesChip(title: Text(example.text), identifier: "today.create.example.\(example.id)") {
                        text = String(localized: example.text)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Examples"))
    }

    private func create() {
        guard let bot, canCreate else { return }
        onCreate(bot.id, trimmed)
        text = ""
        isFocused = false
    }
}
