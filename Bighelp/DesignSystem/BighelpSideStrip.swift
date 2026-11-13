import SwiftUI
import UIKit

// The iPhone Duo's side strip, the column on the trailing edge under the camera and the status: room
// for the chat switcher. The home's places are toolbar items there (`HomeStripTabs`).

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
                        // Only the system's side column supplies its own top clearance.
                        .ignoresSafeArea(.container, edges: screen.usesSideBar ? [.trailing, .top] : .trailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
    }
}
