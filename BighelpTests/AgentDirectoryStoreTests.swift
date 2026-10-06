import Foundation
import Testing
@testable import Bighelp

@MainActor
struct AgentDirectoryStoreTests {
    @Test func relaunchUsesCanonicalCachedProfilesInsteadOfBighelpPlaceholder() {
        let cached = [
            AgentProfile(
                id: "default",
                name: "Juno",
                role: "Primary household agent",
                summary: "Keeps the household moving.",
                instructions: "Be useful.",
                avatarFileName: "juno-avatar.jpg",
                isDefault: true
            ),
        ]

        let initial = BighelpAppComposition.initialAgentProfiles(
            usesFixtures: false,
            cachedAgentProfiles: cached
        )

        #expect(initial == cached)
        #expect(initial.first?.name == "Juno")
        #expect(initial.first?.avatarFileName == "juno-avatar.jpg")
    }

    @Test func productionHostCacheLoadsCanonicalProfilesSynchronously() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-agent-startup-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = [AgentProfile.defaultFixture]
        let repository = DemoRepository<[AgentProfile]>(
            directory: directory,
            name: "agents",
            seed: cached
        )

        let initial = BighelpAppComposition.loadInitialAgentProfiles(
            usesFixtures: false,
            repository: repository
        )

        #expect(initial == cached)
    }

    @Test func firstProductionLaunchDoesNotSynthesizeABighelpAgentWhenCanonicalCacheIsEmpty() {
        let initial = BighelpAppComposition.initialAgentProfiles(
            usesFixtures: false,
            cachedAgentProfiles: []
        )

        #expect(initial.isEmpty)
        #expect(!initial.contains(.bighelpLinkDefault))
    }

    @Test func freshLinkDirectoryCanResolveTheHermesDefaultWithoutDirectCredentials() {
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: []),
            profiles: [.bighelpLinkDefault]
        )

        #expect(store.resolvedAgent(explicitID: nil) == .bighelpLinkDefault)
        #expect(store.resolvedAgent(explicitID: nil)?.id == "default")
    }

    @Test func explicitAgentWinsThenFallsBackToDefault() async throws {
        let defaults = isolatedDefaults()
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: defaults)
        try await store.load()

        store.select("finance")
        #expect(store.resolvedAgent(explicitID: nil)?.id == "finance")
        #expect(store.resolvedAgent(explicitID: "default")?.id == "default")
        client.remove(id: "finance")
        try await store.load()
        #expect(store.resolvedAgent(explicitID: nil)?.id == "default")
    }

    @Test func primaryAgentOverridesTheAdHocSelectionForNewChats() async throws {
        let defaults = isolatedDefaults()
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: defaults)
        try await store.load()

        store.select("default")
        #expect(store.resolvedAgent(explicitID: nil)?.id == "default")

        #expect(store.setPrimaryAgent("finance"))
        #expect(store.isPrimary("finance"))
        #expect(store.resolvedAgent(explicitID: nil)?.id == "finance")
        // An explicit request still wins over the primary override.
        #expect(store.resolvedAgent(explicitID: "default")?.id == "default")
    }

    @Test func primaryAgentSurvivesStoreRecreationAndUnknownIDsAreRefused() async throws {
        let defaults = isolatedDefaults()
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: defaults)
        try await store.load()
        #expect(store.setPrimaryAgent("finance"))
        #expect(store.setPrimaryAgent("missing") == false)

        let restored = AgentDirectoryStore(client: client, defaults: defaults)
        try await restored.load()

        #expect(restored.primaryAgentID == "finance")
        #expect(restored.resolvedAgent(explicitID: nil)?.id == "finance")
    }

    @Test func temporarilyMissingPrimaryUsesAvailableDefaultWithoutErasingPreference() async throws {
        let defaults = isolatedDefaults()
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: defaults)
        try await store.load()
        store.setPrimaryAgent("finance")

        client.remove(id: "finance")
        try await store.load()

        #expect(store.primaryAgentID == "finance")
        #expect(store.resolvedAgent(explicitID: nil)?.id == "default")
    }

    @Test func defaultAgentsStartPinnedAndAnExplicitUnpinIsRemembered() async throws {
        let defaults = isolatedDefaults()
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: defaults)
        try await store.load()

        #expect(store.pinnedAgents.map(\.id) == ["default"])

        #expect(store.unpinAgent("default"))
        #expect(store.pinnedAgents.isEmpty)

        try await store.load()
        #expect(store.pinnedAgents.isEmpty)

        let restored = AgentDirectoryStore(client: client, defaults: defaults)
        try await restored.load()
        #expect(restored.pinnedAgents.isEmpty)
    }

    @Test func quickWorkspaceHoldsAtMostFivePinnedAgents() async throws {
        let defaults = isolatedDefaults()
        let profiles = (0..<7).map { index in
            AgentProfile(
                id: "agent-\(index)",
                name: "Agent \(index)",
                role: "Role",
                summary: "Summary",
                instructions: "",
                avatarFileName: nil,
                isDefault: false
            )
        }
        let client = AgentDirectoryFixtureClient(profiles: profiles)
        let store = AgentDirectoryStore(client: client, defaults: defaults)
        try await store.load()

        for profile in profiles {
            store.pinAgent(profile.id)
        }

        #expect(store.pinnedAgents.count == AgentDirectoryStore.pinnedAgentLimit)
        #expect(store.canPinAnotherAgent == false)
        #expect(store.canPin("agent-6") == false)

        #expect(store.unpinAgent("agent-0"))
        #expect(store.canPin("agent-6"))
        #expect(store.pinAgent("agent-6"))
        #expect(store.pinnedAgents.map(\.id).last == "agent-6")
    }

    @Test func draggedPinnedOrderIsKeptAcrossRelaunch() async throws {
        let defaults = isolatedDefaults()
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: defaults)
        try await store.load()
        store.pinAgent("finance")
        #expect(store.pinnedAgentIDs == ["default", "finance"])

        #expect(store.reorderPinnedAgents(["finance", "default"]))
        #expect(store.reorderPinnedAgents(["finance", "default"]) == false, "Same order, nothing to save")
        #expect(store.reorderPinnedAgents(["nobody", "default"]), "Unknown ids are ignored")
        #expect(store.pinnedAgentIDs == ["default", "finance"])
        store.reorderPinnedAgents(["finance"])

        let restored = AgentDirectoryStore(client: client, defaults: defaults)
        try await restored.load()
        #expect(restored.pinnedAgentIDs == ["finance", "default"])
    }

    @Test func pinnedIntentSurvivesPartialCatalogAndRelaunch() async throws {
        let defaults = isolatedDefaults()
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: defaults)
        try await store.load()
        #expect(store.pinAgent("finance"))
        #expect(store.unpinAgent("default"))
        client.replaceAll(with: [.financeFixture])
        try await store.load()
        client.replaceAll(with: [.defaultFixture])
        try await store.load()
        let restored = AgentDirectoryStore(client: client, defaults: defaults)
        client.replaceAll(with: [.defaultFixture, .financeFixture])
        try await restored.load()
        #expect(restored.pinnedAgentIDs == ["finance"])
        #expect(!restored.isPinned("default"))
    }

    @Test func pinsDropAgentsThatNoLongerExistAndNeverDuplicate() async throws {
        let defaults = isolatedDefaults()
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: defaults)
        try await store.load()
        store.pinAgent("finance")
        #expect(store.pinAgent("finance") == false)
        #expect(store.pinnedAgents.map(\.id) == ["default", "finance"])

        client.remove(id: "finance")
        try await store.load()

        #expect(store.pinnedAgents.map(\.id) == ["default"])
    }

    @Test func hostSwitchKeepsEachHostsPrimaryAndPinsAndRestoresThemOnSwapBack() async throws {
        let defaults = isolatedDefaults()
        var selectedHostID = "host-studio"
        let studioProfiles: [AgentProfile] = [.defaultFixture, .financeFixture]
        let laptopProfiles: [AgentProfile] = [
            .defaultFixture,
            AgentProfile(
                id: "research",
                name: "Rey",
                role: "Research",
                summary: "A research specialist.",
                instructions: "",
                avatarFileName: nil,
                isDefault: false
            ),
        ]
        let client = AgentDirectoryFixtureClient(profiles: studioProfiles)
        let store = AgentDirectoryStore(
            client: client,
            defaults: defaults,
            currentHostID: { selectedHostID }
        )

        // Configure the studio host.
        try await store.load()
        #expect(store.setPrimaryAgent("finance"))
        #expect(store.pinAgent("finance"))
        #expect(store.pinnedAgents.map(\.id) == ["default", "finance"])

        // Switch to a host that publishes a different agent set.
        selectedHostID = "host-laptop"
        client.replaceAll(with: laptopProfiles)
        store.resetForHostChange()
        try await store.load()

        #expect(store.primaryAgentID == nil, "A new host must not inherit another host's primary agent.")
        #expect(store.pinnedAgents.map(\.id) == ["default"])
        #expect(store.setPrimaryAgent("research"))
        #expect(store.pinAgent("research"))

        // Swap back: the studio host's configuration must be intact.
        selectedHostID = "host-studio"
        client.replaceAll(with: studioProfiles)
        store.resetForHostChange()
        try await store.load()

        #expect(store.primaryAgentID == "finance")
        #expect(store.pinnedAgents.map(\.id) == ["default", "finance"])
        #expect(store.resolvedAgent(explicitID: nil)?.id == "finance")

        // And forward again, without re-deriving from defaults.
        selectedHostID = "host-laptop"
        client.replaceAll(with: laptopProfiles)
        store.resetForHostChange()
        try await store.load()

        #expect(store.primaryAgentID == "research")
        #expect(store.pinnedAgents.map(\.id) == ["default", "research"])
    }

    @Test func hostSwitchRestoresOnlyTheNewHostsCachedAgentsBeforeRemoteRefresh() throws {
        let defaults = isolatedDefaults()
        var selectedHostID = "host-old"
        let old = AgentProfile.defaultFixture
        let new = AgentProfile.financeFixture
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: []),
            defaults: defaults,
            profiles: [old],
            currentHostID: { selectedHostID }
        )

        store.resetForHostChange()
        selectedHostID = "host-new"
        store.restoreCachedProfilesForHostSwitch([new])

        #expect(store.profiles == [new])
        #expect(!store.profiles.contains(old))
    }

    @Test func hostSwitchStillDropsTheLoadedDirectoryAndRecencySelection() async throws {
        let defaults = isolatedDefaults()
        var selectedHostID = "host-studio"
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(
            client: client,
            defaults: defaults,
            currentHostID: { selectedHostID }
        )
        try await store.load()
        store.select("finance")

        selectedHostID = "host-laptop"
        store.resetForHostChange()

        #expect(store.profiles.isEmpty, "A host switch must not leave another host's agents on screen.")
        #expect(store.selectedAgentID == nil)
        #expect(store.resolvedAgent(explicitID: nil) == nil)
    }

    @Test func accountResetDiscardsSuspendedCreatePartialMutationAsCancellation() async {
        let client = SuspendedPartialMutationAgentDirectoryClient(
            committedProfile: .financeFixture
        )
        let store = AgentDirectoryStore(client: client, defaults: isolatedDefaults())
        let creation = Task {
            do {
                _ = try await store.create(AgentDraft(
                    name: "Finley",
                    role: "Finance",
                    summary: "A finance specialist.",
                    instructions: "Help with budgets.",
                    avatarFileName: nil,
                    isDefault: false
                ))
                Issue.record("Expected the invalidated create to be cancelled")
                return false
            } catch is CancellationError {
                return true
            } catch {
                Issue.record("Expected CancellationError, received \(error)")
                return false
            }
        }

        await client.waitUntilCreateStarts()
        store.resetForAccountBoundary()
        client.resumeCreateWithPartialMutation()

        #expect(await creation.value)
        #expect(store.profiles.isEmpty)
    }

    @Test func explicitUnpinIsRememberedPerHost() async throws {
        let defaults = isolatedDefaults()
        var selectedHostID = "host-studio"
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture])
        let store = AgentDirectoryStore(
            client: client,
            defaults: defaults,
            currentHostID: { selectedHostID }
        )
        try await store.load()
        #expect(store.unpinAgent("default"))

        selectedHostID = "host-laptop"
        store.resetForHostChange()
        try await store.load()
        // The other host has never been told to unpin its default agent.
        #expect(store.pinnedAgents.map(\.id) == ["default"])

        selectedHostID = "host-studio"
        store.resetForHostChange()
        try await store.load()
        #expect(store.pinnedAgents.isEmpty)
    }

    @Test func accountBoundaryPreservesEveryHostsAgentPreferencesUntilTheUserChangesThem() async throws {
        let defaults = isolatedDefaults()
        let selectedHostID = "host-studio"
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(
            client: client,
            defaults: defaults,
            currentHostID: { selectedHostID }
        )
        try await store.load()
        store.setPrimaryAgent("finance")
        store.pinAgent("finance")

        store.resetForAccountBoundary()

        #expect(store.primaryAgentID == nil)
        #expect(store.pinnedAgentIDs.isEmpty)

        // Signing back in to the same host restores deliberate preferences.
        try await store.load()
        #expect(store.primaryAgentID == "finance")
        #expect(store.pinnedAgents.map(\.id) == ["default", "finance"])

        // Store recreation, including an app update, must preserve them too.
        let restored = AgentDirectoryStore(
            client: client,
            defaults: defaults,
            currentHostID: { selectedHostID }
        )
        try await restored.load()
        #expect(restored.primaryAgentID == "finance")
        #expect(restored.pinnedAgents.map(\.id) == ["default", "finance"])
    }

    @Test func pinLimitCopyMatchesTheStoreLimit() {
        #expect(AgentActionPresentation.pinnedAgentLimit == AgentDirectoryStore.pinnedAgentLimit)
        #expect(AgentActionPresentation.pinLimitHint.contains("5"))
    }

    @Test func deletingTheAccountErasesPersistedAgentPreferences() async throws {
        let defaults = isolatedDefaults()
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: defaults)
        try await store.load()
        store.setPrimaryAgent("finance")
        store.pinAgent("finance")

        AgentDirectoryStore.erasePersistedUserPreferences(defaults: defaults)

        let restored = AgentDirectoryStore(client: client, defaults: defaults)
        try await restored.load()
        #expect(restored.primaryAgentID == nil)
        #expect(restored.pinnedAgents.map(\.id) == ["default"])
    }

    @Test func uncachedDirectoryShowsInitialLoadingBeforeTheViewTaskStarts() {
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: []),
            defaults: isolatedDefaults()
        )

        #expect(store.isInitialLoadPending)
    }

    @Test func cachedAgentsUseInlineRefreshWhileAnEmptyDirectoryUsesFullLoading() {
        #expect(AgentDirectoryPresentation.loadingMode(isLoading: true, hasProfiles: true) == .inline)
        #expect(AgentDirectoryPresentation.loadingMode(isLoading: true, hasProfiles: false) == .fullScreen)
    }

    @Test func visibleDirectorySuppressesOnlyTheInternalBighelpPlaceholder() {
        let canonicalDefault = AgentProfile(
            id: "default",
            name: "Juno",
            role: "Household agent",
            summary: "Keeps things moving.",
            instructions: "Be useful.",
            isDefault: true
        )

        #expect(
            AgentDirectoryPresentation.visibleProfiles([.bighelpLinkDefault, canonicalDefault])
                == [canonicalDefault]
        )
    }

    @Test func agentRowMenuIncludesCanonicalChatAndAllManagementActions() {
        #expect(AgentRowMenuAction.allCases.map(\.title) == [
            "Message",
            "Edit",
            "Past chats",
            "Scheduled tasks",
            "Group chats",
            "Duplicate",
            "Use with Siri",
            "Use for new chats",
            "Pin",
            "Save as template",
            "Delete",
        ])
    }

    @Test func selectedStableIDSurvivesStoreRecreation() async throws {
        let defaults = isolatedDefaults()
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let original = AgentDirectoryStore(client: client, defaults: defaults)
        try await original.load()
        original.select("finance")

        let restored = AgentDirectoryStore(client: client, defaults: defaults)
        try await restored.load()

        #expect(restored.resolvedAgent(explicitID: nil)?.id == "finance")
    }

    @Test func directoryWithoutExplicitSelectedOrDefaultAgentRequiresSelection() async throws {
        let defaults = isolatedDefaults()
        let client = AgentDirectoryFixtureClient(profiles: [.financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: defaults)
        try await store.load()

        #expect(store.resolvedAgent(explicitID: nil) == nil)
    }

    @Test func missingExplicitIDDoesNotFallBackToSelectedOrDefaultAgent() async throws {
        let defaults = isolatedDefaults()
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture]),
            defaults: defaults
        )
        try await store.load()
        store.select("finance")

        #expect(store.resolvedAgent(explicitID: "unavailable") == nil)
    }

    @Test func gatewayCompatibilityFailurePreservesProfilesAndExplainsRecovery() async {
        let client = FailingAgentDirectoryClient(
            profiles: [.defaultFixture], failuresRemaining: 1,
            failure: BighelpLinkWorkspaceClientError.remote(
                status: .failed, code: "hermes_capability_missing", message: "private detail"
            )
        )
        let store = AgentDirectoryStore(client: client, defaults: isolatedDefaults(), profiles: [.defaultFixture])
        await store.loadReportingErrors()
        #expect(store.profiles == [.defaultFixture])
        #expect(store.errorMessage?.contains("Update Hermes") == true)
        #expect(store.errorMessage?.contains("private detail") == false)
        #expect(store.isLoading == false)
    }

    @Test func failedDirectoryLoadPreservesProfilesAndExposesRetryableError() async throws {
        let client = FailingAgentDirectoryClient(
            profiles: [.defaultFixture],
            failuresRemaining: 1
        )
        let store = AgentDirectoryStore(client: client, profiles: [.defaultFixture])

        await #expect(throws: AgentDirectoryFixtureError.unavailable) {
            try await store.load()
        }

        #expect(store.profiles == [.defaultFixture])
        #expect(store.isLoading == false)
        #expect(store.errorMessage == "Agents could not be loaded from Hermes. Check your Hermes connection and try again.")

        try await store.load()

        #expect(store.profiles == [.defaultFixture])
        #expect(store.errorMessage == nil)
    }

    @Test func transientLinkDirectoryFailureIsRecoveredBeforeAgentsAreReportedMissing() async throws {
        let client = FailingAgentDirectoryClient(
            profiles: [.defaultFixture],
            failuresRemaining: 0,
            linkFailuresRemaining: 1
        )
        let store = AgentDirectoryStore(client: client)

        try await store.load()

        #expect(client.listCallCount == 2)
        #expect(store.profiles == [.defaultFixture])
        #expect(store.errorMessage == nil)
    }

    @Test func successfulViewLoadIsNotRepeatedOnRouteReentryButExplicitRefreshStillLoads() async {
        let client = CountingAgentDirectoryClient(profiles: [.defaultFixture])
        let store = AgentDirectoryStore(client: client)

        await store.loadIfNeededReportingErrors()
        await store.loadIfNeededReportingErrors()
        #expect(client.listCallCount == 1)

        await store.loadReportingErrors()
        #expect(client.listCallCount == 2)

        store.resetForAccountBoundary()
        await store.loadIfNeededReportingErrors()
        #expect(client.listCallCount == 3)
    }

    @Test func remoteAvatarIsMaterializedForRenderingOnAFreshDevice() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AgentDirectoryStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let pngData = try #require(Data(base64Encoded: pngBase64))
        let remoteProfile = AgentProfile(
            id: "default",
            name: "Juno",
            role: "Default agent",
            summary: "General help",
            instructions: "Be helpful.",
            avatarFileName: nil,
            avatar: AgentAvatar(
                mimeType: "image/png",
                byteCount: 68,
                sha256: "QxztaRaiohoVbjhwGv5Vu9f4iWn7v8Vtf-CZ1H8mVGA",
                dataURL: "data:image/png;base64,\(pngBase64)"
            ),
            isDefault: true
        )
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [remoteProfile]),
            defaults: isolatedDefaults(),
            avatarDirectory: directory
        )

        try await store.load()

        let loaded = try #require(store.profiles.first)
        let localURL = try #require(store.avatarURL(for: loaded))
        #expect(loaded.avatar == remoteProfile.avatar)
        #expect(try Data(contentsOf: localURL) == pngData)
    }

    @Test func remoteAvatarWithMismatchedDigestIsNeverMaterialized() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AgentDirectoryStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let remoteProfile = AgentProfile(
            id: "default",
            name: "Juno",
            role: "Default agent",
            summary: "General help",
            instructions: "Be helpful.",
            avatarFileName: nil,
            avatar: AgentAvatar(
                mimeType: "image/png",
                byteCount: 68,
                sha256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                dataURL: "data:image/png;base64,\(pngBase64)"
            ),
            isDefault: true
        )
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [remoteProfile]),
            defaults: isolatedDefaults(),
            avatarDirectory: directory
        )

        try await store.load()

        let loaded = try #require(store.profiles.first)
        #expect(store.avatarURL(for: loaded) == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.bighelpFileSystemPath))?.isEmpty != false)
    }
}

