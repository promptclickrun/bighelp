import Observation
import SwiftUI

/// Keeps a host's bighelp plugin current: compares the installed and running
/// versions with the newest release on GitHub, updates it, restarts the Hermes
/// dashboard and messaging gateway so the new code loads, and checks that the
/// new version is actually running.
@MainActor
@Observable
final class HostPluginUpdateModel {
    enum State: Equatable {
        case idle, checking, notInstalled, upToDate, updateAvailable, restartNeeded, updating, restarting, failed
    }

    let hostID: UUID
    /// The newest release, once GitHub has answered.
    private(set) var release: PluginRelease?
    var latestVersion: String? { release?.version }
    private(set) var state: State = .idle
    private(set) var installedVersion: String?
    private(set) var runningVersion: String?
    private(set) var message: String?

    /// The running plugin can restart the Hermes dashboard it runs in (2.17.0 and later): the process
    /// that serves this app's connection and the plugin's routes. Hermes itself can't, so a plugin
    /// the dashboard hasn't loaded yet (a first install) ends with a restart on the computer.
    private(set) var canRestartHost = false
    /// False when the dashboard serving this app answered that the plugin's routes don't exist: the
    /// plugin is on disk, but the dashboard hasn't loaded it, and only a restart there starts it.
    private(set) var isLoaded = true
    @ObservationIgnored private var runtimeID: String?
    @ObservationIgnored private weak var registry: BighelpHostRegistry?
    @ObservationIgnored private let releases: any PluginReleaseResolving

    init(registry: BighelpHostRegistry?, hostID: UUID, releases: (any PluginReleaseResolving)? = nil) {
        self.registry = registry
        self.hostID = hostID
        self.releases = releases ?? GitHubPluginReleaseSource.shared
    }

    /// One model per host, so Settings, the host list and the host page agree.
    private static var shared: [UUID: HostPluginUpdateModel] = [:]

    static func model(for hostID: UUID, registry: BighelpHostRegistry) -> HostPluginUpdateModel {
        if let model = shared[hostID], model.registry === registry { return model }
        let model = HostPluginUpdateModel(registry: registry, hostID: hostID)
        shared[hostID] = model
        return model
    }

    /// Only an existing model; views that merely show a badge don't start checks.
    static func existingModel(for hostID: UUID) -> HostPluginUpdateModel? { shared[hostID] }

    /// Settings flags the host while this is true.
    var needsAttention: Bool { state == .updateAvailable || state == .restartNeeded }

    /// Short line for the Settings menu and the computers list.
    var attentionTitle: String? {
        switch state {
        case .updateAvailable: "bighelp plugin update available"
        case .restartNeeded: "Restart Hermes so the plugin takes effect"
        default: nil
        }
    }

    /// Running code too old to restart itself: only the computer can finish the update.
    var needsRestartOnComputer: Bool { state == .restartNeeded && !canRestartHost }
    var isWorking: Bool { [.checking, .updating, .restarting].contains(state) }

    /// What the versions mean, given the installed files, the running code and the newest release.
    /// `loaded` is false when the dashboard hasn't loaded the installed plugin at all.
    static func state(installed: String?, running: String?, latest: String?, loaded: Bool = true) -> State {
        func isCurrent(_ version: String?) -> Bool {
            guard let version, let latest else { return true }
            // A newer host is never downgraded.
            return HostPluginPin.compare(version, latest) != .orderedAscending
        }
        if !isCurrent(installed) { return .updateAvailable }
        if !loaded || !isCurrent(running) { return .restartNeeded }
        return .upToDate
    }

    /// Asks GitHub for the newest release again.
    func check() async {
        guard !isWorking else { return }
        state = .checking
        message = nil
        await ownCheck(askGitHub: true)
    }

    /// Checks once per app session unless asked again.
    func checkIfNeeded() async {
        guard state == .idle || state == .failed, !isWorking else { return }
        state = .checking
        message = nil
        await ownCheck(askGitHub: false)
    }

    /// Reads the computer again, without asking GitHub: what it has installed and what its dashboard runs.
    func reload() async {
        guard !isWorking else { return }
        state = .checking
        message = nil
        await ownCheck(askGitHub: false)
    }

    /// The model for a computer whose plugin just changed (installed, turned on or updated), read
    /// again so a restart prompt knows what it can restart. A newer Hermes loads a new plugin's
    /// routes on their first use, and then the plugin can restart the dashboard itself.
    static func afterPluginChange(hostID: UUID, registry: BighelpHostRegistry) async -> HostPluginUpdateModel {
        let model = model(for: hostID, registry: registry)
        await model.reload()
        return model
    }

