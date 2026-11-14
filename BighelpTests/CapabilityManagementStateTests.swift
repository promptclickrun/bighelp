import Foundation
import Testing
@testable import Bighelp

@MainActor
struct CapabilityManagementStateTests {
    enum Domain: String, CaseIterable, Sendable { case skills, mcp, plugins, toolsets }
    nonisolated static let trackingDomains: [Domain] = [.skills, .mcp, .toolsets]

    @Test(arguments: Domain.allCases)
    func requestErrorsKeepDomainCopyAndReleaseBusy(domain: Domain) async {
        let fixture = CapabilityStateFixture()
        let harness = Harness(domain, fixture)
        fixture.loadError = ProbeError.failed
        await harness.load()
        let name = [Domain.skills: "Skills Hub", .mcp: "MCP", .plugins: "plugin", .toolsets: "toolset"][domain]!
        #expect(harness.state.errorMessage == "Hermes could not complete this \(name) request. No change was confirmed.")
        #expect(harness.state.support == .unknown)
        #expect(!harness.state.isBusy)
        fixture.loadError = CapabilitiesManagementError.unsupportedHost("Unavailable here")
        await harness.load()
        #expect(harness.state.support == .unavailable("Unavailable here"))
        #expect(harness.state.errorMessage == "Unavailable here")
        fixture.loadError = CancellationError()
        await harness.load()
        #expect(harness.state.errorMessage == nil)
        #expect(!harness.state.isBusy)
        fixture.loadError = nil
        await harness.load()
        #expect(harness.state.support == .available)
    }

    @Test(arguments: Domain.allCases)
    func busyLoadRejectsReentryWithoutDiscardingSuccess(domain: Domain) async throws {
        let fixture = CapabilityStateFixture()
        fixture.writeResult = .confirmed("Confirmed")
        let harness = Harness(domain, fixture)
        await harness.launch()
        let success = try #require(harness.state.successMessage)
        let gate = AsyncOperationTestGate()
        fixture.beforeLoad = { try await gate.wait() }
        let task = Task { await harness.load() }
        defer { gate.finish(); task.cancel() }
        for _ in 0..<100 where !gate.entered { await Task.yield() }
        try #require(gate.entered)
        // Skills and Plugins read again over the list they already show, so they don't say busy.
        #expect(harness.state.isBusy == ![Domain.skills, .plugins].contains(domain))
        let calls = fixture.events
        await harness.load()
        #expect(fixture.events == calls)
        #expect(harness.state.successMessage == success)
        gate.finish()
        await task.value
        #expect(!harness.state.isBusy)
    }

    @Test(arguments: trackingDomains)
    func pendingWithoutTrackerRetainsTheExactReceipt(domain: Domain) async {
        let fixture = CapabilityStateFixture()
        let harness = Harness(domain, fixture, tracking: false)
        await harness.launch()
        #expect(harness.receipt() == fixture.receipt)
        #expect(harness.status() == nil)
        #expect(harness.state.successMessage?.contains("Completion tracking is unavailable") == true)
        #expect(fixture.events == ["launch"])
        #expect(!harness.state.isBusy)
    }

    @Test(arguments: trackingDomains)
    func invalidReturnedSlotIsNotPolledOrRelaunched(domain: Domain) async {
        let fixture = CapabilityStateFixture()
        fixture.receipt = .init(actionName: "../untrusted", processID: 31, actionID: "exact-run")
        let harness = Harness(domain, fixture)
        await harness.launch()
        #expect(harness.receipt() == fixture.receipt)
        #expect(harness.state.successMessage == nil)
        #expect(harness.state.errorMessage?.contains("does not accept its exact returned slot") == true)
        #expect(fixture.events == ["launch"])
    }

