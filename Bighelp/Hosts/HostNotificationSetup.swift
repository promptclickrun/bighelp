import Foundation
import Observation

/// Main's notification implementation must verify the authenticated plugin
/// capability and recipient grant. Installed/configured-enabled is not readiness.
@MainActor
protocol HostPluginManagementServing: AnyObject {
    var isConnected: Bool { get }
    var savedConnection: DirectHermesSavedConnection? { get }
    func reconnect() async
    func managePlugins(_ params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue
}

extension DirectHermesWorkspaceStore: HostPluginManagementServing {}

@MainActor
protocol HostNotificationSetupServing {
    func enroll(host: BighelpConfiguredHost, connection: DirectHermesSavedConnection,
                isCurrent: @escaping @MainActor () -> Bool) async throws -> HostNotificationSetupResult
    /// Removes only this device's recipient trust/grant metadata, not host data.
    func removeLocalEnrollment(host: BighelpConfiguredHost) throws
    /// Clears one computer's notification setup on every side, however far it got.
    func resetHost(_ host: BighelpConfiguredHost) async
    /// Tells every computer with notifications on whether this phone wants Peer chats alerts.
    func applyAlertPreferences() async
    /// Gives this device's Quiet Hours to every computer with notifications on.
    func applyQuietHours() async -> BighelpQuietHoursSyncResult
}

extension HostNotificationSetupServing {
    func resetHost(_ host: BighelpConfiguredHost) async {}
    func applyAlertPreferences() async {}
    func applyQuietHours() async -> BighelpQuietHoursSyncResult { BighelpQuietHoursSyncResult() }
}

/// Whether agents talking to each other alert this phone (`hermes peer`, Bot Chat, and with plugin
/// 3.17.0 any agent's message to another, as from the agent that wrote it). Off unless the person
/// turns it on in Settings › Notifications.
enum BighelpPeerChatAlerts {
    static let key = "bighelp.notifications.peer-chats"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// Settings › Notifications › Workflows: which workflow alerts this device wants. All start on.
enum BighelpWorkflowAlerts {
    enum Kind: String, CaseIterable, Identifiable {
        case needsYou, succeeded, failed, cancelled
        var id: String { rawValue }
        var key: String { "bighelp.notifications.workflows.\(rawValue)" }
        var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }
        var detail: String {
            switch self {
            case .needsYou: "A run waits for your sign-off, or needs a look."
            case .succeeded: "A run finished."
            case .failed: "A run stopped with a problem."
            case .cancelled: "Someone cancelled a run."
            }
        }
    }

    static func isOn(_ kind: Kind) -> Bool { UserDefaults.standard.object(forKey: kind.key) as? Bool ?? true }

    /// What the computer stores for this device (plugin 3.7.0).
    static var current: [String: Bool] {
        Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0.rawValue, isOn($0)) })
    }
}

enum HostNotificationSetupResult: Sendable {
    case enabled
    case backendRestartRequired
    case prerequisitesRequired
}

enum HostNotificationState: String, Codable, Sendable {
    case notConfigured, checking, installing, installed, enabled, backendRestartRequired
    case verificationRequired, prerequisitesRequired, permissionDenied, managementRejected, unsupported, replacementRequired, outcomeUnknown
    case notConnected
    case releaseUnavailable
    /// The connection is signed in to another computer, or as someone else.
    case signInChanged

    /// The state saved with the host. Older builds can't read `signInChanged` and would refuse the
    /// whole saved host list, so it's saved as the nearest state they know.
    var saved: HostNotificationState { self == .signInChanged ? .notConnected : self }

    var message: String {
        switch self {
        case .notConfigured: "Notifications are off."
        case .checking: "Checking setup…"
        case .installing: "Installing plugin…"
        case .installed: "Plugin installed. Finishing setup…"
        case .enabled: "Notifications enabled."
        case .verificationRequired: "Check your saved setup to continue."
        case .backendRestartRequired: "Restart the hermes serve process on the host (not just the messaging gateway), then check again."
        case .prerequisitesRequired: "This computer needs notification support."
        case .permissionDenied: "This computer doesn't allow plugin installation."
        case .managementRejected: "This computer rejected installation. Check Hermes for details."
        case .unsupported: "This Hermes version doesn't support in-app installation."
        case .replacementRequired: "Update the existing bighelp plugin on this computer."
        case .outcomeUnknown: "Couldn't confirm setup. Check again, or use Set Up Again to start over."
        case .notConnected: "Can't reach this computer. Reconnect and check setup again."
        case .releaseUnavailable: "Couldn't reach GitHub for the newest bighelp plugin. Check the internet connection and try again."
        case .signInChanged: "This computer's sign-in changed. Sign in to this computer again, then check setup."
        }
    }
}

