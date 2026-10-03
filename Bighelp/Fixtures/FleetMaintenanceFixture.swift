#if DEBUG
import Foundation
import Observation

/// Demo hosts for Fleet settings, answering the same Hermes routes a real
/// host does (update check, update, action status, gateway restart), so the
/// System page's own store runs against them. Every number is made up.
@MainActor
final class FleetMaintenanceFixture: FleetMaintenanceConnecting {
    enum Reach {
        case ready(FleetMaintenanceFixtureHTTP, FleetPluginFixture)
        case offline(String)
        case signedOut
    }

    struct Host {
        let id: UUID
        let name: String
        let reach: Reach
    }

    private let fixtureHosts: [Host]
    /// Bumped when a host restarts under its connection, like a real reconnect.
    private var connectionGenerations: [UUID: UUID] = [:]
    private(set) var connectCount: [UUID: Int] = [:]

    init(hosts: [Host]) {
        fixtureHosts = hosts
        for host in hosts {
            guard case .ready(let http, _) = host.reach else { continue }
            let id = host.id
            http.onConnectionDropped = { [weak self] in self?.connectionGenerations[id] = UUID() }
        }
    }

    var hosts: [FleetHost] {
        fixtureHosts.enumerated().map { FleetHost(id: $1.id, name: $1.name, isSelected: $0 == 0) }
    }

    func connect(_ hostID: UUID) async -> FleetMaintenanceReach {
        connectCount[hostID, default: 0] += 1
        guard let host = fixtureHosts.first(where: { $0.id == hostID }) else { return .offline("Couldn't reach this host.") }
        switch host.reach {
        case .offline(let message): return .offline(message)
        case .signedOut: return .signedOut
        case .ready(let http, let plugin):
            let generation = UUID()
            connectionGenerations[hostID] = generation
            let owner = WorkspaceOwner(
                authority: try! .direct(endpointIdentity: "https://\(hostID.uuidString.lowercased()).example",
                                        providerID: "basic", userID: "person"),
                authenticationGeneration: generation, connectionGeneration: generation
            )
            let current: @MainActor () -> WorkspaceOwner? = { [weak self] in
                self?.connectionGenerations[hostID] == generation ? owner : nil
            }
            let client = DirectHermesHostOperationsClient(rpc: FixtureRPC(), http: http, owner: owner, currentOwner: current)
            let operations = HostOperationsStore(hostName: host.name, profileID: "default", client: client,
                                                 isCurrent: { current() == owner })
            return .ready(operations: operations, plugin: plugin)
        }
    }

    /// Matches the all-hosts demo (`FleetFixtureReader`): Home Hermes is 12
    /// commits and a plugin release behind; Studio Mac is 3 commits behind and
    /// its update leaves the gateway to restart; Office Linux can't be reached.
    static func demo(arguments: [String] = ProcessInfo.processInfo.arguments) -> FleetMaintenanceFixture {
        let fast = arguments.contains("-disable-demo-delays")
        let latency: Duration = fast ? .milliseconds(150) : .milliseconds(600)
        let step: Duration = fast ? .milliseconds(500) : .seconds(2)
        return FleetMaintenanceFixture(hosts: [
            Host(id: FleetFixtureReader.homeID, name: "Home Hermes", reach: .ready(
                FleetMaintenanceFixtureHTTP(script: .init(version: "0.21.4", commitsBehind: 12), latency: latency),
                FleetPluginFixture(installed: "2.19.0", latest: "2.20.1", step: step))),
            Host(id: FleetFixtureReader.studioID, name: "Studio Mac", reach: .ready(
                FleetMaintenanceFixtureHTTP(script: .init(version: "0.21.3", commitsBehind: 3,
                                                          gatewayRestartIncomplete: true), latency: latency),
                FleetPluginFixture(installed: "2.18.2", latest: "2.20.1", step: step))),
            Host(id: FleetFixtureReader.officeID, name: "Office Linux", reach: .offline("Offline. Couldn't reach this host.")),
        ])
    }

    private final class FixtureRPC: DirectHermesRPC {
        var onEvent: ((DirectHermesEvent) -> Void)?
        func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            throw WorkspaceClientError.unavailable(.policyRestricted)
        }
        func disconnect() async {}
    }
}

/// One demo host's Hermes routes. An update or restart runs in the
/// background like Hermes' own actions: launched, reported running, then
/// finished with an exit code.
@MainActor
final class FleetMaintenanceFixtureHTTP: DirectHermesAuthenticatedHTTP {
    struct Script {
        var version: String
        var commitsBehind: Int
        var canApply = true
        var updateExitCode = 0
        var restartExitCode = 0
        /// The update finished, but the messaging gateway still runs old code.
        var gatewayRestartIncomplete = false
        /// Status reads that still say "running" before the result.
        var runningReads = 1
        /// Hermes restarts during its update and drops the app's connection.
        var dropsConnectionOnUpdate = false
    }

    var script: Script
    private let latency: Duration
    private var updated = false
    private var dropped = false
    private var reads: [String: Int] = [:]
    /// Launches in order, for tests: "hermes-update", "gateway-restart".
    private(set) var launches: [String] = []
    var onConnectionDropped: (() -> Void)?

    init(script: Script, latency: Duration = .zero) {
        self.script = script
        self.latency = latency
    }

