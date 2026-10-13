import Foundation
import Testing
@testable import Bighelp

/// Dev Factory against the plugin's own contract vectors (fixtures/contracts/workflows-v1/*-code.json,
/// copied byte for byte), and its store and demo.
@MainActor
struct DevFactoryContractTests {
    private func vector(_ name: String) throws -> WorkflowJSON { try WorkflowContractVectorTests.vector(name) }
    private func response(_ name: String) throws -> WorkflowJSON { try WorkflowContractVectorTests.response(name) }

    /// A recipe saved by the editor gives every v3 field back: projects, workspace, the
    /// command with its fix, the sign-off on changes and the pull request's title.
    @Test func aRecipeRoundTripsThroughTheEditor() throws {
        let sent = try #require(try WorkflowContractVectorTests.request("draft-save-code.json")["definition"]?.object)
        let definition = WorkflowDefinition(json: sent)

        #expect(definition.isCodeRecipe)
        #expect(definition.codeProjects.map(\.key) == ["app", "web"])
        #expect(definition.codeWorkspace.placement == "worktree")
        let tests = try #require(definition.stage("tests"))
        #expect(tests.kind == .command)
        #expect(tests.run == ["*": "sh check.sh"])
        #expect(tests.fix?.role == "coder" && tests.fix?.maxTries == 1)
        #expect(definition.stage("review")?.signsChanges == true)
        #expect(definition.stage("open_pr")?.kind == .pullRequest)
        #expect(definition.stage("open_pr")?.titleFrom == "fix.title")
        let saved = definition.json
        #expect(saved["projects"] == sent["projects"] && saved["workspace"] == sent["workspace"])
        let sentStages = WorkflowDecode.objects(sent["stages"], max: 20)
        let savedStages = WorkflowDecode.objects(saved["stages"], max: 20)
        for key in ["run", "fix", "changes", "titleFrom", "minutes", "draft"] {
            #expect(savedStages.map { $0[key] } == sentStages.map { $0[key] }, "\(key)")
        }
    }

    @Test func aRunWaitingOnTheChangesCarriesWhatToApprove() throws {
        let detail = try WorkflowRunDetail(json: try response("runs-get-code-review.json"))
        let code = try #require(detail.summary.code)

        #expect(code.project == WorkflowCodeProject(key: "app", label: "App", path: "/Users/you/code/app"))
        #expect(code.workspace?.isWorktree == true)
        #expect(code.workspace?.branch == "factory/fix-the-check-164e6f")
        #expect(detail.summary.waiting?.kind == "signoff")
        #expect(detail.signoff == nil, "No file to approve, only changes.")
        let changes = try #require(detail.changesSignoff)
        #expect(changes.stageKey == "review" && changes.files == 1 && changes.additions == 1 && changes.deletions == 0)
        #expect(changes.sha256.count == 64)
        #expect(detail.stages.map(\.kind) == [.agent, .command, .signoff, .pullRequest])
    }

    @Test func aRunWaitingOnFailingTestsSaysWhyAndCanRetry() throws {
        let detail = try WorkflowRunDetail(json: try response("runs-get-code-command.json"))

        #expect(detail.summary.waiting?.kind == "command")
        #expect(detail.summary.code?.reason == "Run the tests: still failing after 1 try.")
        #expect(detail.allowedActions.contains("retry"))
        #expect(detail.changesSignoff == nil)
    }

    @Test func aFinishedRunHasItsPullRequest() throws {
        let detail = try WorkflowRunDetail(json: try response("runs-get-code-done.json"))

        #expect(detail.summary.state == .succeeded)
        #expect(detail.summary.code?.pullRequest?.number == 42)
        #expect(detail.summary.code?.groupID == "grp_ca29965cc4f52207")
    }

    @Test func aStartReturnsOneRunPerProjectInAGroup() throws {
        let start = try WorkflowCodeStart(json: try response("runs-start-code.json"))

        #expect(start.groupID == "grp_ca29965cc4f52207")
        #expect(start.runs.map(\.project) == ["app"])
        #expect(start.runs.first?.runID == start.first.id)
    }

