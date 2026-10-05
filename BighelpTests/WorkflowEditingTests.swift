import CoreGraphics
import Foundation
import Testing
@testable import Bighelp

// Workflows v2 (plugin `native-workflows-edit-v1`): connections, places on the
// canvas, create from scratch, your templates, pins and computers that can't run them.

@MainActor
enum Flow {
    /// A definition from stage shapes: ("key", kind, extra fields).
    static func definition(_ stages: [WorkflowJSON], layout: WorkflowJSON? = nil, version: Int = 2) -> WorkflowDefinition {
        var json: WorkflowJSON = [
            "schemaVersion": .integer(version), "name": .string("Made up"), "description": .string(""),
            "roles": .array([.object(["key": .string("writer"), "label": .string("Writer")])]),
            "inputs": .array([]), "limits": .object(["stageMinutes": .integer(20), "maxRevisions": .integer(2)]),
            "stages": .array(stages.map(BighelpJSONValue.object)),
        ]
        if let layout { json["layout"] = .object(layout) }
        return WorkflowDefinition(json: json)
    }

    static func agent(_ key: String, next: BighelpJSONValue? = nil, uses: [String] = []) -> WorkflowJSON {
        var stage: WorkflowJSON = [
            "key": .string(key), "kind": .string("agent"), "title": .string(key.capitalized), "role": .string("writer"),
            "instructions": .string("Do it."), "tools": .array([]), "uses": .array(uses.map(BighelpJSONValue.string)),
            "outputs": .array([.object(["name": .string("result"), "type": .string("markdown_file")])]),
        ]
        if let next { stage["next"] = next }
        return stage
    }

    static func decision(_ key: String, pass: String = "next", goTo: String) -> WorkflowJSON {
        ["key": .string(key), "kind": .string("decision"), "title": .string(key.capitalized),
         "on": .string("review.decision"), "pass": .string(pass),
         "changes": .object(["goTo": .string(goTo), "maxRevisions": .integer(2)])]
    }

    static func signoff(_ key: String = "signoff") -> WorkflowJSON {
        ["key": .string(key), "kind": .string("signoff"), "title": .string("Sign-off"), "file": .string("draft.result")]
    }

    /// Research → draft → review → decide (changes back to draft) → sign-off.
    static var loop: WorkflowDefinition {
        definition([agent("research"), agent("draft"), agent("review"), decision("decide", goTo: "draft"), signoff()])
    }

    static func codes(_ definition: WorkflowDefinition) -> Set<String> {
        Set(definition.graph.issues(definition).map(\.code))
    }
}

// MARK: - Shapes

@MainActor
struct WorkflowV2ModelTests {
    @Test func nextAndLayoutDecodeAndGoBackUnchanged() throws {
        let json: WorkflowJSON = [
            "schemaVersion": .integer(2), "name": .string("Made up"), "description": .string(""),
            "roles": .array([]), "inputs": .array([]),
            "limits": .object(["stageMinutes": .integer(20), "maxRevisions": .integer(2)]),
            "stages": .array([
                .object(Flow.agent("a", next: .string("c"))), .object(Flow.agent("b", next: .null)),
                .object(Flow.agent("c")),
            ]),
            "layout": .object([
                "inputs": .object(["x": .integer(40), "y": .integer(60)]),
                "stages": .object(["a": .object(["x": .integer(340), "y": .number(60.5)]),
                                   "c": .object(["x": .integer(640), "y": .integer(60)])]),
            ]),
        ]
        let definition = WorkflowDefinition(json: json)
        #expect(definition.stages.map(\.next) == [.stage("c"), .end, .following])
        #expect(definition.layout?.inputs == CGPoint(x: 40, y: 60))
        #expect(definition.layout?.stages["a"] == CGPoint(x: 340, y: 60.5))
        #expect(definition.json == json, "Saving sends back next and layout exactly as they came")
        // A v1 definition has neither, and doesn't gain them.
        let v1 = DemoWorkflowsClient.researchDraftReview.json
        #expect(v1["layout"] == nil && WorkflowDefinition(json: v1).json == v1)
    }

    @Test func layoutOutsideTheHostsLimitsIsIgnored() {
        let layout = WorkflowLayout(json: .object([
            "stages": .object(["far": .object(["x": .integer(200_000), "y": .integer(0)]),
                               "bad": .object(["x": .string("1"), "y": .integer(0)]),
                               "ok": .object(["x": .integer(-100_000), "y": .integer(100_000)])]),
        ]))
        #expect(layout?.stages.keys.sorted() == ["ok"])
        #expect(WorkflowLayout.clamped(CGPoint(x: 1e9, y: -1e9)) == CGPoint(x: 100_000, y: -100_000))
    }

    @Test func listItemsCarryPinsAndPinnedComeFirst() {
        let list = WorkflowsList(json: ["workflows": .array([
            .object(["id": .string("one"), "name": .string("One")]),
            .object(["id": .string("two"), "name": .string("Two"), "pinned": .boolean(true)]),
            .object(["id": .string("three"), "name": .string("Three"), "archived": .boolean(true)]),
        ])])
        #expect(list.workflows.map(\.id) == ["two", "one", "three"])
        #expect(list.workflows[0].pinned && list.workflows[2].archived)
    }

