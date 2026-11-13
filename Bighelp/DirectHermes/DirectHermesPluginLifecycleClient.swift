import Foundation

/// Explicit, user-selected plugin lifecycle over Hermes' curated catalog and
/// installed-plugin hub. It never bootstraps or automatically installs bighelp.
@MainActor
final class DirectHermesPluginLifecycleClient: PluginLifecycleManagementClient {
    let owner: WorkspaceOwner

    private let http: any DirectHermesAuthenticatedHTTP
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private let marketplace: (any PluginMarketplaceReading)?

    /// `marketplace` adds Hermes' marketplace facts (stars, featured picks, install refusals) to the
    /// catalog; without it the storefront goes by the catalog alone.
    init(
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        marketplace: (any PluginMarketplaceReading)? = nil
    ) {
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
        self.marketplace = marketplace
    }

    func load() async throws -> PluginSnapshot {
        async let facts = marketplace?.plugins()
        let snapshot = try await loadCatalog()
        guard let facts = await facts, !facts.isEmpty else { return snapshot }
        try requireOwner()
        return PluginSnapshot(
            installed: snapshot.installed,
            catalog: snapshot.catalog.map { entry in
                var entry = entry
                entry.marketplace = facts[entry.name] ?? PluginMarketplaceFacts()
                return entry
            },
            removedCatalogEntries: snapshot.removedCatalogEntries, skippedCatalogRows: snapshot.skippedCatalogRows)
    }

    /// The host's lists alone, for the reads an install checks itself against.
    private func loadCatalog() async throws -> PluginSnapshot {
        async let installedValue = loadInstalled()
        async let catalogValue = request(.catalog)
        let installed = try await installedValue
        let catalog = try await catalogValue
        // Hermes lists 900 and more catalog plugins: their rows are read off the main actor.
        let (entries, removed, skipped) = try await Task.detached(priority: .userInitiated) {
            try Self.decodeCatalogPage(catalog)
        }.value
        try requireOwner()
        return PluginSnapshot(installed: installed, catalog: entries, removedCatalogEntries: removed,
                              skippedCatalogRows: skipped)
    }

    /// The installed plugins alone (the hub), a small read next to the catalog.
    func loadInstalled() async throws -> [InstalledPlugin] {
        try CapabilitiesPayload.rows(try await request(.hub)["plugins"], Self.decodeInstalled)
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
        let before = try await loadCatalog()
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
        let after = try await loadCatalog()
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
        guard let plugin = try await loadInstalled().first(where: { $0.name == name }),
              plugin.isEnabled == enabled else { throw CapabilitiesManagementError.readbackFailed }
        return plugin
    }

    /// Hermes may stop before changing anything and ask: a new catalog pin that adds tools or hooks, or a
    /// security scan with findings. Its question comes back as `.asks`, and the same update with the
    /// person's yes in `approvals` applies it.
    func update(pluginName: String, approvals: Set<PluginUpdateApproval>) async throws -> PluginUpdateResult {
        let name = try pluginNameValue(pluginName)
        guard let plugin = try await loadInstalled().first(where: { $0.name == name }), plugin.canUpdate else {
            throw CapabilitiesManagementError.invalidRequest
        }
        let payload = try await request(.update(name: name, approvals: approvals))
        guard payload["ok"]?.boolean == true else {
            if let question = Self.updateQuestion(payload, pluginName: name) { return .asks(question) }
            if let words = HermesRefusalMessage(payload["error"]?.string).sentence {
                throw CapabilitiesManagementError.rejected(words)
            }
            throw CapabilitiesManagementError.invalidResponse
        }
        guard let readback = try await loadInstalled().first(where: { $0.name == name }) else {
            throw CapabilitiesManagementError.readbackFailed
        }
        return .updated(readback)
    }

    func remove(pluginName: String) async throws {
        let name = try pluginNameValue(pluginName)
        guard try await loadInstalled().contains(where: { $0.name == name && $0.canRemove }) else {
            throw CapabilitiesManagementError.invalidRequest
        }
        let payload = try await request(.remove(name: name))
        guard payload["ok"]?.boolean == true else { throw CapabilitiesManagementError.invalidResponse }
        let readback = try await request(.hub)
        guard try !CapabilitiesPayload.listsName(name, in: readback["plugins"]) else {
            throw CapabilitiesManagementError.readbackFailed
        }
    }

    private enum Route {
        case hub, catalog, rescan
        case install(body: [String: BighelpJSONValue])
        case enable(name: String), disable(name: String), remove(name: String)
        case update(name: String, approvals: Set<PluginUpdateApproval>)

