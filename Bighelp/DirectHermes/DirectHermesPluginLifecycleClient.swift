import Foundation

/// Explicit, user-selected plugin lifecycle over Hermes' curated catalog and
/// installed-plugin hub. It never bootstraps or automatically installs bighelp.
@MainActor
final class DirectHermesPluginLifecycleClient: PluginLifecycleManagementClient {
    let owner: WorkspaceOwner

    private let http: any DirectHermesAuthenticatedHTTP
    private let currentOwner: @MainActor () -> WorkspaceOwner?

    init(
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func load() async throws -> PluginSnapshot {
        async let hubValue = request(.hub)
        async let catalogValue = request(.catalog)
        let hub = try await hubValue
        let catalog = try await catalogValue
        let installed = try CapabilitiesPayload.array(hub["plugins"]).map(decodeInstalled)
        let entries = try CapabilitiesPayload.array(catalog["entries"]).map(decodeCatalog)
        let removed = try CapabilitiesPayload.array(catalog["removed"]).map { value -> String in
            let row = try CapabilitiesPayload.object(value)
            let name = try CapabilitiesPayload.text(row["name"], maximumBytes: 160)
            let reason = try CapabilitiesPayload.text(row["reason"], maximumBytes: 2_048, required: false)
            return reason.isEmpty ? name : "\(name): \(reason)"
        }
        return PluginSnapshot(installed: installed, catalog: entries, removedCatalogEntries: removed)
    }

    func rescan() async throws -> PluginSnapshot {
        let payload = try await request(.rescan)
        guard payload["ok"]?.boolean == true,
              let count = payload["count"]?.integer, count >= 0, count <= 10_000 else {
            throw CapabilitiesManagementError.invalidResponse
        }
        return try await load()
    }

    func installCatalog(name: String, expectedCommitSHA: String) async throws -> InstalledPlugin {
        let name = try CapabilitiesPayload.identifier(name, maximumBytes: 64)
        let expectedCommitSHA = try commit(expectedCommitSHA)
        let before = try await load()
        guard let entry = before.catalog.first(where: { $0.name == name }),
              entry.commitSHA == expectedCommitSHA, !entry.isInstalled, entry.removedReason == nil else {
            throw CapabilitiesManagementError.invalidRequest
        }
        let payload = try await request(.install(body: [
            "identifier": .string(""),
            "catalog_name": .string(name),
            "force": .boolean(false),
            "enable": .boolean(true),
            "ref": .string(expectedCommitSHA),
        ]))
        guard payload["ok"]?.boolean == true else { throw CapabilitiesManagementError.invalidResponse }
        let after = try await load()
        guard let catalogReadback = after.catalog.first(where: { $0.name == name }),
              catalogReadback.isInstalled, catalogReadback.commitSHA == expectedCommitSHA,
              catalogReadback.runtimeStatus == "enabled" else {
            throw CapabilitiesManagementError.readbackFailed
        }
        let oldNames = Set(before.installed.map(\.name))
        let newlyInstalled = after.installed.filter { !oldNames.contains($0.name) }
        guard let installed = after.installed.first(where: { $0.name == name })
                ?? (newlyInstalled.count == 1 ? newlyInstalled[0] : nil),
              installed.isEnabled else { throw CapabilitiesManagementError.readbackFailed }
        return installed
    }

    func setEnabled(_ enabled: Bool, pluginName: String) async throws -> InstalledPlugin {
        let name = try pluginNameValue(pluginName)
        let route: Route = enabled ? .enable(name: name) : .disable(name: name)
        let payload = try await request(route)
        guard payload["ok"]?.boolean == true else { throw CapabilitiesManagementError.invalidResponse }
        guard let plugin = try await load().installed.first(where: { $0.name == name }),
              plugin.isEnabled == enabled else { throw CapabilitiesManagementError.readbackFailed }
        return plugin
    }

    func update(pluginName: String) async throws -> InstalledPlugin {
        let name = try pluginNameValue(pluginName)
        let before = try await load()
        guard let plugin = before.installed.first(where: { $0.name == name }), plugin.canUpdate else {
            throw CapabilitiesManagementError.invalidRequest
        }
        let payload = try await request(.update(name: name))
        guard payload["ok"]?.boolean == true else { throw CapabilitiesManagementError.invalidResponse }
        guard let readback = try await load().installed.first(where: { $0.name == name }) else {
            throw CapabilitiesManagementError.readbackFailed
        }
        return readback
    }

    func remove(pluginName: String) async throws {
        let name = try pluginNameValue(pluginName)
        let before = try await load()
        guard before.installed.contains(where: { $0.name == name && $0.canRemove }) else {
            throw CapabilitiesManagementError.invalidRequest
        }
        let payload = try await request(.remove(name: name))
        guard payload["ok"]?.boolean == true else { throw CapabilitiesManagementError.invalidResponse }
        guard try await load().installed.allSatisfy({ $0.name != name }) else {
            throw CapabilitiesManagementError.readbackFailed
        }
    }

    private enum Route {
        case hub, catalog, rescan
        case install(body: [String: BighelpJSONValue])
        case enable(name: String), disable(name: String), update(name: String), remove(name: String)

        var isCapabilityProbe: Bool {
            switch self {
            case .hub, .catalog: true
            default: false
            }
        }

        var request: DirectHermesHTTPRequest {
            switch self {
            case .hub:
                return DirectHermesHTTPRequest(path: "/api/dashboard/plugins/hub", method: .get)
            case .catalog:
                return DirectHermesHTTPRequest(path: "/api/dashboard/plugins/catalog", method: .get)
            case .rescan:
                return DirectHermesHTTPRequest(path: "/api/dashboard/plugins/rescan", method: .get)
            case .install(let body):
                return DirectHermesHTTPRequest(path: "/api/dashboard/agent-plugins/install", method: .post, body: body)
            case .enable(let name):
                return DirectHermesHTTPRequest(path: "/api/dashboard/agent-plugins/\(name)/enable", method: .post)
            case .disable(let name):
                return DirectHermesHTTPRequest(path: "/api/dashboard/agent-plugins/\(name)/disable", method: .post)
            case .update(let name):
                return DirectHermesHTTPRequest(path: "/api/dashboard/agent-plugins/\(name)/update", method: .post)
            case .remove(let name):
                return DirectHermesHTTPRequest(path: "/api/dashboard/agent-plugins/\(name)", method: .delete)
            }
        }
    }

    private func request(_ route: Route) async throws -> [String: BighelpJSONValue] {
        try requireOwner()
        do {
            let value = try await http.request(route.request)
            try requireOwner()
            return try CapabilitiesPayload.object(value)
        } catch DirectHermesError.unsupportedAuthentication where route.isCapabilityProbe {
            throw CapabilitiesManagementError.unsupportedHost("This Hermes host does not expose plugin lifecycle management.")
        } catch DirectHermesError.unsupportedAuthentication {
            throw CapabilitiesManagementError.invalidResponse
        }
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard currentOwner() == owner else { throw CapabilitiesManagementError.staleOwner }
    }

    private func pluginNameValue(_ value: String) throws -> String {
        try CapabilitiesPayload.identifier(value, maximumBytes: 320, allowsSlash: true)
    }

    private func commit(_ value: String) throws -> String {
        let value = value.lowercased()
        guard value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw CapabilitiesManagementError.invalidRequest
        }
        return value
    }