@MainActor
private final class CountingAgentDirectoryClient: AgentDirectoryClient {
    let profiles: [AgentProfile]
    private(set) var listCallCount = 0

    init(profiles: [AgentProfile]) {
        self.profiles = profiles
    }

    func list() async throws -> [AgentProfile] {
        listCallCount += 1
        return profiles
    }

    func create(_ draft: AgentDraft) async throws -> AgentProfile { throw CocoaError(.featureUnsupported) }
    func update(id: String, draft: AgentDraft) async throws -> AgentProfile { throw CocoaError(.featureUnsupported) }
}

@MainActor
private final class SuspendedPartialMutationAgentDirectoryClient: AgentDirectoryClient {
    private let committedProfile: AgentProfile
    private var createStarted = false
    private var createStartedWaiter: CheckedContinuation<Void, Never>?
    private var createWaiter: CheckedContinuation<Void, Never>?

    init(committedProfile: AgentProfile) {
        self.committedProfile = committedProfile
    }

    func list() async throws -> [AgentProfile] { [] }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        await withCheckedContinuation { continuation in
            createWaiter = continuation
            createStarted = true
            createStartedWaiter?.resume()
            createStartedWaiter = nil
        }
        throw AgentDirectoryPartialMutationError(committedProfile: committedProfile)
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        throw CocoaError(.featureUnsupported)
    }

    func waitUntilCreateStarts() async {
        guard !createStarted else { return }
        await withCheckedContinuation { continuation in
            createStartedWaiter = continuation
        }
    }

    func resumeCreateWithPartialMutation() {
        createWaiter?.resume()
        createWaiter = nil
    }
}

