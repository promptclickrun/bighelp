import Foundation
import Observation
import CryptoKit

/// Keep catalogs ordered while overlapping a small number of independent host reads.
@MainActor
func loadAgentDetails<Input: Sendable, Output: Sendable>(
    _ inputs: [Input], operation: @escaping @MainActor @Sendable (Input) async throws -> Output
) async throws -> [Output] {
    try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var next = 0
        var results: [Int: Output] = [:]
        func enqueue(_ index: Int) {
            let input = inputs[index]
            group.addTask { (index, try await operation(input)) }
        }
        while next < min(4, inputs.count) { enqueue(next); next += 1 }
        while let (index, value) = try await group.next() {
            results[index] = value
            if next < inputs.count { enqueue(next); next += 1 }
        }
        return inputs.indices.compactMap { results[$0] }
    }
}

@MainActor
@Observable
final class AgentDirectoryStore {
    /// Quick Workspace shows at most five pinned agents. The cap is a product
    /// decision rather than a layout accident, so it lives with the store that
    /// owns the pin set, and its copy counterpart in `AgentActionPresentation`
    /// is checked against it by test.
    static let pinnedAgentLimit = AgentActionPresentation.pinnedAgentLimit

    private(set) var profiles: [AgentProfile] = []
    private(set) var selectedAgentID: String?
    /// The agent that new chats start with on the currently selected Hermes
    /// host. Agent IDs are only meaningful within one host, so this and the
    /// pin set are stored per host: switching hosts shows that host's own
    /// configuration, and switching back restores it untouched.
    private(set) var primaryAgentID: String?
    private(set) var pinnedAgentIDs: [String] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var errorCode: String?

    static let hermesCompatibilityRecovery = "This Hermes gateway cannot load agents. Update Hermes on the host, restart the gateway, then reconnect bighelp and try again."

    static func isHermesCapabilityMissing(_ error: any Error) -> Bool {
        if case BighelpLinkWorkspaceClientError.remote(_, let code, _) = error {
            return code == "hermes_capability_missing"
        }
        if case BighelpLinkLiveSocketError.requestFailed(let code, _) = error {
            return code == "hermes_capability_missing"
        }
        return false
    }
    var isInitialLoadPending: Bool {
        !hasLoaded && profiles.isEmpty && errorMessage == nil
    }
    var avatarDirectory: URL? { avatarDirectoryProvider() }

    private let client: any AgentDirectoryClient
    private let defaults: UserDefaults
    private let currentHostID: () -> String?
    private let avatarDirectoryProvider: () -> URL?
    private var loadGeneration = 0
    private var hasLoaded = false
    /// Default agents are pinned on first sight. Remembering the explicit
    /// unpins keeps a deliberate removal from being undone by the next load.
    private var unpinnedAgentIDs: Set<String> = []

    init(
        client: any AgentDirectoryClient,
        defaults: UserDefaults = .standard,
        profiles: [AgentProfile] = [],
        avatarDirectory: URL? = nil,
        avatarDirectoryProvider: (() -> URL?)? = nil,
        currentHostID: @escaping () -> String? = { nil }
    ) {
        self.client = client
        self.defaults = defaults
        self.profiles = profiles
        self.avatarDirectoryProvider = avatarDirectoryProvider ?? { avatarDirectory }
        self.currentHostID = currentHostID
        selectedAgentID = defaults.string(forKey: Keys.selectedAgentID)
        loadHostScopedPreferences()
        reconcilePinnedAgents()
    }

    func load() async throws {
        loadGeneration += 1
        let generation = loadGeneration
        let hostID = currentHostID()
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }

