import Foundation
import Observation

/// A host's bighelp plugin update, as Settings drives it for one host
/// (`HostPluginUpdateModel`). Fleet settings drives the same model for each host.
@MainActor
protocol HostPluginUpdating: AnyObject, Sendable {
    var state: HostPluginUpdateModel.State { get }
    var installedVersion: String? { get }
    var runningVersion: String? { get }
    var latestVersion: String? { get }
    var message: String? { get }
    var canRestartHost: Bool { get }
    func check() async
    func checkIfNeeded() async
    func update() async -> Bool
    func restart() async
}

extension HostPluginUpdateModel: HostPluginUpdating {}

/// How Fleet settings reached one host: the single-host System page's own
/// store and plugin model for it, or why it can't be reached.
enum FleetMaintenanceReach {
    case ready(operations: HostOperationsStore, plugin: any HostPluginUpdating)
    case offline(String)
    case signedOut
}

/// Reaches each of the person's hosts for Fleet settings.
@MainActor
protocol FleetMaintenanceConnecting: AnyObject {
    var hosts: [FleetHost] { get }
    /// Connects the host if it isn't, and hands back what updates it.
    func connect(_ hostID: UUID) async -> FleetMaintenanceReach
}

/// One host's line in one of Fleet settings' sections.
struct FleetHostJob: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Offline or signed out: skipped.
        case unavailable
        case checking
        /// Something to do here ("12 commits behind").
        case pending
        /// Only the computer itself can do it.
        case manual
        /// Nothing to do ("Up to date", "Running").
        case current
        case working
        case needsRestart
        case done
        case failed
    }

    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var isWorking: Bool { kind == .working || kind == .checking }
}

/// One host in Fleet settings: its connection, the System page's store for
/// it, its plugin model, and the jobs this page started there.
@MainActor
@Observable
final class FleetMaintenanceHost: Identifiable {
    enum Reach: Equatable {
        case connecting, ready, signedOut
        case offline(String)
    }

    let id: UUID
    fileprivate(set) var name: String
    fileprivate(set) var reach: Reach = .connecting
    fileprivate(set) var operations: HostOperationsStore?
    fileprivate(set) var plugin: (any HostPluginUpdating)?

    /// Background actions this page started, with their last known phase.
    /// Kept here, not only in the store, so a reconnect can keep following them.
    fileprivate var hermesJob = Job()
    fileprivate var gatewayJob = Job()
    /// A Hermes update that left the gateway on old code; its Restart restarts it.
    fileprivate var hermesNeedsGateway = false
    fileprivate var pluginUpdatedHere = false
    fileprivate var pluginRestartTried = false

    fileprivate struct Job {
        var isStarting = false
        var receipt: HermesHostActionReceipt?
        var phase: HermesHostActionStatus.Phase?
        /// The host's state was read again after it finished.
        var isSettled = false
        var error: String?

        var isActive: Bool { isStarting || (receipt != nil && !isSettled && error == nil) }
    }

    fileprivate init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    var isBusy: Bool {
        hermesJob.isActive || gatewayJob.isActive || [.updating, .restarting].contains(plugin?.state)
    }

    private var unavailable: FleetHostJob? {
        switch reach {
        case .ready: nil
        case .connecting: FleetHostJob(.checking, "Connecting…")
        case .signedOut: FleetHostJob(.unavailable, "Signed out. Sign in again in Settings › Hosts.")
        case .offline(let message): FleetHostJob(.unavailable, message)
        }
    }

    /// Phase of a job: the store's latest reading, or the last one this page saw.
    private func phase(_ job: Job) -> HermesHostActionStatus.Phase? {
        guard let receipt = job.receipt else { return nil }
        return operations?.actionStatuses[receipt.id]?.phase ?? job.phase
    }

    // MARK: Hermes