    @Test func templatesSayWhoseTheyAre() throws {
        let yours = try #require(WorkflowTemplate(json: ["id": .string("tpl_1"), "name": .string("Mine"),
                                                          "source": .string("yours"), "stageCount": .integer(3),
                                                          "updatedAt": .string("2026-10-04T10:00:00Z")]))
        #expect(yours.source == .yours && yours.updatedAt != nil)
        let builtin = try #require(WorkflowTemplate(json: ["id": .string("research-draft-review")]))
        #expect(builtin.source == .builtin, "Hosts that don't say are built in")
    }

    /// The fallback runner can't count tokens: null stays "nothing", never 0.
    @Test func nullTokensStayUnknown() throws {
        var run = try #require(Samples.runDetail["run"]?.object)
        run["tokens"] = .null
        var stages = try #require(run["stages"]?.array)
        var first = try #require(stages[0].object)
        first["attempts"] = .array([.object(["id": .integer(1), "state": .string("accepted"), "tokens": .null])])
        stages[0] = .object(first)
        run["stages"] = .array(stages)
        let detail = try WorkflowRunDetail(json: ["run": .object(run)])
        #expect(detail.tokens == nil)
        #expect(detail.stages[0].attempts[0].tokens == nil)
        #expect(try WorkflowRunDetail(json: Samples.runDetail).tokens?.total == 300)
    }

    @Test func createFromScratchIsTheContractsMinimalDefinition() {
        let json = WorkflowDefinition.empty(name: "Weekly notes").json
        #expect(json == [
            "schemaVersion": .integer(2), "name": .string("Weekly notes"), "description": .string(""),
            "roles": .array([]), "inputs": .array([]),
            "limits": .object(["stageMinutes": .integer(20), "maxRevisions": .integer(2)]), "stages": .array([]),
        ])
    }
}

// MARK: - What the plugin says about Workflows

@MainActor
struct WorkflowsSupportTests {
    @Test func featuresAndUnavailableReasonsDecide() {
        #expect(WorkflowsSupport(context: ["features": .array([.string("native-workflows-v1")])])
                == .available(canEdit: false))
        #expect(WorkflowsSupport(context: ["features": .array([.string("native-workflows-v1"),
                                                               .string("native-workflows-edit-v1")])])
                == .available(canEdit: true))
        for code in ["not_posix", "profile_helpers_missing", "chat_runner_missing", "store_unavailable"] {
            let map: WorkflowJSON = ["features": .array([]), "unavailable": .object(["native-workflows-v1": .string(code)])]
            #expect(WorkflowsSupport(context: map) == .unavailable(code: code))
            let list: WorkflowJSON = ["unavailable": .array([.object(["feature": .string("native-workflows-v1"),
                                                                      "code": .string(code)])])]
            #expect(WorkflowsSupport(context: list) == .unavailable(code: code))
        }
        let other: WorkflowJSON = ["unavailable": .object(["native-quiet-hours-v1": .string("not_posix")])]
        #expect(WorkflowsSupport(context: other) == .missing, "Another feature's reason doesn't show Workflows")
        #expect(WorkflowsSupport(context: [:]) == .missing)
        #expect(!WorkflowsSupport.missing.showsMenuRow && WorkflowsSupport.unavailable(code: "not_posix").showsMenuRow)
    }

    /// The screen explains in plain words; the code itself never shows.
    @Test func reasonsArePlainWords() {
        for code in WorkflowsSupport.unavailableCodes.union(["something_new"]) {
            let words = WorkflowWords.unavailable(code)
            #expect(!words.reason.contains("_") && !words.action.contains("_"), "\(code)")
            #expect(!words.reason.isEmpty && !words.action.isEmpty)
        }
    }

    @Test func supportIsRememberedPerComputerAndOlderAnswersStillShowTheRow() async throws {
        let defaults = try #require(UserDefaults(suiteName: "workflows-support-\(UUID().uuidString)"))
        defaults.set(true, forKey: "bighelp.workflows.available.old-host")
        let availability = WorkflowsAvailability(defaults: defaults, retryDelays: [])
        availability.use(host: "old-host")
        #expect(availability.support == .available(canEdit: false) && availability.isAvailable == true)
        availability.use(host: "new-host")
        await availability.check { .unavailable(code: "not_posix") }
        #expect(availability.isAvailable == true, "A computer that says why it can't run them keeps the row")
        availability.use(host: "old-host")
        availability.use(host: "new-host")
        #expect(availability.support == .unavailable(code: "not_posix"))
        for value in [WorkflowsSupport.available(canEdit: true), .available(canEdit: false), .missing,
                      .unavailable(code: "store_unavailable")] {
            #expect(WorkflowsSupport(stored: value.stored) == value)
        }
    }

    @Test func aComputerThatCantRunThemExplainsInsteadOfLoading() async {
        let store = WorkflowsStore(client: DemoWorkflowsClient(delays: false, support: .unavailable(code: "not_posix")))
        await store.load()
        #expect(store.state == .cantRunHere("not_posix"))
        #expect(store.list == nil)
    }
}

// MARK: - Connections

@MainActor
struct WorkflowFlowGraphTests {
    @Test func v1DefinitionsGoToTheFollowingStage() {
        let graph = Flow.loop.graph
        #expect(graph.start == "research")
        #expect(graph.exits["research"]?.primary == "draft" && graph.exits["review"]?.primary == "decide")
        #expect(graph.exits["decide"] == .init(primary: "signoff", changes: "draft"))
        #expect(graph.exits["signoff"]?.primary == nil)
        #expect(Flow.codes(Flow.loop).isEmpty)
    }