@MainActor
final class AgentDirectoryFixtureClient: AgentDirectoryClient {
    private(set) var profiles: [AgentProfile]

    init(profiles: [AgentProfile]) {
        self.profiles = profiles
    }

    func petSheet(_ pet: PetdexPet) async throws -> Data {
        guard let sheet = PetdexFixtures.sheet(slug: pet.slug) else { throw PetdexError.unsupported }
        return sheet
    }

    func list() async throws -> [AgentProfile] {
        profiles
    }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        let profile = AgentProfile(
            id: "fixture-\(profiles.count + 1)",
            name: draft.name,
            role: draft.role,
            summary: draft.summary,
            instructions: draft.instructions,
            avatarFileName: draft.avatarFileName,
            avatar: draft.avatar,
            isDefault: draft.isDefault
        )
        profiles.append(profile)
        return profile
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        let profile = AgentProfile(
            id: id,
            name: draft.name,
            role: draft.role,
            summary: draft.summary,
            instructions: draft.instructions,
            avatarFileName: draft.avatarFileName,
            avatar: draft.avatar,
            isDefault: draft.isDefault
        )
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        profiles[index] = profile
        return profile
    }

    func remove(id: String) {
        profiles.removeAll { $0.id == id }
    }

    /// Stands in for a different Hermes host publishing its own agent set.
    func replaceAll(with profiles: [AgentProfile]) {
        self.profiles = profiles
    }
}

