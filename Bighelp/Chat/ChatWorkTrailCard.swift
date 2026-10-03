import SwiftUI

/// A folder of tool calls as one quiet activity line. While the agent works
/// on it, the line shimmers with what it's doing now ("Reading notes.md… · 2
/// steps") and the calls so far are listed underneath; once the agent moves
/// on, it says what it did ("Read 2 files, ran tests · 3 steps") and folds
/// away. In the chat each step is its own recycled row
/// (`rendersExpandedEvents: false`); elsewhere they're drawn here.
struct ChatWorkTrailCard: View {
    let turn: ChatActivityTurn
    let rendersExpandedEvents: Bool
    /// The agent is still working on this folder: it's the turn's newest work.
    let isLive: Bool
    /// What the live turn is waiting on the person for, if anything.
    let waiting: ChatActivityWaiting?
    let onDisclosureChange: () -> Void

    @Environment(\.chatActivityDisclosureStore) private var inheritedDisclosures
    @State private var localDisclosures = ChatActivityDisclosureStore()
    private var disclosures: ChatActivityDisclosureStore { inheritedDisclosures ?? localDisclosures }
    private var isExpanded: Bool { disclosures.isExpanded(turn, isLive: isLive) }

    init(
        turn: ChatActivityTurn,
        rendersExpandedEvents: Bool = true,
        isLive: Bool = false,
        waiting: ChatActivityWaiting? = nil,
        onDisclosureChange: @escaping () -> Void = {}
    ) {
        self.turn = turn
        self.rendersExpandedEvents = rendersExpandedEvents
        self.isLive = isLive
        self.waiting = waiting
        self.onDisclosureChange = onDisclosureChange
    }

    var body: some View {
        let disclosures = disclosures
        let isLive = isLive
        VStack(alignment: .leading, spacing: 0) {
            BighelpActivityRow(
                phase: ChatActivityPresentation.trailPhase(for: turn.events, waiting: waiting, isLive: isLive),
                stepCount: ChatActivityPresentation.stepCount(of: turn.events),
                detailsBelow: true,
                isExpanded: Binding(get: { disclosures.isExpanded(turn, isLive: isLive) },
                                    set: { disclosures.setExpanded($0, for: turn) }),
                onDisclosureChange: onDisclosureChange,
                accessibilityIdentifier: "chat.work-trail.\(turn.id)"
            )
            if isExpanded, rendersExpandedEvents {
                ForEach(turn.events) { event in
                    ChatActivityRow(event: event, onDisclosureChange: onDisclosureChange)
                }
                .modifier(ChatToolDetailStyle())
            }
        }
        .environment(\.chatActivityDisclosureStore, disclosures)
    }
}

enum ChatActivityDisclosureAccessibility {
    static func value(isExpanded: Bool) -> String {
        isExpanded ? "Expanded" : "Collapsed"
    }
}