    /// Screens start checks from `.task`, which SwiftUI cancels when the connection
    /// flips right after connecting. That cancelled the host requests mid-check and
    /// left "couldn't read this computer's plugins", so the check runs on its own.
    private func ownCheck(askGitHub: Bool) async {
        await Task { await refresh(askGitHub: askGitHub) }.value
    }

    /// Installs the newest release. Returns true when the new files are in place.
    func update() async -> Bool {
        guard state == .updateAvailable, let pin = release?.pin, let registry,
              let connection = currentConnection() else { return false }
        guard let lock = registry.beginPluginManagement(hostID: hostID) else {
            message = "Another plugin change is running on this host. Try again in a moment."
            return false
        }
        defer { registry.endPluginManagement(hostID: hostID, owner: lock) }
        state = .updating
        message = "Installing bighelp plugin \(latestVersion ?? "")…"
        var updateFailed = false
        do { _ = try await connection.workspace.managePlugins(pin.updateParameters) } catch { updateFailed = true }
        // Trust what the host now reports, not the install call's outcome.
        guard let installed = try? await installedPlugin(connection.workspace), installed.found else {
            fail(updateFailed
                 ? "The update didn't finish. Check your host connection and try again."
                 : "bighelp couldn't confirm the update. Check again in a moment.")
            return false
        }
        installedVersion = installed.version
        guard installed.pinnedSHA == pin.revision
                || Self.state(installed: installed.version, running: nil, latest: latestVersion) != .updateAvailable else {
            fail("The host still has version \(installed.version ?? "unknown"). Try the update again.")
            return false
        }
        state = .restartNeeded
        message = canRestartHost
            ? "Installed \(installed.version ?? latestVersion ?? "the update"). Restart Hermes to start using it."
            : Self.restartOnComputerMessage(installed: installed.version ?? latestVersion, running: runningVersion)
        return true
    }

    /// Restarts the messaging gateway, then the Hermes dashboard when the running plugin can: an
    /// installed, turned-on or updated plugin takes effect only after both. Then confirms the running
    /// version and tells the app the computer changed, so it reads it again.
    func restart() async {
        guard !isWorking, let connection = currentConnection() else { return }
        let restartsDashboard = canRestartHost
        state = .restarting
        let gatewayRestarted = await restartGateway(connection)
        let dashboardRestarted = restartsDashboard ? await restartDashboard(connection) : false
        await finishRestart()
        var said = [gatewayRestarted ? "The messaging gateway restarted." : "The messaging gateway didn't restart."]
        if restartsDashboard {
            said.insert(dashboardRestarted ? "The Hermes dashboard restarted." : "The Hermes dashboard didn't restart.", at: 0)
        }
        switch state {
        case .upToDate:
            said.append("bighelp plugin \(runningVersion ?? installedVersion ?? "") is running.")
        case .restartNeeded where dashboardRestarted:
            said.append("It still runs plugin \(runningVersion ?? "an older version"). Restart the dashboard on your computer to finish.")
        case .restartNeeded:
            // What's left to do on the computer, as the check after the restart said it.
            if let message { said.append(message) }
        default:
            return
        }
        message = said.joined(separator: " ")
    }

    /// Restarts only the Hermes dashboard, through the plugin running in it. bighelp's connection
    /// drops while it restarts and comes back once it's up.
    func restartDashboard() async {
        guard !isWorking, canRestartHost, let connection = currentConnection() else { return }
        state = .restarting
        let restarted = await restartDashboard(connection)
        await finishRestart()
        guard state != .failed else { return }
        message = restarted
            ? "The Hermes dashboard restarted." + (state == .upToDate ? " bighelp plugin \(runningVersion ?? installedVersion ?? "") is running." : "")
            : "The Hermes dashboard didn't restart. Restart it on your computer."
    }

    /// Hooks such as reply alerts run in the gateway's own copy of the plugin.
    private func restartGateway(_ connection: Connection) async -> Bool {
        message = "Restarting the messaging gateway…"
        do {
            let operations = DirectHermesHostOperationsClient(
                rpc: connection.direct, http: connection.direct, owner: connection.owner,
                currentOwner: { [weak self] in self?.currentConnection()?.owner }
            )
            let receipt = try await operations.launchMessagingGateway(.restart, profileID: connection.workspace.selectedProfile)
            let result = try await operations.poll(receipt, attempts: 30, intervalNanoseconds: 1_000_000_000)
            return result.phase == .succeeded
        } catch {
            return false
        }
    }