        do {
            let loadedProfiles = try await BighelpLinkTransientRetry.perform {
                try await self.client.list()
            }
            try Task.checkCancellation()
            guard generation == loadGeneration, hostID == currentHostID() else { throw CancellationError() }
            errorMessage = nil
            errorCode = nil
            let updated = loadedProfiles.map(materializeRemoteAvatar)
            if profiles != updated { profiles = updated }
            loadHostScopedPreferences()
            reconcilePinnedAgents()
            hasLoaded = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard generation == loadGeneration, hostID == currentHostID(), !Task.isCancelled else {
                throw CancellationError()
            }
            // A later connection failure does not disprove a known compatibility
            // failure. Only a successful enumeration or scope reset clears it.
            if Self.isHermesCapabilityMissing(error) { errorCode = "hermes_capability_missing" }
            errorMessage = errorCode == "hermes_capability_missing"
                ? Self.hermesCompatibilityRecovery
                : "Agents could not be loaded from Hermes. Check your Hermes connection and try again."
            throw error
        }
    }

    /// Loads the directory for a view that can render its own recovery UI.
    /// The throwing API remains available to coordinators that need to make a
    /// load failure part of their control flow.
    func loadReportingErrors() async {
        do {
            try await load()
        } catch is CancellationError {
            // A cancelled view task should not become a visible error.
        } catch {
            // `load()` records the user-facing recovery state.
        }
    }

    func loadIfNeededReportingErrors() async {
        guard !hasLoaded else { return }
        await loadReportingErrors()
    }

    func resetForAccountBoundary() {
        loadGeneration += 1
        client.resetForAccountBoundary()
        profiles.removeAll()
        hasLoaded = false
        selectedAgentID = nil
        primaryAgentID = nil
        pinnedAgentIDs.removeAll()
        unpinnedAgentIDs.removeAll()
        isLoading = false
        errorMessage = nil
        errorCode = nil
        defaults.removeObject(forKey: Keys.selectedAgentID)
    }

    static func erasePersistedUserPreferences(defaults: UserDefaults = .standard) {
        AgentGroupPreferences.erase(defaults: defaults)
        defaults.removeObject(forKey: Keys.primaryAgentIDByHost)
        defaults.removeObject(forKey: Keys.pinnedAgentIDsByHost)
        defaults.removeObject(forKey: Keys.unpinnedAgentIDsByHost)
    }

    /// Clears the directory for a Hermes host switch.
    ///
    /// A different host publishes a different agent set, so the loaded
    /// profiles and the recency selection must go. The primary agent and the
    /// Quick Workspace pins are host-scoped configuration rather than cache:
    /// they are re-read for the newly selected host and the previous host's
    /// choices are left on disk, so swapping back restores them.
    func resetForHostChange() {
        loadGeneration += 1
        client.resetForAccountBoundary()
        profiles.removeAll()
        hasLoaded = false
        selectedAgentID = nil
        isLoading = false
        errorMessage = nil
        errorCode = nil
        defaults.removeObject(forKey: Keys.selectedAgentID)
        loadHostScopedPreferences()
    }

    /// Clears the owner-scoped remote detail cache without treating a profile
    /// mutation as an account/host boundary. Existing rows remain cache-first
    /// until the authoritative replacement succeeds.
    func reloadAfterProfileLifecycleChange() async throws {
        loadGeneration += 1
        client.resetForAccountBoundary()
        hasLoaded = false
        try await load()
    }

    /// Preserve app-local selection and ordered pin intent across a verified
    /// Hermes profile rename. Identifier comparison is byte-exact.
    func remapProfilePreferences(from oldProfileID: String, to newProfileID: String) {
        guard !oldProfileID.utf8.elementsEqual(newProfileID.utf8) else { return }
        func remap(_ value: String) -> String {
            value.utf8.elementsEqual(oldProfileID.utf8) ? newProfileID : value
        }
        if selectedAgentID.map({ $0.utf8.elementsEqual(oldProfileID.utf8) }) == true {
            selectedAgentID = newProfileID
            defaults.set(newProfileID, forKey: Keys.selectedAgentID)
        }
        if primaryAgentID.map({ $0.utf8.elementsEqual(oldProfileID.utf8) }) == true {
            primaryAgentID = newProfileID
            persistPrimaryAgent()
        }
        pinnedAgentIDs = pinnedAgentIDs.map(remap)
        unpinnedAgentIDs = Set(unpinnedAgentIDs.map(remap))
        profiles.removeAll { $0.id.utf8.elementsEqual(oldProfileID.utf8) }
        persistPinState()
    }

    /// Remove only preferences owned by a profile whose deletion has already
    /// been confirmed by exact server readback.
    func removeProfilePreferences(profileID: String) {
        if selectedAgentID.map({ $0.utf8.elementsEqual(profileID.utf8) }) == true {
            selectedAgentID = nil
            defaults.removeObject(forKey: Keys.selectedAgentID)
        }
        if primaryAgentID.map({ $0.utf8.elementsEqual(profileID.utf8) }) == true {
            primaryAgentID = nil
            persistPrimaryAgent()
        }
        pinnedAgentIDs.removeAll { $0.utf8.elementsEqual(profileID.utf8) }
        unpinnedAgentIDs = Set(unpinnedAgentIDs.filter {
            !$0.utf8.elementsEqual(profileID.utf8)
        })
        profiles.removeAll { $0.id.utf8.elementsEqual(profileID.utf8) }
        persistPinState()
    }

    /// Restores only the cache and preferences belonging to the host whose
    /// repository scope has already been installed. The next view load still
    /// performs the authoritative remote refresh.
    func restoreCachedProfilesForHostSwitch(_ cachedProfiles: [AgentProfile]) {
        profiles = cachedProfiles.filter { $0 != .bighelpLinkDefault }
        loadHostScopedPreferences()
        reconcilePinnedAgents()
    }

    func select(_ id: String) {
        selectedAgentID = id
        defaults.set(id, forKey: Keys.selectedAgentID)
    }

    // MARK: - Primary agent

    func isPrimary(_ id: String) -> Bool {
        primaryAgentID == id
    }

    /// Promotes one agent to the app-level primary for new chats.
    ///
    /// Setting a primary also clears the ad-hoc recency selection so the two
    /// cannot disagree about which agent an implicit new chat should use.
    @discardableResult
    func setPrimaryAgent(_ id: String) -> Bool {
        guard profiles.contains(where: { $0.id == id }), primaryAgentID != id else { return false }
        primaryAgentID = id
        persistPrimaryAgent()
        selectedAgentID = nil
        defaults.removeObject(forKey: Keys.selectedAgentID)
        return true
    }

    /// Makes the agent the one bighelp opens on, as picking it in the app
    /// does. An agent chosen as the default earlier still wins over a pick,
    /// so that one is replaced too.
    func makeHomeAgent(_ id: String) {
        select(id)
        if resolvedAgent(explicitID: nil)?.id != id { setPrimaryAgent(id) }
    }

    @discardableResult
    func clearPrimaryAgent() -> Bool {
        guard primaryAgentID != nil else { return false }
        primaryAgentID = nil
        persistPrimaryAgent()
        return true
    }

    // MARK: - Quick Workspace pins

    var pinnedAgents: [AgentProfile] {
        pinnedAgentIDs.compactMap { id in
            profiles.first(where: { $0.id == id })
        }
    }

    func isPinned(_ id: String) -> Bool {
        pinnedAgentIDs.contains(id)
    }

    var canPinAnotherAgent: Bool {
        pinnedAgentIDs.count < Self.pinnedAgentLimit
    }

    func canPin(_ id: String) -> Bool {
        !isPinned(id) && canPinAnotherAgent && profiles.contains(where: { $0.id == id })
    }

    /// Files an agent into a section or hides it in the all-hosts list, on
    /// its host. Shown at once; put back when the host doesn't take it.
    func setPlacement(_ placement: AgentListPlacement, profileID: String) async throws {
        guard let writer = client as? any AgentListPlacementWriting else {
            throw WorkspaceClientError.unavailable(.unsupportedHost)
        }
        let previous = profiles.first { $0.id == profileID }?.placement
        if let index = profiles.firstIndex(where: { $0.id == profileID }) { profiles[index].placement = placement }
        do {
            try await writer.setPlacement(placement, profileID: profileID)
        } catch {
            if let index = profiles.firstIndex(where: { $0.id == profileID }) { profiles[index].placement = previous }
            throw error
        }
    }

    @discardableResult
    func pinAgent(_ id: String) -> Bool {
        guard canPin(id) else { return false }
        pinnedAgentIDs.append(id)
        unpinnedAgentIDs.remove(id)
        persistPinState()
        return true
    }

    @discardableResult
    func unpinAgent(_ id: String) -> Bool {
        guard let index = pinnedAgentIDs.firstIndex(of: id) else { return false }
        pinnedAgentIDs.remove(at: index)
        unpinnedAgentIDs.insert(id)
        persistPinState()
        return true
    }

    /// Puts the pinned agents in this order (dragging them on the Agents screen).
    /// Pins not named keep their place after the named ones; unknown ids are ignored.
    @discardableResult
    func reorderPinnedAgents(_ ids: [String]) -> Bool {
        let named = ids.filter { pinnedAgentIDs.contains($0) }
        let order = named + pinnedAgentIDs.filter { !named.contains($0) }
        guard order != pinnedAgentIDs else { return false }
        pinnedAgentIDs = order
        persistPinState()
        return true
    }

    /// Keeps the durable pin intent ordered while projecting only agents in the
    /// current catalog. A successful list can still be partial, so absence is
    /// not evidence that a pin, unpin tombstone, or primary was deleted.
    private func reconcilePinnedAgents() {
        guard !profiles.isEmpty else { return }
        var pinned: Set<String> = []
        var reconciled: [String] = []
        for id in pinnedAgentIDs where pinned.insert(id).inserted {
            reconciled.append(id)
        }

        for profile in profiles where profile.isDefault {
            guard reconciled.count < Self.pinnedAgentLimit,
                  !pinned.contains(profile.id),
                  !unpinnedAgentIDs.contains(profile.id)
            else { continue }
            reconciled.append(profile.id)
            pinned.insert(profile.id)
        }

        guard reconciled != pinnedAgentIDs else { return }
        pinnedAgentIDs = reconciled
        persistPinState()
    }

    private func persistPinState() {
        var pinned = defaults.dictionary(forKey: Keys.pinnedAgentIDsByHost) as? [String: [String]] ?? [:]
        var unpinned = defaults.dictionary(forKey: Keys.unpinnedAgentIDsByHost) as? [String: [String]] ?? [:]
        pinned[hostBucket] = pinnedAgentIDs
        unpinned[hostBucket] = Array(unpinnedAgentIDs).sorted()
        defaults.set(pinned, forKey: Keys.pinnedAgentIDsByHost)
        defaults.set(unpinned, forKey: Keys.unpinnedAgentIDsByHost)
    }

    private func persistPrimaryAgent() {
        var primaries = defaults.dictionary(forKey: Keys.primaryAgentIDByHost) as? [String: String] ?? [:]
        if let primaryAgentID {
            primaries[hostBucket] = primaryAgentID
        } else {
            primaries.removeValue(forKey: hostBucket)
        }
        defaults.set(primaries, forKey: Keys.primaryAgentIDByHost)
    }

    private func loadHostScopedPreferences() {
        let bucket = hostBucket
        primaryAgentID = (defaults.dictionary(forKey: Keys.primaryAgentIDByHost)
            as? [String: String])?[bucket]
        pinnedAgentIDs = (defaults.dictionary(forKey: Keys.pinnedAgentIDsByHost)
            as? [String: [String]])?[bucket] ?? []
        unpinnedAgentIDs = Set((defaults.dictionary(forKey: Keys.unpinnedAgentIDsByHost)
            as? [String: [String]])?[bucket] ?? [])
    }

    /// The persistence bucket for the selected host. An unpaired or fixture
    /// run has no host and shares one stable bucket rather than losing its
    /// configuration on every launch.
    private var hostBucket: String {
        currentHostID() ?? ""
    }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        let generation = loadGeneration
        do {
            let profile = materializeRemoteAvatar(try await client.create(draft))
            guard generation == loadGeneration else { throw CancellationError() }
            upsert(profile)
            return profile
        } catch let error as AgentDirectoryPartialMutationError {
            guard generation == loadGeneration else { throw CancellationError() }
            upsert(materializeRemoteAvatar(error.committedProfile))
            throw error
        }
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        let generation = loadGeneration
        do {
            let response = try await client.update(id: id, draft: draft)
            guard generation == loadGeneration else { throw CancellationError() }
            let stableProfile = materializeRemoteAvatar(AgentProfile(
                id: id,
                name: response.name,
                role: response.role,
                summary: response.summary,
                instructions: response.instructions,
                avatarFileName: response.avatarFileName,
                avatar: response.avatar,
                isDefault: response.isDefault,
                look: response.look
            ))
            guard profiles.contains(where: { $0.id == id }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            upsert(stableProfile)
            return stableProfile
        } catch let error as AgentDirectoryPartialMutationError {
            guard generation == loadGeneration else { throw CancellationError() }
            upsert(materializeRemoteAvatar(error.committedProfile))
            throw error
        }
    }

    func petGallery() async throws -> [PetdexPet] { try await client.petGallery() }

    func petThumbnail(_ pet: PetdexPet) async throws -> Data { try await client.petThumbnail(pet) }

    func petSheet(_ pet: PetdexPet) async throws -> Data { try await client.petSheet(pet) }

    func avatarURL(for profile: AgentProfile) -> URL? {
        AvatarFileURL.resolve(fileName: profile.avatarFileName, in: avatarDirectory)
    }

    /// Resolution order for the agent a chat should use.
    ///
    /// An explicit request always wins. Otherwise the app-level primary
    /// override is authoritative, then the last ad-hoc selection, then the
    /// host's own default agent.
    func resolvedAgent(explicitID: String?) -> AgentProfile? {
        if let explicitID {
            return profiles.first(where: { $0.id == explicitID })
        }
        if let primaryAgentID, let primaryAgent = profiles.first(where: { $0.id == primaryAgentID }) {
            return primaryAgent
        }
        if let selectedAgentID, let selectedAgent = profiles.first(where: { $0.id == selectedAgentID }) {
            return selectedAgent
        }
        return profiles.first(where: \.isDefault)
    }

    private func materializeRemoteAvatar(_ profile: AgentProfile) -> AgentProfile {
        guard let avatarDirectory else { return profile }
        if let previous = profiles.first(where: { $0.id == profile.id }),
           previous.avatar == profile.avatar, let fileName = previous.avatarFileName,
           let url = AvatarFileURL.resolve(fileName: fileName, in: avatarDirectory),
           FileManager.default.fileExists(atPath: url.bighelpFileSystemPath) {
            var updated = profile
            updated.avatarFileName = fileName
            return updated
        }
        if let localURL = AvatarFileURL.resolve(
            fileName: profile.avatarFileName,
            in: avatarDirectory
        ), FileManager.default.fileExists(atPath: localURL.bighelpFileSystemPath) {
            return profile
        }
        return (try? RemoteAgentAvatarCache(directory: avatarDirectory).materialize(profile)) ?? profile
    }

    private func upsert(_ profile: AgentProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        reconcilePinnedAgents()
    }
}

