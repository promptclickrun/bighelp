import SwiftUI

// The iPhone Duo's side strip, the column on the trailing edge under the camera and the status:
// the bar's places as toolbar items, and room for the chat switcher.

extension View {
    /// Keeps a column free on the trailing edge and puts `column` in it, under the camera and the
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
            // The system's column already keeps the page clear; elsewhere make room.
            .safeAreaPadding(.trailing, isShown ? max(0, BighelpScreenGeometry.sideColumnWidth - screen.trailingColumnWidth) : 0)
            .overlay(alignment: .topTrailing) {
                if isShown {
                    // Centered in the system's column (84 pt on the Duo), or the room kept for it.
                    column
                        .frame(width: max(screen.trailingColumnWidth, BighelpScreenGeometry.sideColumnWidth))
                        .padding(.top, max(screen.trailingColumnFreeTop + BighelpTokens.space8, 8))
                        .ignoresSafeArea(.container, edges: [.trailing, .top])
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
    }
}

/// The bar's places handed to iOS as toolbar items. Built with the iOS 27.1 SDK, the Duo lays a
/// screen's toolbar out down its side strip, with the screen's own buttons (☰, the brand, a filter),
/// so the places line up with them there instead of a column of our own lying over them.
struct BighelpStripTabs: ToolbarContent {
    @Binding var selection: AppTab
    let tabs: [AppTab]
    var unread: Set<AppTab> = []
    /// In a chat, Chat is the current tab whichever page the chat was opened from.
    var isInChat = false
    var onNewChat: (() -> Void)?
    let selectedTint: Color
    let tint: Color

    private var current: AppTab { isInChat ? .sessions : selection }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            ForEach(tabs) { tab in
                place(tab)
            }
            if let onNewChat {
                Button(action: onNewChat) {
                    Label(FloatingTabBar.newChatVisibleLabel, systemImage: "square.and.pencil")
                }
                .tint(selectedTint)
                .accessibilityIdentifier(ConversationRootNavigationPresentation.composeAccessibilityIdentifier)
            }
        }
    }

    private func place(_ tab: AppTab) -> some View {
        let isSelected = current == tab
        let isNew = unread.contains(tab) && !isSelected
        return Button {
            if isInChat, isSelected { return }
            BighelpKeyboard.dismiss()
            selection = tab
        } label: {
            Label { Text(tab.title) } icon: { icon(tab, selected: isSelected) }
                .labelStyle(.iconOnly)
        }
        .tint(isSelected ? selectedTint : tint)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isNew ? "New" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(tab.accessibilityIdentifier)
    }

    private func icon(_ tab: AppTab, selected: Bool) -> Image {
        if let glyph = tab.glyph {
            return Image(uiImage: glyph.image(selected: selected)).renderingMode(.template)
        }
        return Image(systemName: tab.systemImage(selected: selected))
    }
}
