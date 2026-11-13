import Foundation
import Testing
@testable import Bighelp

@MainActor
struct AgentRuntimeDefaultsModelTests {
    @Test func emptyBootstrapCatalogDoesNotHideLaterSavedPins() async throws {
        let base = AgentRuntimeDefaultsClientFixture(defaults: .automatic)
        let cache = ModelProviderDiscoveryCache(client: base)
        let key = ModelProviderDiscoveryKey(accountGeneration: 1, connectionIdentity: "host", reconnectGeneration: 1, agentID: "agent")
        cache.seed([], for: key, matching: cache.seedToken(for: key))
        #expect(cache.cachedProviders(for: key) == nil)
        cache.seed(Self.providers, for: key, matching: cache.seedToken(for: key))
        #expect(cache.cachedProviders(for: key) == Self.providers)
    }

    @Test func defaultsBootstrapMakesSavedPinsVisibleBeforeOpeningPicker() async throws {
        let base = AgentRuntimeDefaultsClientFixture(defaults: .automatic)
        let client = CachedAgentRuntimeDefaultsClient(base: base, connectionIdentity: "https://link.example")
        let name = "pin-cold-start-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let history = RecentModelHistoryStore(defaults: defaults)
        #expect(history.togglePin(providerID: "openai", modelID: "gpt-5.6-mini"))
        _ = try await client.loadDefaults(agentID: "finance")
        let providers = try #require(client.cachedModelProviders(agentID: "finance"))
        let restored = RecentModelHistoryStore(defaults: defaults)
        #expect(restored.pinnedChoices(providers: providers, currentProviderID: nil, currentModelID: nil).map(\.modelID) == ["gpt-5.6-mini"])
    }

    @Test func editorLoadsAgentDefaultsAndKeepsChangesDraftedUntilSave() async throws {
        let original = AgentRuntimeDefaults(
            mainChats: AgentRuntimeSelection(
                providerID: "nous",
                modelID: "Hermes-4-405B",
                reasoningEffort: "high"
            ),
            subagents: .automatic,
            scheduledTasks: .automatic
        )
        let client = AgentRuntimeDefaultsClientFixture(defaults: original)
        let model = AgentRuntimeDefaultsEditorModel(agentID: "finance", client: client)

        await model.load()
        model.selectModel(
            providerID: "openai",
            modelID: "gpt-5.6-mini",
            for: .subagents
        )
        model.selectReasoning("medium", for: .scheduledTasks)

        #expect(model.draft.subagents.providerID == "openai")
        #expect(model.draft.subagents.modelID == "gpt-5.6-mini")
        #expect(model.draft.scheduledTasks.reasoningEffort == "medium")
        #expect(model.isDirty)
        #expect(client.saved.isEmpty)

        try await model.saveIfNeeded()

        #expect(client.saved == [model.draft])
        #expect(model.isDirty == false)
    }

    @Test func invalidProviderModelAndReasoningSelectionsNeverEnterTheDraft() async {
        let client = AgentRuntimeDefaultsClientFixture(defaults: .automatic)
        let model = AgentRuntimeDefaultsEditorModel(agentID: "finance", client: client)
        await model.load()

        model.selectModel(
            providerID: "openai",
            modelID: "not-a-real-model",
            for: .mainChats
        )
        model.selectReasoning("turbo", for: .mainChats)

        #expect(model.draft == .automatic)
        #expect(model.errorMessage == "That model or reasoning level is no longer available.")
    }

    @Test func failedSaveKeepsTheDraftAndAllowsAnHonestRetry() async {
        let client = AgentRuntimeDefaultsClientFixture(defaults: .automatic)
        let model = AgentRuntimeDefaultsEditorModel(agentID: "finance", client: client)
        await model.load()
        model.selectReasoning("max", for: .mainChats)
        client.saveError = AgentRuntimeDefaultsClientFixture.Failure.save

        await #expect(throws: AgentRuntimeDefaultsClientFixture.Failure.save) {
            try await model.saveIfNeeded()
        }