    /// The app's own connection and screens run in the dashboard's copy. The connection drops as the
    /// dashboard restarts, which is expected; false only when the plugin refused before restarting.
    private func restartDashboard(_ connection: Connection) async -> Bool {
        message = "Restarting the Hermes dashboard…"
        let previousRuntime = runtimeID
        do {
            try await connection.plugin.restartHost()
        } catch WorkspaceClientError.rejected, WorkspaceClientError.unavailable {
            return false
        } catch {}
        await waitForHost(previousRuntime: previousRuntime)
        return true
    }

    private func finishRestart() async {
        await refresh()
        registry?.noteServicesChanged(hostID: hostID)
    }

    // MARK: Checks

    private struct Connection {
        let workspace: DirectHermesWorkspaceStore
        let direct: DirectHermesClient
        let owner: WorkspaceOwner
        let plugin: DirectHermesNativePluginClient
    }

    private func currentConnection() -> Connection? {
        guard let registry, let host = registry.hosts.first(where: { $0.id == hostID }) else { return nil }
        let workspace = registry.workspace(for: host)
        let generation = registry.generation
        guard let verified = try? workspace.verifiedConnection(for: host, generation: generation) else { return nil }
        let direct = verified.client, owner = verified.owner
        let connectionGeneration = owner.connectionGeneration
        let plugin = DirectHermesNativePluginClient(http: direct, owner: owner, currentOwner: { [weak registry] in
            registry?.generation == generation && workspace.connectionGeneration == connectionGeneration
                && workspace.isConnected ? owner : nil
        })
        return Connection(workspace: workspace, direct: direct, owner: owner, plugin: plugin)
    }

    private func refresh(askGitHub: Bool = false) async {
        // After a restart on the computer the old connection is gone; try once more.
        if currentConnection() == nil, let registry, let host = registry.hosts.first(where: { $0.id == hostID }) {
            let workspace = registry.workspace(for: host)
            if !workspace.isConnected { await workspace.reconnect() }
        }
        guard let connection = currentConnection() else {
            fail("Connect to this computer to check its bighelp plugin.")
            return
        }
        do {
            let context = try await connection.plugin.loadContext(force: true)
            runningVersion = HostPluginPin.validVersion(context.pluginVersion) ? context.pluginVersion : nil
            runtimeID = context.runtimeID
            canRestartHost = context.features.contains(DirectHermesNativePluginClient.hostRestartFeature)
            isLoaded = true
        } catch {
            runningVersion = nil
            canRestartHost = false
            // Only a missing route says the dashboard hasn't loaded the plugin; a dropped answer says nothing.
            if case WorkspaceClientError.unavailable(.pluginRequired) = error { isLoaded = false } else { isLoaded = true }
        }
        guard let installed = try? await installedPlugin(connection.workspace) else {
            fail("bighelp couldn't read this computer's plugins. Check again in a moment.")
            return
        }
        installedVersion = installed.version
        guard installed.found else {
            state = .notInstalled
            message = "The bighelp plugin isn't installed on this computer."
            return
        }
        var releaseError: (any Error)?
        do {
            release = try await releases.latest(refresh: askGitHub)
        } catch {
            releaseError = error
        }
        state = Self.state(installed: installed.version, running: runningVersion, latest: latestVersion,
                           loaded: isLoaded)
        if state == .upToDate, let releaseError {
            // Without the newest release there's no telling whether an update exists.
            fail((releaseError as? LocalizedError)?.errorDescription ?? PluginReleaseError.unreachable.errorDescription ?? "")
            return
        }
        switch state {
        case .updateAvailable:
            message = "Version \(latestVersion ?? "") is available."
        case .restartNeeded where !isLoaded:
            message = Self.notLoadedMessage(installed: installed.version)
        case .restartNeeded:
            message = canRestartHost
                ? "Version \(installed.version ?? latestVersion ?? "") is installed, but Hermes is still running \(runningVersion ?? "an older version"). Restart Hermes to start using it."
                : Self.restartOnComputerMessage(installed: installed.version, running: runningVersion)
        default:
            message = nil
        }
    }

    private struct Installed {
        let found: Bool
        let version: String?
        let pinnedSHA: String?
    }

