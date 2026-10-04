import Foundation
import Testing
@testable import Bighelp

/// Default model › Reasoning: every agent by default, or just the one picked.
@MainActor
struct ModelReasoningDefaultsTests {
    @Test func everyAgentByDefaultOrJustThePickedOne() async throws {
        let client = FixtureAgentRuntimeDefaultsClient()
        let reasoning = ModelReasoningDefaults(client: client)
        await reasoning.load(agentID: "finance")
        #expect(reasoning.current == "", "Automatic until changed")

        #expect(await reasoning.set("high", agentID: "finance", every: ["finance", "travel", "home"]) == 3)
        for agent in ["finance", "travel", "home"] {
            #expect(try await client.loadDefaults(agentID: agent).mainChats.reasoningEffort == "high")
        }
        #expect(reasoning.current == "high")
        #expect(reasoning.message == "Reasoning is High for every agent's new chats.")

        reasoning.appliesToEveryAgent = false
        #expect(await reasoning.set("low", agentID: "travel", every: ["finance", "travel", "home"]) == 1)
        #expect(try await client.loadDefaults(agentID: "travel").mainChats.reasoningEffort == "low")
        #expect(try await client.loadDefaults(agentID: "finance").mainChats.reasoningEffort == "high")
        #expect(try await client.loadDefaults(agentID: "travel").mainChats.modelID == "Hermes-4-405B", "The model stays")
    }
}
