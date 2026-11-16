import SwiftUI

/// What the open Dynamic Island shows when a chat has news: it needs the person, it finished or it
/// could not finish. The notification service opens the island for that update; a touch and hold
/// shows the same thing later. A chat that is only working keeps the plain rows.
struct BighelpIslandMoment: Equatable {
    enum Kind: Equatable { case needsYou, done, failed }

    /// The buttons under the words.
    enum Buttons: Equatable {
        /// Deny and Approve, for a command the island shows in full.
        case decide
        /// An approval the person reads in the app first.
        case review
        /// A question, answered in the chat.
        case answer
        /// A finished reply: Open chat and Reply.
        case reply
        case open
    }

    let row: BighelpActivitySession
    let kind: Kind
    let agentID: String
    let agentName: String
    /// The question, the command or the reply's first lines. Nil when the card may not show text.
    let text: String?
    /// The chat's title, shown when there is no text.
    let title: String
    let buttons: Buttons

    /// The most of a command the island shows whole, in three lines. The computer sends at most this much
    /// as a whole command; the island checks again, because a yes here is a yes to what is on screen.
    static let wholeCommandCharacters = 90

    init?(state: LoopdySessionActivityAttributes.ContentState, isStale: Bool, asOf: Date = .now,
          infos: [String: BighelpActivitySessionInfo], details: [String: BighelpActivityDetail]? = nil,
          cardKey: String? = nil, level: BighelpActivityDetailLevel = .current) {
        guard let row = BighelpActivitySession.shown(state).first else { return nil }
        let kind: Kind
        switch row.phase {
        case .waiting:
            // News that is two minutes old without a word from the computer is not news: the rows say Paused.
            guard !isStale, asOf.timeIntervalSince1970 < Double(row.timestamp) + 120 else { return nil }
            kind = .needsYou
        case .completed: kind = .done
        case .failed: kind = .failed
        default: return nil
        }
        var detail: BighelpActivityDetail?
        if level != .statusOnly {
            if let details { detail = details[row.id] } else { detail = row.openDetail(cardKey: cardKey) }
        }
        let words = level == .stepsAndText ? (kind == .needsYou ? detail?.question : detail?.preview) : nil
        let info = infos[row.id]
        self.row = row
        self.kind = kind
        agentID = info?.attributes.agentID ?? "agent"
        agentName = BighelpActivityText.personName(info?.attributes.agentName ?? "") ?? "Your bot"
        title = info?.title ?? "Chat"
        text = words
        switch (kind, detail?.ask) {
        case (.needsYou, .command?):
            buttons = (words?.count ?? .max) <= Self.wholeCommandCharacters ? .decide : .review
        case (.needsYou, .approval?): buttons = .review
        case (.needsYou, .question?): buttons = .answer
        case (.done, _): buttons = .reply
        default: buttons = .open
        }
    }

    var status: String {
        switch kind {
        case .needsYou: "Needs you"
        case .done: "Done"
        case .failed: "Didn't finish"
        }
    }

    var symbolName: String {
        switch kind {
        case .needsYou: "questionmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .needsYou: Color(uiColor: .systemOrange)
        case .done: Color(uiColor: .systemGreen)
        case .failed: Color(uiColor: .systemRed)
        }
    }

    var accessibilityLabel: String {
        [agentName, status, text ?? title].joined(separator: ". ")
    }
}

/// The island's top row for a chat with news: whose it is, and what happened.
struct BighelpIslandMomentSender: View {
    let moment: BighelpIslandMoment

    var body: some View {
        HStack(spacing: 8) {
            BighelpActivityAvatar(agentID: moment.agentID, name: moment.agentName, diameter: 28)
            Text(moment.agentName).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(moment.agentName)
    }
}

struct BighelpIslandMomentStatus: View {
    let moment: BighelpIslandMoment

    var body: some View {
        Label(moment.status, systemImage: moment.symbolName)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(moment.tint)
            .lineLimit(1)
    }
}

/// The words and the buttons under the island's top row. The island is always black, so the colors
/// are fixed: they are the same in light and dark.
struct BighelpIslandMomentBody: View {
    let moment: BighelpIslandMoment

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Link(destination: BighelpWidgetSnapshot.chatURL(moment.row.id)) {
                Text(moment.text ?? moment.title)
                    .font(moment.buttons == .decide ? .system(.footnote, design: .monospaced) : .callout)
                    .foregroundStyle(moment.text == nil ? Color.secondary : Color.white)
                    // A command is on screen whole or Approve isn't offered, so it gets the lines it needs.
                    .lineLimit(moment.buttons == .decide ? 3 : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this conversation")
            HStack(spacing: 8) { buttons }
        }
        // The island is about 160 points tall: text any larger than this pushes the buttons out of it.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    @ViewBuilder
    private var buttons: some View {
        switch moment.buttons {
        case .decide:
            #if os(iOS) && !targetEnvironment(macCatalyst)
            Button(intent: BighelpActivityDecisionIntent(rowID: moment.row.id, approves: false, command: moment.text ?? "")) { label("Deny", filled: false) }
                .buttonStyle(.plain)
            Button(intent: BighelpActivityDecisionIntent(rowID: moment.row.id, approves: true, command: moment.text ?? "")) { label("Approve", filled: true) }
                .buttonStyle(.plain)
            #else
            link("Review", filled: true)
            #endif
        case .review: link("Review", filled: true)
        case .answer: link("Answer", filled: true)
        case .reply:
            link("Open chat", filled: false)
            link("Reply", filled: true, reply: true)
        case .open: link("Open chat", filled: true)
        }
    }

    private func link(_ title: String, filled: Bool, reply: Bool = false) -> some View {
        Link(destination: BighelpWidgetSnapshot.chatURL(moment.row.id, reply: reply)) { label(title, filled: filled) }
            .buttonStyle(.plain)
    }

    private func label(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(filled ? Color.black : Color.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(filled ? AnyShapeStyle(moment.tint) : AnyShapeStyle(Color.white.opacity(0.17)), in: Capsule())
            .contentShape(Capsule())
    }
}