        #expect(model.draft.mainChats.reasoningEffort == "max")
        #expect(model.isDirty)
        #expect(model.errorMessage == "We couldn’t save these bot defaults. Your choices are still here.")
    }

    @Test func transientCatalogFailureIsRetriedWithoutDiscardingTheDefaults() async {
        let client = AgentRuntimeDefaultsClientFixture(defaults: .automatic)
        client.defaultsLoadFailuresRemaining = 1
        let model = AgentRuntimeDefaultsEditorModel(
            agentID: "finance",
            client: client,
            retryDelays: [.milliseconds(0)]
        )

        await model.load()

        #expect(model.hasLoaded)
        #expect(model.errorMessage == nil)
        #expect(model.draft == .automatic)
    }

    @Test func providerDiscoveryCoalescesByAccountConnectionReconnectAndAgentKey() async throws {
        let client = DeferredModelProviderClient()
        let cache = ModelProviderDiscoveryCache(client: client)
        let key = ModelProviderDiscoveryKey(
            accountGeneration: 1,
            connectionIdentity: "https://link.example",
            reconnectGeneration: 2,
            agentID: "finance"
        )

        let first = Task { try await cache.providers(for: key) }
        let second = Task { try await cache.providers(for: key) }
        await client.waitUntilLoadStarts(count: 1)
        client.resume(with: Self.providers)

        #expect(try await first.value == Self.providers)
        #expect(try await second.value == Self.providers)
        #expect(client.loadCount == 1)

        _ = try await cache.providers(for: key)
        #expect(client.loadCount == 1)

        cache.invalidateForReconnect()
        let reconnected = Task { try await cache.providers(for: key) }
        await client.waitUntilLoadStarts(count: 2)
        client.resume(with: Self.providers)
        _ = try await reconnected.value
        #expect(client.loadCount == 2)

        cache.invalidateForAccountBoundary()
        let nextAccount = Task { try await cache.providers(for: key) }
        await client.waitUntilLoadStarts(count: 3)
        client.resume(with: Self.providers)
        _ = try await nextAccount.value
        #expect(client.loadCount == 3)
    }

    @Test func invalidationRejectsBothWaitersOnACoalescedProviderRequest() async {
        let client = DeferredModelProviderClient()
        let cache = ModelProviderDiscoveryCache(client: client)
        let key = ModelProviderDiscoveryKey(
            accountGeneration: 1,
            connectionIdentity: "https://link.example",
            reconnectGeneration: 2,
            agentID: "finance"
        )
        let staleProviders = [BighelpLinkModelProvider(
            id: "stale",
            name: "Stale",
            isCurrent: false,
            isCustom: false,
            models: ["old"]
        )]

        let first = Task { try await cache.providers(for: key) }
        await client.waitUntilLoadStarts(count: 1)
        let second = Task { try await cache.providers(for: key) }
        await Task.yield()
        cache.invalidateForReconnect()
        client.resume(with: staleProviders)

        await #expect(throws: CancellationError.self) { _ = try await first.value }
        await #expect(throws: CancellationError.self) { _ = try await second.value }
        #expect(client.loadCount == 1)
        #expect(cache.cachedProviders(for: key) == nil)
    }

    @Test func cachedClientObservesAutomaticGenerationChangesAndStillCoalescesSameGeneration() async throws {
        let generation = ConnectionGenerationFixture(value: 1)
        let base = DeferredAgentRuntimeDefaultsClient()
        let client = CachedAgentRuntimeDefaultsClient(
            base: base,
            connectionIdentity: "https://link.example",
            connectionGeneration: { generation.value }
        )

        let first = Task { try await client.loadModelProviders(agentID: "finance") }
        let second = Task { try await client.loadModelProviders(agentID: "finance") }
        await base.waitUntilLoadStarts(count: 1)
        base.resume(request: 1, with: Self.providers)
        #expect(try await first.value == Self.providers)
        #expect(try await second.value == Self.providers)
        #expect(base.loadCount == 1)

        _ = try await client.loadModelProviders(agentID: "finance")
        #expect(base.loadCount == 1)

        generation.value = 2
        let automaticReconnect = Task { try await client.loadModelProviders(agentID: "finance") }
        await base.waitUntilLoadStarts(count: 2)
        base.resume(request: 2, with: Self.providers)
        _ = try await automaticReconnect.value
        #expect(base.loadCount == 2)
    }

    @Test func automaticGenerationChangeRejectsStaleInFlightProviderCompletion() async throws {
        let generation = ConnectionGenerationFixture(value: 1)
        let base = DeferredAgentRuntimeDefaultsClient()
        let client = CachedAgentRuntimeDefaultsClient(
            base: base,
            connectionIdentity: "https://link.example",
            connectionGeneration: { generation.value }
        )

        let stale = Task { try await client.loadModelProviders(agentID: "finance") }
        await base.waitUntilLoadStarts(count: 1)
        generation.value = 2
        let current = Task { try await client.loadModelProviders(agentID: "finance") }
        await base.waitUntilLoadStarts(count: 2)

        base.resume(request: 1, with: [BighelpLinkModelProvider(
            id: "stale",
            name: "Stale",
            isCurrent: false,
            isCustom: false,
            models: ["old"]
        )])
        await #expect(throws: CancellationError.self) {
            _ = try await stale.value
        }

        base.resume(request: 2, with: Self.providers)
        #expect(try await current.value == Self.providers)
        #expect(try await client.loadModelProviders(agentID: "finance") == Self.providers)
        #expect(base.loadCount == 2)
    }

    private static let providers = [
        BighelpLinkModelProvider(
            id: "nous",
            name: "Nous Research",
            isCurrent: true,
            isCustom: false,
            models: ["Hermes-4-405B"]
        ),
    ]
}

