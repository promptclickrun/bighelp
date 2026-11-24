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
