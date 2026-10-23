import Observation
import SwiftUI

/// The iPhone Duo open: the list (Bots mode's home, the chat list, or Code's home) as a column
/// beside the page, with its own bar. What it opens is pushed on the app's one navigation stack, as
/// everywhere else, so it shows beside the list and every rule about the open chat still holds.
@MainActor
@Observable
final class BighelpSplitColumn {
    private(set) var content: AnyView?
    @ObservationIgnored private var key: String?

    var isShown: Bool { content != nil }

    /// Shows the list `key` names. The same key keeps the list that's there, scrolled where it was.
    func show(_ key: String, _ view: () -> AnyView) {
        guard self.key != key else { return }
        self.key = key
        content = view()
    }

    func hide() {
        guard content != nil else { return }
        key = nil
        content = nil
    }
}

extension EnvironmentValues {
    @Entry var bighelpSplitColumn: BighelpSplitColumn? = nil
}

/// Lays the list beside the app's navigation stack while the shell shows one.
struct BighelpSplitColumnHost: ViewModifier {
    let column: BighelpSplitColumn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bighelpScreen) private var screen
    @BighelpThemeReader private var theme

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            if let list = column.content {
                // Its own stack, beside the app's: the list's bar and buttons, apart from the page's.
                NavigationStack { list }
                    // Up to the fold, so nothing sits across it.
                    .frame(width: screen.splitColumnWidth)
                    .transition(.move(edge: .leading))
                Rectangle()
                    .fill(theme.border)
                    .frame(width: BighelpTokens.hairline)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            content
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: column.isShown)
        .environment(\.bighelpSplitColumn, column)
    }
}

/// Draws the shell's list again each time it changes, so the column follows the same stores and
/// settings as the rest of the app instead of a copy made when it opened. It sits outside the shell,
/// so it takes the shell's look itself (typeface, tint, ink) from the theme as it is now.
struct BighelpLiveColumn<Content: View>: View {
    let content: () -> Content

    var body: some View {
        content().bighelpThemePresentation(theme)
    }

    @BighelpThemeReader private var theme
}

/// The page beside the list before anything is open in it.
struct BighelpSplitPlaceholder: View {
    let message: String

    var body: some View {
        VStack(spacing: BighelpTokens.space16) {
            BighelpNoodleMark(size: 44)
            Text(message)
                .bighelpFont(.body)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(BighelpTokens.space24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("split.placeholder")
    }

    @BighelpThemeReader private var theme
}