    /// The start sends `projects` only when it's a subset, and code templates ask with `includeCode`.
    @Test func codeRequestsCarryTheirNewKeys() async throws {
        let performer = WorkflowPerformer()
        performer.answers[.workflowsRunsStart] = try response("runs-start-code.json")
        performer.answers[.workflowsTemplatesList] = try response("templates-list-code.json")
        let client = DirectHermesWorkflowsClient(currentWorkspace: { performer })

        _ = try await client.startCodeRun(workflowID: "wf", revision: 1, inputs: [:], clientRunToken: "t", projects: ["app"])
        _ = try await client.startCodeRun(workflowID: "wf", revision: 1, inputs: [:], clientRunToken: "u", projects: nil)
        let templates = try await client.codeTemplates()

        let starts = performer.payloads(.workflowsRunsStart)
        #expect(starts.first?["projects"] == .array([.string("app")]))
        #expect(starts.last?["projects"] == nil)
        #expect(performer.payloads(.workflowsTemplatesList).last?["includeCode"] == .boolean(true))
        // The plain list answers the same vector here, so nothing is only for code.
        #expect(templates.isEmpty)
    }

    @Test func theFeatureListNamesDevFactory() {
        #expect(WorkflowFeatures(features: ["native-workflows-code-v1"]).contains(.code))
        #expect(!WorkflowFeatures(features: ["native-workflows-v1"]).contains(.code))
    }
}

@MainActor
struct DevFactoryStoreTests {
    /// A new recipe gets its projects, folder rule and commands: one command for all, or one each.
    @Test func aSetupFillsTheTemplate() throws {
        let projects = [WorkflowCodeProject(key: "app", label: "App", path: "/repo/app"),
                        WorkflowCodeProject(key: "web", label: "Web", path: "/repo/web")]
        var setup = DevFactoryRecipeSetup(name: "Fix and ship", projects: projects, sharedCommand: "swift test",
                                          placement: "local", base: "develop")
        let template = DemoWorkflowsClient.codeRecipe(id: "fix-test-pr")

        let shared = DevFactoryStore.apply(setup, to: template)
        #expect(shared.name == "Fix and ship")
        #expect(shared.codeProjects == projects)
        #expect(shared.codeWorkspace.placement == "local" && shared.codeWorkspace.base == "develop")
        #expect(shared.stage("tests")?.run == ["*": "swift test"])
        #expect(shared.stage("tests")?.json["run"] == .string("swift test"))

        setup.commands = ["web": "npm test", "app": "  "]
        let mixed = DevFactoryStore.apply(setup, to: template)
        #expect(mixed.stage("tests")?.run == ["*": "swift test", "web": "npm test"])
        #expect(mixed.stage("tests")?.json["run"]?.object?["web"] == .string("npm test"))
    }