private enum AgentDirectoryFixtureError: Error, Equatable {
    case unavailable
}

@MainActor
private final class FailingAgentDirectoryClient: AgentDirectoryClient {
    let profiles: [AgentProfile]
    var failuresRemaining: Int
    var linkFailuresRemaining: Int
    let failure: any Error
    private(set) var listCallCount = 0

    init(
        profiles: [AgentProfile],
        failuresRemaining: Int,
        linkFailuresRemaining: Int = 0,
        failure: any Error = AgentDirectoryFixtureError.unavailable
    ) {
        self.profiles = profiles
        self.failuresRemaining = failuresRemaining
        self.linkFailuresRemaining = linkFailuresRemaining
        self.failure = failure
    }

    func list() async throws -> [AgentProfile] {
        listCallCount += 1
        if linkFailuresRemaining > 0 {
            linkFailuresRemaining -= 1
            throw BighelpLinkLiveSocketError.timedOut
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw failure
        }
        return profiles
    }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        fatalError("Unused by this fixture")
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        fatalError("Unused by this fixture")
    }
}

extension AgentProfile {
    static let defaultFixture = AgentProfile(
        id: "default",
        name: "Avery",
        role: "Generalist",
        summary: "A dependable default assistant.",
        instructions: "Help with everyday work.",
        avatarFileName: nil,
        isDefault: true
    )

    static let financeFixture = AgentProfile(
        id: "finance",
        name: "Finley",
        role: "Finance",
        summary: "A finance specialist.",
        instructions: "Help with budgets.",
        avatarFileName: "finance.png",
        isDefault: false
    )
}

func isolatedDefaults() -> UserDefaults {
    let suiteName = "BighelpTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