    @Test func nextJumpsAndEnds() {
        let definition = Flow.definition([Flow.agent("a", next: .string("c")), Flow.agent("b", next: .null),
                                          Flow.agent("c")])
        let graph = definition.graph
        #expect(graph.exits["a"]?.primary == "c" && graph.exits["b"]?.primary == nil)
        #expect(Flow.codes(definition) == ["unreachable_stage"], "Nothing leads to b")
        #expect(definition.graph.issues(definition).first?.stageKey == "b")
    }

    /// Rewiring changes `next`, and only where it isn't simply the following stage.
    @Test func rewiringWritesTheFewestNexts() {
        var definition = Flow.definition([Flow.agent("a"), Flow.agent("b"), Flow.agent("c")])
        definition.connect("a", .next, to: "c")
        #expect(definition.stages.map(\.key) == ["a", "c", "b"], "Reading order follows the flow")
        #expect(definition.stages.map(\.next) == [.following, .end, .stage("c")])
        #expect(Flow.codes(definition) == ["unreachable_stage"])
        #expect(definition.schemaVersion == 2)
        definition.connect("a", .next, to: "b")
        #expect(definition.stages.map(\.key) == ["a", "b", "c"])
        #expect(definition.stages.allSatisfy { $0.next == .following })
        #expect(Flow.codes(definition).isEmpty)
        #expect(definition.json["stages"]?.array?.allSatisfy { $0.object?["next"] == nil } == true)
    }

    @Test func aDecisionsPortsRewireItsPassAndChanges() {
        var definition = Flow.loop
        definition.connect("decide", .changes, to: "research")
        #expect(definition.stage("decide")?.changesGoTo == "research")
        definition.connect("decide", .pass, to: "draft")
        #expect(definition.graph.exits["decide"]?.primary == "draft")
        #expect(Flow.codes(definition).contains("cycle"), "Only changes may go back")
        #expect(Flow.codes(definition).contains("no_end") || Flow.codes(definition).contains("unreachable_stage"))
    }

    @Test func problemsTheCanvasShowsAtOnce() {
        let unknown = Flow.definition([Flow.agent("a", next: .string("gone"))])
        #expect(Flow.codes(unknown).contains("next_unknown"))
        let cycle = Flow.definition([Flow.agent("a"), Flow.agent("b", next: .string("a"))])
        #expect(Flow.codes(cycle) == ["cycle", "no_end"])
        let forward = Flow.definition([Flow.agent("a"), Flow.decision("d", goTo: "z"), Flow.agent("z")])
        #expect(Flow.codes(forward).contains("goto_not_earlier"))
        let uses = Flow.definition([Flow.agent("a", next: .string("c")), Flow.agent("b"),
                                    Flow.agent("c", uses: ["b.result"])])
        #expect(Flow.codes(uses).contains("uses_not_before"))
        #expect(Flow.codes(Flow.definition([])) == ["no_stages"])
        for code in WorkflowFlowGraph.graphCodes {
            #expect(!WorkflowWords.issue(code, stage: "Draft").contains("_"), "\(code)")
        }
    }

    /// Reordering (iPhone): the stages around the old place join up, and the
    /// stage goes on from the one now above it.
    @Test func movingAStageSplicesItIn() {
        var definition = Flow.definition([Flow.agent("a"), Flow.agent("b"), Flow.agent("c"), Flow.agent("d")])
        definition.move("d", toIndex: 1)
        #expect(definition.stages.map(\.key) == ["a", "d", "b", "c"])
        #expect(definition.stages.allSatisfy { $0.next == .following } && Flow.codes(definition).isEmpty)
        definition.move("a", toIndex: 3)
        #expect(definition.stages.map(\.key) == ["d", "b", "c", "a"])
        #expect(definition.graph.start == "d" && Flow.codes(definition).isEmpty)
        // A loop keeps going back to the same stage wherever it moves.
        var loop = Flow.loop
        loop.move("research", toIndex: 1)
        #expect(loop.stages.map(\.key) == ["draft", "research", "review", "decide", "signoff"])
        #expect(loop.stage("decide")?.changesGoTo == "draft")
    }

    @Test func addingAndDeletingKeepTheFlowJoinedUp() {
        var definition = Flow.loop
        definition.insert(WorkflowStage(new: .check, existing: definition.stages), after: "draft")
        #expect(definition.stages.map(\.key) == ["research", "draft", "check6", "review", "decide", "signoff"])
        #expect(Flow.codes(definition).isEmpty)
        definition.remove("check6")
        #expect(definition.stages.map(\.key) == Flow.loop.stages.map(\.key))
        definition.remove("draft")
        #expect(definition.graph.exits["research"]?.primary == "review")
        #expect(definition.stage("decide")?.changesGoTo == nil, "Changes that went back to it need a new place")
        // At the end of the flow, then before the first stage.
        var line = Flow.definition([Flow.agent("a"), Flow.agent("b")])
        line.insert(WorkflowStage(new: .signoff, existing: line.stages), after: nil)
        #expect(line.stages.map(\.key) == ["a", "b", "signoff3"])
        line.insertFirst(WorkflowStage(new: .agent, existing: line.stages))
        #expect(line.stages.first?.key == "stage4" && line.graph.exits["stage4"]?.primary == "a")
        line.makeStart("b")
        #expect(line.graph.start == "b" && Flow.codes(line).contains("unreachable_stage"))
    }
}

// MARK: - Places on the canvas

