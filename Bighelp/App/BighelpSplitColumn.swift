import Observation
import SwiftUI

/// The iPhone Duo open: the list (the Bots view, the Chats view or Work) as a column
/// beside the page, with its own bar. What it opens is pushed on the app's one navigation stack, as
/// everywhere else, so it shows beside the list and every rule about the open chat still holds.
@MainActor
@Observable
final class BighelpSplitColumn {
    private(set) var content: AnyView?
    /// The places down the list's leading edge: they switch the list, so they stay with it.
    private(set) var rail: AnyView = AnyView(EmptyView())
    /// The list is put away, so the page takes the whole screen. The rail stays to bring it back.
    private(set) var isCollapsed = false
    @ObservationIgnored private var key: String?

    var isShown: Bool { content != nil }

    /// Shows the list `key` names, under `rail`. The same key keeps the list that's there, scrolled
    /// where it was.
    func show(_ key: String, rail: AnyView, _ view: () -> AnyView) {
        guard self.key != key else { return }
        self.key = key
        self.rail = rail
        content = view()
    }

    func hide() {
        guard content != nil else { return }
        key = nil
        content = nil
    }

    func setCollapsed(_ collapsed: Bool) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed
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
                HStack(spacing: 0) {
                    // The places that switch the list, down its leading edge where the list is.
                    column.rail
                    // Put away, the list leaves the hierarchy: the bridge into its own UIKit stack
                    // keeps a merely-hidden one in the accessibility tree, where it would answer
                    // VoiceOver and take taps the page has the room for.
                    if !column.isCollapsed {
                        // Its own stack, beside the app's: the list's bar and buttons, apart from the
                        // page's.
                        NavigationStack { list }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipped()
                    }
                }
                // Up to the fold, so nothing sits across it; put away, only the rail's column is left.
                .frame(width: column.isCollapsed ? HomePlacesRail.width : screen.splitColumnWidth,
                       alignment: .leading)
                .clipped()
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
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: column.isCollapsed)
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
            BighelpLifterMark(size: 44)
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
