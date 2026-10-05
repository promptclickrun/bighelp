import SwiftUI

@MainActor
struct AgentsShellView: View {
    let agents: AgentDirectoryStore
    let runtimeDefaultsClient: any AgentRuntimeDefaultsClient
    let onSelect: (AgentProfile) -> Void
    let onOpenSessions: (AgentProfile) -> Void
    let onOpenHostStatus: () -> Void
    let hostRuntime: HostRuntimeStore?
    let workspaceOwner: WorkspaceOwner?
    let capabilities: WorkspaceCapabilities
    let botModeRooms: BotModeRoomStore
    let cloneClient: (any AgentProfileCloneClient)?
    let shortcutsAvailable: Bool
    let onAction: @MainActor (AgentWorkspaceActionRequest) -> Void
    var groupFilterRequest: Binding<String?> = .constant(nil)
    var createRequest: Binding<Bool> = .constant(false)

    var body: some View {
        AgentsView(
            store: agents,
            runtimeDefaultsClient: runtimeDefaultsClient,
            onSelect: onSelect,
            onOpenSessions: onOpenSessions,
            onOpenHostStatus: onOpenHostStatus,
            hostRuntime: hostRuntime,
            workspaceOwner: workspaceOwner,
            capabilities: capabilities,
            botModeRooms: botModeRooms,
            cloneClient: cloneClient,
            shortcutsAvailable: shortcutsAvailable,
            onAction: onAction,
            groupFilterRequest: groupFilterRequest,
            createRequest: createRequest
        )
    }
}

@MainActor
struct ApprovalDestinationView: View {
    @State private var model: ApprovalModel

    init(model: ApprovalModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            ApprovalCard(model: model)
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.vertical, BighelpTokens.space24)
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("approval.screen")
    }

    @BighelpThemeReader private var theme

}

enum ConversationRootNavigationPresentation {
    static let composeAccessibilityIdentifier = "root.new-chat"
}

/// The Chats compose action: a large, tinted Liquid Glass circle that floats
/// over the list like the iMessage compose affordance, instead of a small
/// toolbar glyph.
struct RootComposeButton: View {
    static let diameter: CGFloat = 60
    var identifier = ConversationRootNavigationPresentation.composeAccessibilityIdentifier
    /// Bigger where it's the screen's one main action (All agents).
    var size: CGFloat = RootComposeButton.diameter
    let action: () -> Void

    @BighelpThemeReader private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .title2) private var glyph: CGFloat = 24
    @State private var taps = 0

    var body: some View {
        Button {
            BighelpKeyboard.dismiss()
            taps += 1
            action()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: glyph * size / Self.diameter, weight: .semibold))
                .foregroundStyle(theme.actionForeground)
                .frame(width: size, height: size)
                .contentShape(.circle)
                .modifier(ComposeSurface(tint: theme.action, reduceTransparency: reduceTransparency))
        }
        .bighelpPointerButtonStyle(BighelpPressFeedbackStyle(), outline: .circle)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .bighelpIconLabel("New chat", shortcut: "⌘N")
        .accessibilityIdentifier(identifier)
    }

    private struct ComposeSurface: ViewModifier {
        let tint: Color
        let reduceTransparency: Bool

        func body(content: Content) -> some View {
            #if compiler(>=6.2) && !os(visionOS) // visionOS has no glassEffect.
            if #available(iOS 26.0, *), !reduceTransparency {
                content.glassEffect(.regular.tint(tint).interactive(), in: .circle)
            } else {
                content.background(tint, in: .circle).shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
            #else
            content.background(tint, in: .circle).shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            #endif
        }
    }
}