    @Test(arguments: trackingDomains, [HermesHostActionStatus.Phase.succeeded, .failed(exitCode: 7), .outcomeUnknown])
    func terminalStatusRequiresOrderedDomainReadback(domain: Domain, phase: HermesHostActionStatus.Phase) async {
        let fixture = CapabilityStateFixture()
        fixture.phase = phase
        let harness = Harness(domain, fixture)
        await harness.launch()
        #expect(harness.receipt() == fixture.receipt)
        #expect(harness.status()?.phase == phase)
        #expect(fixture.polledReceipt?.processID == fixture.receipt.processID)
        #expect(fixture.polledReceipt?.actionID == fixture.receipt.actionID)
        #expect(fixture.polledReceipt?.admission == .launchAcknowledged)
        #expect(fixture.events == (domain == .toolsets ? ["launch", "status", "load", "detail"] : ["launch", "status", "load"]))
        if phase == .succeeded {
            #expect(harness.state.successMessage?.contains("the exact host action ID") == true)
            #expect(harness.state.errorMessage == nil)
        } else {
            #expect(harness.state.successMessage == nil)
            #expect(harness.state.errorMessage?.contains("did not retry the action") == true)
        }
        #expect(!harness.state.isBusy)
    }

    @Test(arguments: trackingDomains)
    func terminalReadbackFailureCannotBecomeConfirmedSuccess(domain: Domain) async {
        let fixture = CapabilityStateFixture()
        fixture.loadError = ProbeError.failed
        let harness = Harness(domain, fixture)
        await harness.launch()
        #expect(harness.status()?.phase == .succeeded)
        #expect(harness.state.successMessage == nil)
        #expect(harness.state.errorMessage?.contains("Completion is not confirmed in Bighelp") == true)
        #expect(fixture.events == ["launch", "status", "load"])
    }

    @Test(arguments: trackingDomains, [false, true])
    func ownerChangeDuringPollingSuppressesBothSuccessAndError(domain: Domain, fail: Bool) async throws {
        let fixture = CapabilityStateFixture()
        let gate = AsyncOperationTestGate()
        fixture.beforeStatus = { try await gate.wait() }
        let harness = Harness(domain, fixture)
        let task = Task { await harness.launch() }
        defer { gate.finish(); task.cancel() }
        for _ in 0..<100 where !gate.entered { await Task.yield() }
        try #require(gate.entered)
        let pending = harness.state.successMessage
        fixture.isCurrentActionOwner = false
        gate.finish(error: fail ? ProbeError.failed : nil)
        await task.value
        #expect(harness.state.successMessage == pending)
        #expect(harness.state.errorMessage == nil)
        #expect(harness.status()?.phase == .running)
        #expect(harness.receipt() == fixture.receipt)
        #expect(fixture.events == ["launch", "status"])
        #expect(!harness.state.isBusy)
    }

    @Test(arguments: trackingDomains, [false, true])
    func cancelledPollingPreservesItsOriginalErrorPolicy(domain: Domain, ordinaryError: Bool) async throws {
        let fixture = CapabilityStateFixture()
        let gate = AsyncOperationTestGate()
        fixture.beforeStatus = { try await gate.wait() }
        let harness = Harness(domain, fixture)
        let task = Task { await harness.launch() }
        defer { gate.finish(); task.cancel() }
        for _ in 0..<100 where !gate.entered { await Task.yield() }
        try #require(gate.entered)
        let pending = harness.state.successMessage
        task.cancel()
        gate.finish(error: ordinaryError ? ProbeError.failed : CancellationError())
        await task.value
        #expect(harness.receipt() == fixture.receipt)
        #expect(harness.status()?.phase == .running)
        if ordinaryError {
            #expect(harness.state.successMessage == nil)
            #expect(harness.state.errorMessage?.contains("could not confirm the retained capability action") == true)
        } else {
            #expect(harness.state.successMessage == pending)
            #expect(harness.state.errorMessage == nil)
        }
        #expect(fixture.events == ["launch", "status"])
        #expect(!harness.state.isBusy)
    }