@MainActor
struct WorkflowCanvasLayoutTests {
    /// Compact widths ignore saved places: every stage in one line, in list order.
    @Test func compactLinesStagesUpInOrder() {
        let definition = Flow.definition([Flow.agent("a"), Flow.agent("b"), Flow.agent("c")], layout: [
            "stages": .object(["a": .object(["x": .integer(4_000), "y": .integer(9_000)]),
                               "b": .object(["x": .integer(-500), "y": .integer(0)]),
                               "c": .object(["x": .integer(20), "y": .integer(-3_000)])]),
        ])
        #expect(WorkflowCanvasLayout.compactOrder(definition) == ["a", "b", "c"])
        #expect(WorkflowCanvasLayout.positions(definition)["a"] == CGPoint(x: 4_000, y: 9_000))
    }

    @Test func automaticPlacesGoLeftToRightWithoutOverlap() {
        let positions = WorkflowCanvasLayout.automatic(Flow.loop)
        let order = ["inputs", "research", "draft", "review", "decide", "signoff"]
        let xs = order.compactMap { positions[$0]?.x }
        #expect(xs == xs.sorted() && Set(xs).count == xs.count, "\(positions)")
        Self.expectNoOverlap(positions, kinds: Self.kinds(Flow.loop))
    }

    @Test func aNewNodeFindsAFreePlaceOnTheGrid() {
        var positions = WorkflowCanvasLayout.automatic(Flow.loop)
        let kinds = Self.kinds(Flow.loop)
        // Right of the draft is the review: the new node goes in that column, above or below.
        let placed = WorkflowCanvasLayout.place(after: "draft", kind: .check, in: positions, kinds: kinds)
        #expect(placed.x == positions["draft"]!.x + WorkflowCanvasLayout.columnStep)
        #expect(placed == WorkflowCanvasLayout.snap(placed))
        positions["new"] = placed
        Self.expectNoOverlap(positions, kinds: kinds.merging(["new": .check]) { $1 })
        // Again and again: never on top of anything.
        for index in 0..<12 {
            let next = WorkflowCanvasLayout.place(after: "draft", kind: .agent, in: positions, kinds: kinds)
            positions["more\(index)"] = next
            Self.expectNoOverlap(positions, kinds: kinds)
        }
        #expect(WorkflowCanvasLayout.snap(CGPoint(x: 31, y: 49)) == CGPoint(x: 40, y: 40))
    }

    static func kinds(_ definition: WorkflowDefinition) -> [String: WorkflowStage.Kind] {
        Dictionary(definition.stages.map { ($0.key, $0.kind) }, uniquingKeysWith: { first, _ in first })
    }

    static func expectNoOverlap(_ positions: [String: CGPoint], kinds: [String: WorkflowStage.Kind],
                                sourceLocation: SourceLocation = #_sourceLocation) {
        let rects = positions.map { key, point in
            (key, CGRect(origin: point, size: WorkflowCanvasLayout.size(key == "inputs" ? nil : kinds[key] ?? .agent)))
        }
        for (index, first) in rects.enumerated() {
            for second in rects.dropFirst(index + 1) {
                #expect(!first.1.intersects(second.1), "\(first.0) overlaps \(second.0)", sourceLocation: sourceLocation)
            }
        }
    }
}

// MARK: - The editor

@MainActor
struct WorkflowFlowEditingTests {
    private func editor(_ demo: DemoWorkflowsClient, canEdit: Bool = true) async -> WorkflowEditorModel {
        let model = WorkflowEditorModel(workflowID: "wf-research", client: demo, canEditFlow: canEdit,
                                        saveDelay: .milliseconds(10))
        await model.load()
        return model
    }

    /// Moving nodes and rewiring save into `layout` and `next`, once, from the draft version the editor has.
    @Test func dragsAndRewiresSaveIntoTheDraft() async throws {
        let demo = DemoWorkflowsClient(delays: false)
        let model = await editor(demo)
        let base = model.baseDraftVersion
        model.place("draft", at: CGPoint(x: 611, y: 409))
        model.place("draft", at: CGPoint(x: 703, y: 451))
        model.connect("research", .next, to: "review")
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.baseDraftVersion == base + 1, "A few quick changes are one save")
        let saved = try await demo.workflow(id: "wf-research", revision: .draft).definition
        #expect(saved.layout?.stages["draft"] == CGPoint(x: 700, y: 460), "On the grid")
        #expect(saved.layout?.stages.count == saved.stages.count, "Every other node keeps its place")
        #expect(saved.graph.exits["research"]?.primary == "review")
        #expect(saved.schemaVersion == 2)
        // Only the decision's changes go to the draft now, and going back doesn't reach a stage.
        #expect(model.issues.contains { $0.code == "unreachable_stage" && $0.stageKey == "draft" })
        #expect(!model.issues.contains { $0.code == "goto_not_earlier" }, "The draft still leads to the decision")
    }

    @Test func aNewStageIsPlacedWiredAndReady() async throws {
        let demo = DemoWorkflowsClient(delays: false)
        let model = await editor(demo)
        let stage = try #require(model.addStage(.check, after: "draft"))
        let definition = try #require(model.definition)
        #expect(definition.graph.exits["draft"]?.primary == stage.key)
        #expect(definition.graph.exits[stage.key]?.primary == "check")
        #expect(stage.rules.first?.of == "draft.draft", "It checks the latest result")
        let positions = WorkflowCanvasLayout.positions(definition)
        WorkflowCanvasLayoutTests.expectNoOverlap(positions, kinds: WorkflowCanvasLayoutTests.kinds(definition))
        let decision = try #require(model.addStage(.decision, after: "research"))
        #expect(decision.on == "research.decision" && decision.changesGoTo != nil)
        #expect(model.definition?.stage("research")?.outputs.contains { $0.type == "decision" } == true)
    }

    /// Older plugins: the flow is shown as it is.
    @Test func withoutEditingTheFlowDoesntChange() async throws {
        let demo = DemoWorkflowsClient(delays: false)
        let model = await editor(demo, canEdit: false)
        let before = model.definition
        model.connect("research", .next, to: "review")
        model.place("draft", at: .zero)
        model.move("signoff", toGap: 0)
        #expect(model.definition == before && !model.isDirty)
    }

    @Test func reorderingByGapMovesOnePlace() async throws {
        let demo = DemoWorkflowsClient(delays: false)
        let model = await editor(demo)
        model.move("check", toGap: 1)
        #expect(model.definition?.stages.map(\.key).prefix(3) == ["research", "check", "draft"])
        model.move("check", toGap: 2)
        #expect(model.definition?.stages.map(\.key).prefix(3) == ["research", "check", "draft"], "Its own place: no change")
    }
}

