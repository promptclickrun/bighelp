import Foundation
import Observation

/// What a new recipe needs from its template: the projects (with their folders), the
/// command each runs (the tests, say), where runs work, and the agent that codes.
struct DevFactoryRecipeSetup: Equatable {
    var name: String
    var projects: [WorkflowCodeProject]
    /// By project key; a project with no command of its own runs `sharedCommand`.
    var commands: [String: String] = [:]
    var sharedCommand = "make test"
    var placement = "worktree"
    var base: String?
    var agentID: String?

    /// The command step's `run`: one string when every project runs the same.
    var run: (map: [String: String], isShared: Bool) {
        let own = commands.filter { key, value in
            projects.contains { $0.key == key } && !value.trimmingCharacters(in: .whitespaces).isEmpty
                && value != sharedCommand
        }
        if own.isEmpty { return (["*": sharedCommand], true) }
        return (own.merging(["*": sharedCommand]) { mine, _ in mine }, false)
    }
}

/// Dev Factory (☰ › Dev Factory in Bighelp IDE) for one computer: its coding recipes,
/// their runs grouped by start (one run per project), and the templates new recipes
/// come from. It's Workflows underneath (`native-workflows-code-v1`): the same client,
/// runs and sign-offs.
@MainActor
@Observable
final class DevFactoryStore {
    let scopeID: String
    private(set) var recipes: [WorkflowSummary] = []
    private(set) var groups: [WorkflowCodeGroup] = []
    private(set) var templates: [WorkflowTemplate] = []
    /// Nil until the computer answers; false when its plugin predates Dev Factory.
    private(set) var isAvailable: Bool?
    private(set) var isLoading = false
    var errorMessage: String?

    @ObservationIgnored let client: any WorkflowsClient

    init(scopeID: String, client: any WorkflowsClient) {
        self.scopeID = scopeID
        self.client = client
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let features = await client.features()
        isAvailable = features.contains(.code)
        guard features.contains(.code) else { return }
        do {
            let list = try await client.list(includeArchived: false)
            recipes = list.workflows.filter(\.isCodeRecipe)
            let recent = try await client.runs(workflowID: nil, filter: .all, before: nil, limit: 50).runs
            groups = WorkflowCodeGroup.groups(list.waiting + list.active + recent)
            templates = try await client.codeTemplates()
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = WorkflowsStore.reason(error)
        }
    }

    func group(id: String) -> WorkflowCodeGroup? { groups.first { $0.id == id } }

    /// Starts `recipe` on `projects` (every project when nil). Returns the new group's ID.
    func start(_ recipe: WorkflowSummary, inputs: WorkflowJSON, projects: [String]?) async -> String? {
        guard let revision = recipe.revision else {
            errorMessage = "Publish this recipe before running it."
            return nil
        }
        do {
            let started = try await client.startCodeRun(workflowID: recipe.id, revision: revision, inputs: inputs,
                                                        clientRunToken: UUID().uuidString.lowercased(),
                                                        projects: projects)
            await load()
            errorMessage = nil
            return started.groupID.isEmpty ? started.first.id : started.groupID
        } catch {
            errorMessage = WorkflowsStore.reason(error)
            return nil
        }
    }

    /// Makes a recipe from `template` with `setup`, binds its agents and publishes it.
    /// Returns the recipe's workflow ID.
    func createRecipe(from template: WorkflowTemplate, setup: DevFactoryRecipeSetup) async -> String? {
        do {
            let id = try await client.useTemplate(id: template.id)
            let detail = try await client.workflow(id: id, revision: .draft)
            var definition = Self.apply(setup, to: detail.definition)
            if definition.name.isEmpty { definition.name = template.name }
            let saved = try await client.saveDraft(workflowID: id, baseDraftVersion: detail.draftVersion,
                                                   definition: definition)
            if let agentID = setup.agentID {
                for role in definition.roles {
                    _ = try await client.bind(workflowID: saved.workflowID, role: role.key, agentID: agentID)
                }
            }
            _ = try await client.publish(workflowID: saved.workflowID, draftVersion: saved.draftVersion)
            await load()
            errorMessage = nil
            return saved.workflowID
        } catch {
            errorMessage = WorkflowsStore.reason(error)
            await load()
            return nil
        }
    }

    /// The template's draft with the setup's name, projects, folder rule and commands.
    static func apply(_ setup: DevFactoryRecipeSetup, to template: WorkflowDefinition) -> WorkflowDefinition {
        var definition = template
        let name = setup.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { definition.name = String(name.prefix(200)) }
        definition.schemaVersion = max(definition.schemaVersion, 3)
        definition.codeProjects = setup.projects
        definition.codeWorkspace = (setup.placement, setup.base)
        let run = setup.run
        for index in definition.stages.indices where definition.stages[index].kind == .command {
            definition.stages[index].run = run.map
            definition.stages[index].runIsShared = run.isShared
        }
        return definition
    }
}
