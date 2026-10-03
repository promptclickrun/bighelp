import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesManagedFilesTests {
    @Test func hostConfiguredRootIsDiscoveredWithoutLiteralFallback() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        http.result = listing(root: http.root)
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { owner })
        let result = try await client.list()
        #expect(result.path == http.root)
        #expect(result.parent == nil)
        #expect(result.files.map(\.path) == [http.root + "/result.txt"])
        #expect(http.requests.first?.path == "/api/plugins/loopdy/native/context")
        #expect(http.requests.contains { $0.path == "/api/plugins/loopdy/native/workspace-files/list" })
        #expect(!http.requests.contains { $0.path.hasPrefix("/api/files") || $0.path == "/api/fs/default-cwd" })
        #expect(!http.requests.contains { $0.query.contains { $0.value == "/workspace" } })
    }

    @Test func traversalAndForeignRootsNeverReadTheirFileContents() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        let scope = try DirectHermesWorkspaceFileScope.fixture(root: http.root, owner: owner)
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, scope: scope, currentOwner: { owner })
        for path in ["/", http.root + "/../private", http.root + "-other", http.root + "//folder"] {
            await #expect(throws: (any Error).self) { _ = try await client.list(path: path) }
        }
        #expect(http.requests.allSatisfy { $0.path == "/api/plugins/loopdy/native/context" || $0.path == "/api/plugins/loopdy/native/workspace-files/scope" })
    }

    @Test func wrongOwnerNeverReadsAndLateOwnerCannotPublish() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        var current: WorkspaceOwner? = nil
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { current })
        await #expect(throws: (any Error).self) { _ = try await client.list() }
        #expect(http.requests.isEmpty)
        current = owner
        http.onRequest = { current = nil }
        await #expect(throws: (any Error).self) { _ = try await client.list() }
        #expect(http.requests.count == 1)
    }

    @Test func listingCannotSmuggleOutsideWorkspaceEntries() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        http.result = listing(root: http.root, filePath: "/private/result.txt")
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: (any Error).self) { _ = try await client.list() }
    }

    @Test func posixScopeDoesNotMergeUnicodeEquivalentPaths() throws {
        let owner = try makeOwner()
        let scope = try DirectHermesWorkspaceFileScope.fixture(root: "/srv/caf\u{e9}", owner: owner)
        #expect(scope.contains("/srv/caf\u{e9}/file.txt"))
        #expect(!scope.contains("/srv/cafe\u{301}/file.txt"))
        #expect(!DirectHermesWorkspaceFileScope.samePath("/srv/caf\u{e9}", "/srv/cafe\u{301}"))
    }

    @Test func changedDefaultWorkspaceRevokesOldListingScope() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        http.result = listing(root: http.root)
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { owner })
        _ = try await client.workspaceScope()
        http.requests.removeAll()
        http.cwdResponse = .object(["cwd": .string("/srv/replacement"), "branch": .string("")])
        await #expect(throws: DirectHermesManagedFilesError.scopeChanged) { _ = try await client.list() }
        #expect(http.requests.allSatisfy { $0.path == "/api/plugins/loopdy/native/context" || $0.path == "/api/plugins/loopdy/native/workspace-files/scope" })
    }

    @Test func missingDefaultWorkspaceDoesNotFallBackToAnyRoot() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        http.cwdResponse = .object(["branch": .string("")])
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: (any Error).self) { _ = try await client.list() }
        #expect(http.requests.count == 2)
        #expect(http.requests.last?.path == "/api/plugins/loopdy/native/workspace-files/scope")
    }

    /// The host says why it can't share files (here: no working folder of its own);
    /// people see that reason, not "did not prove a workspace".
    @Test func hostsReasonForNoWorkspaceReachesPeople() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        http.refusal = (409, "workspace_not_configured",
                        "Set an absolute terminal.cwd for this profile before opening workspace files.")
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { owner })
        do {
            _ = try await client.workspaceScope()
            Issue.record("The host refused, so there is no scope")
        } catch {
            #expect(error as? WorkspaceClientError == .rejected(code: "workspace_not_configured"))
            #expect(error.localizedDescription.contains("no working folder"))
            #expect(ConfiguredWorkspaceArtifactsView.message(for: error).contains("no working folder"))
        }
    }

    /// Each reason the plugin can't share an agent's files is said plainly, not
    /// as "the host changed" or "update the plugin".
    @Test(arguments: [
        (409, "workspace_in_container", "inside a container"),
        (409, "workspace_on_remote", "another computer"),
        (501, "workspace_windows_unsupported", "Windows"),
        (409, "workspace_hermes_folder", "Hermes's own folder"),
        (409, "workspace_not_configured", "working folder of its own"),
    ])
    func hostsReasonsForFilesItCantShareReachPeople(status: Int, code: String, wording: String) async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        http.refusal = (status, code, "The plugin's own wording.")
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { owner })
        do {
            _ = try await client.workspaceScope()
            Issue.record("The host refused, so there is no scope")
        } catch {
            #expect(error as? WorkspaceClientError == .rejected(code: code))
            #expect(ConfiguredWorkspaceArtifactsView.message(for: error).contains(wording))
            #expect(!ConfiguredWorkspaceArtifactsView.message(for: error).contains("Update it"))
        }
    }

    /// The plugin reports the folder Hermes itself gives the agent when no
    /// terminal.cwd is set, and says so in `origin`.
    @Test func hermesDefaultWorkingFolderIsAccepted() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        http.origin = "default"
        http.result = listing(root: http.root)
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { owner })
        #expect(try await client.workspaceScope().root == http.root)
        #expect(try await client.list().files.map(\.name) == ["result.txt"])
    }

    /// An older plugin without workspace files reads as "update the plugin".
    @Test func pluginWithoutWorkspaceFilesSaysToUpdate() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        http.sharesWorkspaceFiles = false
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { owner })
        do {
            _ = try await client.workspaceScope()
            Issue.record("The plugin can't share files, so there is no scope")
        } catch {
            #expect(error as? WorkspaceClientError == .unavailable(.unsupportedOperation))
            #expect(ConfiguredWorkspaceArtifactsView.message(for: error).contains("Update it"))
        }
    }

    @Test func driveRootAndLockedBroaderRootKeepWorkspaceBoundary() throws {
        let owner = try makeOwner()
        let windows = try DirectHermesWorkspaceFileScope.fixture(root: "C:\\", owner: owner)
        #expect(windows.contains("c:\\folder\\file.txt"))
        #expect(!windows.contains("D:\\folder\\file.txt"))
        let locked = try DirectHermesWorkspaceFileScope.fixture(root: "/opt/data/project", owner: owner, lockedManagedRoot: "/opt/data")
        #expect(locked.contains("/opt/data/project/file"))
        #expect(!locked.contains("/opt/data/other"))
        #expect(throws: DirectHermesManagedFilesError.self) { try locked.parent(of: locked.root) }
    }

    private func makeOwner() throws -> WorkspaceOwner {
        WorkspaceOwner(authority: try .direct(endpointIdentity: "https://fixture.example.test", providerID: "test", userID: "files"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    private func listing(root: String, filePath: String? = nil) -> BighelpJSONValue {
        .object(["path": .string(root), "parent": .string("/srv/team"), "can_change_path": .boolean(true),
            "root": .null, "locked_root": .null, "entries": .array([
                .object(["name": .string("result.txt"), "path": .string(filePath ?? root + "/result.txt"), "is_directory": .boolean(false),
                    "size": .integer(3), "mtime": .integer(1), "mime_type": .string("text/plain")])
            ])])
    }
}

@MainActor
private final class ManagedFilesTestHTTP: DirectHermesAuthenticatedHTTP, DirectHermesNativeHTTP {
    let root = "/srv/team/project"
    var requests: [DirectHermesHTTPRequest] = []
    var result: BighelpJSONValue = .object([:])
    var cwdResponse: BighelpJSONValue?
    var refusal: (status: Int, code: String, message: String)?
    var sharesWorkspaceFiles = true
    /// How the plugin found the folder; older plugins send no origin.
    var origin: String?
    var onRequest: (@MainActor () -> Void)?
    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        requests.append(request)
        throw WorkspaceClientError.invalidRequest
    }
    func nativeResponse(_ request: DirectHermesHTTPRequest,
                        requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response {
        requests.append(request)
        onRequest?()
        let etag = "\"sha256:" + String(repeating: "a", count: 64) + "\""
        var headers = ["ETag": etag, "Cache-Control": "no-store"]
        var object: [String: BighelpJSONValue]
        if request.path == "/api/plugins/loopdy/native/context" {
            object = ["schemaVersion": .integer(1), "pluginVersion": .string("test"),
                "runtimeId": .string("fixture-runtime"), "servingProfileId": .string("default"),
                "principal": .object(["provider": .string("test"), "userId": .string("files"), "displayName": .null]),
                "features": .array([.string("native-context-v1"), .string("serving-profile-v1")]
                    + (sharesWorkspaceFiles ? [.string("native-workspace-files-v1")] : []))]
        } else if let refusal {
            // The plugin's own error reply, as Hermes sends it.
            object = ["error": .object(["code": .string(refusal.code), "message": .string(refusal.message),
                                        "retryable": .boolean(false), "details": .object([:])])]
            let url = try #require(URL(string: "https://fixture.example.test" + request.path))
            let response = try #require(HTTPURLResponse(url: url, statusCode: refusal.status, httpVersion: "HTTP/1.1",
                                                        headerFields: ["Cache-Control": "no-store"]))
            return .init(http: response, body: try JSONEncoder().encode(BighelpJSONValue.object(object)))
        } else {
            let guardValue = try #require(requestGuard)
            headers["X-Loopdy-Request-ID"] = guardValue.requestIDHeader
            let configured: String
            if let cwdResponse {
                guard let value = cwdResponse.object?["cwd"]?.string else { throw WorkspaceClientError.invalidResponse }
                configured = value
            } else { configured = root }
            object = request.path.hasSuffix("/list") ? result.object ?? [:] : ["entries": .array([])]
            var workspace: [String: BighelpJSONValue] = ["root": .string(configured), "source": .string("terminal.cwd"),
                                                         "profileId": .string("default")]
            if let origin { workspace["origin"] = .string(origin) }
            object["workspace"] = .object(workspace)
            object["path"] = .string(configured)
            object["root"] = .string(configured)
            object["locked_root"] = .string(configured)
            object["can_change_path"] = .boolean(false)
            object["parent"] = .null
        }
        let url = try #require(URL(string: "https://fixture.example.test" + request.path))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers))
        return .init(http: response, body: try JSONEncoder().encode(BighelpJSONValue.object(object)))
    }
}