// MARK: - Home: create, templates, pins, archive

@MainActor
struct WorkflowsHomeEditingTests {
    @Test func createFromScratchSendsNoWorkflowID() async throws {
        let performer = WorkflowPerformer()
        performer.answers[.workflowsDraftSave] = ["workflowId": .string("wf_new"), "draftVersion": .integer(1),
                                                  "validation": .object(["valid": .boolean(false)])]
        let client = DirectHermesWorkflowsClient(currentWorkspace: { performer })
        let store = WorkflowsStore(client: client, support: .available(canEdit: true))
        let id = try await store.create(name: "  Weekly notes ")
        #expect(id == "wf_new")
        let sent = try #require(performer.payloads(.workflowsDraftSave).first)
        #expect(Set(sent.keys) == ["baseDraftVersion", "definition"])
        #expect(sent["definition"]?.object?["name"] == .string("Weekly notes"))
        #expect(sent["definition"]?.object?["stages"] == .array([]))
    }

    @Test func newRoutesSendWhatTheContractSays() async throws {
        let performer = WorkflowPerformer()
        performer.answers[.workflowsTemplatesSave] = ["templateId": .string("tpl_1")]
        performer.answers[.workflowsTemplatesDelete] = ["deleted": .boolean(true)]
        performer.answers[.workflowsPin] = ["workflowId": .string("wf"), "pinned": .boolean(true)]
        performer.answers[.workflowsUnarchive] = ["archived": .boolean(false)]
        let client = DirectHermesWorkflowsClient(currentWorkspace: { performer })
        #expect(try await client.saveTemplate(workflowID: "wf", name: String(repeating: "n", count: 90),
                                              description: nil) == "tpl_1")
        try await client.deleteTemplate(id: "tpl_1")
        #expect(try await client.pin(workflowID: "wf", pinned: true))
        try await client.unarchive(workflowID: "wf")
        #expect(Set(performer.payloads(.workflowsTemplatesSave)[0].keys) == ["workflowId", "name"])
        #expect(performer.payloads(.workflowsTemplatesSave)[0]["name"]?.string?.count == 80)
        #expect(Set(performer.payloads(.workflowsTemplatesDelete)[0].keys) == ["templateId"])
        #expect(performer.payloads(.workflowsPin)[0] == ["workflowId": .string("wf"), "pinned": .boolean(true)])
        #expect(performer.payloads(.workflowsUnarchive)[0] == ["workflowId": .string("wf")])
    }

    @Test func editingRoutesNeedTheEditFeature() async throws {
        for operation in [WorkspaceOperation.workflowsTemplatesSave, .workflowsTemplatesDelete, .workflowsPin,
                          .workflowsUnarchive] {
            let http = NativeHTTP()
            http.handler = { request, _ in
                try NativeHTTP.response(request, body: NativeHTTP.context(features: ["native-workflows-v1"]))
            }
            let owner = try NativeHTTP.owner()
            let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
            await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
                try await client.perform(operation, payload: ["workflowId": .string("wf")])
            }
            let editing = NativeHTTP()
            editing.handler = { request, guardValue in
                if let guardValue {
                    return try NativeHTTP.response(request, body: ["ok": .boolean(true)],
                        headers: ["ETag": guardValue.etag, "X-Loopdy-Request-ID": guardValue.requestIDHeader])
                }
                return try NativeHTTP.response(request, body: NativeHTTP.context(
                    features: ["native-workflows-v1", "native-workflows-edit-v1"]))
            }
            let editClient = DirectHermesNativePluginClient(http: editing, owner: owner, currentOwner: { owner })
            _ = try await editClient.perform(operation, payload: ["workflowId": .string("wf")])
            let call = try #require(editing.calls.last)
            #expect(call.request.path == "/api/plugins/loopdy/native/" + operation.rawValue.split(separator: ".").joined(separator: "/"))
            #expect(call.request.maximumResponseBytes == 196_608)
        }
    }

    /// Demo: everything here works without a computer.
    @Test func demoPinsArchivesAndKeepsYourTemplates() async throws {
        let demo = DemoWorkflowsClient(delays: false)
        let store = WorkflowsStore(client: demo, support: .available(canEdit: true))
        await store.load()
        let triage = try #require(store.workflows.first { $0.id == "wf-triage" })
        await store.setPinned(triage, true)
        #expect(store.workflows.first?.id == "wf-triage" && store.workflows.first?.pinned == true)
        await store.archive(triage)
        #expect(!store.workflows.contains { $0.id == "wf-triage" })
        #expect(try await store.archived().map(\.id) == ["wf-triage"])
        await store.unarchive("wf-triage")
        #expect(store.workflows.contains { $0.id == "wf-triage" })

        #expect(await store.saveTemplate(workflowID: "wf-research", name: "My review flow"))
        let mine = try #require(store.yourTemplates.first)
        #expect(mine.name == "My review flow" && store.builtinTemplates.map(\.id) == ["research-draft-review", "three-takes"])
        let copy = try await store.use(mine)
        #expect(try await demo.workflow(id: copy, revision: .draft).definition.stages.count == 6)
        await store.deleteTemplate(mine)
        #expect(store.yourTemplates.isEmpty)

        let id = try await store.create(name: "From scratch")
        let empty = try await demo.workflow(id: id, revision: .draft)
        #expect(empty.definition.stages.isEmpty && empty.validation.issues.map(\.code) == ["no_stages"])
    }

    @Test func demoHasAFallbackRunWithoutTokens() async throws {
        let demo = DemoWorkflowsClient(delays: false)
        let run = try await demo.run(id: "run-8")
        #expect(run.tokens == nil && run.stages.flatMap(\.attempts).allSatisfy { $0.tokens == nil })
        #expect(try await demo.run(id: "run-13").tokens != nil)
    }
}

