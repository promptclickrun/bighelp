import Foundation

enum AgentRuntimeScope: String, CaseIterable, Identifiable, Sendable {
    case mainChats
    case subagents
    case scheduledTasks

    var id: Self { self }

    var title: String {
        switch self {
        case .mainChats: "Main chats"
        case .subagents: "Subagents"
        case .scheduledTasks: "Scheduled tasks"
        }
    }

    var detail: String {
        switch self {
        case .mainChats:
            "Used when you start a regular chat with this agent."
        case .subagents:
            "Used when this agent delegates work to another agent."
        case .scheduledTasks:
            "Used for new scheduled tasks created for this agent."
        }
    }

    var systemImage: String {
        switch self {
        case .mainChats: "bubble.left.and.bubble.right"
        case .subagents: "point.3.connected.trianglepath.dotted"
        case .scheduledTasks: "calendar.badge.clock"
        }
    }
}

struct AgentRuntimeSelection: Equatable, Sendable {
    var providerID: String
    var modelID: String
    var reasoningEffort: String
    var fastMode: FastMode = .off

    static let automatic = AgentRuntimeSelection(
        providerID: "",
        modelID: "",
        reasoningEffort: ""
    )
}

struct AgentRuntimeDefaults: Equatable, Sendable {
    var mainChats: AgentRuntimeSelection
    var subagents: AgentRuntimeSelection
    var scheduledTasks: AgentRuntimeSelection

    static let automatic = AgentRuntimeDefaults(
        mainChats: .automatic,
        subagents: .automatic,
        scheduledTasks: .automatic
    )

    subscript(scope: AgentRuntimeScope) -> AgentRuntimeSelection {
        get {
            switch scope {
            case .mainChats: mainChats
            case .subagents: subagents
            case .scheduledTasks: scheduledTasks
            }
        }
        set {
            switch scope {
            case .mainChats: mainChats = newValue
            case .subagents: subagents = newValue
            case .scheduledTasks: scheduledTasks = newValue
            }
        }
    }
}

struct AgentRuntimeDefaultsCatalog: Equatable, Sendable {
    let defaults: AgentRuntimeDefaults
    let providers: [BighelpLinkModelProvider]
    var support: AgentRuntimeDefaultsSupport = .all
}

struct AgentRuntimeDefaultsSupport: Equatable, Sendable {
    var modelUnavailableReasons: [AgentRuntimeScope: String] = [:]
    var reasoningUnavailableReasons: [AgentRuntimeScope: String] = [:]
    var reasoningNotes: [AgentRuntimeScope: String] = [:]
    static let all = AgentRuntimeDefaultsSupport()
}

struct AgentRuntimeDefaultsSaveConfirmation: Identifiable, Equatable, Sendable {
    let id: UUID
    let agentID: String
    let defaults: AgentRuntimeDefaults
    let message: String
}

struct AgentRuntimeDefaultsConfirmationRequired: Error, Equatable, Sendable {
    let confirmation: AgentRuntimeDefaultsSaveConfirmation
}

struct AgentRuntimeDefaultsPartialSaveError: Error, Equatable, Sendable {
    let committed: AgentRuntimeDefaults
}

@MainActor
protocol AgentRuntimeDefaultsConfirmingClient: AgentRuntimeDefaultsClient {
    func saveDefaults(
        _ defaults: AgentRuntimeDefaults, agentID: String,
        confirmation: AgentRuntimeDefaultsSaveConfirmation
    ) async throws
}

struct ModelProviderDiscoveryKey: Hashable, Sendable {
    let accountGeneration: UInt64
    let connectionIdentity: String
    let reconnectGeneration: UInt64
    let agentID: String
}

@MainActor
protocol ModelProviderDiscoveryClient: AnyObject {
    func loadModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider]
}

@MainActor
final class ModelProviderDiscoveryCache {
    struct SeedToken {
        fileprivate let generation: UInt64
        fileprivate let requestRevision: UInt64
    }

    private struct InFlight {
        let generation: UInt64
        let task: Task<[BighelpLinkModelProvider], Error>
    }

    private let client: any ModelProviderDiscoveryClient
    private var values: [ModelProviderDiscoveryKey: [BighelpLinkModelProvider]] = [:]
    private var inFlight: [ModelProviderDiscoveryKey: InFlight] = [:]
    private var requestRevisions: [ModelProviderDiscoveryKey: UInt64] = [:]
    private var generation: UInt64 = 0

    init(client: any ModelProviderDiscoveryClient) {
        self.client = client
    }

    func providers(
        for key: ModelProviderDiscoveryKey,
        refresh: Bool = false
    ) async throws -> [BighelpLinkModelProvider] {
        if !refresh, let value = values[key] { return value }
        if let existing = inFlight[key], existing.generation == generation {
            let value = try await existing.task.value
            guard existing.generation == generation else { throw CancellationError() }
            return value
        }
        let requestGeneration = generation
        requestRevisions[key, default: 0] &+= 1
        let client = client
        let task = Task { try await client.loadModelProviders(agentID: key.agentID) }
        inFlight[key] = InFlight(generation: requestGeneration, task: task)
        do {
            let value = try await task.value
            guard requestGeneration == generation else { throw CancellationError() }
            values[key] = value
            inFlight[key] = nil
            return value
        } catch {
            if inFlight[key]?.generation == requestGeneration { inFlight[key] = nil }
            throw error
        }
    }