    private static let processIDs = ["hermes-update": 4_101, "gateway-restart": 4_202]
    private static let actionID = String(repeating: "c", count: 32)

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        if latency > .zero { try await Task.sleep(for: latency) }
        switch (request.method, request.path) {
        case (.get, "/api/status"):
            return .object([
                "version": .string(currentVersion), "release_date": .string("2026-09-20"),
                "gateway_running": .boolean(true), "gateway_state": .string("running"),
                "gateway_busy": .boolean(false), "gateway_drainable": .boolean(true),
                "gateway_mode": .string("multiplexed"), "gateway_shared_with": .array([]),
                "active_agents": .integer(2), "active_sessions": .integer(1),
                "restart_drain_timeout": .integer(30), "overall": .string("healthy"),
                "components": .object(["gateway": .object(["status": .string("ok")])]),
            ])
        case (.get, "/api/hermes/update/check"):
            let behind = updated ? 0 : script.commitsBehind
            return .object([
                "install_method": .string("git"), "current_version": .string(currentVersion),
                "behind": .integer(behind), "update_available": .boolean(behind > 0),
                "can_apply": .boolean(script.canApply), "update_command": .string("hermes update"),
                "message": .null, "commits": .array([]),
            ])
        case (.get, "/api/hermes/update/receipt"):
            return .object([
                "receipt": .object([
                    "schema": .integer(1), "steps": .array([]), "skips": .array([]), "fleet": .array([]),
                    "gateway_restart": .object(["incomplete": .boolean(updated && script.gatewayRestartIncomplete)]),
                ]),
                "summary": .object(["outcome": .string("success"), "fleet_states": .array([])]),
            ])
        case (.post, "/api/hermes/update"):
            return launch("hermes-update")
        case (.post, "/api/gateway/restart"):
            return launch("gateway-restart")
        case (.get, let path) where path.hasPrefix("/api/actions/") && path.hasSuffix("/status"):
            let name = String(path.dropFirst("/api/actions/".count).dropLast("/status".count))
            if name == "hermes-update", script.dropsConnectionOnUpdate, !dropped {
                // Hermes restarts mid-update: this connection is gone, the update carries on.
                dropped = true
                onConnectionDropped?()
                throw URLError(.networkConnectionLost)
            }
            return status(name)
        default:
            throw DirectHermesError.unsupportedAuthentication
        }
    }

    private var currentVersion: String { updated ? "0.21.5" : script.version }

    private func launch(_ name: String) -> BighelpJSONValue {
        launches.append(name)
        reads[name] = 0
        return .object(["ok": .boolean(true), "name": .string(name), "pid": .integer(Self.processIDs[name] ?? 4_000),
                        "action_id": .string(Self.actionID)])
    }

    private func status(_ name: String) -> BighelpJSONValue {
        let read = reads[name, default: 0]
        reads[name] = read + 1
        let running = read < script.runningReads
        let exitCode = name == "hermes-update" ? script.updateExitCode : script.restartExitCode
        if !running, name == "hermes-update", exitCode == 0 { updated = true }
        return .object([
            "name": .string(name), "running": .boolean(running), "pid": .integer(Self.processIDs[name] ?? 4_000),
            "exit_code": running ? .null : .integer(exitCode), "action_id": .string(Self.actionID),
        ])
    }
}

/// A demo host's bighelp plugin, moving through the same states and words as
/// `HostPluginUpdateModel`: update available, installing, restart needed,
/// restarting, up to date.
@MainActor
@Observable
final class FleetPluginFixture: HostPluginUpdating {
    private(set) var state: HostPluginUpdateModel.State = .idle
    private(set) var installedVersion: String?
    private(set) var runningVersion: String?
    let latestVersion: String?
    private(set) var message: String?
    let canRestartHost = true
    var failsUpdate = false
    private let step: Duration

    init(installed: String, latest: String, step: Duration = .zero) {
        installedVersion = installed
        runningVersion = installed
        latestVersion = latest
        self.step = step
    }

    func check() async {
        guard ![.updating, .restarting].contains(state) else { return }
        state = .checking
        message = nil
        await pause()
        state = HostPluginUpdateModel.state(installed: installedVersion, running: runningVersion, latest: latestVersion)
        message = state == .updateAvailable ? "Version \(latestVersion ?? "") is available." : nil
    }

    func checkIfNeeded() async {
        guard state == .idle || state == .failed else { return }
        await check()
    }

    func update() async -> Bool {
        guard state == .updateAvailable else { return false }
        state = .updating
        message = "Installing bighelp plugin \(latestVersion ?? "")…"
        await pause()
        if failsUpdate {
            state = .failed
            message = "The update didn't finish. Check your host connection and try again."
            return false
        }
        installedVersion = latestVersion
        state = .restartNeeded
        message = "Installed \(latestVersion ?? "the update"). Restart Hermes to start using it."
        return true
    }

    func restart() async {
        guard state == .restartNeeded else { return }
        state = .restarting
        message = "Restarting Hermes…"
        await pause()
        runningVersion = installedVersion
        state = .upToDate
        message = "bighelp plugin \(runningVersion ?? "") is installed and running."
    }

    private func pause() async {
        if step > .zero { try? await Task.sleep(for: step) }
    }
}
#endif
