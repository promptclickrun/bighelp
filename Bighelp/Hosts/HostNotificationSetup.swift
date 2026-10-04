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
    /// Tells every computer with notifications on whether this phone wants Peer chats alerts.
    func applyPeerChatPreference() async
    /// Gives this device's Quiet Hours to every computer with notifications on.
    func applyQuietHours() async -> BighelpQuietHoursSyncResult
}

extension HostNotificationSetupServing {
    func applyPeerChatPreference() async {}
    func applyQuietHours() async -> BighelpQuietHoursSyncResult { BighelpQuietHoursSyncResult() }
}

/// Whether agents talking to each other (`hermes peer`, Bot Chat) alert this phone. Off unless
/// the person turns it on in Settings › Notifications.
enum BighelpPeerChatAlerts {
    static let key = "bighelp.notifications.peer-chats"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
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
        case .outcomeUnknown: "Couldn't confirm setup. Check again before reinstalling."
        case .notConnected: "Can't reach this computer. Reconnect and check setup again."
        case .releaseUnavailable: "Couldn't reach GitHub for the newest bighelp plugin. Check the internet connection and try again."
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
    private(set) var providerFailure: BighelpManagedNotificationSetupError?
    /// The commit an install uses: the newest release, looked up only when one is needed.
    private(set) var pin: HostPluginPin?
    private(set) var release: PluginRelease?
    let hostID: UUID
    let enrollNotifications: Bool
    @ObservationIgnored private let registry: BighelpHostRegistry
    @ObservationIgnored private let management: any HostPluginManagementServing
    @ObservationIgnored private let releases: any PluginReleaseResolving
    @ObservationIgnored private var operation: UUID?

    /// `pin` fixes the commit up front (tests); otherwise the newest release is used.
    init(host: BighelpConfiguredHost, registry: BighelpHostRegistry, pin: HostPluginPin? = nil,
         releases: (any PluginReleaseResolving)? = nil,
         management: (any HostPluginManagementServing)? = nil, enrollNotifications: Bool = true) {
        hostID = host.id
        self.registry = registry
        self.management = management ?? registry.workspace(for: host)
        self.pin = pin
        self.releases = releases ?? GitHubPluginReleaseSource.shared
        self.enrollNotifications = enrollNotifications
        // Preserve the user's saved opt-in without prompting on every visit.
        // Actual grant and delivery authority still belong to the service ledger.
        state = enrollNotifications ? host.notificationState : .notConfigured
    }

