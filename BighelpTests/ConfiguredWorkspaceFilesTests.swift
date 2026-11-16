import Foundation
import Testing
@testable import Bighelp

/// A bot's Files reads that bot's own folder (#518): each request names the bot, except the bot that
/// serves the plugin, which never names itself, so plugins older than 3.20.0 keep working for it.
@MainActor
struct ConfiguredWorkspaceFilesTests {
    @Test func theSelectedAgentsFolderIsReadForThatAgent() async throws {
        let host = try FilesHostFake()
        host.readsOtherAgents = true
        let files = host.files(of: "research")
        let scope = try await files.workspaceScope()
        #expect(scope.root == FilesHostFake.root(for: "research"))
        let listed = try await files.list()
        #expect(listed.files.map(\.name) == ["research.md"])
        #expect(host.fileRequests.first?.route == "scope")
        #expect(host.fileRequests.contains { $0.route == "list" })
        #expect(host.fileRequests.allSatisfy { $0.profile == "research" })
    }

    @Test func theServingAgentsFolderIsReadWithoutNamingIt() async throws {
        let host = try FilesHostFake()
        let files = host.files(of: "default")
        let scope = try await files.workspaceScope()
        _ = try await files.list()
        #expect(scope.root == FilesHostFake.root(for: "default"))
        #expect(host.fileRequests.contains { $0.route == "list" })
        #expect(host.fileRequests.allSatisfy { $0.profile == nil })
    }

    @Test func anotherAgentOnAnOlderPluginSaysToUpdateIt() async throws {
        let host = try FilesHostFake()
        do {
            _ = try await host.files(of: "research").workspaceScope()
            Issue.record("An older plugin can't read another agent's folder")
        } catch {
            #expect(error as? WorkspaceClientError == .rejected(code: WorkspaceClientError.workspacePluginOutdated))
            #expect(SimpleBotFilesModel.phase(for: error) == .needsPluginUpdate)
        }
        #expect(host.fileRequests.isEmpty, "Nothing is read from the serving agent's folder instead")
    }
}

/// A host whose bighelp plugin serves "default" and finds each agent's folder at /srv/agents/<agent>.
@MainActor
private final class FilesHostFake: DirectHermesRPC, DirectHermesAuthenticatedHTTP, DirectHermesNativeHTTP {
    struct FileRequest {
        let route: String
        let profile: String?
    }

    let owner: WorkspaceOwner
    var onEvent: ((DirectHermesEvent) -> Void)?
    /// Plugin 3.20.0 and later read another agent's folder when a request names it.
    var readsOtherAgents = false
    private(set) var fileRequests: [FileRequest] = []
    /// The client a bot's Files tab makes for that bot.
    func files(of agentID: String) -> DirectHermesManagedFilesClient {
        DirectHermesManagedFilesClient(http: self, owner: owner, agentID: agentID, currentOwner: { [owner] in owner })
    }

    static func root(for agentID: String) -> String { "/srv/agents/\(agentID)" }

    init() throws {
        owner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://files.example.test", providerID: "test",
                                                      userID: "files"),
                               authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        throw WorkspaceClientError.invalidRequest
    }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        throw WorkspaceClientError.invalidRequest
    }

    func disconnect() async {}

    func nativeResponse(_ request: DirectHermesHTTPRequest,
                        requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response {
        var headers = ["ETag": "\"sha256:" + String(repeating: "b", count: 64) + "\"", "Cache-Control": "no-store"]
        let object: [String: BighelpJSONValue]
        if request.path == "/api/plugins/loopdy/native/context" {
            let features = ["native-context-v1", "serving-profile-v1", "native-workspace-files-v1",
                            "native-workspace-recent-v1", "native-workspace-hermes-home-v1"]
                + (readsOtherAgents ? ["native-workspace-files-agents-v1"] : [])
            object = ["schemaVersion": .integer(1), "pluginVersion": .string("test"),
                      "runtimeId": .string("files-runtime"), "servingProfileId": .string("default"),
                      "principal": .object(["provider": .string("test"), "userId": .string("files"),
                                            "displayName": .null]),
                      "features": .array(features.map(BighelpJSONValue.string))]
        } else {
            let profile = request.body?["profile"]?.string
            fileRequests.append(.init(route: request.path.components(separatedBy: "/").last ?? "", profile: profile))
            headers["X-Loopdy-Request-ID"] = try #require(requestGuard).requestIDHeader
            let agent = profile ?? "default"
            let root = Self.root(for: agent)
            let path = request.body?["path"]?.string ?? root
            let file: BighelpJSONValue = .object([
                "name": .string("\(agent).md"), "path": .string(root + "/\(agent).md"), "is_directory": .boolean(false),
                "size": .integer(3), "mtime": .integer(1_700_000_000), "mime_type": .string("text/markdown"),
            ])
            object = ["workspace": .object(["root": .string(root), "source": .string("terminal.cwd"),
                                            "profileId": .string(agent)]),
                      "path": .string(path), "parent": .null, "root": .string(root), "locked_root": .string(root),
                      "can_change_path": .boolean(false), "entries": .array(path == root ? [file] : [])]
        }
        let url = try #require(URL(string: "https://files.example.test" + request.path))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                    headerFields: headers))
        return .init(http: response, body: try JSONEncoder().encode(BighelpJSONValue.object(object)))
    }
}