struct HostPluginIntent: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case consented, installRequested, toggleRequested, verified }
    let identifier: String
    let revision: String
    /// Nil means process current scope for every list/install/toggle operation.
    let profile: String?
    var phase: Phase
}

/// One exact plugin commit: a release the app installs and then reads back.
struct HostPluginPin: Equatable, Sendable {
    /// Formerly promptclickrun/loopdy-plugin. The plugin's updater accepts both
    /// names (bighelp-plugin #51 onward), and GitHub redirects the old one.
    let identifier = "promptclickrun/bighelp-plugin"
    let revision: String
    init(revision: String) throws {
        guard revision.utf8.count == 40,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DirectHermesError.invalidResponse
        }
        self.revision = revision
    }
    static func validVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
    }

    /// Numeric comparison of dotted versions ("2.16.1" > "2.9.0").
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }, b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
    var installParameters: [String: BighelpJSONValue] {
        ["action": .string("install"), "identifier": .string(identifier), "catalog_name": .null,
         "ref": .string(revision), "enable": .boolean(true), "force": .boolean(false)]
    }
    /// The stock manager has no custom-ref update verb. Replacing an older plugin
    /// uses its install API with force=true; the host kill list and scanner still
    /// run, and the exact revision is read back afterward.
    var updateParameters: [String: BighelpJSONValue] {
        ["action": .string("install"), "identifier": .string(identifier), "catalog_name": .null,
         "ref": .string(revision), "enable": .boolean(true), "force": .boolean(true)]
    }
}

struct HostInstalledPlugin: Equatable {
    let name: String
    let key: String
    let pinnedSHA: String?
    let configuredEnabled: Bool
    /// The version of the plugin files on disk (plugin.yaml), not necessarily the running one.
    var version: String? = nil

    static func decodeList(_ value: BighelpJSONValue) throws -> [HostInstalledPlugin] {
        guard let values = value.object?["plugins"]?.array, values.count <= 4096 else { throw DirectHermesError.invalidResponse }
        // Only bighelp is managed here. An unrelated plugin's new status or
        // metadata must not invalidate the exact target's installed readback.
        let targets = try values.filter { value in
            guard let name = value.object?["name"]?.string,
                  !name.isEmpty, name.utf8.count <= 256 else { throw DirectHermesError.invalidResponse }
            return name == "loopdy"
        }
        guard targets.count <= 1 else { throw DirectHermesError.invalidResponse }
        return try targets.map { value in
            guard let object = value.object, let name = object["name"]?.string,
                  let key = object["key"]?.string, !name.isEmpty, name.utf8.count <= 256,
                  !key.isEmpty, key.utf8.count <= 512, let status = object["status"]?.string,
                  ["enabled", "disabled", "not enabled"].contains(status) else {
                throw DirectHermesError.invalidResponse
            }
            if let pin = object["pinned_sha"], pin != .null {
                guard let revision = pin.string, (try? HostPluginPin(revision: revision)) != nil else {
                    throw DirectHermesError.invalidResponse
                }
            }
            let version = object["version"]?.string.flatMap { HostPluginPin.validVersion($0) ? $0 : nil }
            return Self(name: name, key: key, pinnedSHA: object["pinned_sha"]?.string,
                        configuredEnabled: status == "enabled", version: version)
        }
    }
}

@MainActor
@Observable
final class HostNotificationSetupModel {
    private(set) var state: HostNotificationState
    private(set) var isWorking = false
    /// What stopped setup, with its code. Nil while setup works or after it finishes.
    private(set) var failure: BighelpNotificationSetupFailure?
    /// The failure is from an earlier run: whatever stopped it may be fixed now.
    private(set) var failureIsFromEarlierRun = false
    /// The commit an install uses: the newest release, looked up only when one is needed.
    private(set) var pin: HostPluginPin?
    private(set) var release: PluginRelease?
    let hostID: UUID
    let enrollNotifications: Bool
    @ObservationIgnored private let registry: BighelpHostRegistry
    @ObservationIgnored private let management: any HostPluginManagementServing
    @ObservationIgnored private let releases: any PluginReleaseResolving
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var operation: UUID?

