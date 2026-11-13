import SwiftUI

/// One of the home's three places as the bar, the ornament, the Duo's strip and the sidebar show it.
struct HomeTabItem: Identifiable, Equatable {
    let id: HomeTab
    let title: String
    let systemImage: String
    let selectedSystemImage: String
    /// Something there the person hasn't seen (Today).
    var showsDot = false

    var accessibilityIdentifier: String { "home.tab.\(id.rawValue)" }

    func symbol(selected: Bool) -> String { selected ? selectedSystemImage : systemImage }

    /// The dot shows only on a place you're not on.
    func showsDot(selected: Bool) -> Bool { showsDot && !selected }

    /// The three places in order. The first is named after the view the app opens on.
    static func standard(view: HomeConversationsView, todayHasNew: Bool = false) -> [HomeTabItem] {
        [
            view == .bots
                ? HomeTabItem(id: .conversations, title: view.title, systemImage: "bubble.left.and.bubble.right",
                              selectedSystemImage: "bubble.left.and.bubble.right.fill")
                : HomeTabItem(id: .conversations, title: view.title, systemImage: "bubble.left",
                              selectedSystemImage: "bubble.left.fill"),
            HomeTabItem(id: .today, title: String(localized: "Today"), systemImage: "sun.max",
                        selectedSystemImage: "sun.max.fill", showsDot: todayHasNew),
            HomeTabItem(id: .work, title: String(localized: "Work"), systemImage: "hammer",
                        selectedSystemImage: "hammer.fill"),
        ]
    }
}

/// The home's bottom bar on iPhone and iPad: the three places in a glass capsule, and the round
/// New chat button beside it. Shown at the roots only; a pushed chat has Back instead.
struct HomeTabBar: View {
    @Binding var selection: HomeTab
    let items: [HomeTabItem]
    let onNewChat: () -> Void
    /// Points the bar drops into the home indicator's area (`homeIndicatorSink(forBottomInset:)`).
    var homeIndicatorSink: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var tabChanges = 0
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 22
    @BighelpThemeReader private var theme

    static let newChatIdentifier = "home.new-chat"
    static let newChatVisibleLabel = "New chat"
    static let newChatAccessibilityLabel = String(localized: "New chat")

    /// Like the system tab bar, the bar sits low, just above the home indicator, instead of a full
    /// safe-area inset above it. Clamped so a keyboard's inset never pushes it off screen.
    static func homeIndicatorSink(forBottomInset inset: CGFloat) -> CGFloat {
        min(max(0, inset - 14), 20)
    }

    private var isVerticallyCompact: Bool { verticalSizeClass == .compact }

    var body: some View {
        HStack(alignment: .center, spacing: BighelpTokens.space12) {
            NavigationRowLayout(constrainsWidth: true) {
                ForEach(items) { item in place(item) }
            }
            .padding(6)
            .bighelpNavigationGlass(in: Capsule())
            .sensoryFeedback(.selection, trigger: tabChanges)
            .frame(maxWidth: BighelpTokens.scaled(380))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Primary navigation")
            .accessibilityIdentifier("primary-navigation")
            Spacer(minLength: 0)
            RootComposeButton(identifier: Self.newChatIdentifier, systemImage: "square.and.pencil",
                              size: BighelpTokens.scaled(isVerticallyCompact ? 44 : 56), action: onNewChat)
                .accessibilityShowsLargeContentViewer {
                    Label(Self.newChatVisibleLabel, systemImage: "square.and.pencil")
                }
        }
        .padding(.horizontal, BighelpTokens.space12)
        .padding(.vertical, isVerticallyCompact ? 4 : 8)
        .frame(maxWidth: BighelpTokens.scaled(620))
        .frame(maxWidth: .infinity)
        // One place on every root: nothing moves the bar.
        .padding(.bottom, -homeIndicatorSink)
    }

    private func place(_ item: HomeTabItem) -> some View {
        let isSelected = selection == item.id
        let showsDot = item.showsDot(selected: isSelected)
        return Button {
            BighelpKeyboard.dismiss()
            guard selection != item.id else { return }
            tabChanges += 1
            withAnimation(reduceMotion ? nil : .snappy(duration: BighelpTokens.transitionDuration)) {
                selection = item.id
            }
        } label: {
            label(item, selected: isSelected)
                .overlay(alignment: .topTrailing) {
                    if showsDot {
                        Circle()
                            .fill(theme.action)
                            .frame(width: 8, height: 8)
                            .padding(.top, isVerticallyCompact ? 4 : 8)
                            .padding(.trailing, 10)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.bighelpTilePress)
        .bighelpHover(in: Capsule())
        .bighelpHelp(item.title, shortcut: items.firstIndex(of: item).map { "⌘\($0 + 1)" })
        .accessibilityLabel(item.title)
        .accessibilityValue(showsDot ? String(localized: "New") : "")
        .accessibilityShowsLargeContentViewer {
            Label(item.title, systemImage: item.symbol(selected: isSelected))
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(item.accessibilityIdentifier)
    }

    private func label(_ item: HomeTabItem, selected: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: item.symbol(selected: selected))
                .resizable()
                .scaledToFit()
                .fontWeight(.medium)
                .frame(width: BighelpTokens.scaled(min(iconSize, 28)), height: BighelpTokens.scaled(min(iconSize, 28)))
                .accessibilityHidden(true)
            Text(item.title)
                .font(.bighelp(.caption2).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        // The theme's ink, not `.secondary`, which goes vibrant on glass. The current place is a pill.
        .foregroundStyle(selected ? theme.actionForeground : theme.secondaryText)
        .padding(.horizontal, 4)
        .padding(.vertical, isVerticallyCompact ? 3 : 6)
        .frame(minWidth: BighelpTokens.hitTarget, maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
        .background {
            if selected {
                Capsule()
                    .fill(theme.action)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.86).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
    }
}