    func cachedProviders(for key: ModelProviderDiscoveryKey) -> [BighelpLinkModelProvider]? {
        values[key]
    }

    /// Captures whether provider discovery for this exact account/connection/
    /// agent partition changes while another request is in flight.
    func seedToken(for key: ModelProviderDiscoveryKey) -> SeedToken {
        SeedToken(
            generation: generation,
            requestRevision: requestRevisions[key, default: 0]
        )
    }

    /// Installs providers returned alongside defaults only when no picker or
    /// refresh request has established newer authority for the same key.
    func seed(
        _ providers: [BighelpLinkModelProvider],
        for key: ModelProviderDiscoveryKey,
        matching token: SeedToken
    ) {
        guard !providers.isEmpty,
              token.generation == generation,
              token.requestRevision == requestRevisions[key, default: 0],
              values[key] == nil,
              inFlight[key] == nil
        else { return }
        values[key] = providers
    }

    func invalidateForAccountBoundary() { invalidateAll() }
    func invalidateForConnectionReplacement() { invalidateAll() }
    func invalidateForReconnect() { invalidateAll() }

    private func invalidateAll() {
        generation &+= 1
        values.removeAll()
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        requestRevisions.removeAll()
    }
}

@MainActor
final class CachedAgentRuntimeDefaultsClient: AgentRuntimeDefaultsConfirmingClient {
    private let base: any AgentRuntimeDefaultsClient
    private let cache: ModelProviderDiscoveryCache
    private let connectionIdentity: String
    private let connectionGeneration: @MainActor () -> UInt64
    private var accountGeneration: UInt64 = 0
    private var reconnectGeneration: UInt64 = 0

    init(
        base: any AgentRuntimeDefaultsClient,
        connectionIdentity: String,
        connectionGeneration: @escaping @MainActor () -> UInt64 = { 0 }
    ) {
        self.base = base
        self.connectionIdentity = connectionIdentity
        self.connectionGeneration = connectionGeneration
        reconnectGeneration = connectionGeneration()
        cache = ModelProviderDiscoveryCache(client: base)
    }

    func loadDefaults(agentID: String) async throws -> AgentRuntimeDefaults {
        try await loadBootstrapCatalog(agentID: agentID).defaults
    }

    func loadCatalog(agentID: String) async throws -> AgentRuntimeDefaultsCatalog {
        synchronizeConnectionGeneration()
        let requestKey = key(agentID: agentID)
        let catalog = try await loadBootstrapCatalog(agentID: agentID)
        synchronizeConnectionGeneration()
        guard requestKey == key(agentID: agentID) else { throw CancellationError() }
        let providers = try await cache.providers(for: requestKey)
        synchronizeConnectionGeneration()
        guard requestKey == key(agentID: agentID) else { throw CancellationError() }
        return AgentRuntimeDefaultsCatalog(defaults: catalog.defaults, providers: providers, support: catalog.support)
    }

    private func loadBootstrapCatalog(agentID: String) async throws -> AgentRuntimeDefaultsCatalog {
        synchronizeConnectionGeneration()
        let requestKey = key(agentID: agentID)
        let seedToken = cache.seedToken(for: requestKey)
        let catalog = try await base.loadCatalog(agentID: agentID)
        synchronizeConnectionGeneration()
        guard requestKey == key(agentID: agentID) else {
            throw CancellationError()
        }
        cache.seed(catalog.providers, for: requestKey, matching: seedToken)
        return catalog
    }

    func loadModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider] {
        synchronizeConnectionGeneration()
        return try await cache.providers(for: key(agentID: agentID))
    }

    func cachedModelProviders(agentID: String) -> [BighelpLinkModelProvider]? {
        synchronizeConnectionGeneration()
        return cache.cachedProviders(for: key(agentID: agentID))
    }

    func refreshModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider] {
        synchronizeConnectionGeneration()
        return try await cache.providers(for: key(agentID: agentID), refresh: true)
    }

    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String) async throws {
        try await base.saveDefaults(defaults, agentID: agentID)
    }

    func saveDefaults(
        _ defaults: AgentRuntimeDefaults, agentID: String,
        confirmation: AgentRuntimeDefaultsSaveConfirmation
    ) async throws {
        guard let confirming = base as? any AgentRuntimeDefaultsConfirmingClient else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        try await confirming.saveDefaults(defaults, agentID: agentID, confirmation: confirmation)
    }

    func replaceConnection(generation: UInt64) {
        guard generation != reconnectGeneration else { return }
        reconnectGeneration = generation
        cache.invalidateForConnectionReplacement()
    }

    func resetForAccountBoundary() {
        accountGeneration &+= 1
        reconnectGeneration = 0
        cache.invalidateForAccountBoundary()
    }

    private func key(agentID: String) -> ModelProviderDiscoveryKey {
        ModelProviderDiscoveryKey(
            accountGeneration: accountGeneration,
            connectionIdentity: connectionIdentity,
            reconnectGeneration: reconnectGeneration,
            agentID: agentID
        )
    }

    private func synchronizeConnectionGeneration() {
        let current = connectionGeneration()
        guard current != reconnectGeneration else { return }
        reconnectGeneration = current
        cache.invalidateForReconnect()
    }
}

