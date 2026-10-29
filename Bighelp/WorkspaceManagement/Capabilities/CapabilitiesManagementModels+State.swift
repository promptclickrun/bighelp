import Foundation
import Observation

@MainActor
protocol CapabilitiesManagementState: AnyObject {
    var support: CapabilitiesHostSupport { get }
    var isBusy: Bool { get }
    var errorMessage: String? { get }
    var successMessage: String? { get }
    func clearMessages()
}

// Writable requirements stay file-local; consumers keep the read-only state contract.
@MainActor
private protocol CapabilityOperationState: CapabilitiesManagementState {
    var support: CapabilitiesHostSupport { get set }
    var isBusy: Bool { get set }
    var errorMessage: String? { get set }
    var successMessage: String? { get set }
    var requestFailureMessage: String { get }
}

private extension CapabilityOperationState {
    func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
            support = .available
        } catch is CancellationError {
        } catch let error as CapabilitiesManagementError {
            if case .unsupportedHost(let message) = error { support = .unavailable(message) }
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = requestFailureMessage
        }
    }
}

// Share mechanics, not storage: every model retains its own receipt and generation.
@MainActor
private protocol CapabilityActionTrackingState: CapabilityOperationState {
    var actionReceipt: CapabilityActionReceipt? { get set }
    var actionStatus: HermesHostActionStatus? { get set }
    var actionGeneration: UUID { get set }
    var actionStatusClient: (any HermesHostActionStatusClient)? { get }
    var isCurrentActionOwner: Bool { get }
}

private extension CapabilityActionTrackingState {
    func accept(
        _ result: CapabilityWriteResult,
        refresh: () async throws -> Void
    ) async throws {
        switch result {
        case .confirmed(let message):
            try await refresh()
            successMessage = message
        case .pending(let receipt, let message):
            await track(receipt, pendingMessage: message, refresh: refresh)
        }
    }

    func track(
        _ receipt: CapabilityActionReceipt,
        pendingMessage: String,
        attempts: Int = 30,
        refresh: () async throws -> Void
    ) async {
        actionReceipt = receipt
        actionStatus = nil
        let token = UUID()
        actionGeneration = token
        guard let actionStatusClient else {
            successMessage = CapabilityActionCopy.pending(receipt, message: pendingMessage, trackingAvailable: false)
            return
        }
        let hostReceipt: HermesHostActionReceipt
        do {
            hostReceipt = try receipt.hostReceipt(using: actionStatusClient)
        } catch {
            errorMessage = CapabilityActionCopy.untrackable(receipt)
            successMessage = nil
            return
        }
        actionStatus = CapabilityActionCopy.initialStatus(for: hostReceipt)
        successMessage = CapabilityActionCopy.pending(receipt, message: pendingMessage, trackingAvailable: true)
        do {
            let status = try await actionStatusClient.poll(hostReceipt, attempts: attempts)
            guard actionGeneration == token, isCurrentActionOwner, !Task.isCancelled else { return }
            actionStatus = status
            guard status.phase != .running else {
                successMessage = CapabilityActionCopy.stillRunning(status)
                return
            }
            do {
                try await refresh()
            } catch {
                guard actionGeneration == token, isCurrentActionOwner, !Task.isCancelled else { return }
                successMessage = nil
                errorMessage = CapabilityActionCopy.terminalReadbackFailed(status)
                return
            }
            guard actionGeneration == token, isCurrentActionOwner, !Task.isCancelled else { return }
            CapabilityActionCopy.publishTerminal(status, success: &successMessage, error: &errorMessage)
        } catch is CancellationError {
        } catch {
            guard actionGeneration == token, isCurrentActionOwner else { return }
            successMessage = nil
            errorMessage = CapabilityActionCopy.trackingFailed(receipt)
        }
    }
}

@MainActor @Observable
final class SkillsHubManagementModel: CapabilityActionTrackingState {
    struct Review: Identifiable, Equatable {
        let preview: SkillHubPreview
        let scan: SkillHubScan
        var id: String { preview.item.id }
    }

    fileprivate(set) var support: CapabilitiesHostSupport = .unknown
    private(set) var snapshot: SkillHubSnapshot?
    private(set) var searchResult: SkillHubSearchResult?
    private(set) var review: Review?
    fileprivate(set) var isBusy = false
    fileprivate(set) var errorMessage: String?
    fileprivate(set) var successMessage: String?
    fileprivate(set) var actionReceipt: CapabilityActionReceipt?
    fileprivate(set) var actionStatus: HermesHostActionStatus?
    var query = ""
    var source = "all"