    private func installedPlugin(_ workspace: DirectHermesWorkspaceStore) async throws -> Installed {
        let rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
        guard let row = rows.first else { return Installed(found: false, version: nil, pinnedSHA: nil) }
        return Installed(found: true, version: row.version, pinnedSHA: row.pinnedSHA)
    }

    /// Waits for the restarted process to accept connections again (up to ~90 s).
    private func waitForHost(previousRuntime: String?) async {
        guard let registry, let host = registry.hosts.first(where: { $0.id == hostID }) else { return }
        let workspace = registry.workspace(for: host)
        for _ in 0..<45 {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if !workspace.isConnected { await workspace.reconnect() }
            guard let connection = currentConnection(),
                  let context = try? await connection.plugin.loadContext(force: true) else { continue }
            if context.runtimeID != previousRuntime { return }
        }
    }

    static func restartOnComputerMessage(installed: String?, running: String?) -> String {
        "Version \(installed ?? "the update") is installed, but Hermes still runs \(running ?? "an older version"). "
            + "Restart the Hermes dashboard on your computer once, then \(BighelpPlatform.isMac ? "click" : "tap") Check for Updates. "
            + "Later updates restart from here."
    }

    /// The plugin is on disk, but the dashboard hasn't loaded it, so nothing of it runs to restart from here.
    static func notLoadedMessage(installed: String?) -> String {
        "Version \(installed ?? "") is installed, but the Hermes dashboard hasn't loaded it yet. "
            + "Restart the dashboard on your computer once, then \(BighelpPlatform.isMac ? "click" : "tap") Check for Updates. "
            + "Later restarts work from here."
    }

    private func fail(_ text: String) {
        state = .failed
        message = text
    }
}

/// A computer's bighelp plugin: its version, and Update or Restart as the one
/// obvious button when it's behind.
struct HostPluginUpdateSection: View {
    let model: HostPluginUpdateModel
    @State private var restartPrompt: HostPluginUpdateModel?

    var body: some View {
        Section {
            LabeledContent("Version", value: model.installedVersion ?? "—")
                .accessibilityIdentifier("settings.plugin.installed")
            if let running = model.runningVersion, running != model.installedVersion {
                LabeledContent("Running", value: running)
                    .accessibilityIdentifier("settings.plugin.running")
            }
            switch model.state {
            case .updateAvailable:
                BighelpActionRow(title: "Update Plugin", detail: "Version \(model.latestVersion ?? "") is ready",
                                 systemImage: "arrow.down.circle.fill") {
                    Task { if await model.update() { restartPrompt = model } }
                }
                .accessibilityLabel("Update plugin to \(model.latestVersion ?? "the latest version")")
                .accessibilityIdentifier("settings.plugin.update")
            case .restartNeeded where model.canRestartHost:
                BighelpActionRow(title: "Restart Hermes", detail: "Restarts the dashboard and the gateway",
                                 systemImage: "arrow.clockwise") { restartPrompt = model }
                    .accessibilityIdentifier("settings.plugin.restart")
            case .upToDate where model.message == nil:
                Label("Up to date", systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("settings.plugin.up-to-date")
            default:
                EmptyView()
            }
            if let message = statusMessage {
                Label {
                    Text(message)
                } icon: {
                    if model.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: statusSymbol)
                    }
                }
                .font(.bighelp(.footnote))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.plugin.status")
            }
            if model.state == .updateAvailable, let release = model.release, !release.whatsNew.isEmpty {
                DisclosureGroup("What's new in \(release.version)") {
                    Text(release.whatsNew)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("settings.plugin.whats-new")
            }
            if [.idle, .notInstalled, .upToDate, .failed].contains(model.state)
                || (model.state == .restartNeeded && !model.canRestartHost) {
                Button("Check for Updates", systemImage: "arrow.triangle.2.circlepath") { Task { await model.check() } }
                    .accessibilityIdentifier("settings.plugin.check")
            }
        } header: {
            Text("bighelp plugin")
        }
        .pluginRestartPrompt($restartPrompt)
    }

    private var statusSymbol: String {
        switch model.state {
        case .failed: "exclamationmark.triangle"
        case .upToDate: "checkmark.circle.fill"
        default: "info.circle"
        }
    }

    /// Only what needs saying: progress, a problem, a step on the computer, or
    /// that an update finished. "Version 3.2 is available" is already the button.
    private var statusMessage: String? {
        switch model.state {
        case .checking: "Checking the plugin…"
        case .updateAvailable: nil
        default: model.message
        }
    }
}

