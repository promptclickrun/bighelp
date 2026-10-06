import CryptoKit
import Foundation
import Observation
import SwiftUI

enum BighelpHostConnectionMode: String, Codable, Sendable {
    case independent
    case link
}

struct BighelpLegacyHostOrigin: Codable, Equatable, Sendable {
    let accountScope: String
    let hostID: UUID
}

/// Explicit optional delivery enrollment. Never an authority for native chat.
struct BighelpHostNotificationBinding: Codable, Equatable, Sendable {
    let deviceID: String
    let authorizationEpoch: Int
    var scope: String { ManagedNotificationValidation.digest(deviceID + ":" + String(authorizationEpoch)) }
}

/// Non-secret, device-local metadata. Credentials remain in a separate exact
/// account/host Keychain item. A configured host need not currently be online.
enum HostRenameError: LocalizedError {
    case invalidName
    var errorDescription: String? { "Use a name up to 60 characters." }
}

struct BighelpConfiguredHost: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let accountScope: String
    let accountID: String?
    var hostConnectionID: String { id.uuidString }
    let endpoint: DirectHermesEndpoint
    let principalIdentity: String
    var name: String
    var connectionMode: BighelpHostConnectionMode? = nil
    var legacyOrigin: BighelpLegacyHostOrigin? = nil
    var notificationState: HostNotificationState = .notConfigured
    var pluginIntent: HostPluginIntent?
    var notificationBinding: BighelpHostNotificationBinding? = nil

    var isIndependent: Bool { connectionMode == .independent }
    var notificationScope: String { notificationBinding?.scope ?? accountScope }

    func notificationAccountID() throws -> String {
        if let notificationBinding { return notificationBinding.deviceID }
        if isIndependent { throw DirectHermesError.authenticationRequired }
        guard let accountID else { throw DirectHermesError.authenticationRequired }
        return accountID
    }
}

struct HostPluginFeatureReadiness: Equatable, Sendable {
    let hostID: UUID
    let registryGeneration: UUID
    let connectionGeneration: UUID
    let contextETag: String
    let capabilities: Set<String>
}

@MainActor
@Observable
final class BighelpHostRegistry {
    private(set) var accountScope: String?
    private(set) var accountID: String?
    private(set) var connectionMode: BighelpHostConnectionMode = .link
    private(set) var storageIsReadable = true
    @ObservationIgnored private var authorizationEpoch: Int?
    @ObservationIgnored private var linkedDeviceID: String?
    @ObservationIgnored private var linkedAuthorizationEpoch: Int?
    var canConfigureHosts: Bool { isWorkspaceReady && storageIsReadable }
    func retryLoading() {
        if connectionMode == .independent { bindIndependent(forceReload: true) }
        else { bind(deviceID: accountID, authorizationEpoch: authorizationEpoch, forceReload: true) }
    }
    var activeHostConnectionID: String? { selectedHostID?.uuidString }
    private(set) var hosts: [BighelpConfiguredHost] = []
    private(set) var selectedHostID: UUID?
    private(set) var selectedWorkspace: DirectHermesWorkspaceStore?
    private(set) var errorMessage: String?
    private(set) var generation = UUID()
    private(set) var deviceToolFeatureReadinessToken: UInt64 = 0
    private(set) var liveVoiceFeatureReadinessToken: UInt64 = 0
    var isSetupPresented = false
    /// While the all-hosts view is on and the app is open, a host the app
    /// switches away from keeps its connection, so switching back skips
    /// connecting and signing in. Turning it off closes them all again.
    var keepsOtherHostsConnected = false {
        didSet { if oldValue, !keepsOtherHostsConnected { closeUnselectedConnections() } }
    }
    private(set) var setupHostID: UUID?
    private(set) var onboardingHostID: UUID?
    func finishSetup() { onboardingHostID = nil; setupHostID = nil; isSetupPresented = false }
    var notificationSetup: (any HostNotificationSetupServing)?
    var notificationSetupError: String?
    @ObservationIgnored var nativeChatPrepared: ((BighelpConfiguredHost, DirectHermesChat) -> Void)?
    @ObservationIgnored var prepareChat: ((BighelpConfiguredHost, DirectHermesChat) async throws -> Void)?
    @ObservationIgnored var onNativeEvent: ((BighelpConfiguredHost, DirectHermesEvent) -> Void)?
    @ObservationIgnored private var workspaces: [UUID: DirectHermesWorkspaceStore] = [:]
    @ObservationIgnored private var vaults: [UUID: DirectHermesKeychainVault] = [:]
    @ObservationIgnored private var draftStores: [UUID: DirectHermesDraftStore] = [:]
    @ObservationIgnored private var pendingIDs: Set<UUID> = []
    @ObservationIgnored private var pluginManagementOwners: [UUID: UUID] = [:]
    @ObservationIgnored private var pluginFeatureReadiness: [HostPluginFeature: HostPluginFeatureReadiness] = [:]
    private struct PendingSetupCleanup {
        let vault: DirectHermesKeychainVault
        let draftDirectory: URL
    }
    @ObservationIgnored private var pendingCleanup: [PendingSetupCleanup] = []
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let keychainService: String
    @ObservationIgnored private let independentRoot: URL
    @ObservationIgnored private let defaults: UserDefaults
    private static let independentScope = "independent-v2"
    private static let selectionKey = "loopdy.hosts.connection-mode.v2"

