import SwiftUI
import UIKit

// The iPhone Duo's side strip, the column on the trailing edge under the camera and the status: room
// for the working agent and for the chat switcher. The home's places are toolbar items there
// (`HomeStripTabs`).

extension View {
    /// Keeps a column free on the trailing edge and puts `column` in it, under the camera and the
    /// status where the system has a column there (the Duo), else beside the page.
    func bighelpSideColumn<Column: View>(
        _ screen: BighelpScreenGeometry, isShown: Bool, @ViewBuilder column: () -> Column
    ) -> some View {
        modifier(BighelpSideColumnLayout(screen: screen, isShown: isShown, column: column()))
    }
}

/// The working agent at the top of the side column, under the camera: the Duo's answer to the
/// Dynamic Island, which has no island there to widen. Its face acts out the work and the line under
/// it names the work, in a stop as wide as the chats' faces below; a tap opens the chat.
///
/// Nothing is drawn while the agent rests, so the column costs nothing then. It sits beside the bar
/// rather than in it, so iOS's own stacking and overflow of the toolbar items keep working.
struct AgentStripPill: View {
    let agentID: String
    let name: String
    let imageURL: URL?
    let kind: AgentActivityKind
    let open: () -> Void

    /// A stop wide, the same as `BighelpChatSwitcherColumn`, so the two read as one column.
    static let width: CGFloat = 54

    @BighelpThemeReader private var theme

    var body: some View {
        Button(action: open) {
            VStack(spacing: BighelpTokens.space4) {
                // No badge: the line underneath already names the work, and at this size a badge
                // would cover the face it belongs to.
                AgentLiveAvatar(agentID: agentID, displayName: name, imageURL: imageURL,
                                activity: kind, size: 40, showsBadge: false)
                Text(kind.label)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: Self.width)
            .padding(.vertical, BighelpTokens.space8)
            .contentShape(Capsule())
            .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
        }
        .buttonStyle(.bighelpTilePress)
        .bighelpHelp(name)
        .accessibilityLabel("\(name), \(kind.label)")
        .accessibilityHint("Opens the chat where it is working")
        .accessibilityIdentifier("strip.agent")
    }
}

/// Reads who is working in its own body, so a streaming reply redraws this pill alone rather than
/// the chat behind it — and draws nothing at all while every agent rests.
struct AgentStripWorking: View {
    let working: @MainActor () -> AgentIslandActivity?
    let open: @MainActor (AgentIslandActivity) -> Void

    var body: some View {
        if let activity = working() {
            AgentStripPill(agentID: activity.agentID, name: activity.name,
                           imageURL: activity.imageURL, kind: activity.kind,
                           open: { open(activity) })
        }
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
