import CryptoKit
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
        } catch {
            report(error)
        }
    }

    func report(_ error: any Error) {
        switch error {
        case is CancellationError:
            break
        case let error as CapabilitiesManagementError:
            if case .unsupportedHost(let message) = error { support = .unavailable(message) }
            errorMessage = error.localizedDescription
        default:
            errorMessage = requestFailureMessage
        }
    }
}

/// The last Plugins and Skills Hub lists each computer gave, so a page opens on them at once and its
/// read only updates them: in memory for this run, and on disk (`CapabilitiesSavedLists`) for the
/// first page of the next. Hermes builds its plugin lists again on every read (4 s for 108 plugins on
/// one host), and reads that overlap slow each other down (four at once took 14 s each), so a read a
/// page asks for while one is out for the same computer waits for that one (`readPlugins`, `readSkills`).
@MainActor
final class CapabilitiesKeptCopies {
    static let shared = CapabilitiesKeptCopies(saved: CapabilitiesSavedLists.caches)

    var plugins: [String: PluginSnapshot] = [:]
    var skills: [String: SkillHubSnapshot] = [:]

    private let saved: CapabilitiesSavedLists?
    private let pluginReads = SharedReads<PluginSnapshot>()
    private let skillReads = SharedReads<SkillHubSnapshot>()

    init(saved: CapabilitiesSavedLists? = nil) {
        self.saved = saved
    }

    static func skillsKey(_ owner: WorkspaceOwner, profileID: String) -> String {
        "\(owner.cacheScopeID)\n\(profileID)"
    }

    func keepPlugins(_ snapshot: PluginSnapshot, for key: String) {
        plugins[key] = snapshot
        saved?.write(snapshot, key: "plugins\n\(key)")
    }

    func keepSkills(_ snapshot: SkillHubSnapshot, for key: String) {
        skills[key] = snapshot
        saved?.write(snapshot, key: "skills\n\(key)")
    }

    /// The copy saved by an earlier run, now in memory too; nil without one.
    func savedPlugins(for key: String) async -> PluginSnapshot? {
        guard let copy = await saved?.read(PluginSnapshot.self, key: "plugins\n\(key)") else { return nil }
        if plugins[key] == nil { plugins[key] = copy }
        return plugins[key]
    }

    func savedSkills(for key: String) async -> SkillHubSnapshot? {
        guard let copy = await saved?.read(SkillHubSnapshot.self, key: "skills\n\(key)") else { return nil }
        if skills[key] == nil { skills[key] = copy }
        return skills[key]
    }

    /// `read`, unless a read for this computer is already out: then that one's answer.
    func readPlugins(for key: String, _ read: @escaping @MainActor () async throws -> PluginSnapshot) async throws -> PluginSnapshot {
        try await pluginReads.run(key, read)
    }

    func readSkills(for key: String, _ read: @escaping @MainActor () async throws -> SkillHubSnapshot) async throws -> SkillHubSnapshot {
        try await skillReads.run(key, read)
    }
}

/// One read per key at a time: a caller that asks while one is out waits for it. The read runs to the
/// end even when the caller that started it goes away, so its answer is still kept.
@MainActor
final class SharedReads<Value: Sendable> {
    private var running: [String: Task<Value, any Error>] = [:]

    func run(_ key: String, _ read: @escaping @MainActor () async throws -> Value) async throws -> Value {
        if let task = running[key] { return try await task.value }
        let task = Task { @MainActor in try await read() }
        running[key] = task
        defer { if running[key] == task { running[key] = nil } }
        return try await task.value
    }
}

/// The kept lists on disk (Caches, which the system may clear), so the first Plugins or Skills Hub page
/// of a launch opens on the last list too. A copy older than a month, from another format or that
/// doesn't read is no copy. Demo runs and tests keep none, so made-up lists never outlive their run.
struct CapabilitiesSavedLists: Sendable {
    static let format = 1
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    let folder: URL

    static var caches: CapabilitiesSavedLists? {
        let process = ProcessInfo.processInfo
        guard !process.arguments.contains("-use-demo-fixtures"),
              process.environment["XCTestConfigurationFilePath"] == nil,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return CapabilitiesSavedLists(folder: caches.appending(path: "CapabilityLists", directoryHint: .isDirectory))
    }

    private struct Saved<Value: Codable>: Codable {
        let format: Int
        let savedAt: Date
        let value: Value
    }

