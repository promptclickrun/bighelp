import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

/// Files in the agent home reads the selected agent's own folder (DESIGN.md › Navigation and
/// simplicity), and the folder chooser saves for the agent Files reads, never another one (#518).
@MainActor
struct ConfiguredWorkspaceFilesTests {
    @Test func theSelectedAgentsFolderIsReadByBothClients() async throws {
        let host = try FilesHostFake()
        host.readsOtherAgents = true
        let workspace = try await host.source.open(.init(owner: host.owner, agentID: "research"),
                                                   currentOwner: { host.owner })
        #expect(workspace.scope.root == FilesHostFake.root(for: "research"))
        _ = try await workspace.performer.perform(.filesRecent, payload: [:], owner: host.owner)
        _ = try await workspace.performer.perform(.filesList, payload: ["path": .string(workspace.scope.root)],
                                                  owner: host.owner)
        #expect(host.fileRequests.map(\.route) == ["scope", "recent", "list"])
        #expect(host.fileRequests.allSatisfy { $0.profile == "research" })
    }

    /// The serving agent never names itself, so plugins older than 3.20.0 keep working for it.
    @Test func theServingAgentsFolderIsReadWithoutNamingIt() async throws {
        let host = try FilesHostFake()
        let workspace = try await host.source.open(.init(owner: host.owner, agentID: "default"),
                                                   currentOwner: { host.owner })
        _ = try await workspace.performer.perform(.filesRecent, payload: [:], owner: host.owner)
        #expect(workspace.scope.root == FilesHostFake.root(for: "default"))
        #expect(host.fileRequests.map(\.route) == ["scope", "recent"])
        #expect(host.fileRequests.allSatisfy { $0.profile == nil })
    }

    @Test func anotherAgentOnAnOlderPluginSaysToUpdateIt() async throws {
        let host = try FilesHostFake()
        do {
            _ = try await host.source.open(.init(owner: host.owner, agentID: "research"), currentOwner: { host.owner })
            Issue.record("An older plugin can't read another agent's folder")
        } catch {
            #expect(error as? WorkspaceClientError == .rejected(code: WorkspaceClientError.workspacePluginOutdated))
            #expect(ConfiguredWorkspaceArtifactsView.message(for: error).contains("Update it in Settings"))
            #expect(!WorkspaceFolderChooser.canFix(error), "A folder doesn't fix an old plugin")
        }
        #expect(host.fileRequests.isEmpty, "Nothing is read from the serving agent's folder instead")
    }

    /// The agent home's Files reads the selected agent, so its chooser saves that agent's folder.
    @Test(arguments: ["research", "default"])
    func theAgentHomesChooserSavesForTheSelectedAgent(agentID: String) async throws {
        let host = try FilesHostFake()
        try await host.loadContext()
        let chooser = try #require(host.source.folderChooser(for: .init(owner: host.owner, agentID: agentID)))
        try await chooser.save("/srv/agents/chosen")
        #expect(host.savedWorkingFolders == [agentID: "/srv/agents/chosen"])
    }

    /// Nerd Mode's Artifacts reads the serving agent whichever agent is selected, so its chooser
    /// saves the serving agent's folder; until the host names that agent, there's no chooser.
    @Test func nerdModeArtifactsChooserSavesForTheServingAgent() async throws {
        let host = try FilesHostFake()
        let target = WorkspaceFilesTarget(owner: host.owner, agentID: nil)
        #expect(host.source.folderChooser(for: target) == nil)
        try await host.loadContext()
        let chooser = try #require(host.source.folderChooser(for: target))
        try await chooser.save("/srv/agents/chosen")
        #expect(host.savedWorkingFolders == ["default": "/srv/agents/chosen"])
    }

    /// The person picks another agent while the last one's folder is still on its way.
    @Test func aLateReplyForThePreviousAgentIsDropped() async throws {
        let host = try FilesHostFake()
        host.readsOtherAgents = true
        let previous = WorkspaceFilesTarget(owner: host.owner, agentID: "default")
        var current: WorkspaceFilesTarget? = previous
        host.onScope = { current = .init(owner: host.owner, agentID: "research") }
        let opened = try? await ConfiguredWorkspaceArtifactsView.open(previous, from: host.source,
                                                                      currentTarget: { current })
        #expect(opened == nil)
        #expect(host.fileRequests.map(\.route) == ["scope"], "Nothing more is read for the previous agent")
    }

    /// Files stays on screen while the agent changes; it reads the new agent's folder.
    @Test func aSameHostAgentSwitchReloadsTheFiles() async throws {
        let host = try FilesHostFake()
        host.readsOtherAgents = true
        let selection = FilesSelection()
        let controller = UIHostingController(rootView: FilesHarness(owner: host.owner, source: host.source,
                                                                    selection: selection))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        try await waitUntil(controller) { host.fileRequests.contains { $0.route == "recent" && $0.profile == nil } }

        selection.agentID = "research"
        try await waitUntil(controller) { host.fileRequests.contains { $0.route == "recent" && $0.profile == "research" } }
        #expect(host.fileRequests.filter { $0.route == "scope" }.last?.profile == "research")
    }

    private func waitUntil(_ controller: UIViewController, _ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

@MainActor
@Observable
private final class FilesSelection {
    var agentID = "default"
}

/// Files the way the agent home builds it, with the selected agent read live.
private struct FilesHarness: View {
    let owner: WorkspaceOwner
    let source: any ConfiguredWorkspaceSource
    let selection: FilesSelection

    var body: some View {
        ConfiguredWorkspaceArtifactsView(hostName: "Test computer",
            target: .init(owner: owner, agentID: selection.agentID), source: source,
            currentTarget: { [owner, selection] in .init(owner: owner, agentID: selection.agentID) },
            isEmbedded: true)
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
    var onScope: (@MainActor () -> Void)?
    private(set) var fileRequests: [FileRequest] = []
    /// Working folders saved through Hermes' `config.set`, by agent.
    private(set) var savedWorkingFolders: [String: String] = [:]
    lazy var workspaceClient = DirectHermesWorkspaceClient(rpc: self, http: self, owner: owner,
        capabilities: .init(owner: owner), currentOwner: { [owner] in owner })
    var source: HostConfiguredWorkspace { .init(http: self, workspace: workspaceClient) }

    static func root(for agentID: String) -> String { "/srv/agents/\(agentID)" }

    init() throws {
        owner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://files.example.test", providerID: "test",
                                                      userID: "files"),
                               authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    /// The app reads the plugin's context through its workspace client soon after it connects.
    func loadContext() async throws {
        _ = try await workspaceClient.perform(.nativeContext, payload: [:], owner: owner)
    }

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        guard method == "config.set", params["key"]?.string == "terminal.cwd",
              let profile = params["profile"]?.string, let folder = params["value"]?.string else {
            throw WorkspaceClientError.invalidRequest
        }
        savedWorkingFolders[profile] = folder
        return .object(["key": .string("terminal.cwd")])
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
            if request.path.hasSuffix("/scope") { onScope?() }
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