    static var storageRoot: URL {
        URL.applicationSupportDirectory.appending(path: "LoopdyConfiguredHosts", directoryHint: .isDirectory)
    }

    init(root: URL = BighelpHostRegistry.storageRoot,
         keychainService: String = "app.loopdy.mobile.direct-hermes",
         independentRoot: URL? = nil,
         defaults: UserDefaults = .standard) {
        self.root = root
        self.keychainService = keychainService
        self.independentRoot = independentRoot ?? root.deletingLastPathComponent()
            .appending(path: root.lastPathComponent + "-independent", directoryHint: .isDirectory)
        self.defaults = defaults
    }

    var selectedHost: BighelpConfiguredHost? { hosts.first { $0.id == selectedHostID } }
    var isAccountReady: Bool { accountID != nil }
    var isWorkspaceReady: Bool { accountScope != nil }
    private var activeRoot: URL { connectionMode == .independent ? independentRoot : root }
    private var activeKeychainService: String {
        connectionMode == .independent ? keychainService + ".independent" : keychainService
    }

    func restoreConnectionSelection(deviceID: String?, authorizationEpoch: Int?) {
        linkedDeviceID = deviceID
        linkedAuthorizationEpoch = authorizationEpoch
        // A saved cloud account is notification identity, never chat authority.
        // Preserve the old account-scoped files and credentials for explicit
        // host reauthentication; do not adopt them by matching an address.
        useIndependentWorkspace()
    }

    func useIndependentWorkspace() {
        defaults.set(BighelpHostConnectionMode.independent.rawValue, forKey: Self.selectionKey)
        bindIndependent()
    }

    func useLinkedWorkspace() {
        defaults.set(BighelpHostConnectionMode.link.rawValue, forKey: Self.selectionKey)
        bindScope(
            deviceID: linkedDeviceID, authorizationEpoch: linkedAuthorizationEpoch,
            mode: .link, forceReload: false
        )
    }