private struct RemoteAgentAvatarCache {
    let directory: URL
    private let processor = AvatarImageProcessor()
    private let fileProtection: any BighelpLocalFileProtecting = BighelpLocalFileProtector()

    func materialize(_ profile: AgentProfile) throws -> AgentProfile {
        guard let avatar = profile.avatar else { return profile }
        guard
            let separator = avatar.dataURL.range(of: ";base64,"),
            let data = Data(base64Encoded: String(avatar.dataURL[separator.upperBound...])),
            data.count == avatar.byteCount,
            BighelpLinkBase64URL.encode(Data(SHA256.hash(data: data))) == avatar.sha256
        else { return profile }

        let prepared = try processor.prepare(data: data)
        let digest = SHA256.hash(data: prepared.data)
            .map { String(format: "%02x", $0) }
            .joined()
        let fileName = "remote-agent-avatar-\(digest).\(prepared.fileExtension)"
        let destination = directory.appending(path: fileName, directoryHint: .notDirectory)
        try fileProtection.prepareDirectory(
            directory,
            protection: .privateVisual,
            fileManager: .default
        )
        if !FileManager.default.fileExists(atPath: destination.bighelpFileSystemPath) {
            try fileProtection.write(
                prepared.data,
                to: destination,
                protection: .privateVisual
            )
        }
        try fileProtection.apply(
            .privateVisual,
            to: destination,
            fileManager: .default
        )

        var materialized = profile
        materialized.avatarFileName = fileName
        return materialized
    }
}