    /// `pin` fixes the commit up front (tests); otherwise the newest release is used.
    init(host: BighelpConfiguredHost, registry: BighelpHostRegistry, pin: HostPluginPin? = nil,
         releases: (any PluginReleaseResolving)? = nil,
         management: (any HostPluginManagementServing)? = nil, enrollNotifications: Bool = true,
         defaults: UserDefaults = .standard) {
        hostID = host.id
        self.registry = registry
        self.management = management ?? registry.workspace(for: host)
        self.pin = pin
        self.releases = releases ?? GitHubPluginReleaseSource.shared
        self.enrollNotifications = enrollNotifications
        self.defaults = defaults
        // Preserve the user's saved opt-in without prompting on every visit.
        // Actual grant and delivery authority still belong to the service ledger.
        state = enrollNotifications ? host.notificationState : .notConfigured
        // The code of a setup that stopped earlier stays with its message, on this build only:
        // an update can change what happens next.
        if enrollNotifications, let last = BighelpNotificationLastFailure.load(defaults), last.hostID == host.id,
           last.state == host.notificationState, last.build == BighelpNotificationFailureReport.build {
            failure = last.failure
            failureIsFromEarlierRun = true
        }
        #if DEBUG
        // Demo mode has no computer to set up, so a forced failure shows as soon as setup opens.
        if enrollNotifications, let forced = Self.forcedFailure() {
            failure = forced
            failureIsFromEarlierRun = false
            state = forced.state
            BighelpNotificationLastFailure.save(forced, hostID: host.id, defaults: defaults)
        }
        #endif
    }

    /// A push service failure: setup shows it as an error, not a warning.
    var providerFailure: BighelpManagedNotificationSetupError? { failure?.provider }

    var message: String {
        if let failure { return failure.message }
        guard !enrollNotifications else { return state.message }
        return switch state {
        case .notConfigured:
            "Add optional bighelp features to this computer."
        case .installed, .enabled:
            "Plugin installed."
        case .verificationRequired:
            "Check the installed plugin."
        case .prerequisitesRequired:
            "Update bighelp to install this plugin."
        default:
            state.message
        }
    }

    /// Trying again can help. False when the failure's way forward is something else (Set Up
    /// Again, turning notifications off and on, updating bighelp), so no Check Again shows.
    /// A plugin page has no other way forward, so it always offers one.
    var offersRetry: Bool {
        guard let failure, enrollNotifications else { return true }
        return failure.canRetry || failureIsFromEarlierRun
    }

    var actionTitle: String? {
        guard !isWorking, offersRetry else { return nil }
        return switch state {
        case .enabled:
            nil
        case .checking:
            "Check Again"
        case .installing, .outcomeUnknown:
            "Check Installed State"
        case .notConnected:
            "Retry Connection"
        case .signInChanged:
            "Check Setup Again"
        case .installed:
            enrollNotifications ? "Continue Notification Setup" : nil
        case .verificationRequired:
            enrollNotifications ? "Verify Notification Setup" : nil
        case .notConfigured:
            enrollNotifications ? "Enable Notifications" : "Install bighelp Plugin"
        case .backendRestartRequired:
            "Check After Backend Restart"
        case .managementRejected:
            "Retry Plugin Setup"
        case .permissionDenied:
            "Check Host Permission Again"
        case .unsupported:
            "Check Host Support Again"
        case .replacementRequired:
            "Check Installed Plugin Again"
        case .releaseUnavailable:
            "Try Again"
        case .prerequisitesRequired:
            enrollNotifications ? "Try Notification Setup Again" : "Check Plugin Requirements Again"
        }
    }