    @ObservationIgnored private let client: any SkillsHubManagementClient
    @ObservationIgnored fileprivate let actionStatusClient: (any HermesHostActionStatusClient)?
    @ObservationIgnored fileprivate var actionGeneration = UUID()

    init(
        client: any SkillsHubManagementClient,
        actionStatusClient: (any HermesHostActionStatusClient)? = nil
    ) {
        self.client = client
        self.actionStatusClient = actionStatusClient ?? client.actionStatusClient
    }

    func load() async {
        await perform {
            if let receipt = actionReceipt, actionStatus?.phase == .running {
                await track(receipt, pendingMessage: "Refreshing the retained Skills Hub action.", attempts: 1) {
                    snapshot = try await client.load()
                }
            }
            snapshot = try await client.load()
        }
    }

    func search() async {
        let query = query
        let source = source
        await perform { searchResult = try await client.search(query: query, source: source) }
    }

    func clearSearch() {
        searchResult = nil
    }

    func inspect(_ item: SkillHubItem) async {
        await perform {
            async let previewValue = client.preview(identifier: item.id)
            async let scanValue = client.scan(identifier: item.id)
            let preview = try await previewValue
            let scan = try await scanValue
            review = Review(preview: preview, scan: scan)
        }
    }

    func setEnabled(_ enabled: Bool, skill: InstalledSkill) async {
        await perform {
            let confirmed = try await client.setEnabled(enabled, skillName: skill.name)
            guard let current = snapshot else { throw CapabilitiesManagementError.readbackFailed }
            var rows = current.installedSkills.filter { $0.name != confirmed.name }
            rows.append(confirmed)
            rows.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            snapshot = SkillHubSnapshot(
                sources: current.sources, featured: current.featured, official: current.official,
                installedSkills: rows, installedIdentifiers: current.installedIdentifiers,
                indexAvailable: current.indexAvailable
            )
            successMessage = "Hermes confirmed the skill is \(enabled ? "enabled" : "disabled")."
        }
    }

    func installReviewed() async {
        guard let review else { return }
        await perform {
            let result = try await client.install(identifier: review.id, preview: review.preview, scan: review.scan)
            self.review = nil
            try await accept(result) { snapshot = try await client.load() }
        }
    }

    func dismissReview() { review = nil }

    /// The newest copy of `item` the host listed (official, search results or featured), so a
    /// skill's page shows an install as soon as a refresh reports it.
    func latest(_ item: SkillHubItem) -> SkillHubItem {
        snapshot?.official.first { $0.id == item.id }
            ?? searchResult?.items.first { $0.id == item.id }
            ?? snapshot?.featured.first { $0.id == item.id }
            ?? item
    }

    /// A hub's name for a source ID.
    func sourceLabel(_ source: String) -> String {
        snapshot?.sources.first { $0.id == source }?.label ?? source
    }

    func uninstall(_ item: SkillHubItem) async {
        await perform {
            let result = try await client.uninstall(name: item.name)
            try await accept(result) { snapshot = try await client.load() }
        }
    }

    func updateInstalled() async {
        await perform {
            try await accept(try await client.updateInstalled()) { snapshot = try await client.load() }
        }
    }

    func clearMessages() { errorMessage = nil; successMessage = nil }

    fileprivate var isCurrentActionOwner: Bool { client.isCurrentActionOwner }

    fileprivate var requestFailureMessage: String {
        "Hermes could not complete this Skills Hub request. No change was confirmed."
    }
}

@MainActor @Observable
final class MCPManagementModel: CapabilityActionTrackingState {
    fileprivate(set) var support: CapabilitiesHostSupport = .unknown
    private(set) var snapshot: MCPSnapshot?
    private(set) var runtimeSnapshot: MCPRuntimeSnapshot?
    private(set) var probes: [String: MCPProbeResult] = [:]
    private(set) var oauthFlows: [String: MCPOAuthFlow] = [:]
    fileprivate(set) var isBusy = false
    fileprivate(set) var errorMessage: String?
    fileprivate(set) var successMessage: String?
    fileprivate(set) var actionReceipt: CapabilityActionReceipt?
    fileprivate(set) var actionStatus: HermesHostActionStatus?

    @ObservationIgnored private let client: any MCPManagementClient
    @ObservationIgnored fileprivate let actionStatusClient: (any HermesHostActionStatusClient)?
    @ObservationIgnored fileprivate var actionGeneration = UUID()

    private var runtimeClient: (any MCPRuntimeManagementClient)? {
        client as? any MCPRuntimeManagementClient
    }