extension AgentDirectoryStore {
    /// A host's pinned agents, as saved while it was selected (the all-hosts
    /// view reads them for hosts that aren't).
    static func savedPinnedAgentIDs(in defaults: UserDefaults, hostBucket: String) -> [String]? {
        (defaults.dictionary(forKey: Keys.pinnedAgentIDsByHost) as? [String: [String]])?[hostBucket]
    }

    static func savedUnpinnedAgentIDs(in defaults: UserDefaults, hostBucket: String) -> [String]? {
        (defaults.dictionary(forKey: Keys.unpinnedAgentIDsByHost) as? [String: [String]])?[hostBucket]
    }

    /// Pins or unpins an agent of a host that isn't selected (from the all-hosts
    /// view), saved just as the Agents screen saves it while that host is selected.
    /// An unpinned agent is remembered as unpinned, so a default agent stays off.
    @discardableResult
    static func savePin(_ pinned: Bool, agentID: String, in defaults: UserDefaults, hostBucket: String) -> Bool {
        var pins = defaults.dictionary(forKey: Keys.pinnedAgentIDsByHost) as? [String: [String]] ?? [:]
        var unpins = defaults.dictionary(forKey: Keys.unpinnedAgentIDsByHost) as? [String: [String]] ?? [:]
        var list = pins[hostBucket] ?? []
        var removed = Set(unpins[hostBucket] ?? [])
        if pinned {
            guard !list.contains(agentID), list.count < pinnedAgentLimit else { return false }
            list.append(agentID)
            removed.remove(agentID)
        } else {
            list.removeAll { $0 == agentID }
            removed.insert(agentID)
        }
        pins[hostBucket] = list
        unpins[hostBucket] = removed.sorted()
        defaults.set(pins, forKey: Keys.pinnedAgentIDsByHost)
        defaults.set(unpins, forKey: Keys.unpinnedAgentIDsByHost)
        return true
    }
}

private extension AgentDirectoryStore {
    enum Keys {
        static let selectedAgentID = "loopdy.demo.selectedAgentID"
        // Agent IDs are only unique within one Hermes host, so these are
        // stored as host-id keyed buckets rather than flat values.
        static let primaryAgentIDByHost = "loopdy.agents.primary-agent-id.by-host"
        static let pinnedAgentIDsByHost = "loopdy.agents.pinned-agent-ids.by-host"
        static let unpinnedAgentIDsByHost = "loopdy.agents.unpinned-agent-ids.by-host"
    }
}
