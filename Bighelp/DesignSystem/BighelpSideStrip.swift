import SwiftUI
import UIKit

// The iPhone Duo's side strip, the column under the camera and the status — on the trailing edge on
// the cover screen, on the leading edge for the app left of Split View — with room for work in another
// chat (`WorkingChatPill`) and the chat switcher. The home's places are toolbar items there
// (`HomeStripTabs`).

extension View {
    /// Keeps a column free on the screen's own edge and puts `column` in it, under the camera and the
    /// status where the system has a column there (the Duo), else beside the page.
    func bighelpSideColumn<Column: View>(
        _ screen: BighelpScreenGeometry, isShown: Bool, @ViewBuilder column: () -> Column
    ) -> some View {
        modifier(BighelpSideColumnLayout(screen: screen, isShown: isShown, column: column()))
    }
}

private struct BighelpSideColumnLayout<Column: View>: ViewModifier {
    let screen: BighelpScreenGeometry
    let isShown: Bool
    let column: Column

    func body(content: Content) -> some View {
        content
            // The system's column already keeps the page clear; elsewhere make room. Its edge is the
            // screen's own: trailing on the cover screen, leading for the app left of Split View.
            .safeAreaPadding(screen.sideColumnEdge.edgeSet,
                             isShown ? max(0, BighelpScreenGeometry.sideColumnWidth - screen.sideColumnWidth) : 0)
            .overlay(alignment: screen.sideColumnEdge == .leading ? .topLeading : .topTrailing) {
                if isShown {
                    // Centered in the system's column (84 pt on the Duo), or the room kept for it.
                    column
                        .frame(width: max(screen.sideColumnWidth, BighelpScreenGeometry.sideColumnWidth))
                        .padding(.top, max(screen.sideColumnFreeTop + BighelpTokens.space8, 8))
                        // Only the system's side column supplies its own top clearance.
                        .ignoresSafeArea(.container, edges: screen.usesSideBar
                                         ? [screen.sideColumnEdge.edgeSet, .top] : screen.sideColumnEdge.edgeSet)
                        .transition(.move(edge: screen.sideColumnEdge.edge).combined(with: .opacity))
                }
            }
    }
}

/// The home's places down a column of the list's own, on the leading edge beside it. In the open
/// posture the system's strip is on the window's trailing edge, which belongs to the chat, so the
/// places that switch the list travel with the list instead. The last button puts the list away,
/// leaving the page the whole screen (wide tables, a picture, a long line of code).
struct HomePlacesRail: View {
    let column: BighelpSplitColumn
    @Binding var selection: HomeTab
    let items: [HomeTabItem]
    let onNewChat: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 22
    @BighelpThemeReader private var theme

    /// As wide as the system's column on the Duo, so both columns read as one kind of strip.
    static let width = BighelpScreenGeometry.sideColumnWidth
    static let listToggleIdentifier = "home.list.toggle"

    var body: some View {
        VStack(spacing: BighelpTokens.space4) {
            ForEach(items) { item in
                place(item)
            }
            button(HomeTabBar.newChatVisibleLabel, "square.and.pencil",
                   identifier: HomeTabBar.newChatIdentifier, action: onNewChat)
            Spacer(minLength: BighelpTokens.space8)
            button(column.isCollapsed ? String(localized: "Show the list") : String(localized: "Hide the list"),
                   "sidebar.left", identifier: Self.listToggleIdentifier) {
                setCollapsed(!column.isCollapsed)
            }
        }
        .padding(.vertical, BighelpTokens.space8)
        .frame(width: Self.width)
    }

    private func place(_ item: HomeTabItem) -> some View {
        let isSelected = selection == item.id
        let showsDot = item.showsDot(selected: isSelected)
        return Button {
            BighelpKeyboard.dismiss()
            // A place chosen while the list is away brings it back: the tap asked to see it.
            setCollapsed(false)
            // Always assign so tapping the active place pops pushed pages back to its root,
            // matching `HomeTabBar`.
            selection = item.id
        } label: {
            glyph(item.symbol(selected: isSelected), isSelected: isSelected)
                .overlay(alignment: .topTrailing) {
                    if showsDot {
                        Circle()
                            .fill(theme.action)
                            .frame(width: 8, height: 8)
                            .padding(.top, 7)
                            .padding(.trailing, 7)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.bighelpTilePress)
        .tint(isSelected ? theme.action : theme.secondaryText)
        .accessibilityLabel(item.title)
        .accessibilityValue(showsDot ? String(localized: "New") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(item.accessibilityIdentifier)
    }

    private func button(_ title: String, _ symbol: String, identifier: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            glyph(symbol, isSelected: false)
        }
        .buttonStyle(.bighelpTilePress)
        .tint(theme.secondaryText)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func glyph(_ symbol: String, isSelected: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: min(iconSize, 28), weight: .medium))
            .foregroundStyle(isSelected ? theme.actionForeground : theme.secondaryText)
            .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
            .background {
                if isSelected {
                    Capsule()
                        .fill(theme.action)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
            .accessibilityHidden(true)
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard column.isCollapsed != collapsed else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            column.setCollapsed(collapsed)
        }
    }
}