@MainActor
private final class ConnectionGenerationFixture {
    var value: UInt64

    init(value: UInt64) {
        self.value = value
    }
}

@MainActor
private final class DeferredAgentRuntimeDefaultsClient: AgentRuntimeDefaultsClient {
    private var continuations: [Int: CheckedContinuation<[BighelpLinkModelProvider], Error>] = [:]
    private(set) var loadCount = 0

    func loadDefaults(agentID: String) async throws -> AgentRuntimeDefaults { .automatic }

    func loadModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider] {
        loadCount += 1
        let request = loadCount
        return try await withCheckedThrowingContinuation { continuations[request] = $0 }
    }

    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String) async throws {}

    func waitUntilLoadStarts(count: Int) async {
        while loadCount < count { await Task.yield() }
    }

    func resume(request: Int, with providers: [BighelpLinkModelProvider]) {
        continuations.removeValue(forKey: request)?.resume(returning: providers)
    }
}

@MainActor
private final class DeferredModelProviderClient: ModelProviderDiscoveryClient {
    private var continuations: [CheckedContinuation<[BighelpLinkModelProvider], Error>] = []
    private(set) var loadCount = 0

    func loadModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider] {
        loadCount += 1
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func waitUntilLoadStarts(count: Int) async {
        while loadCount < count { await Task.yield() }
    }

    func resume(with providers: [BighelpLinkModelProvider]) {
        continuations.removeFirst().resume(returning: providers)
    }
}

@MainActor
final class AgentRuntimeDefaultsClientFixture: AgentRuntimeDefaultsClient {
    enum Failure: Error { case save, load }

    let defaults: AgentRuntimeDefaults
    var saveError: Error?
    var defaultsLoadFailuresRemaining = 0
    private(set) var saved: [AgentRuntimeDefaults] = []

    init(defaults: AgentRuntimeDefaults) {
        self.defaults = defaults
    }

    func loadDefaults(agentID: String) async throws -> AgentRuntimeDefaults {
        if defaultsLoadFailuresRemaining > 0 {
            defaultsLoadFailuresRemaining -= 1
            throw Failure.load
        }
        return defaults
    }

    func loadModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider] {
        [
            BighelpLinkModelProvider(
                id: "nous",
                name: "Nous Research",
                isCurrent: true,
                isCustom: false,
                models: ["Hermes-4-405B"]
            ),
            BighelpLinkModelProvider(
                id: "openai",
                name: "OpenAI",
                isCurrent: false,
                isCustom: false,
                models: ["gpt-5.6-mini"]
            ),
        ]
    }

    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String) async throws {
        if let saveError { throw saveError }
        saved.append(defaults)
    }
}