struct AgentReasoningOption: Identifiable, Equatable, Sendable {
    let value: String
    let title: String
    let detail: String

    var id: String { value.isEmpty ? "automatic" : value }

    static let all: [AgentReasoningOption] = [
        AgentReasoningOption(
            value: "",
            title: "Automatic",
            detail: "Let Hermes and the selected model choose."
        ),
        AgentReasoningOption(
            value: "none",
            title: "Off",
            detail: "Answer without an explicit reasoning budget."
        ),
        AgentReasoningOption(
            value: "minimal",
            title: "Minimal",
            detail: "Use the smallest available reasoning budget."
        ),
        AgentReasoningOption(
            value: "low",
            title: "Low",
            detail: "Faster responses with lighter reasoning."
        ),
        AgentReasoningOption(
            value: "medium",
            title: "Medium",
            detail: "Balance speed and depth."
        ),
        AgentReasoningOption(
            value: "high",
            title: "High",
            detail: "Spend more time on deliberate reasoning."
        ),
        AgentReasoningOption(
            value: "xhigh",
            title: "X-High",
            detail: "Use a very deep reasoning budget when supported."
        ),
        AgentReasoningOption(
            value: "max",
            title: "Max",
            detail: "Use the strongest provider-supported reasoning level."
        ),
        AgentReasoningOption(
            value: "ultra",
            title: "Ultra",
            detail: "Ask Hermes for its deepest reasoning tier."
        ),
    ]

    static func option(for value: String) -> AgentReasoningOption {
        all.first(where: { $0.value == value })
            ?? AgentReasoningOption(
                value: value,
                title: value.isEmpty ? "Automatic" : value.capitalized,
                detail: "Configured in Hermes."
            )
    }
}

@MainActor
protocol AgentRuntimeDefaultsClient: ModelProviderDiscoveryClient {
    func loadCatalog(agentID: String) async throws -> AgentRuntimeDefaultsCatalog
    func loadDefaults(agentID: String) async throws -> AgentRuntimeDefaults
    func cachedModelProviders(agentID: String) -> [BighelpLinkModelProvider]?
    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String) async throws
}

@MainActor
extension AgentRuntimeDefaultsClient {
    func cachedModelProviders(agentID: String) -> [BighelpLinkModelProvider]? { nil }

    func loadCatalog(agentID: String) async throws -> AgentRuntimeDefaultsCatalog {
        let defaults = try await loadDefaults(agentID: agentID)
        let providers = try await loadModelProviders(agentID: agentID)
        return AgentRuntimeDefaultsCatalog(
            defaults: defaults,
            providers: providers
        )
    }

    func refreshModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider] {
        try await loadModelProviders(agentID: agentID)
    }
}

@MainActor
final class FixtureAgentRuntimeDefaultsClient: AgentRuntimeDefaultsClient {
    private var values: [String: AgentRuntimeDefaults] = [:]
    private let providers: [BighelpLinkModelProvider]

    init() {
        providers = [
            BighelpLinkModelProvider(
                id: "nous",
                name: "Nous Research",
                isCurrent: true,
                isCustom: false,
                models: ["Hermes-4-405B", "Hermes-4-70B"]
            ),
            BighelpLinkModelProvider(
                id: "openai",
                name: "OpenAI",
                isCurrent: false,
                isCustom: false,
                models: ["gpt-5.6", "gpt-5.6-mini"],
                fastModeModels: ["gpt-5.6", "gpt-5.6-mini"]
            ),
            BighelpLinkModelProvider(
                id: "anthropic",
                name: "Anthropic",
                isCurrent: false,
                isCustom: false,
                models: ["claude-opus-4.1", "claude-sonnet-4.1"]
            ),
        ]
    }

    func loadDefaults(agentID: String) async throws -> AgentRuntimeDefaults {
        var defaults = values[agentID] ?? AgentRuntimeDefaults(
            mainChats: AgentRuntimeSelection(
                providerID: "nous",
                modelID: "Hermes-4-405B",
                reasoningEffort: ""
            ),
            subagents: .automatic,
            scheduledTasks: .automatic
        )
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-use-demo-fixtures") {
            let current = DemoModels.transport.main(for: agentID)
            defaults.mainChats.providerID = current.provider
            defaults.mainChats.modelID = current.model
        }
        #endif
        return defaults
    }

    func loadModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider] {
        providers
    }

    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String) async throws {
        values[agentID] = defaults
    }
}