// MARK: - The plugin's v2 vectors (fixtures/contracts/workflows-v1, byte for byte)

@MainActor
struct WorkflowV2VectorTests {
    private typealias Vector = WorkflowContractVectorTests

    @Test func createFromScratchSendsTheVectorsRequest() async throws {
        let request = try Vector.request("draft-save-new.json")
        let definition = try #require(request["definition"]?.object)
        #expect(WorkflowDefinition.empty(name: "New workflow").json == definition)
        let performer = WorkflowPerformer()
        performer.answers[.workflowsDraftSave] = try Vector.response("draft-save-new.json")
        let store = WorkflowsStore(client: DirectHermesWorkflowsClient(currentWorkspace: { performer }),
                                   support: .available(canEdit: true))
        #expect(try await store.create(name: "") == "wf_2b3c4d5e6f708192")
        #expect(performer.payloads(.workflowsDraftSave).first == request)
        let saved = WorkflowValidation(json: try Vector.response("draft-save-new.json")["validation"]?.object)
        #expect(!saved.valid && saved.issues.map(\.code) == ["no_stages"])
    }

    /// next, layout and a decision loop come back to the host exactly as sent.
    @Test func aV2DefinitionGoesBackUnchanged() throws {
        let request = try Vector.request("draft-save-v2.json")
        let json = try #require(request["definition"]?.object)
        let definition = WorkflowDefinition(json: json)
        #expect(WorkflowDefinition(json: definition.json) == definition)
        let stages = definition.json["stages"]?.array ?? []
        #expect(stages.first?.object?["next"] == .string("draft"))
        #expect(stages[1].object?["next"] == .null, "The sign-off ends the run")
        #expect(stages.last?.object?["next"] == nil, "A decision never has next")
        #expect(definition.json["layout"] == json["layout"])
        #expect(definition.layout?.stages["draft"] == CGPoint(x: 0, y: 240.5))
        #expect(definition.layout?.stages["signoff"] == CGPoint(x: -220, y: 600))
    }

    @Test func getV2ReadsTheGraphPinAndPlaces() throws {
        let detail = try WorkflowDetail(json: try Vector.response("get-v2.json"))
        #expect(detail.pinned)
        let graph = detail.definition.graph
        #expect(graph.start == "research")
        #expect(graph.exits["research"]?.primary == "draft" && graph.exits["draft"]?.primary == "review")
        #expect(graph.exits["review"]?.primary == "review_decision")
        #expect(graph.exits["review_decision"] == .init(primary: "signoff", changes: "draft"))
        #expect(graph.exits["signoff"]?.primary == nil)
        #expect(Flow.codes(detail.definition).isEmpty, "The canvas finds nothing wrong with the host's own example")
        #expect(WorkflowCanvasLayout.positions(detail.definition)["signoff"] == CGPoint(x: -220, y: 600))
        #expect(try WorkflowDetail(json: try Vector.response("get.json")).pinned == false)
    }

    @Test func listV2PutsPinnedFirst() throws {
        let list = WorkflowsList(json: try Vector.response("list-v2.json"))
        #expect(list.workflows.map(\.pinned) == [true, false, false])
        #expect(list.workflows.first?.id == "wf_2b3c4d5e6f708192")
    }

    @Test func templatesListV2SaysWhoseTheyAre() throws {
        let templates = WorkflowDecode.objects(try Vector.response("templates-list-v2.json")["templates"], max: 150)
            .compactMap(WorkflowTemplate.init(json:))
        #expect(templates.map(\.source) == [.yours, .builtin])
        #expect(templates[0].updatedAt != nil && templates[1].updatedAt == nil)
        #expect(templates[0].stageCount == 5)
    }

