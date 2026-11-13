#if DEBUG
import SwiftUI

/// The Chats view alone on made-up data, before the shell holds it: the demo's chats and bots on
/// "Home Hermes", Studio Mac's chats from the all-hosts demo, and Office Linux, which doesn't answer.
/// The first demo chat carries the Code tag. Long-press changes only print.
@MainActor
enum ChatsInboxFixture {
    /// Suggested: `-use-demo-fixtures -test-chats-inbox` shows `ChatsInboxFixture.view()` as the root.
    static let launchArgument = "-test-chats-inbox"

    static func view(header: AnyView = AnyView(EmptyView())) -> some View {
        ChatsInboxView(context: context(header: header))
    }

    static func context(header: AnyView = AnyView(EmptyView())) -> ChatsInboxContext {
        let defaults = UserDefaults(suiteName: "bighelp.chats-inbox-fixture") ?? .standard
        let records = DemoSessionCatalogClient.fixtureRecords
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(records: records), records: records,
                                          repository: nil, loadsRepositoryOnInit: false, defaults: defaults)
        let agents = AgentDirectoryStore(client: UnavailableAppCatalogClient(), defaults: defaults,
                                         profiles: DemoAgentDirectoryClient.fixtureProfiles)
        let fleet = FleetStore(reader: FleetFixtureReader(), directory: FileManager.default.temporaryDirectory
            .appending(path: "bighelp-chats-inbox-\(ProcessInfo.processInfo.processIdentifier)"))
        return ChatsInboxContext(
            catalog: catalog,
            agents: agents,
            fleet: fleet,
            showsEveryComputer: true,
            codeSessionIDs: Set(records.prefix(1).map(\.id)),
            header: header,
            onOpen: { print("ChatsInboxFixture open", $0) },
            onChange: { row, change in print("ChatsInboxFixture change", row.id, change) },
            onRefresh: { try? await Task.sleep(for: .milliseconds(300)) },
            onNewChat: { print("ChatsInboxFixture new chat") },
            onOpenArchived: { print("ChatsInboxFixture archived") },
            onOpenThisComputer: { print("ChatsInboxFixture this computer") }
        )
    }
}
#endif