    @MainActor
    private struct Harness {
        let state: any CapabilitiesManagementState
        let load: @MainActor () async -> Void
        let launch: @MainActor () async -> Void
        let receipt: @MainActor () -> CapabilityActionReceipt?
        let status: @MainActor () -> HermesHostActionStatus?

        init(_ domain: Domain, _ fixture: CapabilityStateFixture, tracking: Bool = true) {
            let tracker: (any HermesHostActionStatusClient)? = tracking ? fixture : nil
            switch domain {
            case .skills:
                let model = SkillsHubManagementModel(client: fixture, actionStatusClient: tracker)
                state = model
                load = { await model.load() }
                launch = { await model.updateInstalled() }
                receipt = { model.actionReceipt }
                status = { model.actionStatus }
            case .mcp:
                let model = MCPManagementModel(client: fixture, actionStatusClient: tracker)
                state = model
                load = { await model.load() }
                launch = { await model.install(fixture.mcpEntry, environment: [:], enable: true) }
                receipt = { model.actionReceipt }
                status = { model.actionStatus }
            case .plugins:
                let model = PluginLifecycleManagementModel(client: fixture)
                state = model
                load = { await model.load() }
                launch = { await model.rescan() }
                receipt = { nil }
                status = { nil }
            case .toolsets:
                let model = ToolsetManagementModel(client: fixture, actionStatusClient: tracker)
                state = model
                load = { await model.load() }
                launch = { await model.runPostSetup(key: "setup", toolset: fixture.toolset) }
                receipt = { model.actionReceipt }
                status = { model.actionStatus }
            }
        }
    }
}

private enum ProbeError: Error { case failed }