    init(
        client: any MCPManagementClient,
        actionStatusClient: (any HermesHostActionStatusClient)? = nil
    ) {
        self.client = client
        self.actionStatusClient = actionStatusClient ?? client.actionStatusClient
    }

    func load() async {
        await perform {
            if let receipt = actionReceipt, actionStatus?.phase == .running {
                await track(receipt, pendingMessage: "Refreshing the retained MCP install action.", attempts: 1) {
                    try await reloadSnapshotAndRuntime()
                }
            }
            try await reloadSnapshotAndRuntime()
        }
    }

    func add(_ draft: MCPServerDraft) async {
        await perform {
            _ = try await client.add(draft)
            try await reloadSnapshotAndRuntime()
            successMessage = "Hermes confirmed the new MCP server."
        }
    }

    func install(_ entry: MCPCatalogEntry, environment: [String: String], enable: Bool) async {
        await perform {
            let result = try await client.installCatalog(name: entry.name, environment: environment, enable: enable)
            try await accept(result) { try await reloadSnapshotAndRuntime() }
        }
    }

    func setEnabled(_ enabled: Bool, server: MCPServer) async {
        await perform {
            _ = try await client.setEnabled(enabled, serverName: server.name)
            try await reloadSnapshotAndRuntime()
            successMessage = "Hermes confirmed the MCP server is \(enabled ? "enabled" : "disabled")."
        }
    }

    func remove(_ server: MCPServer) async {
        await perform {
            try await client.remove(serverName: server.name)
            try await reloadSnapshotAndRuntime()
            probes[server.name] = nil
            oauthFlows[server.name] = nil
            successMessage = "Hermes confirmed the MCP server was removed."
        }
    }

    func runtimeStatus(for serverName: String) -> MCPServerRuntimeStatus? {
        runtimeSnapshot?.servers.first { $0.name == serverName }
    }

    func setAPIKey(_ value: String, environmentVariable: String?, server: MCPServer) async -> Bool {
        var succeeded = false
        await perform {
            guard let runtimeClient else {
                throw CapabilitiesManagementError.unsupportedHost("This Hermes host does not expose write-only MCP credential updates.")
            }
            _ = try await runtimeClient.setAPIKey(
                value, environmentVariable: environmentVariable, serverName: server.name
            )
            try await reloadSnapshotAndRuntime()
            successMessage = "Hermes saved the write-only MCP credential and confirmed the server reference."
            succeeded = true
        }
        return succeeded
    }

    func test(_ server: MCPServer) async {
        await perform {
            probes[server.name] = try await client.test(serverName: server.name)
            successMessage = probes[server.name]?.succeeded == true
                ? "Hermes connected and read this server’s capabilities." : nil
        }
    }

    func startOAuth(_ server: MCPServer) async -> URL? {
        var result: URL?
        await perform {
            let flow = try await client.startOAuth(serverName: server.name)
            oauthFlows[server.name] = flow
            result = flow.authorizationURL
        }
        return result
    }

    func pollOAuth(_ server: MCPServer) async {
        guard let flow = oauthFlows[server.name] else { return }
        await perform {
            let updated = try await client.pollOAuth(flowID: flow.id)
            oauthFlows[server.name] = updated
            if updated.status == .approved {
                successMessage = "Hermes confirmed MCP authorization."
                probes[server.name] = try await client.test(serverName: server.name)
            }
        }
    }

    func cancelOAuth(_ server: MCPServer) async {
        guard let flow = oauthFlows[server.name] else { return }
        await perform {
            _ = try await client.cancelOAuth(flowID: flow.id)
            oauthFlows[server.name] = nil
            successMessage = "Authorization was cancelled."
        }
    }

    func clearMessages() { errorMessage = nil; successMessage = nil }

    private func reloadSnapshotAndRuntime() async throws {
        let loaded = try await client.load()
        let runtime: MCPRuntimeSnapshot?
        if let runtimeClient {
            do {
                runtime = try await runtimeClient.cachedRuntimeStatus(configuredServers: loaded.servers)
            } catch let error as CapabilitiesManagementError {
                if case .unsupportedHost = error { runtime = nil }
                else { throw error }
            }
        } else {
            runtime = nil
        }
        snapshot = loaded
        runtimeSnapshot = runtime
    }

    fileprivate var isCurrentActionOwner: Bool { client.isCurrentActionOwner }

    fileprivate var requestFailureMessage: String {
        "Hermes could not complete this MCP request. No change was confirmed."
    }
}