    /// Publishes a feature-ready token only for the still-current host owner.
    /// The token changes when the authenticated context or its capability set
    /// changes, allowing consumers to retry without reacting to repeated reads.
    @discardableResult
    func recordPluginFeatureReadiness(
        feature: HostPluginFeature,
        hostID: UUID,
        registryGeneration: UUID,
        connectionGeneration: UUID,
        contextETag: String,
        capabilities: Set<String>,
        isCurrent: @escaping @MainActor () -> Bool
    ) -> Bool {
        guard !contextETag.isEmpty,
              capabilities.contains(feature.capability),
              selectedHostID == hostID,
              generation == registryGeneration,
              selectedWorkspace?.connectionGeneration == connectionGeneration,
              isCurrent() else { return false }

        let readiness = HostPluginFeatureReadiness(
            hostID: hostID,
            registryGeneration: registryGeneration,
            connectionGeneration: connectionGeneration,
            contextETag: contextETag,
            capabilities: capabilities
        )
        guard pluginFeatureReadiness[feature] != readiness else { return true }
        pluginFeatureReadiness[feature] = readiness
        switch feature {
        case .deviceAccess: deviceToolFeatureReadinessToken &+= 1
        case .liveVoice: liveVoiceFeatureReadinessToken &+= 1
        }
        return true
    }

    private func bindIndependent(forceReload: Bool = false, restoreSelection: Bool = true) {
        bindScope(deviceID: nil, authorizationEpoch: nil, mode: .independent,
                  forceReload: forceReload, restoreSelection: restoreSelection)
    }

    /// Device credential identity + authorization epoch, not account display name.
    /// No credential bytes are placed in the namespace or metadata.
    func bind(deviceID: String?, authorizationEpoch: Int?, forceReload: Bool = false) {
        linkedDeviceID = deviceID
        linkedAuthorizationEpoch = authorizationEpoch
        guard connectionMode != .independent else { return }
        if deviceID == nil, accountID != nil {
            defaults.set(BighelpHostConnectionMode.independent.rawValue, forKey: Self.selectionKey)
            bindIndependent(restoreSelection: false)
            return
        }
        bindScope(deviceID: deviceID, authorizationEpoch: authorizationEpoch, mode: .link, forceReload: forceReload)
    }

    private func bindScope(deviceID: String?, authorizationEpoch: Int?, mode: BighelpHostConnectionMode,
                           forceReload: Bool, restoreSelection: Bool = true) {
        let scope = mode == .independent ? Self.independentScope
            : deviceID.flatMap { id in authorizationEpoch.map { Self.digest(id + ":" + String($0)) } }
        guard scope != accountScope || connectionMode != mode || forceReload else { return }
        generation = UUID()
        isSetupPresented = false
        setupHostID = nil
        onboardingHostID = nil
        for workspace in workspaces.values { workspace.suspendForPresentationExit() }
        for id in pendingIDs {
            if let vault = vaults[id] {
                pendingCleanup.append(PendingSetupCleanup(vault: vault, draftDirectory: draftRoot(id: id)))
            }
        }
        for vault in vaults.values { vault.invalidate() }
        for drafts in draftStores.values { drafts.invalidate() }
        workspaces = [:]; vaults = [:]; draftStores = [:]; pendingIDs = []
        pluginManagementOwners = [:]
        hosts = []; selectedHostID = nil; selectedWorkspace = nil; errorMessage = nil
        accountScope = scope
        accountID = deviceID
        self.authorizationEpoch = authorizationEpoch
        connectionMode = mode
        storageIsReadable = true
        do {
            try finishPendingCleanup()
        } catch {
            storageIsReadable = false
            errorMessage = "Temporary host setup data could not be removed. Unlock this device and retry before connecting another host."
            return
        }
        guard let scope else { return }
        do {
            let file = activeRoot.appending(path: scope + ".json")
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            let data = try Data(contentsOf: file)
            guard data.count <= 1_048_576 else { throw DirectHermesError.savedConnectionInvalid }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == (mode == .independent ? 2 : 1), snapshot.hosts.count <= 32,
                  Set(snapshot.hosts.map(\.id)).count == snapshot.hosts.count,
                  snapshot.hosts.allSatisfy({
                      $0.accountScope == scope && $0.accountID == deviceID
                          && ($0.connectionMode ?? .link) == mode
                          && $0.name.utf8.count <= 160 && $0.principalIdentity.utf8.count <= 4096
                  }),
                  snapshot.selected == nil || snapshot.hosts.contains(where: { $0.id == snapshot.selected }) else {
                throw DirectHermesError.savedConnectionInvalid
            }
            hosts = snapshot.hosts
            selectedHostID = restoreSelection ? snapshot.selected : nil
            if let selected = selectedHost { selectedWorkspace = workspace(for: selected) }
        } catch {
            // Corrupt/newer metadata is not an empty valid registry; don't overwrite it.
            storageIsReadable = false
            errorMessage = "Saved hosts could not be read. Their data has not been replaced."
        }
    }

