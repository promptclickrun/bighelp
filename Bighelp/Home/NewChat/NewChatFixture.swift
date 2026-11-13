#if DEBUG
import SwiftUI

/// New chat's parts alone on made-up data, before the shell hosts them in a chat: the To row and
/// people list (two computers, a group chat), and the choices row under a stand-in message box
/// with demo projects. Nothing here sends; Send all and Manage worktrees do nothing.
@MainActor
enum NewChatFixture {
    /// The launch argument the integrator can show it behind.
    static let launchArgument = "-test-new-chat"

    static func makeView() -> some View { NewChatFixtureScreen() }

    static let homeComputer = FleetHost(id: UUID(uuidString: "6F1A2B3C-0000-4000-8000-000000000001")!,
                                        name: "Home computer", isSelected: true)
    static let studioComputer = FleetHost(id: UUID(uuidString: "6F1A2B3C-0000-4000-8000-000000000002")!,
                                          name: "Studio computer", isSelected: false)

    static let bots: [SimpleBotsBot] = [
        bot("avery", "Avery", "Money and plans", on: homeComputer),
        bot("mina", "Mina", "Travel", on: homeComputer),
        bot("jordan", "Jordan", "Home", on: homeComputer),
        bot("juno", "Juno", "Code", on: studioComputer),
    ]

    static var groups: [SimpleBotsGroup] {
        let group = FleetGroup(hostID: homeComputer.id, roomID: "room-family-budget", name: "Family budget",
                               memberNames: ["Avery", "Jordan"], updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
                               isWorking: false, canRename: true, canDelete: true, memberIDs: ["avery", "jordan"])
        return [SimpleBotsGroup(group, members: bots.filter { ["avery", "jordan"].contains($0.profileID) })]
    }

    static let rules = NewChatGroupRules(hostInUse: homeComputer.id, canMakeGroups: true)

    private static func bot(_ id: String, _ name: String, _ role: String, on host: FleetHost) -> SimpleBotsBot {
        SimpleBotsBot(id: FleetID.make(host.id, id), profileID: id, hostID: host.id, name: name, role: role)
    }

    /// Demo projects and git, saved in a suite of their own so the real Code home's choices stay put.
    static func makeStore() -> CodeHomeStore {
        let git = DemoCodeGit()
        return CodeHomeStore(scopeID: "new-chat-fixture", agentID: "avery", source: DemoCodeProjectSource(),
                             git: { git }, starter: NewChatFixtureStarter(),
                             defaults: UserDefaults(suiteName: "bighelp.new-chat-fixture") ?? .standard)
    }
}

private struct NewChatFixtureScreen: View {
    @State private var session = NewChatSession()
    @State private var store = NewChatFixture.makeStore()
    @State private var draft = ""
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: 0) {
            NewChatView(context: NewChatContext(
                session: session, bots: NewChatFixture.bots,
                hosts: [NewChatFixture.homeComputer, NewChatFixture.studioComputer],
                groups: NewChatFixture.groups, rules: NewChatFixture.rules,
                onRecipientsChanged: { _ in }, onOpenGroup: { _ in }))
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                if let line = NewChatSend.contextLine(session, stagedJobs: store.projectStaged.count,
                                                      hasText: !draft.isEmpty) {
                    Text(verbatim: line)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, BighelpTokens.space20)
                }
                // A stand-in for the chat's message box, which the chat screen draws.
                TextField("", text: $draft, prompt: Text(verbatim: "Message"), axis: .vertical)
                    .padding(BighelpTokens.space12)
                    .bighelpSurface(.composer)
                    .padding(.horizontal, BighelpTokens.space12)
                if let bot = session.recipients.first {
                    let text = draft
                    NewChatChoicesRow(context: NewChatChoicesContext(
                        session: session, store: store, agentID: bot.profileID, hasText: !text.isEmpty,
                        draft: { text }, clearDraft: { draft = "" }, onWorktrees: {}, onSendAll: {}))
                        .equatable()
                }
            }
            .padding(.vertical, BighelpTokens.space8)
        }
        .background(theme.canvas.ignoresSafeArea())
        .onAppear {
            if session.recipients.isEmpty { session.start(with: [NewChatFixture.bots[0]]) }
        }
    }
}

/// The fixture never starts a session.
private struct NewChatFixtureStarter: CodeSessionStarting {
    func startSession(agentID: String, folder: String, title: String, runtime: CodeRuntimeChoice) async throws -> String {
        throw CancellationError()
    }

    func apply(_ mode: CodeSessionMode, toSession sessionID: String, agentID: String) async throws {}

    func send(_ message: String, toSession sessionID: String) async throws {
        throw CancellationError()
    }
}
#endif