@MainActor @Observable
final class PluginLifecycleManagementModel: CapabilityOperationState {
    fileprivate(set) var support: CapabilitiesHostSupport = .unknown
    private(set) var snapshot: PluginSnapshot?
    fileprivate(set) var isBusy = false
    fileprivate(set) var errorMessage: String?
    fileprivate(set) var successMessage: String?

    @ObservationIgnored private let client: any PluginLifecycleManagementClient

    init(client: any PluginLifecycleManagementClient) { self.client = client }

    func load() async { await perform { snapshot = try await client.load() } }
    func rescan() async {
        await perform {
            snapshot = try await client.rescan()
            successMessage = "Hermes rescanned installed plugins."
        }
    }

    func install(_ entry: PluginCatalogEntry) async {
        await perform {
            _ = try await client.installCatalog(name: entry.name, expectedCommitSHA: entry.commitSHA)
            snapshot = try await client.load()
            successMessage = "Hermes installed and enabled the selected plugin."
        }
    }

    func setEnabled(_ enabled: Bool, plugin: InstalledPlugin) async {
        await perform {
            _ = try await client.setEnabled(enabled, pluginName: plugin.name)
            snapshot = try await client.load()
            successMessage = "Hermes confirmed the plugin is \(enabled ? "enabled" : "disabled")."
        }
    }

    func update(_ plugin: InstalledPlugin) async {
        await perform {
            _ = try await client.update(pluginName: plugin.name)
            snapshot = try await client.load()
            successMessage = "Hermes updated the selected plugin and confirmed it is still installed."
        }
    }

    func remove(_ plugin: InstalledPlugin) async {
        await perform {
            try await client.remove(pluginName: plugin.name)
            snapshot = try await client.load()
            successMessage = "Hermes confirmed the plugin was removed."
        }
    }

    func clearMessages() { errorMessage = nil; successMessage = nil }

    fileprivate var requestFailureMessage: String {
        "Hermes could not complete this plugin request. No change was confirmed."
    }
}

@MainActor @Observable
final class ToolsetManagementModel: CapabilityActionTrackingState {
    fileprivate(set) var support: CapabilitiesHostSupport = .unknown
    private(set) var snapshot: ToolsetSnapshot?
    private(set) var details: [String: ToolsetDetail] = [:]
    fileprivate(set) var isBusy = false
    fileprivate(set) var errorMessage: String?
    fileprivate(set) var successMessage: String?
    fileprivate(set) var actionReceipt: CapabilityActionReceipt?
    fileprivate(set) var actionStatus: HermesHostActionStatus?
    private(set) var actionToolsetName: String?

    @ObservationIgnored private let client: any ToolsetManagementClient
    @ObservationIgnored fileprivate let actionStatusClient: (any HermesHostActionStatusClient)?
    @ObservationIgnored fileprivate var actionGeneration = UUID()

    init(
        client: any ToolsetManagementClient,
        actionStatusClient: (any HermesHostActionStatusClient)? = nil
    ) {
        self.client = client
        self.actionStatusClient = actionStatusClient ?? client.actionStatusClient
    }

    func load() async {
        await perform {
            if let receipt = actionReceipt,
               let toolsetName = actionToolsetName,
               actionStatus?.phase == .running {
                await track(receipt, pendingMessage: "Refreshing the retained toolset setup action.", attempts: 1) {
                    snapshot = try await client.load()
                    details[toolsetName] = try await client.detail(name: toolsetName, modelProvider: nil)
                }
            }
            snapshot = try await client.load()
        }
    }

    func loadDetail(_ name: String, provider: String? = nil) async {
        await perform { details[name] = try await client.detail(name: name, modelProvider: provider) }
    }

    func setEnabled(_ enabled: Bool, toolset: ToolsetSummary) async {
        await perform {
            _ = try await client.setEnabled(enabled, name: toolset.name)
            snapshot = try await client.load()
            details[toolset.name] = try await client.detail(name: toolset.name, modelProvider: nil)
            successMessage = "Hermes confirmed the toolset is \(enabled ? "enabled" : "disabled")."
        }
    }

    func selectProvider(_ provider: String, capability: ToolsetWebCapability?, toolset: ToolsetSummary) async {
        await perform {
            details[toolset.name] = try await client.selectProvider(provider, name: toolset.name, capability: capability)
            snapshot = try await client.load()
            successMessage = "Hermes confirmed the selected provider."
        }
    }

    func saveEnvironment(_ values: [String: String], toolset: ToolsetSummary) async {
        await perform {
            details[toolset.name] = try await client.saveEnvironment(values, name: toolset.name)
            snapshot = try await client.load()
            successMessage = "Hermes confirmed the selected credential fields are configured."
        }
    }