    var hermes: FleetHostJob {
        if hermesJob.isStarting { return FleetHostJob(.working, "Starting the update…") }
        if let error = hermesJob.error { return FleetHostJob(.failed, error) }
        if hermesJob.receipt != nil {
            switch phase(hermesJob) {
            case .running, nil:
                return FleetHostJob(.working, reach == .ready ? "Updating…" : "Updating… waiting for the host")
            case .failed:
                return FleetHostJob(.failed, "Update failed")
            case .outcomeUnknown:
                return FleetHostJob(.failed, "Couldn't confirm the update")
            case .succeeded:
                guard hermesJob.isSettled else { return FleetHostJob(.working, "Finishing…") }
                guard hermesNeedsGateway else { return FleetHostJob(.done, updatedText) }
                if gatewayJob.receipt != nil || gatewayJob.isStarting || gatewayJob.error != nil {
                    let gateway = self.gateway
                    return gateway.kind == .done ? FleetHostJob(.done, updatedText) : gateway
                }
                return FleetHostJob(.needsRestart, "Updated · Needs restart")
            }
        }
        if let unavailable { return unavailable }
        guard let check = operations?.updateCheck else {
            if let operations, !operations.isMutating, operations.errorMessage != nil {
                return FleetHostJob(.failed, "Couldn't check for updates")
            }
            return FleetHostJob(.checking, "Checking…")
        }
        let behind = check.behindText
        guard check.updateAvailable else { return FleetHostJob(.current, "Up to date · \(check.currentVersion)") }
        return check.canApply
            ? FleetHostJob(.pending, behind)
            : FleetHostJob(.manual, "\(behind). Update Hermes on the computer.")
    }

    private var updatedText: String {
        operations?.updateCheck.map { "Updated · \($0.currentVersion)" } ?? "Updated"
    }

    // MARK: Plugin

    var pluginJob: FleetHostJob {
        if let unavailable { return unavailable }
        guard let plugin else { return FleetHostJob(.checking, "Checking…") }
        let installed = plugin.installedVersion ?? "Unknown version"
        switch plugin.state {
        case .idle, .checking:
            return FleetHostJob(.checking, "Checking…")
        case .notInstalled:
            return FleetHostJob(.manual, "Not installed")
        case .upToDate:
            let running = plugin.runningVersion ?? installed
            return pluginUpdatedHere
                ? FleetHostJob(.done, "Updated · \(running)")
                : FleetHostJob(.current, "Up to date · \(running)")
        case .updateAvailable:
            return FleetHostJob(.pending, "\(installed) → \(plugin.latestVersion ?? "newer")")
        case .updating:
            return FleetHostJob(.working, "Installing \(plugin.latestVersion ?? "the update")…")
        case .restartNeeded:
            // A restart already ran and the old code still runs: only the computer can finish.
            if pluginRestartTried, let message = plugin.message { return FleetHostJob(.manual, message) }
            return FleetHostJob(.needsRestart, "\(installed) installed · Needs restart")
        case .restarting:
            return FleetHostJob(.working, "Restarting…")
        case .failed:
            return FleetHostJob(.failed, plugin.message ?? "Couldn't update the plugin")
        }
    }

    // MARK: Gateway

    var gateway: FleetHostJob {
        if gatewayJob.isStarting { return FleetHostJob(.working, "Restarting…") }
        if let error = gatewayJob.error { return FleetHostJob(.failed, error) }
        if gatewayJob.receipt != nil {
            switch phase(gatewayJob) {
            case .running, nil: return FleetHostJob(.working, "Restarting…")
            case .succeeded: return FleetHostJob(.done, "Restarted")
            case .failed: return FleetHostJob(.failed, "Restart failed")
            case .outcomeUnknown: return FleetHostJob(.failed, "Couldn't confirm the restart")
            }
        }
        if let unavailable { return unavailable }
        guard let overview = operations?.overview else { return FleetHostJob(.checking, "Checking…") }
        if overview.gatewayState == "draining" { return FleetHostJob(.current, "Paused for new messages") }
        return FleetHostJob(.current, overview.gatewayRunning ? "Running" : "Stopped")
    }
}