@MainActor
private final class CapabilityStateFixture: SkillsHubManagementClient, MCPManagementClient,
    PluginLifecycleManagementClient, ToolsetManagementClient, HermesHostActionStatusClient {
    let owner = WorkspaceOwner(
        authority: try! .fixture(id: "capability-state-tests"),
        authenticationGeneration: UUID(), connectionGeneration: UUID()
    )
    let profileID = "default"
    var isCurrentActionOwner = true
    var receipt = CapabilityActionReceipt(actionName: "skills-update", processID: 31, actionID: "exact-run")
    var phase = HermesHostActionStatus.Phase.succeeded
    var writeResult: CapabilityWriteResult?
    var loadError: (any Error)?
    var beforeLoad: (() async throws -> Void)?
    var beforeStatus: (() async throws -> Void)?
    var events: [String] = []
    var polledReceipt: HermesHostActionReceipt?
    let toolset = ToolsetSummary(name: "web", label: "Web", summary: "", platform: "native",
                                platformLabel: "Native", isEnabled: true, isConfigured: true, tools: [])
    let mcpEntry = MCPCatalogEntry(name: "docs", summary: "", source: "catalog", transport: "stdio",
                                  authType: "none", requiredEnvironment: [], command: nil, arguments: [],
                                  url: nil, installURL: nil, installReference: nil, bootstrap: [], postInstall: "",
                                  needsInstall: true, isInstalled: false, isEnabled: false)

    func receipt(forActionName name: String) throws -> HermesHostActionReceipt {
        try .actionSlot(named: name)
    }
    func status(for receipt: HermesHostActionReceipt) async throws -> HermesHostActionStatus {
        events.append("status")
        polledReceipt = receipt
        try await beforeStatus?()
        return .init(action: receipt.action, phase: phase, processID: receipt.processID,
                     actionID: receipt.actionID, correlation: .exactActionID, updateSummary: nil)
    }
    private func read() async throws {
        events.append("load")
        try await beforeLoad?()
        if let loadError { throw loadError }
    }
    private func write() -> CapabilityWriteResult {
        events.append("launch")
        return writeResult ?? .pending(receipt: receipt, message: "Admitted")
    }
    func load() async throws -> SkillHubSnapshot {
        try await read()
        return .init(sources: [], featured: [], official: [], installedSkills: [], installedIdentifiers: [], indexAvailable: true)
    }
    func load() async throws -> MCPSnapshot {
        try await read()
        return .init(servers: [], catalog: [], diagnostics: [])
    }
    func load() async throws -> PluginSnapshot {
        try await read()
        return .init(installed: [], catalog: [], removedCatalogEntries: [])
    }
    func loadInstalled() async throws -> [InstalledPlugin] { try await (load() as PluginSnapshot).installed }
    func load() async throws -> ToolsetSnapshot {
        try await read()
        return .init(toolsets: [toolset])
    }
    func detail(name: String, modelProvider: String?) async throws -> ToolsetDetail {
        events.append("detail")
        #expect(name == toolset.name && modelProvider == nil)
        return .init(summary: toolset,
                     configuration: .init(name: name, hasCategory: false, providers: [], activeProvider: nil,
                                          activeSearchBackend: nil, activeExtractBackend: nil),
                     models: .init(name: name, hasModels: false, provider: nil, models: [], current: nil, defaultModel: nil))
    }
    func updateInstalled() async throws -> CapabilityWriteResult { write() }
    func installCatalog(name: String, environment: [String: String], enable: Bool) async throws -> CapabilityWriteResult { write() }
    func runPostSetup(key: String, name: String) async throws -> CapabilityWriteResult { write() }
    func rescan() async throws -> PluginSnapshot { try await load() }
    func search(query: String, source: String) async throws -> SkillHubSearchResult { throw ProbeError.failed }
    func preview(identifier: String) async throws -> SkillHubPreview { throw ProbeError.failed }
    func scan(identifier: String) async throws -> SkillHubScan { throw ProbeError.failed }
    func setEnabled(_ enabled: Bool, skillName: String) async throws -> InstalledSkill { throw ProbeError.failed }
    func install(identifier: String, preview: SkillHubPreview, scan: SkillHubScan) async throws -> CapabilityWriteResult { throw ProbeError.failed }
    func uninstall(name: String) async throws -> CapabilityWriteResult { throw ProbeError.failed }
    func add(_ draft: MCPServerDraft) async throws -> MCPServer { throw ProbeError.failed }
    func setEnabled(_ enabled: Bool, serverName: String) async throws -> MCPServer { throw ProbeError.failed }
    func remove(serverName: String) async throws { throw ProbeError.failed }
    func test(serverName: String) async throws -> MCPProbeResult { throw ProbeError.failed }
    func startOAuth(serverName: String) async throws -> MCPOAuthFlow { throw ProbeError.failed }
    func pollOAuth(flowID: String) async throws -> MCPOAuthFlow { throw ProbeError.failed }
    func cancelOAuth(flowID: String) async throws -> MCPOAuthFlow.Status { throw ProbeError.failed }
    func installCatalog(name: String, expectedCommitSHA: String) async throws -> InstalledPlugin { throw ProbeError.failed }
    func setEnabled(_ enabled: Bool, pluginName: String) async throws -> InstalledPlugin { throw ProbeError.failed }
    func update(pluginName: String, approvals: Set<PluginUpdateApproval>) async throws -> PluginUpdateResult {
        throw ProbeError.failed
    }
    func remove(pluginName: String) async throws { throw ProbeError.failed }
    func setEnabled(_ enabled: Bool, name: String) async throws -> ToolsetSummary { throw ProbeError.failed }
    func selectProvider(_ provider: String, name: String, capability: ToolsetWebCapability?) async throws -> ToolsetDetail { throw ProbeError.failed }
    func saveEnvironment(_ environment: [String: String], name: String) async throws -> ToolsetDetail { throw ProbeError.failed }
    func selectModel(_ model: String, provider: String?, name: String) async throws -> ToolsetDetail { throw ProbeError.failed }
}