    @Test func validateV2IssuesPointAtTheirStages() throws {
        let validation = WorkflowValidation(json: try Vector.response("validate-v2.json")["validation"]?.object)
        #expect(!validation.valid && validation.issues.count == 7)
        #expect(validation.issues.first { $0.code == "cycle" }?.stageKey == "extra")
        #expect(validation.issues.first { $0.code == "no_end" }?.stageKey == nil)
        #expect(Set(validation.issues.map(\.code)).isSubset(of: WorkflowFlowGraph.graphCodes))
    }

    /// pin, unarchive, templates/save, delete and use send what the vectors send.
    @Test func newRoutesSendTheVectorsRequests() async throws {
        let performer = WorkflowPerformer()
        for (operation, name) in [(WorkspaceOperation.workflowsPin, "pin.json"), (.workflowsUnarchive, "unarchive.json"),
                                  (.workflowsTemplatesSave, "templates-save.json"),
                                  (.workflowsTemplatesDelete, "templates-delete.json"),
                                  (.workflowsTemplatesUse, "templates-use-yours.json")] {
            performer.answers[operation] = try Vector.response(name)
        }
        let client = DirectHermesWorkflowsClient(currentWorkspace: { performer })
        #expect(try await client.pin(workflowID: "wf_2b3c4d5e6f708192", pinned: true))
        try await client.unarchive(workflowID: "wf_8c1d2e3f4a5b6c7d")
        #expect(try await client.saveTemplate(workflowID: "wf_2b3c4d5e6f708192", name: "Newsletter with a loop",
                                              description: "Draft until the review passes.") == "tpl-5d6e7f8091a2b3c4")
        try await client.deleteTemplate(id: "tpl-5d6e7f8091a2b3c4")
        #expect(try await client.useTemplate(id: "tpl-5d6e7f8091a2b3c4") == "wf_3c4d5e6f708192a3")
        #expect(performer.payloads(.workflowsPin).first == (try Vector.request("pin.json")))
        #expect(performer.payloads(.workflowsUnarchive).first == (try Vector.request("unarchive.json")))
        #expect(performer.payloads(.workflowsTemplatesSave).first == (try Vector.request("templates-save.json")))
        #expect(performer.payloads(.workflowsTemplatesDelete).first == (try Vector.request("templates-delete.json")))
        #expect(performer.payloads(.workflowsTemplatesUse).first?["templateId"] == .string("tpl-5d6e7f8091a2b3c4"))
    }

    @Test func statusV2SaysWhichRunner() throws {
        #expect(WorkflowStatus(json: try Vector.response("status-v2.json")).runnerMode == .text)
        #expect(WorkflowStatus(json: try Vector.response("status.json")).runnerMode == nil)
    }

    /// The text runner can't count tokens: null attempts show nothing.
    @Test func textRunnerRunHasNoTokenCounts() throws {
        let run = try WorkflowRunDetail(json: try Vector.response("runs-get-text-runner.json"))
        #expect(run.stages.flatMap(\.attempts).allSatisfy { $0.tokens == nil })
        #expect((run.tokens?.total ?? 0) == 0)
    }

    @Test func contextUnavailableExplainsInsteadOfHiding() throws {
        let support = WorkflowsSupport(context: try Vector.response("context-unavailable.json"))
        #expect(support == .unavailable(code: "chat_runner_missing") && support.showsMenuRow)
    }
}

// MARK: - Details the plugin settled

@MainActor
struct WorkflowV2ContractDetailTests {
    /// goto_not_earlier: the goTo stage must lead back to the decision, wherever it sits in the list.
    @Test func goToIsEarlierByTheFlowNotTheList() {
        let reordered = Flow.definition([Flow.agent("research", next: .string("draft")),
                                         Flow.decision("decide", pass: "signoff", goTo: "draft"),
                                         { var s = Flow.signoff(); s["next"] = .null; return s }(),
                                         Flow.agent("draft"), Flow.agent("review", next: .string("decide"))])
        #expect(Flow.codes(reordered).isEmpty, "\(Flow.codes(reordered))")
        let deadEnd = Flow.definition([Flow.agent("a"), Flow.agent("b", next: .string("d")),
                                       Flow.decision("d", pass: "next", goTo: "z"), Flow.agent("z", next: .null)])
        #expect(Flow.codes(deadEnd).contains("goto_not_earlier"), "z can't lead back to the decision")
    }

    /// As on the host, only ways on count: a decision's changes don't reach a stage, and
    /// "leads back to the decision" and "made on every way" follow ways on only.
    @Test func goingBackDoesntReachAStage() {
        let skipped = Flow.definition([Flow.agent("research", next: .string("review")), Flow.agent("draft"),
                                       Flow.agent("review"), Flow.decision("decide", goTo: "draft"), Flow.signoff()])
        let issues = skipped.graph.issues(skipped)
        #expect(issues.contains { $0.code == "unreachable_stage" && $0.stageKey == "draft" })
        #expect(!issues.contains { $0.code == "goto_not_earlier" })
        // The sign-off reads draft.result, which only going back makes.
        #expect(issues.contains { $0.code == "uses_not_before" && $0.stageKey == "signoff" })
        // A goTo that reaches the decision only by going back again isn't before it.
        let around = Flow.definition([Flow.agent("a", next: .string("decide")), Flow.agent("x", next: .string("other")),
                                      Flow.decision("other", pass: "end", goTo: "a"),
                                      Flow.decision("decide", pass: "end", goTo: "x"), Flow.agent("end", next: .null)])
        #expect(around.graph.issues(around).contains { $0.code == "goto_not_earlier" && $0.stageKey == "decide" })
    }