        var isCapabilityProbe: Bool {
            switch self {
            case .hub, .catalog: true
            default: false
            }
        }

        @MainActor var request: DirectHermesHTTPRequest {
            // Hermes rebuilds the plugin list when it's read; a busy host took 26
            // seconds, past an ordinary request's wait.
            let listTimeout = DirectHermesHTTP.longestRequestSeconds
            switch self {
            case .hub:
                return DirectHermesHTTPRequest(path: "/api/dashboard/plugins/hub", method: .get, timeout: listTimeout)
            case .catalog:
                return DirectHermesHTTPRequest(path: "/api/dashboard/plugins/catalog", method: .get, timeout: listTimeout)
            case .rescan:
                return DirectHermesHTTPRequest(path: "/api/dashboard/plugins/rescan", method: .get, timeout: listTimeout)
            case .install(let body):
                return DirectHermesHTTPRequest(path: "/api/dashboard/agent-plugins/install", method: .post, body: body)
            case .enable(let name):
                return DirectHermesHTTPRequest(path: "/api/dashboard/agent-plugins/\(name)/enable", method: .post)
            case .disable(let name):
                return DirectHermesHTTPRequest(path: "/api/dashboard/agent-plugins/\(name)/disable", method: .post)
            case .update(let name, let approvals):
                // Hermes' answers to its own questions: `consent_required` and a caution `scan_blocked`.
                var body: [String: BighelpJSONValue] = [:]
                if approvals.contains(.capabilities) { body["accept_capabilities"] = .boolean(true) }
                if approvals.contains(.scanFindings) { body["force"] = .boolean(true) }
                return DirectHermesHTTPRequest(path: "/api/dashboard/agent-plugins/\(name)/update", method: .post,
                                               body: body.isEmpty ? nil : body)
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
            throw CapabilitiesManagementError.unsupportedHost("This Hermes computer does not expose plugin lifecycle management.")
        } catch DirectHermesError.unsupportedAuthentication {
            throw CapabilitiesManagementError.invalidResponse
        } catch DirectHermesError.rpcRejected(_, let message) {
            // Hermes' reason for a refused install or update (`DirectHermesHTTP.pluginChangeRefusal`).
            throw CapabilitiesManagementError.rejected(message.sentence ?? "Hermes refused this plugin change.")
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

    private nonisolated static func decodeCatalogPage(
        _ catalog: [String: BighelpJSONValue]
    ) throws -> (entries: [PluginCatalogEntry], removed: [String], skipped: Int) {
        let rows = try CapabilitiesPayload.array(catalog["entries"])
        // A name is a row's identity on screen; a second row with the same name is left out.
        var names = Set<String>()
        let entries = rows.compactMap { try? decodeCatalog($0) }.filter { names.insert($0.name).inserted }
        let removed = try CapabilitiesPayload.rows(catalog["removed"]) { value -> String in
            let row = try CapabilitiesPayload.object(value)
            let name = try CapabilitiesPayload.text(row["name"], maximumBytes: 160)
            let reason = try CapabilitiesPayload.text(row["reason"], maximumBytes: 2_048, required: false)
            return reason.isEmpty ? name : "\(name): \(reason)"
        }
        return (entries, removed, rows.count - entries.count)
    }

    private nonisolated static func decodeInstalled(_ value: BighelpJSONValue) throws -> InstalledPlugin {
        let row = try CapabilitiesPayload.object(value)
        let runtime = try CapabilitiesPayload.text(row["runtime_status"], maximumBytes: 32)
        guard ["enabled", "disabled", "inactive"].contains(runtime) else {
            throw CapabilitiesManagementError.invalidResponse
        }
        return InstalledPlugin(
            name: try CapabilitiesPayload.text(row["name"], maximumBytes: 320),
            version: try CapabilitiesPayload.text(row["version"], maximumBytes: 128, required: false),
            summary: try CapabilitiesPayload.summary(row["description"]),
            source: try CapabilitiesPayload.text(row["source"], maximumBytes: 80),
            runtimeStatus: runtime,
            canRemove: try CapabilitiesPayload.boolean(row["can_remove"]),
            canUpdate: try CapabilitiesPayload.boolean(row["can_update_git"]),
            requiresAuthentication: try CapabilitiesPayload.boolean(row["auth_required"]),
            authenticationCommand: try CapabilitiesPayload.text(row["auth_command"], maximumBytes: 2_048, required: false),
            removedReason: try CapabilitiesPayload.optionalText(row["removed_reason"], maximumBytes: 2_048)
        )
    }

    private nonisolated static func decodeCatalog(_ value: BighelpJSONValue) throws -> PluginCatalogEntry {
        let row = try CapabilitiesPayload.object(value)
        let capabilities = try CapabilitiesPayload.object(row["capabilities"])
        let sha = try CapabilitiesPayload.text(row["sha"], maximumBytes: 40)
        guard sha.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else {
            throw CapabilitiesManagementError.invalidResponse
        }
        return PluginCatalogEntry(
            name: try CapabilitiesPayload.text(row["name"], maximumBytes: 64),
            repository: try CapabilitiesPayload.text(row["repo"], maximumBytes: 4_096),
            commitSHA: sha.lowercased(),
            summary: try CapabilitiesPayload.summary(row["description"]),
            maintainer: try CapabilitiesPayload.text(row["maintainer"], maximumBytes: 256),
            tier: try CapabilitiesPayload.text(row["tier"], maximumBytes: 64),
            requiredHermesVersion: try CapabilitiesPayload.text(row["requires_hermes"], maximumBytes: 128, required: false),
            documentationURL: Self.httpsURL(row["docs_url"]),
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
            removedReason: nil,
            title: Self.label(row["title"], maximumBytes: 160),
            category: Self.label(row["category"], maximumBytes: 64)?.lowercased(),
            imageURL: Self.httpsURL(row["image"]),
            screenshotURLs: Array((row["screenshots"]?.array ?? []).compactMap(Self.httpsURL).prefix(12)),
            version: Self.label(row["version"], maximumBytes: 64),
            knownIssues: Self.knownIssues(row["known_issues"])
        )
    }

    /// Hermes' question in an update it didn't make: the parts a new pin adds, or its scan's findings.
    nonisolated static func updateQuestion(_ payload: [String: BighelpJSONValue],
                                           pluginName: String) -> PluginUpdateQuestion? {
        let message = HermesRefusalMessage(payload["error"]?.string)
        if payload["consent_required"]?.boolean == true {
            var lines = (payload["delta_lines"]?.array ?? []).compactMap { label($0, maximumBytes: 2_048) }
            if lines.isEmpty, let delta = payload["delta"]?.object {
                lines = delta.keys.sorted().compactMap { surface in
                    let names = (delta[surface]?.array ?? []).compactMap { label($0, maximumBytes: 256) }
                    return names.isEmpty ? nil : "\(surface): \(names.prefix(50).joined(separator: ", "))"
                }
            }
            return PluginUpdateQuestion(pluginName: pluginName, kind: .addsCapabilities,
                                        additions: Array(lines.prefix(20)), findings: [], message: message)
        }
        if payload["scan_blocked"]?.boolean == true {
            let findings = (payload["scan_findings"]?.array ?? []).prefix(100).compactMap(Self.scanFinding)
            // Only a caution verdict can be applied anyway; anything else stays blocked.
            let kind: PluginUpdateQuestion.Kind = payload["scan_verdict"]?.string == "caution" ? .scanCaution : .scanBlocked
            return PluginUpdateQuestion(pluginName: pluginName, kind: kind, additions: [],
                                        findings: Array(findings), message: message)
        }
        return nil
    }

    private nonisolated static func scanFinding(_ value: BighelpJSONValue) -> SkillHubScanFinding? {
        guard let row = value.object, let severity = label(row["severity"], maximumBytes: 32),
              let detail = label(row["description"], maximumBytes: 8_192) else { return nil }
        let line = row["line"]?.integer.flatMap { (0...10_000_000).contains($0) ? $0 : nil }
        return SkillHubScanFinding(severity: severity, category: label(row["category"], maximumBytes: 128) ?? "",
                                   file: label(row["file"], maximumBytes: 4_096) ?? "", line: line, detail: detail)
    }

    // The storefront's fields are display-only: a missing or odd value is nil, never a refused row.

    /// An https address with a host, else nil.
    private nonisolated static func httpsURL(_ value: BighelpJSONValue?) -> URL? {
        guard let raw = value?.string, raw.utf8.count <= 4_096, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.host() != nil else { return nil }
        return url
    }

    /// Short text, trimmed; nil when missing, empty or too long.
    private nonisolated static func label(_ value: BighelpJSONValue?, maximumBytes: Int) -> String? {
        guard let value = (try? CapabilitiesPayload.optionalText(value, maximumBytes: maximumBytes)) ?? nil else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `known_issues` comes as one string or a list of them.
    private nonisolated static func knownIssues(_ value: BighelpJSONValue?) -> [String] {
        let values = value?.array ?? (value.map { [$0] } ?? [])
        return Array(values.compactMap { label($0, maximumBytes: 2_048) }.prefix(10))
    }
}