    /// Opening a plugin page is a read, not consent to install or enroll.
    func refreshInstalledState() async {
        guard !enrollNotifications, !isWorking,
              let host = registry.hosts.first(where: { $0.id == hostID }),
              let managementOwner = registry.beginPluginManagement(hostID: hostID) else { return }
        defer { registry.endPluginManagement(hostID: hostID, owner: managementOwner) }
        let generation = registry.generation
        let scope = registry.accountScope
        let request = UUID()
        operation = request
        isWorking = true
        defer { if operation == request { isWorking = false } }
        func owns() -> Bool {
            operation == request && registry.generation == generation
                && registry.accountScope == scope
                && registry.hosts.contains(where: { $0.id == hostID }) && !Task.isCancelled
        }
        state = .checking
        failure = nil
        do {
            if !management.isConnected { await management.reconnect() }
            guard owns() else { return }
            guard management.isConnected, let saved = management.savedConnection else { throw DirectHermesError.notConnected }
            guard host.owns(saved) else { throw DirectHermesError.identityChanged }
            let rows = try HostInstalledPlugin.decodeList(
                await management.managePlugins(["action": .string("list")])
            )
            guard owns() else { return }
            state = rows.first?.configuredEnabled == true ? .installed : .notConfigured
        } catch {
            guard owns() else { return }
            let named = BighelpNotificationSetupFailure(step: .pluginCheck, error: error)
            named.log()
            failure = named
            state = named.state
        }
    }

    func cancel() {
        let wasActive = operation != nil || isWorking
        operation = nil
        isWorking = false
        guard wasActive, var host = registry.hosts.first(where: { $0.id == hostID }) else { return }
        switch state {
        case .installing:
            // The request may still have reached the host. Preserve its intent
            // and require list readback instead of exposing another install.
            let named = BighelpNotificationSetupFailure(.pluginInstallMayBeRunning, step: .pluginInstall,
                                                        kind: .check("left_during_install"), state: .outcomeUnknown)
            note(named)
            state = .outcomeUnknown
            if enrollNotifications {
                host.notificationState = .outcomeUnknown
                try? registry.update(host)
            }
        case .checking:
            state = enrollNotifications ? host.notificationState : .notConfigured
        default:
            break
        }
        // Persisted install/toggle intent remains for readback. Never replay it.
    }

    /// Set Up Again: clears this computer's notification setup on every side (the
    /// computer, the notification service and this device), however far an earlier
    /// setup got, then sets it up fresh. For a setup that's stuck or half there.
    func setUpAgain() async {
        guard enrollNotifications, !isWorking, let host = registry.hosts.first(where: { $0.id == hostID }),
              let setup = registry.notificationSetup else { return }
        isWorking = true
        failure = nil
        state = .checking
        await setup.resetHost(host)
        isWorking = false
        await enable()
    }

