import Foundation
import Testing
@testable import Bighelp

/// Turning a plugin off or removing it waited for the whole catalog (900 and more plugins, a few
/// megabytes) to be read twice, and Plugins read it all again on every visit.
@MainActor
struct PluginChangeSpeedTests {
    @Test func turningAPluginOffReadsOnlyTheInstalledList() async throws {
        let host = PluginHost()
        let model = PluginLifecycleManagementModel(client: host.client())
        await model.load()

        await model.setEnabled(false, plugin: try #require(model.snapshot?.installed.first))

        #expect(model.snapshot?.installed.first?.isEnabled == false)
        #expect(model.errorMessage == nil)
        #expect(host.reads["/api/dashboard/plugins/catalog"] == 1)
    }

    @Test func removingAPluginDoesNotWaitForTheCatalog() async throws {
        let host = PluginHost()
        let model = PluginLifecycleManagementModel(client: host.client())
        await model.load()
        let start = host.log.count

        await model.remove(try #require(model.snapshot?.installed.first))

        let beforeDelete = host.log[start...].prefix { !$0.hasPrefix("DELETE") }
        #expect(!beforeDelete.contains("GET /api/dashboard/plugins/catalog"))
        #expect(model.snapshot?.installed.isEmpty == true)
        #expect(model.isBusy == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func pluginsOpenOnTheKeptCopyAndATurnOffIsNotRefusedWhileItUpdates() async throws {
        let host = PluginHost()
        let kept = CapabilitiesKeptCopies()
        let first = PluginLifecycleManagementModel(client: host.client(), keptCopies: kept)
        await first.load()

        host.holdCatalog = true
        let second = PluginLifecycleManagementModel(client: host.client(), keptCopies: kept)
        #expect(second.snapshot?.catalog.map(\.name) == ["notes"])
        let refresh = Task { await second.load() }
        while host.reads["/api/dashboard/plugins/catalog"] != 2 { await Task.yield() }
        #expect(second.isBusy == false)

        await second.setEnabled(false, plugin: try #require(second.snapshot?.installed.first))
        #expect(second.snapshot?.installed.first?.isEnabled == false)

        host.holdCatalog = false
        await refresh.value
        // The read that started before the change doesn't put the old list back.
        #expect(second.snapshot?.installed.first?.isEnabled == false)
    }
}

/// One installed, removable plugin and a one-row catalog, answered like Hermes' dashboard.
/// `holdCatalog` keeps catalog reads waiting until it's cleared.
@MainActor
private final class PluginHost: DirectHermesAuthenticatedHTTP {
    private(set) var reads: [String: Int] = [:]
    private(set) var log: [String] = []
    var holdCatalog = false
    private var runtime = "enabled"
    private var installed = true
    private let owner = WorkspaceOwner(authority: try! .fixture(id: "plugin-change-speed"),
                                       authenticationGeneration: UUID(), connectionGeneration: UUID())

    func client() -> DirectHermesPluginLifecycleClient {
        let owner = owner
        return DirectHermesPluginLifecycleClient(http: self, owner: owner, currentOwner: { owner })
    }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        reads[request.path, default: 0] += 1
        log.append("\(request.method.rawValue) \(request.path)")
        switch (request.method, request.path) {
        case (.get, "/api/dashboard/plugins/hub"):
            return .object(["plugins": .array(installed ? [plugin] : [])])
        case (.get, "/api/dashboard/plugins/catalog"):
            while holdCatalog { try await Task.sleep(for: .milliseconds(5)) }
            return .object(["entries": .array([catalogRow]), "removed": .array([])])
        case (.post, "/api/dashboard/agent-plugins/notes/disable"):
            runtime = "disabled"
            return .object(["ok": .boolean(true)])
        case (.delete, "/api/dashboard/agent-plugins/notes"):
            installed = false
            return .object(["ok": .boolean(true)])
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }

    private var plugin: BighelpJSONValue {
        .object([
            "name": .string("notes"), "version": .string("1.0.0"), "description": .string("Keeps notes."),
            "source": .string("user"), "runtime_status": .string(runtime), "can_remove": .boolean(true),
            "can_update_git": .boolean(false), "auth_required": .boolean(false), "auth_command": .string(""),
            "removed_reason": .null,
        ])
    }

    private var catalogRow: BighelpJSONValue {
        .object([
            "name": .string("notes"), "repo": .string("https://example.com/notes"),
            "sha": .string(String(repeating: "c", count: 40)), "description": .string("Keeps notes."),
            "maintainer": .string("Example"), "tier": .string("official"), "docs_url": .string(""),
            "requires_hermes": .string(""), "platforms": .array([]),
            "capabilities": .object([
                "provides_tools": .array([]), "provides_hooks": .array([]),
                "provides_middleware": .array([]), "requires_env": .array([]),
            ]),
            "installed": .boolean(installed), "update_available": .boolean(false),
        ])
    }
}
