import Testing
@testable import Bighelp

@MainActor
struct ChatDestinationAgentResolverTests {
    @Test func opaqueSessionIDUsesItsCanonicalTravelAgentIdentity() {
        let travel = AgentProfile(
            id: "travel",
            name: "Mina Shah",
            role: "Travel agent",
            summary: "Trips and itineraries.",
            instructions: "Help with travel planning.",
            avatarFileName: nil,
            isDefault: false
        )
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [travel]),
            profiles: [travel]
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [
                SessionRecord(
                    id: "session-opaque-42",
                    kind: .direct,
                    agentIDs: ["travel"],
                    title: "Trip planning"
                )
            ]
        )

        let identity = ChatDestinationAgentResolver(
            catalog: catalog,
            agents: agents
        ).resolve(sessionID: "session-opaque-42")

        #expect(identity == ChatDestinationAgentIdentity(
            name: "Mina Shah",
            role: "Travel agent"
        ))
    }

    @Test func restoredTranscriptIdentityIsUsedWhileTheAgentDirectoryLoads() {
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [
                SessionRecord(
                    id: "session-restored-42",
                    kind: .direct,
                    agentIDs: ["juno"],
                    title: "Weather"
                ),
            ]
        )
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: []),
            profiles: []
        )

        let identity = ChatDestinationAgentResolver(
            catalog: catalog,
            agents: agents
        ).resolve(sessionID: "session-restored-42", fallbackName: "  Juno  ")

        #expect(identity == ChatDestinationAgentIdentity(
            name: "Juno",
            role: "Hermes bot"
        ))
    }

    @Test func restoredSessionKeepsCanonicalAgentNameWhileDirectoryIsDelayedThenUsesResolvedProfile() async {
        let restoredItem = TimelineItem(
            id: "restored-juno-answer",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Juno")),
            content: .message("The restored answer."),
            metadata: .init(delivery: "Saved")
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [
                SessionRecord(
                    id: "session-delayed-agent-directory",
                    kind: .direct,
                    agentIDs: ["default"],
                    title: "Restored weather",
                    items: [restoredItem]
                ),
            ]
        )
        let canonical = AgentProfile(
            id: "default",
            name: "Juno",
            role: "Primary household agent",
            summary: "Keeps the household moving.",
            instructions: "Be useful.",
            avatarFileName: nil,
            isDefault: true
        )
        let client = DelayedHeaderAgentDirectoryClient(profile: canonical)
        let agents = AgentDirectoryStore(client: client, profiles: [])
        let resolver = ChatDestinationAgentResolver(catalog: catalog, agents: agents)

        let loading = Task { try? await agents.load() }
        await client.waitUntilListStarts()

        #expect(resolver.resolve(sessionID: "session-delayed-agent-directory") == ChatDestinationAgentIdentity(
            name: "Juno",
            role: "Hermes bot"
        ))

        client.resumeList()
        await loading.value

        #expect(resolver.resolve(sessionID: "session-delayed-agent-directory") == ChatDestinationAgentIdentity(
            name: "Juno",
            role: "Primary household agent"
        ))
    }
}

@MainActor
private final class DelayedHeaderAgentDirectoryClient: AgentDirectoryClient {
    private let profile: AgentProfile
    private var continuation: CheckedContinuation<[AgentProfile], Error>?
    private var didStart = false

    init(profile: AgentProfile) {
        self.profile = profile
    }

    func list() async throws -> [AgentProfile] {
        didStart = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        profile
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        profile
    }

    func waitUntilListStarts() async {
        while !didStart { await Task.yield() }
    }

    func resumeList() {
        continuation?.resume(returning: [profile])
        continuation = nil
    }
}