    func read<Value: Codable & Sendable>(_ type: Value.Type, key: String, now: Date = .now) async -> Value? {
        let file = file(for: key)
        return await Task.detached(priority: .userInitiated) { () -> Value? in
            guard let data = try? Data(contentsOf: file),
                  let saved = try? JSONDecoder().decode(Saved<Value>.self, from: data),
                  saved.format == Self.format, now.timeIntervalSince(saved.savedAt) < Self.maximumAge else { return nil }
            return saved.value
        }.value
    }

    /// Written off the main actor; a write that fails leaves the last copy.
    func write<Value: Codable & Sendable>(_ value: Value, key: String) {
        let file = file(for: key), folder = folder
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(Saved(format: Self.format, savedAt: .now, value: value)) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// The key names the computer's sign-in, so the file is named by its hash.
    private func file(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: "\(digest).json")
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
    @ObservationIgnored private let keptCopies: CapabilitiesKeptCopies?
    @ObservationIgnored private var hasRead = false
    @ObservationIgnored private var isRereading = false

    init(
        client: any SkillsHubManagementClient,
        actionStatusClient: (any HermesHostActionStatusClient)? = nil,
        keptCopies: CapabilitiesKeptCopies? = nil
    ) {
        self.client = client
        self.actionStatusClient = actionStatusClient ?? client.actionStatusClient
        self.keptCopies = keptCopies
        snapshot = keptCopies?.skills[CapabilitiesKeptCopies.skillsKey(client.owner, profileID: client.profileID)]
    }

    /// The first read for this page: over the kept copy (or the one an earlier run saved) it updates quietly.
    func loadIfNeeded() async {
        guard !hasRead else { return }
        if snapshot == nil, let saved = await keptCopies?.savedSkills(for: keptKey), snapshot == nil {
            snapshot = saved
        }
        await load()
    }

    func load() async {
        hasRead = true
        if snapshot != nil, actionStatus?.phase != .running {
            // The kept copy stays on screen and in use: no "Waiting", nothing turned off.
            guard !isBusy, !isRereading else { return }
            isRereading = true
            defer { isRereading = false }
            do { keep(try await sharedLoad()); support = .available } catch { report(error) }
            return
        }
        await perform {
            if let receipt = actionReceipt, actionStatus?.phase == .running {
                await track(receipt, pendingMessage: "Refreshing the retained Skills Hub action.", attempts: 1) {
                    keep(try await client.load())
                }
            }
            keep(try await sharedLoad())
        }
    }

    private var keptKey: String { CapabilitiesKeptCopies.skillsKey(client.owner, profileID: client.profileID) }

    /// A plain read: one for this agent at a time, shared with any other page reading it now. Reads after
    /// a change go to the client, so they never take an answer from before it.
    private func sharedLoad() async throws -> SkillHubSnapshot {
        let client = client
        guard let keptCopies else { return try await client.load() }
        return try await keptCopies.readSkills(for: keptKey) { try await client.load() }
    }

    private func keep(_ snapshot: SkillHubSnapshot) {
        self.snapshot = snapshot
        keptCopies?.keepSkills(snapshot, for: keptKey)
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
            keep(SkillHubSnapshot(
                sources: current.sources, featured: current.featured, official: current.official,
                installedSkills: rows, installedIdentifiers: current.installedIdentifiers,
                indexAvailable: current.indexAvailable
            ))
            successMessage = "Hermes confirmed the skill is \(enabled ? "enabled" : "disabled")."
        }
    }

    /// Installs the reviewed skill, only when it is `identifier`: a page never installs a
    /// review it isn't showing.
    func installReviewed(_ identifier: String) async {
        guard let review else { return }
        await perform {
            guard review.id == identifier else { throw CapabilitiesManagementError.invalidRequest }
            let result = try await client.install(identifier: review.id, preview: review.preview, scan: review.scan)
            self.review = nil
            try await accept(result) { keep(try await client.load()) }
        }
    }

    func dismissReview() { review = nil }

    /// The newest copy of `item` the host listed (official, search results or featured), so a
    /// skill's page shows an install as soon as a refresh reports it.
    /// Installed whenever the latest reload lists its identifier, wherever it was found.
    func latest(_ item: SkillHubItem) -> SkillHubItem {
        let found = snapshot?.official.first { $0.id == item.id }
            ?? searchResult?.items.first { $0.id == item.id }
            ?? snapshot?.featured.first { $0.id == item.id }
            ?? item
        guard !found.isInstalled, snapshot?.installedIdentifiers.contains(found.id) == true else { return found }
        return SkillHubItem(id: found.id, name: found.name, summary: found.summary, source: found.source,
                            trustLevel: found.trustLevel, repository: found.repository, tags: found.tags,
                            category: found.category, isInstalled: true)
    }