    private func decodeInstalled(_ value: BighelpJSONValue) throws -> InstalledPlugin {
        let row = try CapabilitiesPayload.object(value)
        let runtime = try CapabilitiesPayload.text(row["runtime_status"], maximumBytes: 32)
        guard ["enabled", "disabled", "inactive"].contains(runtime) else {
            throw CapabilitiesManagementError.invalidResponse
        }
        return InstalledPlugin(
            name: try CapabilitiesPayload.text(row["name"], maximumBytes: 320),
            version: try CapabilitiesPayload.text(row["version"], maximumBytes: 128, required: false),
            summary: try CapabilitiesPayload.text(row["description"], maximumBytes: 8_192, required: false),
            source: try CapabilitiesPayload.text(row["source"], maximumBytes: 80),
            runtimeStatus: runtime,
            canRemove: try CapabilitiesPayload.boolean(row["can_remove"]),
            canUpdate: try CapabilitiesPayload.boolean(row["can_update_git"]),
            requiresAuthentication: try CapabilitiesPayload.boolean(row["auth_required"]),
            authenticationCommand: try CapabilitiesPayload.text(row["auth_command"], maximumBytes: 2_048, required: false),
            removedReason: try CapabilitiesPayload.optionalText(row["removed_reason"], maximumBytes: 2_048)
        )
    }

    private func decodeCatalog(_ value: BighelpJSONValue) throws -> PluginCatalogEntry {
        let row = try CapabilitiesPayload.object(value)
        let capabilities = try CapabilitiesPayload.object(row["capabilities"])
        let rawURL = try CapabilitiesPayload.text(row["docs_url"], maximumBytes: 4_096, required: false)
        let documentationURL: URL?
        if rawURL.isEmpty { documentationURL = nil }
        else {
            guard let url = URL(string: rawURL), url.scheme?.lowercased() == "https", url.host != nil else {
                throw CapabilitiesManagementError.invalidResponse
            }
            documentationURL = url
        }
        let sha = try CapabilitiesPayload.text(row["sha"], maximumBytes: 40)
        guard sha.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else {
            throw CapabilitiesManagementError.invalidResponse
        }
        return PluginCatalogEntry(
            name: try CapabilitiesPayload.text(row["name"], maximumBytes: 64),
            repository: try CapabilitiesPayload.text(row["repo"], maximumBytes: 4_096),
            commitSHA: sha.lowercased(),
            summary: try CapabilitiesPayload.text(row["description"], maximumBytes: 8_192, required: false),
            maintainer: try CapabilitiesPayload.text(row["maintainer"], maximumBytes: 256),
            tier: try CapabilitiesPayload.text(row["tier"], maximumBytes: 64),
            requiredHermesVersion: try CapabilitiesPayload.text(row["requires_hermes"], maximumBytes: 128, required: false),
            documentationURL: documentationURL,
            platforms: try CapabilitiesPayload.strings(row["platforms"]),
            capabilities: PluginCapabilitySummary(
                tools: try CapabilitiesPayload.strings(capabilities["provides_tools"]),
                hooks: try CapabilitiesPayload.strings(capabilities["provides_hooks"]),
                middleware: try CapabilitiesPayload.strings(capabilities["provides_middleware"]),
                requiredEnvironment: try CapabilitiesPayload.strings(capabilities["requires_env"])
            ),
            isInstalled: try CapabilitiesPayload.boolean(row["installed"]),
            installedSHA: try CapabilitiesPayload.optionalText(row["installed_sha"], maximumBytes: 40),
            updateAvailable: try CapabilitiesPayload.boolean(row["update_available"]),
            runtimeStatus: try CapabilitiesPayload.optionalText(row["runtime_status"], maximumBytes: 32),
            removedReason: nil
        )
    }
}
