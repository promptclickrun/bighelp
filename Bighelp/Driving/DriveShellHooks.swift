import SwiftUI

/// Gives `DriveNavigator` the shell's navigation, agents and the chat on screen, so an agent's
/// `iphone_navigation` call can drive the app (#662). In demo mode it also plays `DriveFixture`.
struct DriveShellHooks: ViewModifier {
    let appState: AppState
    let featureStore: ShellFeatureStore
    let agents: AgentDirectoryStore
    let settings: SettingsStore
    let usesDemoFixtures: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                let state = appState, features = featureStore, directory = agents
                DriveNavigator.shared.attach(
                    AppDriveRouter(appState: state),
                    agent: { id in
                        directory.profiles.first { $0.id == id }.map { DriveAgent(id: $0.id, name: $0.name, imageURL: nil) }
                    },
                    chat: { state.chatOnScreen.flatMap { features.preparedChatModel(id: $0) } })
            }
            #if DEBUG
            .onAppear {
                guard usesDemoFixtures, ProcessInfo.processInfo.arguments.contains(DriveFixture.launchArgument) else { return }
                let state = appState, features = featureStore, settings = settings
                // Not a `.task`: the root's tasks stop once a chat covers it (AGENTS.md › Root `.task(id:)`).
                Task {
                    await DriveFixture.play(arguments: ProcessInfo.processInfo.arguments, mode: { settings.currentMode },
                                            chat: { state.chatOnScreen.flatMap { features.preparedChatModel(id: $0) } })
                }
            }
            #endif
    }
}

#if DEBUG
/// Demo mode has no host, so no agent can call `iphone_navigation`. With `-test-agent-drive <place id>`
/// (and `-test-agent-drive-note "…"` for the spotlight's note), the first chat opened plays that
/// drive a moment later, for UI tests and screenshots.
@MainActor
enum DriveFixture {
    static let launchArgument = "-test-agent-drive"
    static let noteArgument = "-test-agent-drive-note"
    private static var played = false

    /// Waits up to 20 seconds for a chat to be on screen (a test taps one, or the demo opens it), then
    /// plays the drive a moment later, once.
    static func play(arguments: [String], mode: () -> BighelpMode, chat: () -> ChatModel?) async {
        guard !played, let place = value(after: launchArgument, in: arguments).flatMap(DriveCatalog.place) else { return }
        var open: ChatModel?
        for _ in 0..<80 {
            open = chat()
            if open != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let agentID = open?.memberIDs.first, let steps = place.playbooks[mode()] else { return }
        try? await Task.sleep(for: .milliseconds(1500))
        guard !played else { return }
        played = true
        let bot = place.needs.contains(.bot) ? DriveNavigator.shared.agent(agentID).map { (id: $0.id, name: $0.name) } : nil
        DriveNavigator.shared.open(place, steps: steps, bot: bot,
                                   note: value(after: noteArgument, in: arguments) ?? place.what, agentID: agentID)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
#endif