    /// A check's `of`, a decision's `on` and a sign-off's `file` must come first too.
    @Test func everyReadNeedsItsSourceFirst() {
        var signoff = Flow.signoff()
        signoff["file"] = .string("late.result")
        let late = Flow.definition([Flow.agent("a", next: .string("signoff")), signoff,
                                    Flow.agent("late", next: .null)])
        #expect(Flow.codes(late).contains("uses_not_before"))
        let check: WorkflowJSON = ["key": .string("check"), "kind": .string("check"), "title": .string("Check"),
                                   "rules": .array([.object(["type": .string("word_range"), "of": .string("b.result"),
                                                             "min": .integer(1)])])]
        let checkFirst = Flow.definition([Flow.agent("a", next: .string("check")), check, Flow.agent("b", next: .null)])
        #expect(checkFirst.graph.issues(checkFirst).contains { $0.code == "uses_not_before" && $0.stageKey == "check" })
    }

    @Test func newIssueAndEventWordsArePlain() {
        let words = WorkflowWords.issue("tool_scope_unsupported", stage: "Draft")
        #expect(!words.contains("_") && words.localizedCaseInsensitiveContains("Hermes"))
        let events = [WorkflowEvent(seq: 1, at: nil, kind: "stage_launched", stageKey: "draft", attempt: 1, text: "Started"),
                      WorkflowEvent(seq: 2, at: nil, kind: "agent_error", stageKey: "draft", attempt: 1,
                                    text: "The agent writer isn't on this computer."),
                      WorkflowEvent(seq: 3, at: nil, kind: "needs_attention", stageKey: "draft", attempt: 1, text: "x")]
        #expect(WorkflowEvent.agentError(in: events, stageKey: "draft")?.text == "The agent writer isn't on this computer.")
        #expect(WorkflowEvent.agentError(in: events, stageKey: "review") == nil)
    }

    /// A 101st template is 409 not_allowed; the app says why in plain words.
    @Test func theHundredAndFirstTemplateSaysWhy() async {
        let performer = WorkflowPerformer()
        performer.failures[.workflowsTemplatesSave] = [WorkspaceClientError.rejected(code: "not_allowed")]
        let store = WorkflowsStore(client: DirectHermesWorkflowsClient(currentWorkspace: { performer }),
                                   support: .available(canEdit: true))
        #expect(await store.saveTemplate(workflowID: "wf", name: "One more") == false)
        #expect(store.message == "You have 100 templates. Delete one, then save this one.")
        #expect(await store.saveTemplate(workflowID: "wf", name: "   ") == false, "A blank name never goes to the host")
        #expect(performer.calls(.workflowsTemplatesSave) == 1)
    }
}

/// Parallel blocks: several agent stages at once, and a decision that reads all their verdicts.
@MainActor
struct WorkflowParallelTests {
    @Test func blocksAndSeveralVerdictsSurviveARoundTrip() throws {
        let definition = DemoWorkflowsClient.threeTakes
        let block = try #require(definition.stages.first)
        #expect(block.kind == .parallel && block.branches.map(\.key) == ["facts", "risks", "practice"])
        let decision = try #require(definition.stage("agree"))
        #expect(decision.sources == ["facts.decision", "risks.decision", "practice.decision"])
        #expect(definition.stage("risks")?.title == "The risks", "An agent of a block is found like any stage")
        #expect(definition.parent(of: "risks")?.key == "takes")
        // What goes back to the host is what came.
        let again = WorkflowDefinition(json: definition.json)
        #expect(again == definition)
        #expect(again.stage("agree")?.json["on"]?.array?.count == 3)
        #expect(!definition.graph.issues(definition).contains { $0.code == "uses_not_before" },
                "A decision may read every agent of the block before it")
    }

    @Test func aNewBlockHasThreeAgentsAndADecisionAfterItReadsThemAll() async throws {
        let demo = DemoWorkflowsClient(delays: false)
        let editor = WorkflowEditorModel(workflowID: "wf-research", client: demo, canEditFlow: true, canParallel: true)
        await editor.load()
        let block = try #require(editor.addStage(.parallel, after: nil))
        #expect(block.branches.count == 3)
        let keys = try #require(editor.definition?.allStages.map(\.key))
        #expect(Set(keys).count == keys.count, "Every agent has a key no other stage has")
        let decision = try #require(editor.addStage(.decision, after: block.key))
        #expect(decision.sources.count == 3 && decision.changesGoTo == block.key)
        let saved = try #require(editor.definition?.stage(block.key))
        #expect(saved.branches.allSatisfy { $0.outputs.contains { $0.type == "decision" } },
                "Each agent learns to say pass or changes")

        // An agent edited on its own goes back into its block.
        var agent = saved.branches[1]
        agent.title = "The skeptic"
        editor.update(agent)
        #expect(editor.definition?.stage(block.key)?.branches[1].title == "The skeptic")
        #expect(editor.definition?.stages.contains { $0.key == agent.key } == false)
    }

    @Test func theThreeTakesTemplateIsOfferedAndRuns() async throws {
        let demo = DemoWorkflowsClient(delays: false)
        #expect(await demo.supportsParallel())
        #expect(try await demo.templates().contains { $0.id == "three-takes" })
        let id = try await demo.useTemplate(id: "three-takes")
        let detail = try await demo.workflow(id: id, revision: .draft)
        #expect(detail.definition.stages.first?.kind == .parallel)
    }
}