    /// User consent authorizes one pinned install/enable in backend current scope,
    /// not a restart, force replacement, profile change, or Link enrollment.
    func enable() async {
        guard !isWorking, let original = registry.hosts.first(where: { $0.id == hostID }) else { return }
        guard let managementOwner = registry.beginPluginManagement(hostID: hostID) else { state = .checking; return }
        defer { registry.endPluginManagement(hostID: hostID, owner: managementOwner) }
        let owner = registry.generation
        let scope = registry.accountScope
        let operationID = UUID()
        operation = operationID
        isWorking = true
        failure = nil
        failureIsFromEarlierRun = false
        defer { if operation == operationID { isWorking = false } }
        @MainActor func owns() -> Bool {
            registry.generation == owner && registry.accountScope == scope && operation == operationID
                && registry.hosts.contains(where: { $0.id == hostID }) && !Task.isCancelled
        }
        var host = original
        let workspace = management
        // Where setup is, so an error says which step it stopped.
        var step = BighelpNotificationSetupStep.pluginCheck
        do {
            #if DEBUG
            if let forced = Self.forcedFailure() {
                try? await Task.sleep(for: .milliseconds(300))
                throw forced
            }
            #endif
            if !workspace.isConnected { await workspace.reconnect() }
            guard owns() else { return }
            guard workspace.isConnected else { throw DirectHermesError.notConnected }
            guard let saved = workspace.savedConnection, host.owns(saved) else {
                throw DirectHermesError.identityChanged
            }
            state = .checking
            var rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
            guard owns() else { return }
            var matches = rows.filter { $0.name == "loopdy" }
            guard matches.count <= 1 else {
                try fail(.duplicatePlugins, step, "several_plugins", state: .replacementRequired, host: &host); return
            }
            if let installed = matches.first {
                // A newer or equal plugin stays; GitHub being unreachable doesn't block enabling it.
                var target: HostPluginPin?
                if !enrollNotifications { target = try? await installTarget(for: host) }
                guard owns() else { return }
                if let pin = target, installed.pinnedSHA != pin.revision, isOlderThanRelease(installed) {
                    step = .pluginInstall
                    host.pluginIntent = HostPluginIntent(
                        identifier: pin.identifier, revision: pin.revision,
                        profile: nil, phase: .installRequested
                    )
                    try registry.update(host)
                    state = .installing
                    var updateError: (any Error)?
                    do { _ = try await workspace.managePlugins(pin.updateParameters) }
                    catch { updateError = error }
                    guard owns() else { return }
                    let observed = try HostInstalledPlugin.decodeList(
                        await workspace.managePlugins(["action": .string("list")])
                    ).filter { $0.name == "loopdy" }
                    guard owns() else { return }
                    guard observed.count == 1, let verified = observed.first,
                          verified.pinnedSHA == pin.revision, verified.configuredEnabled else {
                        if let updateError {
                            try fail(BighelpNotificationSetupFailure(step: step, error: updateError), host: &host)
                        } else {
                            try fail(.pluginInstallUnconfirmed, step, "update_not_listed", state: .outcomeUnknown, host: &host)
                        }
                        return
                    }
                    host.pluginIntent = HostPluginIntent(
                        identifier: pin.identifier, revision: pin.revision,
                        profile: nil, phase: .verified
                    )
                    try finish(.installed, host: &host)
                    return
                }
                if !installed.configuredEnabled {
                    step = .pluginEnable
                    try Self.validateKey(installed.key)
                    var toggleError: (any Error)?
                    do {
                        _ = try await workspace.managePlugins(["action": .string("toggle"),
                            "key": .string(installed.key), "enable": .boolean(true)])
                    } catch { toggleError = error }
                    guard owns() else { return }
                    // Enabling preserves the operator's installed revision. A
                    // lost receipt is reconciled without reinstalling anything.
                    let observed = try HostInstalledPlugin.decodeList(
                        await workspace.managePlugins(["action": .string("list")])
                    ).filter { $0.name == "loopdy" }
                    guard owns() else { return }
                    guard observed.count == 1, let verified = observed.first,
                          verified.key == installed.key, verified.pinnedSHA == installed.pinnedSHA,
                          verified.configuredEnabled else {
                        if let toggleError {
                            try fail(BighelpNotificationSetupFailure(step: step, error: toggleError), host: &host)
                        } else {
                            try fail(.pluginNotTurnedOn, step, "plugin_not_enabled", state: .outcomeUnknown, host: &host)
                        }
                        return
                    }
                }
                // The pin controls an installation we initiate, not compatibility
                // of an operator's existing plugin. Enrollment verifies the live
                // authenticated capability schema, host identity, and grant.
                // Observed installation also resolves an older app's install intent.
                host.pluginIntent = nil
                try finish(.installed, host: &host)
                step = .startingSetup
                try await enrollInstalled(host: &host, connection: workspace.savedConnection, isCurrent: { owns() })
                return
            }
            let pin: HostPluginPin
            do {
                pin = try await installTarget(for: host)
            } catch is CancellationError {
                return
            } catch {
                guard owns() else { return }
                try fail(BighelpNotificationSetupFailure(.pluginReleaseUnavailable, step: .pluginRelease,
                                                         kind: BighelpNotificationErrorKind(error), state: .releaseUnavailable),
                         host: &host)
                return
            }
            guard owns() else { return }
            step = .pluginInstall
            if let intent = host.pluginIntent, Self.isUnfinished(intent),
               intent.profile != nil || intent.identifier != pin.identifier || intent.revision != pin.revision {
                try fail(.earlierInstallUnfinished, step, "other_install_pending", state: .replacementRequired, host: &host)
                return
            }
            if let found = matches.first, found.pinnedSHA != pin.revision {
                try fail(.earlierInstallUnfinished, step, "other_plugin_commit", state: .replacementRequired, host: &host)
                return
            }
            if matches.isEmpty {
                // A lost reply may still be executing on the backend. Absence is
                // not proof of rejection and never authorizes duplicate install.
                if let intent = host.pluginIntent, intent.phase != .consented {
                    try fail(.pluginInstallMayBeRunning, step, "install_pending", state: .outcomeUnknown, host: &host)
                    return
                }
                host.pluginIntent = HostPluginIntent(identifier: pin.identifier, revision: pin.revision,
                    profile: nil, phase: .installRequested)
                if enrollNotifications { host.notificationState = .installing }
                try registry.update(host)
                state = .installing
                do { _ = try await workspace.managePlugins(pin.installParameters) }
                catch {
                    guard owns() else { return }
                    // Always reconcile once, including scanner/policy rejections
                    // that may follow a completed file install but failed enable.
                    do {
                        rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
                    } catch let listError {
                        guard owns() else { return }
                        try fail(BighelpNotificationSetupFailure(.pluginInstallUnconfirmed, step: step,
                                                                 kind: BighelpNotificationErrorKind(listError),
                                                                 state: .outcomeUnknown), host: &host)
                        return
                    }
                    guard owns() else { return }
                    matches = rows.filter { $0.name == "loopdy" }
                    guard matches.count == 1, matches[0].pinnedSHA == pin.revision else {
                        // A terminal RPC rejection followed by verified absence
                        // permits another explicit attempt, not automatic replay.
                        if matches.isEmpty, let directError = error as? DirectHermesError, case .rpcRejected = directError {
                            host.pluginIntent?.phase = .consented
                        }
                        try fail(BighelpNotificationSetupFailure(step: step, error: error), host: &host); return
                    }
                }
                guard owns() else { return }
                rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
                guard owns() else { return }
                matches = rows.filter { $0.name == "loopdy" }
            }
            guard matches.count == 1, let installed = matches.first, installed.pinnedSHA == pin.revision else {
                try fail(.pluginInstallUnconfirmed, step, "install_not_listed", state: .outcomeUnknown, host: &host); return
            }
            if !installed.configuredEnabled {
                step = .pluginEnable
                if host.pluginIntent?.phase == .toggleRequested {
                    try fail(.pluginNotTurnedOn, step, "enable_pending", state: .outcomeUnknown, host: &host); return
                }
                // Canonical key is read from this same verified list. Reject
                // controls and path traversal instead of interpolating into a URL.
                try Self.validateKey(installed.key)
                host.pluginIntent = HostPluginIntent(identifier: pin.identifier, revision: pin.revision, profile: nil, phase: .toggleRequested)
                try registry.update(host)
                do {
                    _ = try await workspace.managePlugins(["action": .string("toggle"), "key": .string(installed.key), "enable": .boolean(true)])
                } catch {
                    guard owns() else { return }
                    do {
                        rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
                    } catch let listError {
                        guard owns() else { return }
                        try fail(BighelpNotificationSetupFailure(.pluginNotTurnedOn, step: step,
                                                                 kind: BighelpNotificationErrorKind(listError),
                                                                 state: .outcomeUnknown), host: &host)
                        return
                    }
                    guard owns() else { return }
                    let observed = rows.filter { $0.name == "loopdy" }
                    guard observed.count == 1, observed[0].key == installed.key,
                          observed[0].pinnedSHA == pin.revision else {
                        try fail(.pluginInstallUnconfirmed, step, "plugin_changed_while_enabling", state: .outcomeUnknown,
                                 host: &host)
                        return
                    }
                    if !observed[0].configuredEnabled {
                        if let directError = error as? DirectHermesError, case .rpcRejected = directError {
                            host.pluginIntent?.phase = .consented
                        }
                        try fail(BighelpNotificationSetupFailure(step: step, error: error), host: &host); return
                    }
                }
                guard owns() else { return }
                rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
                guard owns() else { return }
                guard rows.filter({ $0.name == "loopdy" }).count == 1,
                      rows.contains(where: { $0.key == installed.key && $0.pinnedSHA == pin.revision && $0.configuredEnabled }) else {
                    try fail(.pluginNotTurnedOn, step, "plugin_not_enabled", state: .outcomeUnknown, host: &host); return
                }
            }
            host.pluginIntent = HostPluginIntent(identifier: pin.identifier, revision: pin.revision, profile: nil, phase: .verified)
            try finish(.installed, host: &host)
            step = .startingSetup
            try await enrollInstalled(host: &host, connection: workspace.savedConnection, isCurrent: { owns() })
        } catch {
            let named = BighelpNotificationSetupFailure(step: step, error: error)
            named.log()
            guard owns() else { return }
            show(named)
            state = named.state
            host.notificationBinding = registry.hosts.first(where: { $0.id == host.id })?.notificationBinding
            if enrollNotifications { host.notificationState = state.saved }
            try? registry.update(host)
        }
    }

