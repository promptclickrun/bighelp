#if DEBUG && os(iOS) && targetEnvironment(simulator)
import SwiftUI

/// UI tests drive CarPlay's voice session here: the simulator's CarPlay
/// window can't be opened from a test. Runs on the demo data. The saved agent
/// lives in a throwaway defaults suite, so a run never changes the next one.
enum CarPlaySessionFixture {
    static let launchArgument = "-test-carplay-session"

    @MainActor
    static func rootView() -> some View {
        let runID = ProcessInfo.processInfo.environment["BIGHELP_UI_TEST_RUN_ID"] ?? "default"
        let suite = "bighelp.carplay.fixture.\(runID)"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        return CarPlaySessionFixtureView(suite: suite)
    }
}

private struct CarPlaySessionFixtureView: View {
    let suite: String
    @State private var session: CarPlayVoiceSession
    @State private var rows: [CarPlayAgentRow] = []

    init(suite: String) {
        self.suite = suite
        _session = State(initialValue: Self.makeSession(suite: suite))
    }

    /// A new car connection: a new session over the same saved choice.
    private static func makeSession(suite: String) -> CarPlayVoiceSession {
        CarPlayVoiceSession(
            microphoneAllowed: { true }, speechAllowed: { true },
            preference: CarPlayAgentPreference(defaults: UserDefaults(suiteName: suite) ?? .standard))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(phase).font(.bighelp(.title2)).accessibilityIdentifier("carplay.phase")
            Text(session.agentName).accessibilityIdentifier("carplay.agent")
            Text(session.chatID ?? "none").accessibilityIdentifier("carplay.chat")
            HStack {
                Button("Talk") { Task { await session.start() } }.accessibilityIdentifier("carplay.talk")
                Button(session.isMuted ? "Unmute" : "Mute") { session.toggleMute() }.accessibilityIdentifier("carplay.mute")
                Button("End") { session.stop() }.accessibilityIdentifier("carplay.end")
            }
            HStack {
                // Like the car's Agents button: it ends listening, then lists the agents.
                Button("Agents") {
                    session.stop()
                    Task { rows = (try? await session.agentRows()) ?? [] }
                }
                .accessibilityIdentifier("carplay.agents")
                Button("New connection") {
                    session.stop()
                    rows = []
                    session = Self.makeSession(suite: suite)
                }
                .accessibilityIdentifier("carplay.reconnect")
            }
            ForEach(rows) { row in
                Button([row.title, row.detail].compactMap { $0 }.joined(separator: ", ")) {
                    rows = []
                    Task { await session.start(agentID: row.id) }
                }
                .accessibilityIdentifier("carplay.pick.\(row.id)")
            }
        }
        .buttonStyle(.borderedProminent)
    }

    private var phase: String {
        switch session.phase {
        case .connecting: "connecting"
        case .listening: "listening"
        case .working: "working"
        case .speaking: "speaking"
        case .paused: "paused"
        case .problem(let message): "problem: \(message)"
        }
    }
}
#endif