/// Fleet settings: Update Hermes, update the bighelp plugin and restart the
/// gateway on every host at once. Each host runs the single-host flows
/// (`HostOperationsStore`, `HostPluginUpdateModel`), so a host's progress and
/// result read the same as on its own System page, and one host's failure
/// never stops the others.
@MainActor
@Observable
final class FleetMaintenanceStore {
    private(set) var hosts: [FleetMaintenanceHost] = []
    private(set) var isRefreshing = false
    private(set) var hasChecked = false

    @ObservationIgnored private let connector: any FleetMaintenanceConnecting
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let maximumPolls: Int

    /// Hermes updates can take minutes; follow one for up to about ten.
    init(connector: any FleetMaintenanceConnecting, pollInterval: Duration = .seconds(2), maximumPolls: Int = 300) {
        self.connector = connector
        self.pollInterval = pollInterval
        self.maximumPolls = maximumPolls
        syncHosts()
    }

    func host(_ id: UUID) -> FleetMaintenanceHost? { hosts.first { $0.id == id } }

    var hermesCandidates: [FleetMaintenanceHost] { hosts.filter { $0.hermes.kind == .pending } }
    var pluginCandidates: [FleetMaintenanceHost] { hosts.filter { $0.pluginJob.kind == .pending } }
    var gatewayCandidates: [FleetMaintenanceHost] { hosts.filter { $0.reach == .ready && !$0.gateway.isWorking } }

    /// Follows the configured hosts: new ones are added, removed ones dropped.
    func syncHosts() {
        let current = connector.hosts
        hosts = current.map { host in
            let row = hosts.first { $0.id == host.id } ?? FleetMaintenanceHost(id: host.id, name: host.name)
            row.name = host.name
            return row
        }
    }

    /// Checks every host once when the page first shows.
    func refreshIfNeeded() async {
        guard !hasChecked else { return }
        await refresh()
    }