    /// Shows the newest release before someone confirms an install.
    func loadRelease() async {
        guard pin == nil else { return }
        if let latest = try? await releases.latest(refresh: false) {
            release = latest
            pin = latest.pin
        }
    }

    /// An install that may still be running on the host is finished with the same
    /// commit it asked for; anything else uses the newest release.
    private func installTarget(for host: BighelpConfiguredHost) async throws -> HostPluginPin {
        if let intent = host.pluginIntent, Self.isUnfinished(intent), intent.profile == nil,
           let requested = try? HostPluginPin(revision: intent.revision), intent.identifier == requested.identifier {
            return requested
        }
        if let pin { return pin }
        let latest = try await releases.latest(refresh: false)
        release = latest
        pin = latest.pin
        return latest.pin
    }

    private static func isUnfinished(_ intent: HostPluginIntent) -> Bool {
        intent.phase == .installRequested || intent.phase == .toggleRequested
    }

    /// Never replaces a plugin with an older or equal release. Without a release
    /// version (a fixed pin) any different commit is replaced, as before.
    private func isOlderThanRelease(_ installed: HostInstalledPlugin) -> Bool {
        guard let latest = release?.version, let current = installed.version else { return true }
        return HostPluginPin.compare(current, latest) == .orderedAscending
    }