    /// A hub's name for a source ID.
    func sourceLabel(_ source: String) -> String {
        snapshot?.sources.first { $0.id == source }?.label ?? source
    }

    func uninstall(_ item: SkillHubItem) async {
        await perform {
            let result = try await client.uninstall(name: item.name)
            try await accept(result) { keep(try await client.load()) }
        }
    }

    func updateInstalled() async {
        await perform {
            try await accept(try await client.updateInstalled()) { keep(try await client.load()) }
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

struct PluginChange: Equatable {
    enum Kind: Equatable { case turningOn, turningOff, updating, removing }
    let pluginName: String
    let kind: Kind
}

@MainActor @Observable
final class PluginLifecycleManagementModel: CapabilityOperationState {
    fileprivate(set) var support: CapabilitiesHostSupport = .unknown
    private(set) var snapshot: PluginSnapshot?
    /// The storefront's shelves, worked out once per list rather than on every redraw.
    private(set) var storefront: PluginStorefront?
    fileprivate(set) var isBusy = false
    fileprivate(set) var errorMessage: String?
    fileprivate(set) var successMessage: String?
    /// The change under way on an installed plugin, so its page says what's happening.
    private(set) var change: PluginChange?
    /// What Hermes asked before the last update, until the person answers or leaves it.
    private(set) var updateQuestion: PluginUpdateQuestion?
    /// The yes answers given to this update's questions so far, sent again with each retry.
    @ObservationIgnored private var updateApprovals: Set<PluginUpdateApproval> = []

    @ObservationIgnored private let client: any PluginLifecycleManagementClient
    @ObservationIgnored private let keptCopies: CapabilitiesKeptCopies?
    @ObservationIgnored private var hasRead = false
    /// Bumped by each change, so a read that started before it never puts the old list back.
    @ObservationIgnored private var changeGeneration = 0
    @ObservationIgnored private var isRereading = false

    init(client: any PluginLifecycleManagementClient, keptCopies: CapabilitiesKeptCopies? = nil) {
        self.client = client
        self.keptCopies = keptCopies
        snapshot = keptCopies?.plugins[client.owner.cacheScopeID]
        storefront = snapshot.map { PluginStorefront(catalog: $0.catalog) }
    }

    /// The first read for this page: over the kept copy (or the one an earlier run saved) it updates quietly.
    func loadIfNeeded() async {
        guard !hasRead else { return }
        if snapshot == nil, let saved = await keptCopies?.savedPlugins(for: client.owner.cacheScopeID), snapshot == nil {
            snapshot = saved
            storefront = PluginStorefront(catalog: saved.catalog)
        }
        await load()
    }

    func load() async {
        hasRead = true
        guard snapshot != nil else {
            await perform { keep(try await sharedLoad()) }
            return
        }
        // The kept copy stays on screen and in use: no "Waiting", and a change isn't refused.
        guard !isBusy, !isRereading else { return }
        isRereading = true
        defer { isRereading = false }
        // A change made while this read was out makes its answer old: read again.
        while !Task.isCancelled {
            let generation = changeGeneration
            do {
                let fresh = try await sharedLoad()
                support = .available
                guard generation != changeGeneration else { return keep(fresh) }
            } catch {
                return report(error)
            }
        }
    }

    func rescan() async {
        await perform {
            changeGeneration += 1
            keep(try await client.rescan())
            successMessage = "Hermes rescanned installed plugins."
        }
    }

    func install(_ entry: PluginCatalogEntry) async {
        await perform {
            changeGeneration += 1
            _ = try await client.installCatalog(name: entry.name, expectedCommitSHA: entry.commitSHA)
            keep(try await client.load())
            successMessage = "Hermes installed and enabled the selected plugin."
        }
    }

    /// Turning a plugin on or off changes only its own row, so only the small installed list is
    /// read back (the catalog was read twice more before, a few megabytes each).
    func setEnabled(_ enabled: Bool, plugin: InstalledPlugin) async {
        await change(enabled ? .turningOn : .turningOff, plugin) {
            let confirmed = try await client.setEnabled(enabled, pluginName: plugin.name)
            replaceInstalled(plugin.name, with: confirmed)
            successMessage = "Hermes confirmed the plugin is \(enabled ? "enabled" : "disabled")."
        }
    }

    /// Updates `plugin`. If Hermes asks first (new tools or hooks, scan findings), its question stays in
    /// `updateQuestion` and nothing changes until `answerUpdateQuestion()`.
    func update(_ plugin: InstalledPlugin) async {
        updateApprovals = []
        await runUpdate(plugin)
    }

    /// The person's yes to `updateQuestion`: the same update again, with every yes so far.
    func answerUpdateQuestion() async {
        guard let question = updateQuestion, let approval = question.approval,
              let plugin = snapshot?.installed.first(where: { $0.name == question.pluginName }) else { return }
        updateApprovals.insert(approval)
        await runUpdate(plugin)
    }

    func dismissUpdateQuestion() {
        updateQuestion = nil
        updateApprovals = []
    }

    private func runUpdate(_ plugin: InstalledPlugin) async {
        updateQuestion = nil
        var updated = false
        await change(.updating, plugin) {
            switch try await client.update(pluginName: plugin.name, approvals: updateApprovals) {
            case .updated(let confirmed):
                replaceInstalled(plugin.name, with: confirmed)
                successMessage = "Hermes updated the selected plugin and confirmed it is still installed."
                updated = true
            case .asks(let question):
                updateQuestion = question
            }
        }
        guard updated else { return }
        updateApprovals = []
        // Update available and the pinned commit come from the catalog.
        readCatalogAgain()
    }

    func remove(_ plugin: InstalledPlugin) async {
        await change(.removing, plugin) {
            try await client.remove(pluginName: plugin.name)
            replaceInstalled(plugin.name, with: nil)
            successMessage = "Hermes confirmed the plugin was removed."
        }
        // The storefront's Get or Open comes from the catalog.
        if errorMessage == nil { readCatalogAgain() }
    }

    /// Reads both lists again in the background, so the page that made the change can close now.
    /// A read already out sees the change and reads again itself.
    private func readCatalogAgain() {
        Task { [weak self] in await self?.load() }
    }

    private func change(_ kind: PluginChange.Kind, _ plugin: InstalledPlugin,
                        _ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        changeGeneration += 1
        change = PluginChange(pluginName: plugin.name, kind: kind)
        defer { change = nil }
        await perform(operation)
    }

    private func replaceInstalled(_ name: String, with plugin: InstalledPlugin?) {
        guard let current = snapshot else { return }
        var installed = current.installed
        if let index = installed.firstIndex(where: { $0.name == name }) {
            if let plugin { installed[index] = plugin } else { installed.remove(at: index) }
        }
        keep(PluginSnapshot(installed: installed, catalog: current.catalog,
                            removedCatalogEntries: current.removedCatalogEntries,
                            skippedCatalogRows: current.skippedCatalogRows))
    }

    /// A plain read: one for this computer at a time, shared with any other page reading it now (the
    /// Marketplace and the Plugins page it opens). Reads after a change go to the client, so they never
    /// take an answer from before it.
    private func sharedLoad() async throws -> PluginSnapshot {
        let client = client
        guard let keptCopies else { return try await client.load() }
        return try await keptCopies.readPlugins(for: client.owner.cacheScopeID) { try await client.load() }
    }

    private func keep(_ snapshot: PluginSnapshot) {
        self.snapshot = snapshot
        storefront = PluginStorefront(catalog: snapshot.catalog)
        keptCopies?.keepPlugins(snapshot, for: client.owner.cacheScopeID)
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
            ? "Bighelp retained the host’s per-run launch identity."
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
        "Hermes still reports \(status.action.rawValue) as running. Its launch receipt is retained; Bighelp did not repeat the action."
    }

    static func terminalReadbackFailed(_ status: HermesHostActionStatus) -> String {
        switch status.phase {
        case .succeeded:
            "Hermes reported \(status.action.rawValue) succeeded, but the affected capability snapshot could not be read back. Completion is not confirmed in Bighelp. Refresh before acting again."
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
            success = "Hermes reported \(status.action.rawValue) succeeded for \(correlation), and Bighelp refreshed the affected capability snapshot."
        case .failed(let code):
            success = nil
            error = "Hermes reported \(status.action.rawValue) failed with exit code \(code) for \(correlation). Bighelp refreshed the affected capability snapshot and did not retry the action."
        case .outcomeUnknown:
            success = nil
            error = "Hermes stopped reporting \(status.action.rawValue) as running but has no durable exit result for \(correlation). Bighelp refreshed the affected capability snapshot and did not retry the action."
        case .running:
            success = stillRunning(status)
        }
    }

    static func trackingFailed(_ receipt: CapabilityActionReceipt) -> String {
        _ = receipt
        return "Bighelp could not confirm the retained capability action. Its exact launch receipt is retained; refresh status or authoritative capability state instead of starting it again."
    }
}
