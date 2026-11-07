#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftUI

/// `-test-system-page`: Settings › System against a synthetic host that is 12
/// commits behind, for UI tests and screenshots. Add `-test-system-page-current`
/// for a host that's up to date, and `-test-system-page-plugin-not-loaded` for a
/// plugin its dashboard hasn't loaded yet. Every number here is made up.
enum SystemPageFixture {
    static let launchArgument = "-test-system-page"
    static let upToDateArgument = "-test-system-page-current"
    static let pluginNotLoadedArgument = "-test-system-page-plugin-not-loaded"

    @MainActor
    static func rootView() -> some View {
        Root()
    }

    /// Held in state: the app's body runs again at launch, and a store made in
    /// `rootView()` each time would be replaced before it finished loading.
    private struct Root: View {
        @State private var store = SystemPageFixture.makeStore()
        @State private var plugin = SystemPageFixture.makePlugin()

        var body: some View {
            let arguments = ProcessInfo.processInfo.arguments
            let appearance = arguments.firstIndex(of: "-loopdy.demo.appearance").flatMap {
                arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
            }
            NavigationStack {
                HostOperationsView(store: store, pluginUpdate: plugin)
            }
            .environment(\.bighelpUIV3Enabled, true)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
    }

    /// The plugin as it runs: restartable from here, or not loaded by its dashboard yet.
    @MainActor
    private static func makePlugin() -> HostPluginUpdateModel {
        guard ProcessInfo.processInfo.arguments.contains(pluginNotLoadedArgument) else {
            return HostPluginUpdateFixture.model(.upToDate, installed: "2.17.0", running: "2.17.0",
                                                 message: "bighelp plugin 2.17.0 is running.", canRestartHost: true)
        }
        return HostPluginUpdateFixture.model(.restartNeeded, installed: "2.17.0", running: nil,
                                             message: HostPluginUpdateModel.notLoadedMessage(installed: "2.17.0"),
                                             canRestartHost: false, loaded: false)
    }

    @MainActor
    private static func makeStore() -> HostOperationsStore {
        let owner = WorkspaceOwner(
            authority: try! .direct(endpointIdentity: "https://hermes.example", providerID: "basic", userID: "person"),
            authenticationGeneration: UUID(),
            connectionGeneration: UUID()
        )
        let upToDate = ProcessInfo.processInfo.arguments.contains(upToDateArgument)
        let client = DirectHermesHostOperationsClient(
            rpc: FixtureRPC(), http: FixtureHTTP(upToDate: upToDate), owner: owner, currentOwner: { owner }
        )
        return HostOperationsStore(hostName: "Home Hermes", profileID: "default", client: client, isCurrent: { true })
    }

    private final class FixtureRPC: DirectHermesRPC {
        var onEvent: ((DirectHermesEvent) -> Void)?
        func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            throw WorkspaceClientError.unavailable(.policyRestricted)
        }
        func disconnect() async {}
    }

    /// Answers status, the update check and a small raw config.yaml that saves;
    /// everything else reads as not on this host.
    @MainActor
    private final class FixtureHTTP: DirectHermesAuthenticatedHTTP {
        let upToDate: Bool
        private var configuration = """
            model:
              provider: nous
              default: hermes-4-405b
            agent:
              max_turns: 60
            display:
              tool_progress: all
            terminal:
              backend: local
              timeout: 180

            """

        init(upToDate: Bool) { self.upToDate = upToDate }

        func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
            switch request.path {
            case "/api/status":
                return .object([
                    "version": .string("0.21.4"), "release_date": .string("2026-09-20"),
                    "gateway_running": .boolean(true), "gateway_state": .string("running"),
                    "gateway_busy": .boolean(false), "gateway_drainable": .boolean(true),
                    "gateway_mode": .string("multiplexed"), "gateway_shared_with": .array([]),
                    "active_agents": .integer(2), "active_sessions": .integer(3),
                    "restart_drain_timeout": .integer(30), "overall": .string("healthy"),
                    "components": .object([
                        "gateway": .object(["status": .string("ok")]),
                        "scheduler": .object(["status": .string("ok")]),
                    ]),
                ])
            case "/api/hermes/update/check":
                let summaries = ["Faster tool calls in long chats", "Clearer errors when a provider is down",
                                 "Scheduled tasks keep their time zone"]
                let commits = upToDate ? [] : summaries.enumerated().map { index, summary in
                    BighelpJSONValue.object([
                        "sha": .string(String(repeating: String(index + 1), count: 40)),
                        "summary": .string(summary),
                    ])
                }
                return .object([
                    "install_method": .string("git"), "current_version": .string("0.21.4"),
                    "behind": .integer(upToDate ? 0 : 12), "update_available": .boolean(!upToDate),
                    "can_apply": .boolean(true), "update_command": .string("hermes update"),
                    "message": .null, "commits": .array(commits),
                ])
            case "/api/config/raw":
                if request.method == .put, let yaml = request.body?["yaml_text"]?.string {
                    configuration = yaml
                    return .object(["ok": .boolean(true)])
                }
                return .object(["yaml": .string(configuration), "path": .string("~/.hermes/config.yaml")])
            default:
                throw DirectHermesError.unsupportedAuthentication
            }
        }
    }
}
#endif