    private func enrollInstalled(host: inout BighelpConfiguredHost, connection: DirectHermesSavedConnection?,
                                 isCurrent: @escaping @MainActor () -> Bool) async throws {
        guard enrollNotifications else { return }
        guard let setup = registry.notificationSetup else {
            // Only demo mode and tests run without the notification service.
            try fail(.demoMode, .startingSetup, "notifications_not_running", state: .prerequisitesRequired, host: &host)
            return
        }
        guard let connection, host.owns(connection) else {
            try fail(.computerSignInChanged, .startingSetup, "connection_changed", state: .prerequisitesRequired, host: &host)
            return
        }
        let result = try await setup.enroll(host: host, connection: connection, isCurrent: isCurrent)
        guard isCurrent() else { return }
        host.notificationBinding = registry.hosts.first(where: { $0.id == host.id })?.notificationBinding
        switch result {
        case .enabled: try finish(.enabled, host: &host)
        case .backendRestartRequired:
            try fail(.restartHermes, .computerCheck, "notification_routes_missing", state: .backendRestartRequired, host: &host)
        case .prerequisitesRequired:
            try fail(.pluginTooOld, .computerCheck, "no_managed_enrollment", state: .prerequisitesRequired, host: &host)
        }
    }

    private func finish(_ next: HostNotificationState, host: inout BighelpConfiguredHost) throws {
        if enrollNotifications { host.notificationState = next }
        do { try registry.update(host) } catch {
            throw BighelpNotificationSetupFailure(step: .savingSetup, error: error)
        }
        state = next
    }

    /// Setup stopped at one of its own checks.
    private func fail(_ code: BighelpNotificationErrorCode, _ step: BighelpNotificationSetupStep, _ check: String,
                      state next: HostNotificationState, host: inout BighelpConfiguredHost) throws {
        try fail(BighelpNotificationSetupFailure(code, step: step, kind: .check(check), state: next), host: &host)
    }

    private func fail(_ named: BighelpNotificationSetupFailure, host: inout BighelpConfiguredHost) throws {
        note(named)
        try finish(named.state, host: &host)
    }

    private func note(_ named: BighelpNotificationSetupFailure) {
        named.log()
        show(named)
    }

    /// Shows and keeps the failure (the setup screen shows its code when it opens again).
    private func show(_ named: BighelpNotificationSetupFailure) {
        failure = named
        failureIsFromEarlierRun = false
        if enrollNotifications { BighelpNotificationLastFailure.save(named, hostID: hostID, defaults: defaults) }
    }

    private static func validateKey(_ key: String) throws {
        guard key.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7f }),
              !key.contains(".."), !key.contains("\\") else { throw DirectHermesError.invalidResponse }
    }

    #if DEBUG
    /// "-test-notification-failure NS-102" stops setup with that code, for screenshots and UI
    /// tests in demo mode.
    private static func forcedFailure() -> BighelpNotificationSetupFailure? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-test-notification-failure"), arguments.indices.contains(index + 1),
              let code = BighelpNotificationErrorCode(rawValue: arguments[index + 1]) else { return nil }
        let state: HostNotificationState = switch code.rawValue.dropFirst(3).first {
        case "1", "2": .prerequisitesRequired
        case "3": code == .computerNotConnected ? .notConnected : .outcomeUnknown
        default: .outcomeUnknown
        }
        return BighelpNotificationSetupFailure(code, step: .startingSetup, kind: .check("forced_for_testing"), state: state)
    }
    #endif
}
