import SwiftUI

/// Voice mode's one status line: the step the agent is on right now, in plain
/// words ("Checking your calendars…"). Each step replaces the last, so it's never
/// a list, and it's only shown, never spoken.
struct VoiceStepLine: View {
    /// The chat's current step, or nil between steps and once the turn ends. Read
    /// here, not by the screen, so each new step redraws only this line.
    let step: () -> String?

    @State private var shown: String?
    @State private var shownAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme

    /// Quick steps would flicker past unread; each one stays this long.
    static let minimumDwell: TimeInterval = 1.2
    /// A short gap between two steps keeps the line instead of blinking.
    static let gapGrace: TimeInterval = 0.8

    var body: some View {
        let next = step()
        ZStack {
            // Holds one line's height, so the caption under it never jumps.
            Text(" ").bighelpFont(.label).hidden()
            if let shown {
                HStack(spacing: BighelpTokens.space8) {
                    BighelpThinkingOrb(scenario: .working, scale: .inline)
                        .accessibilityHidden(true)
                    Text(shown)
                        .bighelpFont(.label, weight: .medium)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .id(shown)
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
            }
        }
        .frame(maxWidth: 520)
        .clipped()
        .task(id: next) {
            let wait = Self.delay(showing: next, current: shown, shownFor: Date.now.timeIntervalSince(shownAt))
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, shown != next else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)) {
                shown = next
                shownAt = .now
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown ?? "")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityHidden(shown == nil)
        .accessibilityIdentifier("voice.step")
    }

    /// How long to wait before `next` replaces `current`: a step stays at least
    /// `minimumDwell`, and clearing waits out `gapGrace` in case the next step follows.
    static func delay(showing next: String?, current: String?, shownFor elapsed: TimeInterval) -> TimeInterval {
        guard next != current else { return 0 }
        let hold = current == nil ? 0 : max(0, minimumDwell - elapsed)
        return next == nil ? max(hold, gapGrace) : hold
    }
}
