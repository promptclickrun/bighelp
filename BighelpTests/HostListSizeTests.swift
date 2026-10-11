import Foundation
import Testing
@testable import Bighelp

/// Stock Hermes lists more plugins, catalog entries and per-plugin details than
/// the fixed caps these screens had, and Plugins stopped with "The host response
/// exceeded this screen's safe display limit". The connection's reply-size limit
/// is the only bound; a long list still shows.
@MainActor
struct HostListSizeTests {
    @Test func pluginsShowsEveryInstalledAndCatalogPlugin() async throws {
        let owner = try Self.owner()
        let client = DirectHermesPluginLifecycleClient(http: PluginsHost(), owner: owner, currentOwner: { owner })

        let snapshot = try await client.load()

        #expect(snapshot.installed.count == 700)
        #expect(snapshot.catalog.count == 900)
        #expect(snapshot.catalog[0].platforms.count == 60)
        #expect(snapshot.catalog[0].capabilities.tools.count == 800)
    }

    @Test func anAgentsSkillsAndToolsShowEveryPlugin() async throws {
        let owner = try Self.owner()
        let host = CatalogHost(owner: owner)
        let catalog = try await DirectHermesSkillsAndToolsClient(workspace: host, owner: owner, currentOwner: { owner })
            .load(agentID: "default")

        #expect(catalog.plugins.count == 400)
        #expect(catalog.tools.count == 400)
    }

    private static func owner() throws -> WorkspaceOwner {
        WorkspaceOwner(
            authority: try .direct(endpointIdentity: "https://hermes.example", providerID: "basic", userID: "person"),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
    }
}

@MainActor
private final class PluginsHost: DirectHermesAuthenticatedHTTP {
    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        switch request.path {
        case "/api/dashboard/plugins/hub":
            return .object(["plugins": .array((0..<700).map { index in
                .object([
                    "name": .string("plugin-\(index)"), "version": .string("1.0.0"), "description": .string(""),
                    "source": .string("bundled"), "runtime_status": .string("enabled"),
                    "can_remove": .boolean(false), "can_update_git": .boolean(false),
                    "auth_required": .boolean(false), "auth_command": .string(""),
                ])
            })])
        case "/api/dashboard/plugins/catalog":
            return .object([
                "entries": .array((0..<900).map { index in
                    .object([
                        "name": .string("catalog-\(index)"), "repo": .string("https://github.com/example/catalog-\(index)"),
                        "sha": .string(String(repeating: "a", count: 40)), "description": .string(""),
                        "maintainer": .string("Example"), "tier": .string("community"), "docs_url": .string(""), "requires_hermes": .string(""),
                        "platforms": .array((0..<(index == 0 ? 60 : 1)).map { .string("platform-\($0)") }),
                        "capabilities": .object([
                            "provides_tools": .array((0..<(index == 0 ? 800 : 1)).map { .string("tool_\($0)") }),
                            "provides_hooks": .array([]), "provides_middleware": .array([]), "requires_env": .array([]),
                        ]),
                        "installed": .boolean(false), "update_available": .boolean(false),
                    ])
                }),
                "removed": .array([]),
            ])
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }
}

@MainActor
private final class CatalogHost: WorkspaceOperationPerforming {
    let owner: WorkspaceOwner?
    let capabilities: WorkspaceCapabilities

    init(owner: WorkspaceOwner) {
        self.owner = owner
        capabilities = .init(owner: owner, values: [
            .skillsRead: .available, .pluginsRead: .available, .mcpServersRead: .available, .toolsetsRead: .available,
        ])
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        switch operation {
        case .skillsToolsList: return ["skills": .array([])]
        case .mcpServersList: return ["servers": .array([])]
        case .pluginsList:
            return ["plugins": .array((0..<400).map { .object(["name": .string("plugin-\($0)"), "enabled": .boolean(true)]) })]
        case .toolsetsList:
            return ["toolsets": .array((0..<400).map {
                .object(["name": .string("toolset-\($0)"), "label": .string("Toolset \($0)"), "platform": .string("cli"),
                         "enabled": .boolean(true), "tools": .array([])])
            })]
        default:
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }
}