    func beginSetup() { guard canConfigureHosts else { return }; errorMessage = nil; setupHostID = nil; isSetupPresented = true }

    func beginAuthentication(for host: BighelpConfiguredHost) {
        guard canConfigureHosts, hosts.contains(where: { $0.id == host.id && $0.accountScope == host.accountScope }) else { return }
        setupHostID = host.id
        isSetupPresented = true
    }

    func acceptAuthentication(for host: BighelpConfiguredHost, workspace: DirectHermesWorkspaceStore) throws -> BighelpConfiguredHost {
        guard host.accountScope == accountScope, hosts.contains(where: { $0.id == host.id }),
              workspaces[host.id] === workspace, workspace.isConnected,
              DirectHermesIdentity.matches(workspace.savedConnection?.identity, host.principalIdentity) else {
            throw DirectHermesError.identityChanged
        }
        try persist(hosts: hosts, selected: host.id)
        generation = UUID()
        if selectedWorkspace !== workspace { selectedWorkspace?.suspendForPresentationExit() }
        selectedHostID = host.id; selectedWorkspace = workspace; onboardingHostID = host.id
        return hosts.first(where: { $0.id == host.id }) ?? host
    }

    func makePendingWorkspace() throws -> (UUID, DirectHermesWorkspaceStore) {
        guard canConfigureHosts, hosts.count < 32 else { throw DirectHermesError.secureStorageUnavailable }
        let id = UUID()
        pendingIDs.insert(id)
        return (id, makeWorkspace(id: id))
    }

    func discardPending(_ id: UUID) {
        guard pendingIDs.remove(id) != nil else { return }
        workspaces[id]?.suspendForPresentationExit()
        do { try vaults[id]?.delete() }
        catch { errorMessage = "Temporary host credentials could not be removed. Unlock this device and retry account cleanup." }
        vaults[id]?.invalidate(); draftStores[id]?.invalidate()
        workspaces[id] = nil; vaults[id] = nil; draftStores[id] = nil
    }

