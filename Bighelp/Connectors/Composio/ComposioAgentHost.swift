import Foundation

/// The plugin's answer to `composio/status` and `composio/install`: Composio's MCP servers in
/// this agent's Hermes settings, and which is Composio Connect. Never any credential.
struct ComposioAgentStatus: Equatable, Sendable {
    struct Server: Equatable, Sendable {
        let name: String
        let enabled: Bool
        let auth: String
        let isConnect: Bool
        let signedIn: Bool?
    }

    let connect: String?
    let servers: [Server]

    var access: ComposioAgentAccess {
        guard let name = connect, let server = servers.first(where: { $0.name == name }) else { return .notInstalled }
        if !server.enabled { return .turnedOff(server: name) }
        if server.auth == "oauth", server.signedIn != true { return .needsSignIn(server: name) }
        return .ready(server: name)
    }

    static func decode(_ object: [String: BighelpJSONValue]) throws -> ComposioAgentStatus {
        guard object["schemaVersion"]?.integer == 1, case .array(let rows)? = object["servers"], rows.count <= 32 else {
            throw WorkspaceClientError.invalidResponse
        }
        let servers = rows.compactMap { row -> Server? in
            guard let item = row.object, let name = item["name"]?.string, isServerName(name),
                  let enabled = item["enabled"]?.boolean else { return nil }
            let auth = item["auth"]?.string ?? "none"
            return Server(name: name, enabled: enabled, auth: ["oauth", "headers", "none"].contains(auth) ? auth : "none",
                          isConnect: item["kind"]?.string == "connect", signedIn: item["signedIn"]?.boolean)
        }
        let connect = object["connect"]?.string.flatMap { name in servers.contains { $0.name == name && $0.isConnect } ? name : nil }
        return ComposioAgentStatus(connect: connect, servers: servers)
    }

    private static func isServerName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (0x61...0x7a).contains($0) || (0x41...0x5a).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2d || $0 == 0x5f
        }
    }
}

/// The computer in use: our plugin installs Composio Connect for the agent, Hermes signs it in.
@MainActor
final class DirectHermesComposioAgentHost: ComposioAgentHost {
    let hostName: String
    let agentName: String
    private let workspace: any WorkspaceOperationPerforming
    private let mcp: any MCPManagementClient
    private let profileID: String

    init(hostName: String, agentName: String, profileID: String,
         workspace: any WorkspaceOperationPerforming, mcp: any MCPManagementClient) {
        self.hostName = hostName
        self.agentName = agentName
        self.profileID = profileID
        self.workspace = workspace
        self.mcp = mcp
    }

    func access() async throws -> ComposioAgentAccess {
        let access = try await status(.composioStatus).access
        guard case .ready(let server) = access else { return access }
        // The plugin sees a saved sign-in, not whether Composio still takes it. Hermes' own test
        // connects with this agent's sign-in and lists Composio's tools (#450). A host that can't
        // run the test keeps the plugin's answer.
        guard let test = try? await mcp.test(serverName: server) else { return access }
        return test.succeeded && test.toolCount > 0 ? access : .cannotReach(server: server)
    }

    func install() async throws -> String {
        guard let name = try await status(.composioInstall).connect else { throw WorkspaceClientError.invalidResponse }
        return name
    }

    func startSignIn(server: String) async throws -> MCPOAuthFlow { try await mcp.startOAuth(serverName: server) }

    func signInStatus(flowID: String) async throws -> MCPOAuthFlow { try await mcp.pollOAuth(flowID: flowID) }

    private func status(_ operation: WorkspaceOperation) async throws -> ComposioAgentStatus {
        guard let owner = workspace.owner else { throw WorkspaceClientError.ownerChanged }
        let payload: [String: BighelpJSONValue] = ["agentId": .string(profileID)]
        do {
            return try ComposioAgentStatus.decode(try await workspace.perform(operation, payload: payload, owner: owner))
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed: it's loaded again on the next call. Once.
            return try ComposioAgentStatus.decode(try await workspace.perform(operation, payload: payload, owner: owner))
        }
    }
}