    /// Connects each host and reads where it stands. Hosts with work running are left alone.
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        syncHosts()
        await each(hosts.filter { !$0.isBusy }) { row in await self.check(row, force: force) }
        hasChecked = true
    }

    private func check(_ row: FleetMaintenanceHost, force: Bool) async {
        if row.operations?.ownsScope != true || row.plugin == nil { await connect(row) }
        guard row.reach == .ready, let operations = row.operations, let plugin = row.plugin else { return }
        // A fresh look: what this page did last time is history now.
        row.hermesJob = .init()
        row.gatewayJob = .init()
        row.hermesNeedsGateway = false
        row.pluginUpdatedHere = false
        row.pluginRestartTried = false
        let pluginCheck = Task { if force { await plugin.check() } else { await plugin.checkIfNeeded() } }
        await operations.refreshOverview()
        await operations.checkForUpdates(force: force)
        await pluginCheck.value
    }

    /// A new connection, and with it a new System store; the last one stops.
    private func connect(_ row: FleetMaintenanceHost) async {
        row.operations?.retire()
        row.operations = nil
        row.reach = .connecting
        switch await connector.connect(row.id) {
        case .ready(let operations, let plugin):
            row.operations = operations
            row.plugin = plugin
            row.reach = .ready
        case .offline(let message):
            row.reach = .offline(message)
        case .signedOut:
            row.reach = .signedOut
        }
    }

    /// Runs `body` for every host at once and returns when all are done.
    private func each(_ rows: [FleetMaintenanceHost],
                      _ body: @escaping @MainActor @Sendable (FleetMaintenanceHost) async -> Void) async {
        let tasks = rows.map { row in Task { await body(row) } }
        for task in tasks { await task.value }
    }

    // MARK: Update Hermes

    func updateHermesEverywhere() async {
        await each(hermesCandidates) { row in await self.updateHermes(row) }
    }

    private func updateHermes(_ row: FleetMaintenanceHost) async {
        guard let operations = row.operations, operations.canAct else { return }
        row.hermesJob = .init(isStarting: true)
        row.hermesNeedsGateway = false
        guard let receipt = await launch(.hermesUpdate, on: operations, { await operations.applyReviewedUpdate() }) else {
            row.hermesJob = .init(error: "Couldn't start the update")
            return
        }
        row.hermesJob = .init(receipt: receipt, phase: .running)
        let phase = await follow(row, \.hermesJob)
        guard phase == .succeeded else {
            row.hermesJob.isSettled = true
            return
        }
        // Read the host again: its new version, and whether the gateway still runs old code.
        if let operations = row.operations {
            await operations.checkForUpdates(force: false)
            row.hermesNeedsGateway = operations.updateReceipt?.gatewayRestartIncomplete == true
        }
        row.hermesJob.isSettled = true
    }

    /// The Restart button beside a host whose Hermes update left the gateway on old code.
    func finishHermesUpdate(on hostID: UUID) async {
        guard let row = host(hostID), row.hermes.kind == .needsRestart else { return }
        await restartGateway(row)
    }

    // MARK: bighelp plugin

    func updatePluginEverywhere() async {
        await each(pluginCandidates) { row in
            guard let plugin = row.plugin else { return }
            row.pluginUpdatedHere = true
            row.pluginRestartTried = false
            _ = await plugin.update()
        }
    }

    /// The Restart button beside a host whose plugin update needs one.
    func restartPlugin(on hostID: UUID) async {
        guard let row = host(hostID), let plugin = row.plugin, plugin.state == .restartNeeded else { return }
        row.pluginUpdatedHere = true
        row.pluginRestartTried = true
        await plugin.restart()
    }

    // MARK: Gateway

    func restartGatewaysEverywhere() async {
        await each(gatewayCandidates) { row in await self.restartGateway(row) }
    }

    private func restartGateway(_ row: FleetMaintenanceHost) async {
        if row.operations?.ownsScope != true { await connect(row) }
        guard let operations = row.operations, operations.canAct else { return }
        row.gatewayJob = .init(isStarting: true)
        guard let receipt = await launch(.gatewayRestart, on: operations, { await operations.launchGateway(.restart) })
        else {
            row.gatewayJob = .init(error: "Couldn't start the restart")
            return
        }
        row.gatewayJob = .init(receipt: receipt, phase: .running)
        _ = await follow(row, \.gatewayJob)
        row.gatewayJob.isSettled = true
    }

    // MARK: Following a background action

    /// Starts an action through the System store and returns the receipt it
    /// admitted, or nil when the host didn't start it.
    private func launch(_ action: HermesHostAction, on operations: HostOperationsStore,
                        _ start: () async -> Void) async -> HermesHostActionReceipt? {
        let previous = operations.actionReceipts.last { $0.action == action }?.id
        await start()
        guard let receipt = operations.actionReceipts.last(where: { $0.action == action }),
              receipt.id != previous else { return nil }
        return receipt
    }

    /// Waits for an action to finish. The System store tracks it; when Hermes
    /// restarts under the connection, this reconnects and keeps reading the
    /// same action's status. It never starts the action again.
    private func follow(_ row: FleetMaintenanceHost,
                        _ job: ReferenceWritableKeyPath<FleetMaintenanceHost, FleetMaintenanceHost.Job>) async
        -> HermesHostActionStatus.Phase? {
        guard let receipt = row[keyPath: job].receipt else { return nil }
        for _ in 0..<maximumPolls {
            if let phase = row.operations?.actionStatuses[receipt.id]?.phase {
                row[keyPath: job].phase = phase
                if phase != .running { return phase }
            }
            do { try await Task.sleep(for: pollInterval) } catch { return nil }
            if row.operations?.ownsScope != true { await connect(row) }
            if let operations = row.operations, operations.ownsScope { await operations.pollAction(receipt) }
        }
        row[keyPath: job].error = "Still not confirmed. Pull down to check again."
        return nil
    }
}