    /// Only a principal-verified socket-ready connection can become configured.
    @discardableResult
    func commit(_ id: UUID, workspace: DirectHermesWorkspaceStore, name: String) throws -> BighelpConfiguredHost {
        guard let scope = accountScope, pendingIDs.contains(id), workspaces[id] === workspace,
              workspace.isConnected, let connection = workspace.savedConnection else { throw DirectHermesError.secureStorageChanged }
        try connection.validate()
        if connectionMode == .independent {
            guard connection.workspaceAuthority != nil else {
                throw DirectHermesError.authenticationRequired
            }
        }
        guard !hosts.contains(where: { DirectHermesIdentity.matches($0.principalIdentity, connection.identity) }) else {
            throw HostSetupError.alreadyConfigured
        }
        let label = name.isEmpty ? connection.endpoint.host : name
        guard label.utf8.count <= 160, connection.identity.utf8.count <= 4096,
              !label.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw DirectHermesError.invalidResponse
        }
        let host = BighelpConfiguredHost(id: id, accountScope: scope, accountID: accountID, endpoint: connection.endpoint,
            principalIdentity: connection.identity, name: label,
            connectionMode: connectionMode == .independent ? .independent : nil)
        // Persist before publishing; a failed write retains a retryable pending owner.
        guard let vault = vaults[id] else { throw DirectHermesError.secureStorageChanged }
        try vault.bindIdentity(connection.identity)
        // Journal the verified host before promoting its in-memory credentials.
        // An interruption can require authentication again, never leave an
        // unreferenced Keychain item. A failed promotion rolls metadata back.
        try persist(hosts: hosts + [host], selected: id)
        do { try vault.commitStagedCredentials() }
        catch {
            if !vault.requiresRegistryReference {
                try persist(hosts: hosts, selected: selectedHostID)
            }
            throw error
        }
        generation = UUID()
        selectedWorkspace?.suspendForPresentationExit()
        hosts.append(host); pendingIDs.remove(id)
        onboardingHostID = id
        selectedHostID = id; selectedWorkspace = workspace
        return host
    }

    func select(_ id: UUID?) {
        guard id != selectedHostID, id == nil || hosts.contains(where: { $0.id == id }) else { return }
        do {
            try persist(hosts: hosts, selected: id)
            generation = UUID()
            if !keepsOtherHostsConnected { selectedWorkspace?.suspendForPresentationExit() }
            selectedHostID = id
            selectedWorkspace = selectedHost.map { workspace(for: $0) }
            errorMessage = nil
        } catch { errorMessage = "The host selection could not be saved on this device." }
    }

    /// The name people see for a computer. Its address, sign-in and chats don't change.
    func rename(_ id: UUID, to newName: String) throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let index = hosts.firstIndex(where: { $0.id == id }) else {
            throw HostRenameError.invalidName
        }
        guard hosts[index].name != name else { return }
        var renamed = hosts
        renamed[index].name = name
        try persist(hosts: renamed, selected: selectedHostID)
        hosts = renamed
    }

    func remove(_ host: BighelpConfiguredHost) throws {
        guard host.accountScope == accountScope, hosts.contains(where: { $0.id == host.id }) else {
            throw DirectHermesError.secureStorageChanged
        }
        // Stop local activity before deletion; never mutate or delete host sessions.
        generation = UUID()
        workspaces[host.id]?.suspendForPresentationExit()
        try notificationSetup?.removeLocalEnrollment(host: host)
        let vault = vaults[host.id] ?? makeVault(id: host.id)
        try vault.delete()
        let remaining = hosts.filter { $0.id != host.id }
        let selection = selectedHostID == host.id ? nil : selectedHostID
        try persist(hosts: remaining, selected: selection)
        // The Cloudflare Access token belongs to the address; keep it while another host uses it.
        if !remaining.contains(where: { $0.endpoint.identity == host.endpoint.identity }) {
            DirectHermesAccessCredentialStore.shared.remove(for: host.endpoint)
        }
        try removeDrafts(id: host.id)
        // Saved files are named by a one-way key, so a removed host's can't be
        // picked out; clear them all and let other hosts' download again.
        Task { await AgentAttachmentCache.shared.removeAll() }
        vault.invalidate(); draftStores[host.id]?.invalidate()
        hosts = remaining; selectedHostID = selection
        selectedWorkspace = selectedHost.map { workspace(for: $0) }
        workspaces[host.id] = nil; vaults[host.id] = nil; draftStores[host.id] = nil
        generation = UUID()
    }

    /// Every host's connection but the selected one's.
    func closeUnselectedConnections() {
        for (id, store) in workspaces where id != selectedHostID && !pendingIDs.contains(id)
            && (store.isConnected || store.isConnecting) {
            store.suspendForPresentationExit()
        }
    }

    func beginPluginManagement(hostID: UUID) -> UUID? {
        guard pluginManagementOwners[hostID] == nil, hosts.contains(where: { $0.id == hostID }) else { return nil }
        let owner = UUID()
        pluginManagementOwners[hostID] = owner
        return owner
    }

    func endPluginManagement(hostID: UUID, owner: UUID) {
        if pluginManagementOwners[hostID] == owner { pluginManagementOwners[hostID] = nil }
    }

    func update(_ host: BighelpConfiguredHost) throws {
        guard host.accountScope == accountScope, let index = hosts.firstIndex(where: { $0.id == host.id }) else {
            throw DirectHermesError.secureStorageChanged
        }
        var candidate = hosts
        candidate[index] = host
        try persist(hosts: candidate, selected: selectedHostID)
        hosts = candidate
    }

    func workspace(for host: BighelpConfiguredHost) -> DirectHermesWorkspaceStore {
        precondition(host.accountScope == accountScope)
        return workspaces[host.id] ?? makeWorkspace(id: host.id)
    }

    func credentialVault(for host: BighelpConfiguredHost) -> any DirectHermesCredentialVault {
        precondition(host.accountScope == accountScope)
        return vaults[host.id] ?? makeVault(id: host.id)
    }

    private func makeWorkspace(id: UUID) -> DirectHermesWorkspaceStore {
        let vault = makeVault(id: id)
        let drafts = DirectHermesDraftStore(root: draftRoot(id: id))
        let store = DirectHermesWorkspaceStore(vault: vault, drafts: drafts)
        store.prepareChat = { [weak self] chat in
            guard let self, let host = self.hosts.first(where: { $0.id == id }) else { return }
            do { try await self.prepareChat?(host, chat) }
            catch { self.notificationSetupError = "Chat is connected, but notifications for this session could not be prepared. Retry notification setup in Accounts and Devices." }
        }
        store.onNativeEvent = { [weak self] event in
            guard let self, let host = self.hosts.first(where: { $0.id == id }) else { return }
            self.onNativeEvent?(host, event)
        }
        vaults[id] = vault; draftStores[id] = drafts; workspaces[id] = store
        return store
    }
    private func makeVault(id: UUID) -> DirectHermesKeychainVault {
        DirectHermesKeychainVault(service: activeKeychainService, account: "host-v1.\(accountScope ?? "unbound").\(id.uuidString)",
            expectedIdentity: hosts.first(where: { $0.id == id })?.principalIdentity,
            stagesUntilCommit: pendingIDs.contains(id))
    }
    private func finishPendingCleanup() throws {
        while let cleanup = pendingCleanup.first {
            try cleanup.vault.delete()
            if FileManager.default.fileExists(atPath: cleanup.draftDirectory.path) {
                try FileManager.default.removeItem(at: cleanup.draftDirectory)
            }
            pendingCleanup.removeFirst()
        }
    }

    private func draftRoot(id: UUID) -> URL {
        activeRoot.appending(path: accountScope ?? "unbound", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }
    private func removeDrafts(id: UUID) throws {
        let path = draftRoot(id: id)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    private struct Snapshot: Codable {
        var version = 1
        let hosts: [BighelpConfiguredHost]
        let selected: UUID?
    }
    private func persist(hosts: [BighelpConfiguredHost], selected: UUID?) throws {
        guard let scope = accountScope, storageIsReadable else { throw DirectHermesError.secureStorageChanged }
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var directory = activeRoot
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try directory.setResourceValues(attributes)
        let data = try JSONEncoder().encode(Snapshot(version: connectionMode == .independent ? 2 : 1,
                                                   hosts: hosts, selected: selected))
        let file = activeRoot.appending(path: scope + ".json")
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let verified = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        guard verified.hosts == hosts, verified.selected == selected else {
            throw DirectHermesError.secureStorageChanged
        }
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct BighelpHostRegistryKey: EnvironmentKey {
    static let defaultValue: BighelpHostRegistry? = nil
}
extension EnvironmentValues {
    var bighelpHostRegistry: BighelpHostRegistry? {
        get { self[BighelpHostRegistryKey.self] }
        set { self[BighelpHostRegistryKey.self] = newValue }
    }
}

enum HostSetupError: Error, LocalizedError {
    case alreadyConfigured
    var errorDescription: String? { "This host account is already configured. Select it in Accounts and Devices." }
}
