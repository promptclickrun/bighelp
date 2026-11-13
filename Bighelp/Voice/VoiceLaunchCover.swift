import SwiftUI

/// Set the moment a "Start voice chat" shortcut runs (the Action button), so
/// the voice stage shows at once while the host reconnects and the chat is
/// created, instead of the app's last screen.
@MainActor @Observable
final class VoiceLaunchState {
    struct Agent: Equatable {
        let id: String
        let name: String
        let imageURL: URL?
    }

    static let shared = VoiceLaunchState()

    private(set) var isStarting = false
    private(set) var agent: Agent?
    @ObservationIgnored private var token = UUID()

    func begin(agent: Agent?) {
        let current = UUID()
        token = current
        self.agent = agent
        isStarting = true
        // Never outlive a start that got lost: the shortcut reports failures itself.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            if self?.token == current { self?.finish() }
        }
    }

    func update(agent: Agent) {
        guard isStarting else { return }
        self.agent = agent
    }

    func finish() {
        token = UUID()
        isStarting = false
        agent = nil
    }
}

/// The voice stage's look with the agent's face, shown until voice opens.
struct VoiceLaunchCover: View {
    let agent: VoiceLaunchState.Agent?
    @BighelpThemeReader private var theme

    var body: some View {
        let persona = AgentPersona(stableID: agent?.id ?? "voice")
        VStack(spacing: BighelpTokens.space24) {
            Spacer()
            AgentLiveAvatar(agentID: agent?.id ?? "voice", displayName: agent?.name ?? "Bot",
                            imageURL: agent?.imageURL, activity: .thinking, size: 200, showsBadge: false)
            Text(agent.map { "Starting voice with \($0.name)…" } ?? "Starting voice…")
                .font(.bighelp(.title3).weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
            ProgressView()
            Spacer()
        }
        .padding(BighelpTokens.space24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { VoiceStageBackground(agentColor: persona.color).ignoresSafeArea() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voice.launching")
    }
}

/// Covers the app with the voice stage while a voice shortcut is starting.
struct VoiceLaunchCoverOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay {
            if VoiceLaunchState.shared.isStarting {
                VoiceLaunchCover(agent: VoiceLaunchState.shared.agent)
                    .transition(.opacity)
            }
        }
    }
}