    func selectModel(_ model: String, provider: String?, toolset: ToolsetSummary) async {
        await perform {
            details[toolset.name] = try await client.selectModel(model, provider: provider, name: toolset.name)
            successMessage = "Hermes confirmed the selected model."
        }
    }

    func runPostSetup(key: String, toolset: ToolsetSummary) async {
        await perform {
            let result = try await client.runPostSetup(key: key, name: toolset.name)
            switch result {
            case .confirmed(let message):
                snapshot = try await client.load()
                details[toolset.name] = try await client.detail(name: toolset.name, modelProvider: nil)
                successMessage = message
            case .pending(let receipt, let message):
                actionToolsetName = toolset.name
                await track(receipt, pendingMessage: message) {
                    snapshot = try await client.load()
                    details[toolset.name] = try await client.detail(name: toolset.name, modelProvider: nil)
                }
            }
        }
    }

    func clearMessages() { errorMessage = nil; successMessage = nil }

    fileprivate var isCurrentActionOwner: Bool { client.isCurrentActionOwner }

    fileprivate var requestFailureMessage: String {
        "Hermes could not complete this toolset request. No change was confirmed."
    }
}

@MainActor
private enum CapabilityActionCopy {
    static func initialStatus(for receipt: HermesHostActionReceipt) -> HermesHostActionStatus {
        .init(
            action: receipt.action,
            phase: .running,
            processID: receipt.processID,
            actionID: receipt.actionID,
            correlation: receipt.admission == .actionSlotOnly ? .actionSlotOnly : .pendingIdentity,
            updateSummary: nil
        )
    }

    static func pending(
        _ receipt: CapabilityActionReceipt,
        message: String,
        trackingAvailable: Bool
    ) -> String {
        let correlation = receipt.processID != nil || receipt.actionID != nil
            ? "bighelp retained the host’s per-run launch identity."
            : "Only the named host action slot was returned; its status cannot identify one exact run."
        let tracking = trackingAvailable
            ? "Completion is pending."
            : "Completion tracking is unavailable until the parent injects the shared Host Operations status client."
        return "\(message) \(tracking) \(correlation)"
    }

    static func untrackable(_ receipt: CapabilityActionReceipt) -> String {
        _ = receipt
        return "Hermes admitted the capability action, but the shared Host Operations client does not accept its exact returned slot. The launch receipt is retained; refresh authoritative state instead of starting it again."
    }

    static func stillRunning(_ status: HermesHostActionStatus) -> String {
        "Hermes still reports \(status.action.rawValue) as running. Its launch receipt is retained; bighelp did not repeat the action."
    }

    static func terminalReadbackFailed(_ status: HermesHostActionStatus) -> String {
        switch status.phase {
        case .succeeded:
            "Hermes reported \(status.action.rawValue) succeeded, but the affected capability snapshot could not be read back. Completion is not confirmed in bighelp. Refresh before acting again."
        case .failed(let code):
            "Hermes reported \(status.action.rawValue) failed with exit code \(code), and the affected capability snapshot could not be refreshed. The action was not retried."
        case .outcomeUnknown:
            "Hermes stopped reporting \(status.action.rawValue) as running without a durable result, and the affected capability snapshot could not be refreshed. The action was not retried."
        case .running:
            stillRunning(status)
        }
    }

    static func publishTerminal(
        _ status: HermesHostActionStatus,
        success: inout String?,
        error: inout String?
    ) {
        let correlation = switch status.correlation {
        case .exactActionID: "the exact host action ID"
        case .matchingProcess: "the retained launch process"
        case .actionSlotOnly: "the named action slot only; this is weaker than per-run correlation"
        case .pendingIdentity: "a host status without a matching per-run identity"
        }
        switch status.phase {
        case .succeeded:
            error = nil
            success = "Hermes reported \(status.action.rawValue) succeeded for \(correlation), and bighelp refreshed the affected capability snapshot."
        case .failed(let code):
            success = nil
            error = "Hermes reported \(status.action.rawValue) failed with exit code \(code) for \(correlation). bighelp refreshed the affected capability snapshot and did not retry the action."
        case .outcomeUnknown:
            success = nil
            error = "Hermes stopped reporting \(status.action.rawValue) as running but has no durable exit result for \(correlation). bighelp refreshed the affected capability snapshot and did not retry the action."
        case .running:
            success = stillRunning(status)
        }
    }

    static func trackingFailed(_ receipt: CapabilityActionReceipt) -> String {
        _ = receipt
        return "bighelp could not confirm the retained capability action. Its exact launch receipt is retained; refresh status or authoritative capability state instead of starting it again."
    }
}
