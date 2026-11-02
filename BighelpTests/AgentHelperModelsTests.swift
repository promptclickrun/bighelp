import Foundation
import Testing
@testable import Bighelp

/// Default Model › Advanced: subagents, scheduled tasks and each helper task can go back to the
/// chat model on their own.
@MainActor
struct AgentHelperModelsTests {
    @Test func aHelperTaskGoesBackToTheChatModelAlone() async throws {
        let transport = DemoModelsTransport()
        let owner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://hermes.example",
                                                          providerID: "basic", userID: "person"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
        let helpers = AgentHelperModelsModel(agentID: "finance", client: DirectHermesModelAdministrationClient(
            rpc: transport, http: transport, owner: owner, currentOwner: { owner }))
        await helpers.load()
        #expect(helpers.tasks.first { $0.task == "compression" }?.usesChatModel == false)
        #expect(helpers.ownModelCount == 1)

        await helpers.choose("vision", providerID: "openai", modelID: "gpt-5.6-mini")
        await helpers.useChatModel("compression")

        #expect(helpers.errorMessage == nil)
        #expect(helpers.tasks.first { $0.task == "compression" }?.usesChatModel == true)
        #expect(helpers.tasks.first { $0.task == "vision" }?.modelID == "gpt-5.6-mini")
        #expect(helpers.ownModelCount == 1)
    }

    @Test func helperTasksHavePlainNamesAndKeepTheHostsForNewOnes() {
        #expect(DirectHermesAuxiliaryModelAssignment.title(for: "title_generation") == "Naming chats")
        #expect(DirectHermesAuxiliaryModelAssignment.title(for: "plugin_task") == "Plugin task")
    }

    @Test func subagentsFollowTheChatModelAgainButTheChatModelStays() async throws {
        let saved = AgentRuntimeDefaults(
            mainChats: AgentRuntimeSelection(providerID: "nous", modelID: "Hermes-4-405B", reasoningEffort: "high"),
            subagents: AgentRuntimeSelection(providerID: "openai", modelID: "gpt-5.6-mini", reasoningEffort: ""),
            scheduledTasks: .automatic
        )
        let client = AgentRuntimeDefaultsClientFixture(defaults: saved)
        let model = AgentRuntimeDefaultsEditorModel(agentID: "finance", client: client)
        await model.load()

        model.useChatModel(for: .subagents)
        model.useChatModel(for: .mainChats)
        try await model.saveIfNeeded()

        #expect(client.saved.last?.subagents.modelID == "")
        #expect(client.saved.last?.subagents.providerID == "")
        #expect(client.saved.last?.mainChats == saved.mainChats)
    }
}