    @Test func stepTitlesShowTheRunsInputs() {
        let inputs: WorkflowJSON = ["package": .string("markdown-kit"), "version": .string("3.0")]
        #expect(DevFactoryWords.filled("Update {package} to {inputs.version}", inputs: inputs)
            == "Update markdown-kit to 3.0")
        #expect(DevFactoryWords.filled("Fix {task}", inputs: inputs) == "Fix {task}")
    }

    @Test func projectKeysAreSafeAndNeverRepeat() {
        #expect(WorkflowCodeProject.key(for: "bighelp-plugin", taken: []) == "bighelp-plugin")
        #expect(WorkflowCodeProject.key(for: "My App!", taken: []) == "my-app")
        #expect(WorkflowCodeProject.key(for: "My App", taken: ["my-app"]) == "my-app-2")
        #expect(WorkflowCodeProject.key(for: "✨", taken: []) == "project")
    }

    @Test func runsGroupByTheirStartNewestFirst() {
        func run(_ id: String, _ number: Int, group: String, at offset: TimeInterval) -> WorkflowRunSummary {
            var summary = WorkflowRunSummary(id: id, number: number, workflowID: "wf", workflowName: "Bump", revision: 1,
                                             state: .running, stageKey: nil, stageTitle: nil, stageState: nil,
                                             stagesDone: 0, stageCount: 4, startedAt: Date(timeIntervalSince1970: offset),
                                             updatedAt: nil, version: 1)
            summary.code = WorkflowCodeRun(groupID: group, project: .init(key: id, label: id, path: nil))
            return summary
        }
        let plain = WorkflowRunSummary(id: "p", number: 1, workflowID: "wf2", workflowName: "Other", revision: 1,
                                       state: .running, stageKey: nil, stageTitle: nil, stageState: nil, stagesDone: 0,
                                       stageCount: 1, startedAt: nil, updatedAt: nil, version: 1)

        let groups = WorkflowCodeGroup.groups([run("b", 6, group: "g1", at: 10), plain, run("c", 8, group: "g2", at: 20),
                                               run("a", 5, group: "g1", at: 10), run("a", 5, group: "g1", at: 10)])

        #expect(groups.map(\.id) == ["g2", "g1"])
        #expect(groups.last?.runs.map(\.id) == ["a", "b"], "Project order, each run once.")
    }

    /// The demo runs a recipe like the plugin: one run per project, waiting on the changes,
    /// then the pull request after you approve.
    @Test func aRecipeRunsToItsPullRequest() async throws {
        let client = DemoWorkflowsClient(delays: false)
        let store = DevFactoryStore(scopeID: "demo", client: client)
        await store.load()
        #expect(store.isAvailable == true)
        #expect(store.templates.map(\.id) == ["fix-test-pr", "bump-dependency", "test-sweep"])
        let recipe = try #require(store.recipes.first)
        #expect(recipe.projects.map(\.key) == ["bighelp", "bighelp-plugin", "site"])
        #expect(store.groups.first?.needsYou == 2, "The sample start has two runs waiting for you.")

        let group = try #require(await store.start(recipe, inputs: ["package": .string("x"), "version": .string("1")],
                                                   projects: ["bighelp", "site"]))
        let runs = try #require(store.group(id: group)?.runs)
        #expect(runs.compactMap { $0.code?.project.key } == ["bighelp", "site"])

        var detail = try await client.run(id: runs[0].id)
        for _ in 0..<12 where detail.changesSignoff == nil { detail = try await client.run(id: runs[0].id) }
        let changes = try #require(detail.changesSignoff)
        _ = try await client.signoff(runID: runs[0].id, stageKey: changes.stageKey, decision: .approve,
                                     artifactSHA256: changes.sha256, notes: "")
        for _ in 0..<12 where detail.summary.state != .succeeded { detail = try await client.run(id: runs[0].id) }
        #expect(detail.summary.state == .succeeded)
        #expect(detail.summary.code?.pullRequest != nil)
    }

    /// A template becomes a published recipe with the projects and agent you picked.
    @Test func aTemplateBecomesAPublishedRecipe() async throws {
        let client = DemoWorkflowsClient(delays: false)
        let store = DevFactoryStore(scopeID: "demo", client: client)
        await store.load()
        let template = try #require(store.templates.first { $0.id == "fix-test-pr" })
        let setup = DevFactoryRecipeSetup(name: "Fix in bighelp",
                                          projects: [.init(key: "bighelp", label: "bighelp", path: "/Users/demo/code/bighelp")],
                                          agentID: "default")

        let id = await store.createRecipe(from: template, setup: setup)

        #expect(store.errorMessage == nil)
        let recipe = try #require(store.recipes.first { $0.id == id })
        #expect(recipe.revision != nil && recipe.name == "Fix in bighelp")
        #expect(recipe.projects.map(\.key) == ["bighelp"])
    }

    /// Recipes and their runs live in Dev Factory, not on the Workflows page.
    @Test func workflowsLeavesRecipesToDevFactory() async {
        let store = WorkflowsStore(client: DemoWorkflowsClient(delays: false), support: .available(canEdit: true))
        await store.load()
        #expect(store.list?.workflows.contains(where: \.isCodeRecipe) == false)
        #expect(store.list?.waiting.contains { $0.code != nil } == false)
    }
}