    var message: String {
        if let providerFailure { return providerFailure.localizedDescription }
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

    var actionTitle: String? {
        guard !isWorking else { return nil }
        return switch state {
        case .enabled:
            nil
        case .checking:
            "Check Again"
        case .installing, .outcomeUnknown:
            "Check Installed State"
        case .notConnected:
            "Retry Connection"
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
        do {
            if !management.isConnected { await management.reconnect() }
            guard owns() else { return }
            guard management.isConnected,
                  DirectHermesIdentity.matches(management.savedConnection?.identity, host.principalIdentity) else {
                throw DirectHermesError.notConnected
            }
            let rows = try HostInstalledPlugin.decodeList(
                await management.managePlugins(["action": .string("list")])
            )
            guard owns() else { return }
            state = rows.first?.configuredEnabled == true ? .installed : .notConfigured
        } catch {
            guard owns() else { return }
            state = Self.failureState(error)
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
        providerFailure = nil
        defer { if operation == operationID { isWorking = false } }
        @MainActor func owns() -> Bool {
            registry.generation == owner && registry.accountScope == scope && operation == operationID
                && registry.hosts.contains(where: { $0.id == hostID }) && !Task.isCancelled
        }
        var host = original
        let workspace = management
        do {
            if !workspace.isConnected { await workspace.reconnect() }
            guard owns() else { return }
            guard workspace.isConnected else { throw DirectHermesError.notConnected }
            guard DirectHermesIdentity.matches(workspace.savedConnection?.identity, host.principalIdentity) else {
                throw DirectHermesError.identityChanged
            }
            state = .checking
            var rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
            guard owns() else { return }
            var matches = rows.filter { $0.name == "loopdy" }
            guard matches.count <= 1 else { try finish(.replacementRequired, host: &host); return }
            if let installed = matches.first {
                // A newer or equal plugin stays; GitHub being unreachable doesn't block enabling it.
                var target: HostPluginPin?
                if !enrollNotifications { target = try? await installTarget(for: host) }
                guard owns() else { return }
                if let pin = target, installed.pinnedSHA != pin.revision, isOlderThanRelease(installed) {
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
                        try finish(updateError.map(Self.failureState) ?? .outcomeUnknown, host: &host)
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
                        try finish(toggleError.map(Self.failureState) ?? .outcomeUnknown, host: &host)
                        return
                    }
                }
                // The pin controls an installation we initiate, not compatibility
                // of an operator's existing plugin. Enrollment verifies the live
                // authenticated capability schema, host identity, and grant.
                // Observed installation also resolves an older app's install intent.
                host.pluginIntent = nil
                try finish(.installed, host: &host)
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
                try finish(.releaseUnavailable, host: &host)
                return
            }
            guard owns() else { return }
            if let intent = host.pluginIntent, Self.isUnfinished(intent),
               intent.profile != nil || intent.identifier != pin.identifier || intent.revision != pin.revision {
                try finish(.replacementRequired, host: &host)
                return
            }
            if let found = matches.first, found.pinnedSHA != pin.revision {
                try finish(.replacementRequired, host: &host); return
            }
            if matches.isEmpty {
                // A lost reply may still be executing on the backend. Absence is
                // not proof of rejection and never authorizes duplicate install.
                if let intent = host.pluginIntent, intent.phase != .consented {
                    try finish(.outcomeUnknown, host: &host); return
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
                    } catch {
                        guard owns() else { return }
                        try finish(.outcomeUnknown, host: &host); return
                    }
                    guard owns() else { return }
                    matches = rows.filter { $0.name == "loopdy" }
                    guard matches.count == 1, matches[0].pinnedSHA == pin.revision else {
                        // A terminal RPC rejection followed by verified absence
                        // permits another explicit attempt, not automatic replay.
                        if matches.isEmpty, let directError = error as? DirectHermesError, case .rpcRejected = directError {
                            host.pluginIntent?.phase = .consented
                        }
                        try finish(Self.failureState(error), host: &host); return
                    }
                }
                guard owns() else { return }
                rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
                guard owns() else { return }
                matches = rows.filter { $0.name == "loopdy" }
            }
            guard matches.count == 1, let installed = matches.first, installed.pinnedSHA == pin.revision else {
                try finish(.outcomeUnknown, host: &host); return
            }
            if !installed.configuredEnabled {
                if host.pluginIntent?.phase == .toggleRequested { try finish(.outcomeUnknown, host: &host); return }
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
                    } catch {
                        guard owns() else { return }
                        try finish(.outcomeUnknown, host: &host); return
                    }
                    guard owns() else { return }
                    let observed = rows.filter { $0.name == "loopdy" }
                    guard observed.count == 1, observed[0].key == installed.key,
                          observed[0].pinnedSHA == pin.revision else {
                        try finish(.outcomeUnknown, host: &host); return
                    }
                    if !observed[0].configuredEnabled {
                        if let directError = error as? DirectHermesError, case .rpcRejected = directError {
                            host.pluginIntent?.phase = .consented
                        }
                        try finish(Self.failureState(error), host: &host); return
                    }
                }
                guard owns() else { return }
                rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
                guard owns() else { return }
                guard rows.filter({ $0.name == "loopdy" }).count == 1,
                      rows.contains(where: { $0.key == installed.key && $0.pinnedSHA == pin.revision && $0.configuredEnabled }) else {
                    try finish(.outcomeUnknown, host: &host); return
                }
            }
            host.pluginIntent = HostPluginIntent(identifier: pin.identifier, revision: pin.revision, profile: nil, phase: .verified)
            try finish(.installed, host: &host)
            try await enrollInstalled(host: &host, connection: workspace.savedConnection, isCurrent: { owns() })
        } catch {
            guard owns() else { return }
            state = Self.failureState(error)
            host.notificationBinding = registry.hosts.first(where: { $0.id == host.id })?.notificationBinding
            providerFailure = error as? BighelpManagedNotificationSetupError
            if enrollNotifications { host.notificationState = state }
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
        guard let setup = registry.notificationSetup, let connection,
              DirectHermesIdentity.matches(connection.identity, host.principalIdentity) else {
            try finish(.prerequisitesRequired, host: &host); return
        }
        let result = try await setup.enroll(host: host, connection: connection, isCurrent: isCurrent)
        guard isCurrent() else { return }
        host.notificationBinding = registry.hosts.first(where: { $0.id == host.id })?.notificationBinding
        switch result {
        case .enabled: try finish(.enabled, host: &host)
        case .backendRestartRequired: try finish(.backendRestartRequired, host: &host)
        case .prerequisitesRequired: try finish(.prerequisitesRequired, host: &host)
        }
    }

    private func finish(_ next: HostNotificationState, host: inout BighelpConfiguredHost) throws {
        if enrollNotifications { host.notificationState = next }
        try registry.update(host)
        state = next
    }
    private static func validateKey(_ key: String) throws {
        guard key.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7f }),
              !key.contains(".."), !key.contains("\\") else { throw DirectHermesError.invalidResponse }
    }
    private static func failureState(_ error: any Error) -> HostNotificationState {
        if error is BighelpManagedNotificationSetupError { return .prerequisitesRequired }
        if let linkError = error as? BighelpLinkAPIError,
           case let .requestFailed(_, code) = linkError {
            switch code {
            case "not_found", "device_credentials_missing", "notification_service_unavailable",
                 "notification_mobile_required", "notification_recipient_unavailable",
                 "notification_recipient_changed":
                return .prerequisitesRequired
            default:
                break
            }
        }
        guard let error = error as? DirectHermesError else { return .outcomeUnknown }
        switch error {
        case .notConnected: return .notConnected
        case .rpcRejected(code: -32601): return .unsupported
        case .rpcRejected(code: 403): return .permissionDenied
        case .rpcRejected(code: 5026): return .managementRejected
        default: return .outcomeUnknown
        }
    }
}
