import SwiftUI

/// On the iPhone Duo's cover screen, the top of a chat's side column, under the camera: an agent
/// working in a chat that isn't this one. Its face acts out the work, a line under it names the
/// work, and a tap opens that chat. The Duo has no Dynamic Island to say it.
///
/// Nothing is drawn while no other chat works. It is a view in the column, never a toolbar item, so
/// iOS's own stacking of the bar's items there stays as it is.
struct WorkingChatPill: View {
    /// Read in this view's own body, so a reply streaming in another chat redraws the pill and not
    /// the chat behind it.
    let working: @MainActor () -> AgentIslandActivity?
    let open: @MainActor (AgentIslandActivity) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme
    @State private var taps = 0

    static let width: CGFloat = 58
    /// Squarer than the switcher's capsule, so the line of text keeps clear of the corners.
    private static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    /// Only where the column is there anyway: the system's own under the camera, or the room the
    /// chat switcher keeps. Work that starts and ends then never moves the page.
    static func isShown(screen: BighelpScreenGeometry, hasSwitcher: Bool) -> Bool {
        screen.posture == .cover
            && (hasSwitcher || screen.sideColumnWidth >= BighelpScreenGeometry.sideColumnWidth)
    }

    var body: some View {
        let activity = working()
        ZStack {
            if let activity {
                pill(activity)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: activity?.conversationID)
        .sensoryFeedback(.selection, trigger: taps)
    }

    private func pill(_ activity: AgentIslandActivity) -> some View {
        Button {
            BighelpKeyboard.dismiss()
            taps += 1
            open(activity)
        } label: {
            VStack(spacing: 2) {
                // The face the switcher under it and the Bots view draw for this agent.
                SimpleBotFace(agentID: activity.agentID, name: activity.name, imageURL: activity.imageURL, size: 38,
                              activity: activity.kind == .waiting ? .waiting : .working(tool: nil))
                    .frame(width: 48, height: 48)
                Text(activity.kind.label)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    // The column is as wide as a face: larger text would only cut the words.
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
                    .padding(.horizontal, 5)
            }
            .padding(.top, 3)
            .padding(.bottom, 10)
            // Near the width of the chat switcher under it, so the two read as one column.
            .frame(width: Self.width)
            // The shape takes the tap before the glass is laid on it, or taps miss.
            .contentShape(Self.shape)
            .bighelpNavigationGlass(in: Self.shape, isInteractive: true)
        }
        .buttonStyle(.bighelpTilePress)
        .bighelpHelp(activity.name)
        .accessibilityLabel("\(activity.name), \(activity.kind.label)")
        .accessibilityHint("Opens the chat where it works")
        .accessibilityIdentifier("chat.working-elsewhere")
    }
}
