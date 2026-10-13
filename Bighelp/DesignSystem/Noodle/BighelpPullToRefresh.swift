import SwiftUI
import UIKit

extension View {
    /// `.refreshable` with the Noodle: the system still runs the pull and holds the list
    /// open while `action` runs, but the kit's pull follows your finger (its frames track
    /// the pull distance), then its loader plays until the refresh ends. Where the pull
    /// can't be read (before iOS 18, and on the Mac), it's the system spinner.
    func bighelpRefreshable(_ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modifier(BighelpPullToRefresh(action: action))
    }
}

enum BighelpPullToRefreshMetrics {
    /// The pull distance that finishes the kit's pull (and about where the system lets go).
    static let fullPull: CGFloat = 90
    static let markSize: CGFloat = 30

    /// The system spinner is hidden only where the Noodle can stand in for it.
    static var drawsNoodle: Bool {
        guard !BighelpPlatform.isMac else { return false }
        if #available(iOS 18.0, visionOS 2.0, *) { return true }
        return false
    }

    /// Called once at launch, before any list makes its refresh control.
    @MainActor static func hideSystemSpinner() {
        guard drawsNoodle else { return }
        UIRefreshControl.appearance().tintColor = .clear
    }

    /// How far into the kit's pull (0...1) a pull of `distance` points is.
    static func progress(_ distance: CGFloat) -> Double {
        Double(min(max(distance / fullPull, 0), 1))
    }
}

/// Whether a refresh runs, set from inside the `@Sendable` refresh action.
@MainActor
@Observable
private final class BighelpRefreshState {
    var isRefreshing = false

    func run(_ action: @MainActor @Sendable () async -> Void) async {
        isRefreshing = true
        await action()
        isRefreshing = false
    }
}

private struct BighelpPullToRefresh: ViewModifier {
    let action: @MainActor @Sendable () async -> Void
    @State private var state = BighelpRefreshState()
    @State private var pull: CGFloat = 0
    @State private var topInset: CGFloat = 0
    /// Where the content's top rests when nothing refreshes. While a refresh runs, the
    /// system holds the content lower by raising the inset, so the gap starts here.
    @State private var restingInset: CGFloat = 0

    func body(content: Content) -> some View {
        let state = state
        let refreshing = content.refreshable { [state, action] in await state.run(action) }
        if BighelpPullToRefreshMetrics.drawsNoodle, #available(iOS 18.0, visionOS 2.0, *) {
            refreshing
                .onScrollGeometryChange(for: [CGFloat].self) { geometry in
                    [-(geometry.contentOffset.y + geometry.contentInsets.top), geometry.contentInsets.top]
                } action: { _, reading in
                    pull = max(reading[0], 0)
                    topInset = reading[1]
                    if !state.isRefreshing, pull == 0 { restingInset = topInset }
                }
                .overlay(alignment: .top) { indicator }
        } else {
            refreshing
        }
    }

    @ViewBuilder
    private var indicator: some View {
        let size = BighelpPullToRefreshMetrics.markSize
        let gap = max(topInset - restingInset, 0) + pull
        if pull > 4 || state.isRefreshing {
            BighelpNoodleView(motion: state.isRefreshing ? .loader : .pull, size: size,
                              playback: state.isRefreshing ? .automatic : .progress(BighelpPullToRefreshMetrics.progress(pull)),
                              accessibilityLabel: state.isRefreshing ? "Refreshing" : nil)
                // Centered in the gap the pull opens above the content. The insets are measured
                // from the list's top edge, so the indicator is placed from there too.
                .offset(y: restingInset + max(gap, size + 16) / 2 - size / 2)
                .ignoresSafeArea(.container, edges: .top)
                .opacity(state.isRefreshing ? 1 : min(1, Double(gap / 30)))
                .allowsHitTesting(false)
        }
    }
}