/// After the bighelp plugin is installed, turned on or updated: it takes effect only once the Hermes
/// dashboard and the messaging gateway restart, so this asks to restart both. When nothing of the
/// plugin runs in the dashboard yet (a first install on a Hermes that loads plugins only as it
/// starts), the app can restart only the gateway, and the prompt says to restart the dashboard on the
/// computer. Shows while `model` is set; `onFinished` runs after the restart, or after Later.
struct PluginRestartPrompt: ViewModifier {
    @Binding var model: HostPluginUpdateModel?
    var onFinished: @MainActor (_ restarted: Bool) async -> Void = { _ in }

    static let restartBothMessage = "The plugin takes effect only after the Hermes dashboard and the messaging gateway restart. Replies in progress on your computer stop, and bighelp reconnects."
    static let restartGatewayMessage = "The plugin takes effect only after the Hermes dashboard and the messaging gateway restart. bighelp can restart the gateway now. Then restart the dashboard on your computer."

    func body(content: Content) -> some View {
        content.alert("Restart Hermes to finish?",
                      isPresented: Binding(get: { model != nil }, set: { if !$0 { model = nil } }),
                      presenting: model) { model in
            Button(model.canRestartHost ? "Restart Both" : "Restart Gateway") {
                Task {
                    await model.restart()
                    await onFinished(true)
                }
            }
            .accessibilityIdentifier("plugin-restart.confirm")
            Button("Later", role: .cancel) { Task { await onFinished(false) } }
                .accessibilityIdentifier("plugin-restart.later")
        } message: { model in
            Text(model.canRestartHost ? Self.restartBothMessage : Self.restartGatewayMessage)
        }
    }
}

extension View {
    func pluginRestartPrompt(_ model: Binding<HostPluginUpdateModel?>,
                             onFinished: @escaping @MainActor (_ restarted: Bool) async -> Void = { _ in }) -> some View {
        modifier(PluginRestartPrompt(model: model, onFinished: onFinished))
    }
}

#if DEBUG && targetEnvironment(simulator)
/// `-test-plugin-update`: the plugin version section in each state, for screenshots.
enum HostPluginUpdateFixture {
    static let launchArgument = "-test-plugin-update"

    @MainActor
    static func rootView() -> some View {
        NavigationStack {
            Form {
                HostPluginUpdateSection(model: model(.updateAvailable, installed: "2.15.0", running: "2.15.0",
                                                     message: "Version 2.17.0 is available."))
                HostPluginUpdateSection(model: model(.restartNeeded, installed: "2.17.0", running: "2.15.0",
                                                     message: HostPluginUpdateModel.restartOnComputerMessage(
                                                        installed: "2.17.0", running: "2.15.0")))
                HostPluginUpdateSection(model: model(.restartNeeded, installed: "2.17.1", running: "2.17.0",
                                                     message: "Installed 2.17.1. Restart Hermes to start using it.",
                                                     canRestartHost: true))
                HostPluginUpdateSection(model: model(.restarting, installed: "2.17.1", running: "2.17.0",
                                                     message: "Restarting Hermes…"))
                HostPluginUpdateSection(model: model(.upToDate, installed: "2.17.0", running: "2.17.0",
                                                     message: "bighelp plugin 2.17.0 is installed and running."))
            }
            .navigationTitle("Plugin updates")
        }
    }

    /// Also Settings › System's fixture (`SystemPageFixture`).
    @MainActor
    static func model(_ state: HostPluginUpdateModel.State, installed: String, running: String?,
                      message: String, canRestartHost: Bool = false, loaded: Bool = true) -> HostPluginUpdateModel {
        let model = HostPluginUpdateModel(registry: nil, hostID: UUID())
        model.freeze(state, installed: installed, running: running, message: message, canRestartHost: canRestartHost,
                     loaded: loaded)
        return model
    }
}

extension HostPluginUpdateModel {
    fileprivate func freeze(_ state: State, installed: String, running: String?, message: String, canRestartHost: Bool,
                            loaded: Bool) {
        release = try? PluginRelease(version: "2.17.0", pin: HostPluginPin(revision: String(repeating: "a", count: 40)),
                                     notes: "## 2.17.0: in-app restart\n\n- The app can restart Hermes after an update.")
        self.state = state
        self.canRestartHost = canRestartHost
        isLoaded = loaded
        installedVersion = installed
        runningVersion = running
        self.message = message
    }
}
#endif
