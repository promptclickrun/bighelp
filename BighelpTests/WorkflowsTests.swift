import Foundation
import Testing
@testable import Bighelp

// MARK: - Shapes

@MainActor
struct WorkflowModelTests {
    /// Hosts differ: an unknown state stays readable, and a missing part hides one row.
    @Test func runSummaryParsesEveryStateAndKeepsUnknownOnes() throws {
        let states = ["planned", "launched", "running", "checking_output", "accepted", "waiting_for_you",
                      "needs_attention", "succeeded", "failed", "cancelled", "paused_by_host"]
        for state in states {
            let run = try #require(WorkflowRunSummary(json: ["id": .string("r1"), "state": .string(state)]))
            #expect(run.state.rawValue == state)
        }
        #expect(WorkflowRunState("paused_by_host") == .unknown("paused_by_host"))
        let bare = try #require(WorkflowRunSummary(json: ["id": .string("r2")]))
        #expect(bare.workflowName == "Workflow" && bare.stageCount == 0 && bare.attention == nil)
        #expect(WorkflowRunSummary(json: ["state": .string("running")]) == nil, "A run needs its id")
    }

    @Test func listStatusDetailAndEventsDecodeThePlanShapes() throws {
        let list = WorkflowsList(json: Samples.list)
        #expect(list.workflows.map(\.id) == ["wf-1", "wf-2"])
        #expect(list.workflows[1].needsSetupRoles == ["captioner", "checker"] && list.workflows[1].revision == nil)
        #expect(list.waiting.first?.waiting?.stageKey == "signoff")
        #expect(list.active.first?.state == .running)

        let status = WorkflowStatus(json: Samples.status)
        #expect(status.coordinator == .online && status.slotsUsed == 1 && status.slotsTotal == 2)
        #expect(status.heartbeatAt != nil && status.epoch == 7 && status.hostName == "studio")

        let detail = try WorkflowRunDetail(json: Samples.runDetail)
        #expect(detail.summary.number == 14 && detail.stages.count == 2)
        #expect(detail.signoff?.artifactSHA256 == Samples.sha && detail.signoff?.reviewNotes.count == 2)
        #expect(detail.signoff?.history.first?.asksForChanges == true)
        #expect(detail.tokens?.total == 300 && detail.allowedActions == ["cancel"])
        #expect(detail.previousVersion(of: try #require(detail.signoff))?.iteration == 1)

        let events = WorkflowEventPage(json: ["events": .array([.object(["seq": .integer(4), "at": .string("2026-10-04T10:52:04Z"),
                                                                        "kind": .string("accepted"), "text": .string("Run accepted")])]),
                                              "cursor": .integer(4), "hasMore": .boolean(false)], after: 0)
        #expect(events.events.first?.at != nil && events.cursor == 4)
    }

    /// Saving a draft sends back what a newer plugin added, unchanged.
    @Test func definitionRoundTripKeepsFieldsTheAppDoesntKnow() throws {
        var json = Samples.definition
        json["futureField"] = .string("kept")
        var stages = try #require(json["stages"]?.array)
        var first = try #require(stages[0].object)
        first["futureStageField"] = .integer(3)
        stages[0] = .object(first)
        json["stages"] = .array(stages)
        var definition = WorkflowDefinition(json: json)
        definition.stages[0].title = "Research harder"
        let back = definition.json
        #expect(back["futureField"] == .string("kept"))
        #expect(back["stages"]?.array?.first?.object?["futureStageField"] == .integer(3))
        #expect(back["stages"]?.array?.first?.object?["title"] == .string("Research harder"))
        #expect(WorkflowDefinition(json: back) == definition)
    }

    @Test func checkRulesReadBothShapes() {
        let flat = WorkflowStage.Rule(json: ["rule": .string("word_range"), "of": .string("draft.draft"),
                                             "min": .integer(700), "max": .integer(1_100)])
        let nested = WorkflowStage.Rule(json: ["word_range": .object(["of": .string("draft.draft"),
                                                                      "min": .integer(700), "max": .integer(1_100)])])
        #expect(flat.summary == "700-1,100 words" && nested.summary == "700-1,100 words")
        #expect(nested.of == "draft.draft")
    }

    @Test func changesFromTheLastVersionMarkAddedAndRemovedParagraphs() {
        let old = "# Title\n\nKeep this.\n\nCut this.\n\nEnd."
        let new = "# Title\n\nKeep this.\n\nA new example.\n\nEnd."
        let segments = WorkflowTextDiff.compare(old: old, new: new)
        #expect(segments.map(\.kind) == [.same, .same, .removed, .added, .same])
        #expect(segments.filter { $0.kind == .removed }.map(\.text) == ["Cut this."])
        #expect(segments.filter { $0.kind == .added }.map(\.text) == ["A new example."])
    }

    @Test func shortFingerprintShowsEnoughToTellFilesApart() {
        #expect(WorkflowSHA.short(Samples.sha) == "4f1c…9a2e")
        #expect(WorkflowSHA.valid("ABC") == nil && WorkflowSHA.valid(Samples.sha) == Samples.sha)
    }

    /// Every vector the plugin publishes (fixtures/contracts/workflows-v1, copied
    /// byte for byte) decodes without losing its runs or workflows.
    @Test func contractVectorsDecode() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/Workflows")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        for file in files {
            let value = try JSONDecoder().decode(BighelpJSONValue.self, from: Data(contentsOf: file))
            try WorkflowVectorCheck.check(value, name: file.lastPathComponent)
        }
    }
}

// MARK: - Contract vectors (bighelp-plugin fixtures/contracts/workflows-v1, byte for byte)

@MainActor
struct WorkflowContractVectorTests {
    static func vector(_ name: String) throws -> WorkflowJSON {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/Workflows/\(name)")
        let value = try JSONDecoder().decode(BighelpJSONValue.self, from: Data(contentsOf: url))
        return try #require(value.object)
    }

    static func response(_ name: String) throws -> WorkflowJSON {
        try #require(try vector(name)["response"]?.object)
    }

    static func request(_ name: String) throws -> WorkflowJSON {
        try #require(try vector(name)["request"]?.object)
    }

    @Test func statusVectors() throws {
        let online = WorkflowStatus(json: try Self.response("status.json"))
        #expect(online.coordinator == .online && online.slotsUsed == 1 && online.slotsTotal == 2)
        #expect(online.heartbeatAt != nil && online.hostName == "studio-mac" && online.runnerAvailable)
        let offline = WorkflowStatus(json: try Self.response("status-offline.json"))
        #expect(offline.coordinator == .offline && offline.heartbeatAt == nil)
        #expect(!offline.runnerAvailable && offline.runnerReason == "service_manager_missing")
    }

    @Test func listVector() throws {
        let list = WorkflowsList(json: try Self.response("list.json"))
        #expect(list.workflows.count == 2)
        #expect(list.workflows[1].revision == nil && list.workflows[1].needsSetupRoles.count == 3)
        #expect(list.waiting.first?.waiting?.since != nil && list.waiting.first?.state == .waitingForYou)
        #expect(list.active.first?.state == .running && list.active.first?.version == 7)
    }

    @Test func getVectorAndTheDefinitionGoesBackUnchanged() throws {
        let response = try Self.response("get.json")
        let detail = try WorkflowDetail(json: response)
        #expect(detail.revision == nil && detail.latestRevision == 3 && detail.draftVersion == 5)
        #expect(detail.bindings.count == 3 && detail.validation.valid && detail.validation.checkedOnHost)
        let stages = detail.definition.stages
        #expect(stages.map(\.kind) == [.agent, .agent, .check, .agent, .decision, .signoff])
        #expect(stages[2].rules.first?.kind == "word_range" && stages[2].rules.first?.max == 3_000)
        #expect(stages[4].pass == "next" && stages[4].changesGoTo == "draft" && stages[4].changesMaxRevisions == 2)
        #expect(stages[5].file == "draft.draft" && stages[3].minutes == 15)
        #expect(detail.definition.inputs[2].kind == .choice && detail.definition.inputs[2].sample == "Medium")

        let definition = try #require(response["workflow"]?.object?["definition"]?.object)
        #expect(WorkflowDefinition(json: definition).json == definition)
        let saved = try #require(try Self.request("draft-save.json")["definition"]?.object)
        #expect(WorkflowDefinition(json: saved).json == saved)
        let template = try Self.vector("template-research-draft-review.json")
        #expect(WorkflowDefinition(json: template).json == template)
    }

    @Test func runVectors() throws {
        let waiting = try WorkflowRunDetail(json: try Self.response("runs-get.json"))
        let signoff = try #require(waiting.signoff)
        #expect(signoff.artifactSHA256.hasPrefix("4f1c") && signoff.artifactIteration == 2)
        #expect(signoff.artifactName == "draft-v2.md" && signoff.artifactWords == 884)
        #expect(waiting.previousVersion(of: signoff)?.iteration == 1)
        #expect(signoff.reviewNotes.map(\.isMajor) == [true, false])
        #expect(waiting.reviewDecision(for: signoff) == "pass")
        #expect(waiting.tokens?.total == 60_940 && waiting.allowedActions == ["cancel", "pause"])
        let history = waiting.signoffHistory(for: signoff)
        #expect(history.map(\.title) == ["Research the topic", "Write the draft v1", "Review the draft v1 asked for changes",
                                         "Write the draft v2", "Review the draft v2"])
        #expect(history.map(\.asksForChanges) == [false, false, true, false, false])

        let running = try WorkflowRunDetail(json: try Self.response("runs-get-running.json"))
        #expect(running.summary.state == .running && running.signoff == nil)
        #expect(running.stages.first { $0.key == "draft" }?.attempts.first?.state == .running)

        let states = WorkflowRunPage(json: try Self.response("run-states.json")).runs
        #expect(states.map(\.state) == [.planned, .launched, .running, .checkingOutput, .accepted, .waitingForYou,
                                         .needsAttention, .succeeded, .failed, .cancelled])
        #expect(states[0].stageState == .planned, "A stage that hasn't started is pending")
        #expect(states[6].attention?.code == "host_restarted" && states[8].failure?.stageKey == "draft")
        #expect(states[8].stateLine == "Failed at Write the draft")

        let page = WorkflowRunPage(json: try Self.response("runs-list.json"))
        #expect(page.runs.count == 10 && page.hasMore)

        for name in ["runs-start.json", "runs-signoff.json", "runs-control.json"] {
            let run = try #require(try Self.response(name)["run"]?.object)
            #expect(WorkflowRunSummary(json: run) != nil, "\(name)")
        }
        let events = WorkflowEventPage(json: try Self.response("runs-events.json"), after: 0)
        #expect(events.events.count == 6 && events.cursor == 6 && events.events[0].stageKey == nil)
        let chunk = try WorkflowArtifactChunk(json: try Self.response("artifacts-read.json"))
        #expect(chunk.total == 5_214 && !chunk.done && !chunk.data.isEmpty)
    }

    @Test func smallerVectors() throws {
        #expect(WorkflowBinding.list(try Self.response("bind.json")["bindings"]).count == 3)
        let validation = WorkflowValidation(json: try Self.response("validate.json")["validation"]?.object)
        #expect(!validation.valid && validation.errors.count == 1 && validation.warnings.count == 1)
        let templates = WorkflowDecode.objects(try Self.response("templates-list.json")["templates"])
            .compactMap(WorkflowTemplate.init(json:))
        #expect(templates.first?.id == "research-draft-review" && templates.first?.stageCount == 6)
        #expect(WorkflowDecode.string(try Self.response("templates-use.json")["workflowId"]) == "wf_1a2b3c4d5e6f7081")
        #expect(WorkflowDecode.int(try Self.response("publish.json")["revision"]) == 4)
        #expect(try Self.response("archive.json")["archived"] == .boolean(true))
    }

    /// Bodies are extra="forbid" on the host: the app sends exactly the keys each vector's request has.
    @Test func requestsCarryExactlyTheVectorsKeys() async throws {
        let performer = WorkflowPerformer()
        for (operation, file) in [(WorkspaceOperation.workflowsStatus, "status.json"), (.workflowsList, "list.json"),
                                  (.workflowsGet, "get.json"), (.workflowsDraftSave, "draft-save.json"),
                                  (.workflowsValidate, "validate.json"), (.workflowsPublish, "publish.json"),
                                  (.workflowsBind, "bind.json"), (.workflowsArchive, "archive.json"),
                                  (.workflowsRunsStart, "runs-start.json"), (.workflowsRunsList, "runs-list.json"),
                                  (.workflowsRunsGet, "runs-get.json"), (.workflowsRunsEvents, "runs-events.json"),
                                  (.workflowsRunsControl, "runs-control.json"), (.workflowsRunsSignoff, "runs-signoff.json"),
                                  (.workflowsArtifactsRead, "artifacts-read.json"),
                                  (.workflowsTemplatesList, "templates-list.json"), (.workflowsTemplatesUse, "templates-use.json")] {
            performer.answers[operation] = try Self.response(file)
        }
        let client = DirectHermesWorkflowsClient(currentWorkspace: { performer })
        let definition = WorkflowDefinition(json: try #require(try Self.request("draft-save.json")["definition"]?.object))
        _ = try await client.status()
        _ = try await client.list(includeArchived: false)
        _ = try await client.workflow(id: "wf", revision: .draft)
        _ = try await client.saveDraft(workflowID: "wf", baseDraftVersion: 5, definition: definition)
        _ = try await client.validate(workflowID: "wf")
        _ = try await client.publish(workflowID: "wf", draftVersion: 6)
        _ = try await client.bind(workflowID: "wf", role: "reviewer", agentID: "editor")
        try await client.archive(workflowID: "wf")
        _ = try await client.startRun(workflowID: "wf", revision: 3, inputs: [:], clientRunToken: UUID().uuidString.lowercased())
        _ = try await client.runs(workflowID: nil, filter: .all, before: nil, limit: 20)
        _ = try await client.run(id: "run")
        _ = try await client.events(runID: "run", after: 0, limit: 100)
        _ = try await client.control(runID: "run", action: .cancel, expectedVersion: 7)
        _ = try await client.signoff(runID: "run", stageKey: "signoff", decision: .approve,
                                     artifactSHA256: String(repeating: "a", count: 64), notes: "")
        _ = try? await client.readArtifact(runID: "run", sha256: String(repeating: "a", count: 64), offset: 0, length: 38)
        _ = try await client.templates()
        _ = try await client.useTemplate(id: "research-draft-review")
        for (operation, file) in [(WorkspaceOperation.workflowsStatus, "status.json"), (.workflowsList, "list.json"),
                                  (.workflowsGet, "get.json"), (.workflowsDraftSave, "draft-save.json"),
                                  (.workflowsValidate, "validate.json"), (.workflowsPublish, "publish.json"),
                                  (.workflowsBind, "bind.json"), (.workflowsArchive, "archive.json"),
                                  (.workflowsRunsStart, "runs-start.json"), (.workflowsRunsList, "runs-list.json"),
                                  (.workflowsRunsGet, "runs-get.json"), (.workflowsRunsEvents, "runs-events.json"),
                                  (.workflowsRunsControl, "runs-control.json"), (.workflowsRunsSignoff, "runs-signoff.json"),
                                  (.workflowsArtifactsRead, "artifacts-read.json"),
                                  (.workflowsTemplatesList, "templates-list.json"), (.workflowsTemplatesUse, "templates-use.json")] {
            let sent = try #require(performer.payloads(operation).first, "\(file)")
            #expect(Set(sent.keys) == Set(try Self.request(file).keys), "\(file)")
        }
    }

    /// The host's 4xx codes reach the screens as codes, worded plainly.
    @Test func errorVectorsBecomeRejectedCodes() async throws {
        let errors = try #require(try Self.vector("errors.json")["errors"]?.array?.compactMap(\.object))
        #expect(errors.count >= 20)
        for error in errors {
            let status = try #require(WorkflowDecode.int(error["status"]))
            let code = try #require(WorkflowDecode.string(error["code"]))
            let body = try #require(error["example"]?.object)
            guard (400...499).contains(status), ![412, 413, 428].contains(status) else { continue }
            let http = NativeHTTP()
            http.handler = { request, guardValue in
                if guardValue != nil { return try NativeHTTP.response(request, status: status, body: body, headers: [:]) }
                return try NativeHTTP.response(request, body: NativeHTTP.context(features: ["native-workflows-v1"]))
            }
            let owner = try NativeHTTP.owner()
            let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
            await #expect(throws: WorkspaceClientError.rejected(code: code)) {
                try await client.perform(.workflowsRunsStart, payload: [:])
            }
            #expect(!WorkflowWords.problem(code).contains("_"), "\(code)")
        }
    }
}

// MARK: - Routes

@MainActor
struct WorkflowRouteTests {
    nonisolated static let operations: [WorkspaceOperation] = [
        .workflowsStatus, .workflowsList, .workflowsGet, .workflowsDraftSave, .workflowsValidate, .workflowsPublish,
        .workflowsBind, .workflowsArchive, .workflowsRunsStart, .workflowsRunsList, .workflowsRunsGet,
        .workflowsRunsEvents, .workflowsRunsControl, .workflowsRunsSignoff, .workflowsArtifactsRead,
        .workflowsTemplatesList, .workflowsTemplatesUse,
    ]
    nonisolated static let mutations: Set<WorkspaceOperation> = [
        .workflowsDraftSave, .workflowsPublish, .workflowsBind, .workflowsArchive, .workflowsRunsStart,
        .workflowsRunsControl, .workflowsRunsSignoff, .workflowsTemplatesUse,
    ]

    @Test(arguments: operations)
    func eachOperationHasItsFixedRouteAndLimits(operation: WorkspaceOperation) async throws {
        let http = NativeHTTP()
        http.handler = { request, guardValue in
            if let guardValue {
                return try NativeHTTP.response(request, body: ["ok": .boolean(true)],
                    headers: ["ETag": guardValue.etag, "X-Loopdy-Request-ID": guardValue.requestIDHeader])
            }
            return try NativeHTTP.response(request, body: NativeHTTP.context(features: ["native-workflows-v1"]))
        }
        let owner = try NativeHTTP.owner()
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        _ = try await client.perform(operation, payload: ["workflowId": .string("wf-1")])
        let call = try #require(http.calls.last)
        let path = operation.rawValue.split(separator: ".").joined(separator: "/")
        #expect(call.request.path == "/api/plugins/loopdy/native/" + path)
        #expect(call.request.method == .post)
        #expect(call.request.maximumResponseBytes == 196_608)
        #expect(call.guardValue?.requestIDHeader == call.guardValue?.requestIDHeader.lowercased())
    }

    @Test(arguments: operations)
    func aLostReplyIsUnknownOnlyForMutations(operation: WorkspaceOperation) async throws {
        let http = NativeHTTP()
        http.handler = { request, guardValue in
            if guardValue != nil { throw WorkspaceClientError.transportUnavailable }
            return try NativeHTTP.response(request, body: NativeHTTP.context(features: ["native-workflows-v1"]))
        }
        let owner = try NativeHTTP.owner()
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        let expected = Self.mutations.contains(operation) ? WorkspaceClientError.outcomeUnknown : .transportUnavailable
        await #expect(throws: expected) { try await client.perform(operation, payload: [:]) }
    }

    /// An older plugin: the route says so, and the screen asks to update the plugin.
    @Test func aPluginWithoutWorkflowsIsUnsupported() async throws {
        let http = NativeHTTP()
        http.handler = { request, _ in try NativeHTTP.response(request, body: NativeHTTP.context(features: [])) }
        let owner = try NativeHTTP.owner()
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            try await client.perform(.workflowsList, payload: [:])
        }
        #expect(http.calls.count == 1, "Nothing is sent to a route the plugin doesn't list")
        #expect(WorkflowsLoadState.from(WorkspaceClientError.unavailable(.unsupportedOperation), hasContent: false)
                == .needsPluginUpdate)
    }

    /// Workflow routes refuse requests over 192 KB, like card templates.
    @Test func requestsOverTheRouteLimitAreNotSent() async throws {
        let http = NativeHTTP()
        http.handler = { request, _ in
            try NativeHTTP.response(request, body: NativeHTTP.context(features: ["native-workflows-v1"]))
        }
        let owner = try NativeHTTP.owner()
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: DirectHermesError.messageTooLarge) {
            try await client.perform(.workflowsDraftSave, payload: ["definition": .string(String(repeating: "a", count: 200_000))])
        }
        #expect(http.calls.isEmpty)
    }
}

// MARK: - Client

@MainActor
struct WorkflowsClientTests {
    /// The plugin's context changed (412): the next call loads it again. Once.
    @Test func aContextConflictIsTriedOnceMore() async throws {
        let performer = WorkflowPerformer()
        performer.failures[.workflowsList] = [WorkspaceClientError.conflict]
        performer.answers[.workflowsList] = Samples.list
        let client = DirectHermesWorkflowsClient(currentWorkspace: { performer })
        let list = try await client.list(includeArchived: false)
        #expect(list.workflows.count == 2)
        #expect(performer.calls(.workflowsList) == 2)

        performer.failures[.workflowsList] = [WorkspaceClientError.conflict, WorkspaceClientError.conflict]
        await #expect(throws: WorkspaceClientError.conflict) { try await client.list(includeArchived: false) }
        #expect(performer.calls(.workflowsList) == 4, "Never more than once more")
    }

    /// The start reached the host but its answer didn't come back: the run it
    /// made is found by its token instead of starting a second one.
    @Test func anUnconfirmedStartIsFoundByItsToken() async throws {
        let performer = WorkflowPerformer()
        performer.failures[.workflowsRunsStart] = [WorkspaceClientError.outcomeUnknown]
        performer.answers[.workflowsRunsList] = ["runs": .array([
            .object(["id": .string("other"), "clientRunToken": .string("someone-else"), "state": .string("running")]),
            .object(["id": .string("mine"), "clientRunToken": .string("token-1"), "state": .string("planned")]),
        ])]
        let client = DirectHermesWorkflowsClient(currentWorkspace: { performer })
        let run = try await client.startRun(workflowID: "wf-1", revision: 4, inputs: [:], clientRunToken: "token-1")
        #expect(run.id == "mine")
        #expect(performer.calls(.workflowsRunsStart) == 1, "No second start")
        #expect(performer.payloads(.workflowsRunsStart).first?["clientRunToken"] == .string("token-1"))
        #expect(performer.payloads(.workflowsRunsStart).first?["sample"] == .boolean(false))
    }

    /// A host that doesn't echo tokens dedupes by them: the same token again returns the same run.
    @Test func anUnconfirmedStartOnAHostWithoutEchoedTokensReusesTheToken() async throws {
        let performer = WorkflowPerformer()
        performer.failures[.workflowsRunsStart] = [WorkspaceClientError.outcomeUnknown]
        performer.answers[.workflowsRunsList] = ["runs": .array([])]
        performer.answers[.workflowsRunsStart] = ["run": .object(["id": .string("mine"), "state": .string("planned")])]
        let client = DirectHermesWorkflowsClient(currentWorkspace: { performer })
        let run = try await client.startRun(workflowID: "wf-1", revision: 4, inputs: [:], clientRunToken: "token-1")
        #expect(run.id == "mine")
        #expect(performer.payloads(.workflowsRunsStart).map { $0["clientRunToken"] } == [.string("token-1"), .string("token-1")])
    }

    /// A sign-off whose answer is lost is read back from the run.
    @Test func anUnconfirmedSignoffReadsTheRunBack() async throws {
        let performer = WorkflowPerformer()
        performer.failures[.workflowsRunsSignoff] = [WorkspaceClientError.outcomeUnknown]
        var detail = Samples.runDetail
        var run = try #require(detail["run"]?.object)
        run["state"] = .string("succeeded")
        detail["run"] = .object(run)
        performer.answers[.workflowsRunsGet] = detail
        let client = DirectHermesWorkflowsClient(currentWorkspace: { performer })
        let result = try await client.signoff(runID: "run-14", stageKey: "signoff", decision: .approve,
                                              artifactSHA256: Samples.sha, notes: "")
        #expect(result.state == .succeeded)
        #expect(performer.calls(.workflowsRunsSignoff) == 1, "The sign-off isn't sent twice")
        #expect(performer.payloads(.workflowsRunsSignoff).first?["artifactSha256"] == .string(Samples.sha))
    }

    @Test func availabilityComesFromThePluginsFeatures() async throws {
        let performer = WorkflowPerformer()
        performer.answers[.nativeContext] = ["features": .array([.string("native-context-v1"), .string("native-workflows-v1")])]
        let client = DirectHermesWorkflowsClient(currentWorkspace: { performer })
        #expect(try await client.isAvailable())
        #expect(try await client.support() == .available(canEdit: false), "An older plugin shows the flow as it is")
        performer.answers[.nativeContext] = ["features": .array([.string("native-workflows-v1"),
                                                                 .string("native-workflows-edit-v1")])]
        #expect(try await client.support() == .available(canEdit: true))
        performer.answers[.nativeContext] = ["features": .array([.string("native-context-v1")])]
        #expect(try await client.isAvailable() == false)
        #expect(try await client.support() == .missing)
    }

    /// Files come in pieces and must add up to exactly the file that was asked for.
    @Test func artifactsDownloadInPiecesAndMustMatchTheirFingerprint() async throws {
        let text = String(repeating: "Line of the draft.\n", count: 12_000)
        let data = Data(text.utf8)
        let sha = WorkflowArtifactReader.sha256(data)
        let client = ChunkClient(files: [sha: data])
        let read = try await WorkflowArtifactReader.read(client: client, runID: "run", sha256: sha)
        #expect(read == data)
        #expect(client.reads.count == Int((Double(data.count) / Double(WorkflowArtifactReader.chunkBytes)).rounded(.up)))
        #expect(client.reads.allSatisfy { $0.length <= 98_304 })

        let wrong = String(repeating: "0", count: 64)
        let liar = ChunkClient(files: [wrong: data])
        await #expect(throws: WorkspaceClientError.invalidResponse) {
            try await WorkflowArtifactReader.read(client: liar, runID: "run", sha256: wrong)
        }
    }
}

// MARK: - Store, run and editor

@MainActor
struct WorkflowsStoreTests {
    /// The home asks every 15 seconds while it's on screen, and never when it isn't.
    @Test func homePollingStopsOffScreen() async throws {
        let client = CountingClient()
        let store = WorkflowsStore(client: client, pollInterval: .milliseconds(20))
        store.setOnScreen(true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(client.listCalls >= 2)
        store.setOnScreen(false)
        try await Task.sleep(for: .milliseconds(40))
        let stopped = client.listCalls
        try await Task.sleep(for: .milliseconds(150))
        #expect(client.listCalls == stopped, "No calls once the home is off screen")
        #expect(store.state == .loaded && store.workflows.count == 4)
    }

    /// A run polls every 2 seconds while it works, stops when it waits for you,
    /// and stops when it leaves the screen.
    @Test func runPollingFollowsTheRunAndTheScreen() async throws {
        let client = CountingClient()
        client.runState = .running
        let model = WorkflowRunModel(runID: "run-15", client: client, pollInterval: .milliseconds(20))
        model.setOnScreen(true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.isPolling && client.runCalls >= 3)
        model.setOnScreen(false)
        #expect(!model.isPolling)
        let stopped = client.runCalls
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.runCalls == stopped)

        client.runState = .waitingForYou
        model.setOnScreen(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.isPolling, "Nothing changes by itself while it waits for you")
    }

    /// Controls send the version the screen showed; a run that moved on says so plainly.
    @Test func controlsSendTheRunsVersion() async throws {
        let client = CountingClient()
        client.runState = .needsAttention
        let model = WorkflowRunModel(runID: "run-12", client: client)
        await model.load()
        client.controlError = WorkspaceClientError.rejected(code: "run_conflict")
        await model.perform(.retry)
        #expect(client.controls.first?.version == 3 && client.controls.first?.action == .retry)
        #expect(model.message?.contains("changed") == true)
    }

    /// Approving sends exactly the file on screen; a file that changed is shown again, not approved.
    @Test func approvingSendsTheExactFileAndAStaleOneIsShownAgain() async throws {
        let demo = DemoWorkflowsClient(delays: false)
        let model = WorkflowRunModel(runID: "run-14", client: demo)
        await model.load()
        #expect(await model.signoff(.approve, notes: "") == false, "Nothing is approved before the file is read")
        await model.loadSignoffFile()
        #expect(model.signoffText?.contains("Honest beats optimistic") == true)
        #expect(model.previousText?.contains("What it costs") == true, "The earlier version is there for Changes")
        #expect(await model.signoff(.changes, notes: "  ") == false, "Changes need notes")
        #expect(await model.signoff(.approve, notes: ""))
        #expect(model.summary?.state == .succeeded)
        #expect(model.detail?.approvedFile != nil)

        let stale = StaleSignoffClient(base: DemoWorkflowsClient(delays: false))
        let staleModel = WorkflowRunModel(runID: "run-14", client: stale)
        await staleModel.load()
        await staleModel.loadSignoffFile()
        #expect(await staleModel.signoff(.approve, notes: "") == false)
        #expect(staleModel.message?.contains("changed") == true)
        #expect(staleModel.summary?.state == .waitingForYou)
    }

    @Test func editorSavesFromItsDraftVersionAndRunsWithOneToken() async throws {
        let demo = DemoWorkflowsClient(delays: false)
        let editor = WorkflowEditorModel(workflowID: "wf-research", client: demo)
        await editor.load()
        #expect(editor.baseDraftVersion == 9 && editor.canRun)
        editor.definition?.stages[0].title = "Research well"
        #expect(editor.isDirty)
        let run = await editor.run(inputs: ["topic": .string("Made-up topic")])
        #expect(run?.state == .planned)
        #expect(editor.baseDraftVersion == 10 && !editor.isDirty)
        #expect(editor.detail?.latestRevision == 5, "A changed draft is published before it runs")

        // Someone else saved meanwhile: the newest version comes back instead of overwriting it.
        let other = WorkflowEditorModel(workflowID: "wf-research", client: demo)
        await other.load()
        _ = try await demo.saveDraft(workflowID: "wf-research", baseDraftVersion: 10,
                                     definition: try #require(other.definition))
        other.definition?.name = "Mine"
        #expect(await other.save() == false)
        #expect(other.message?.contains("another device") == true)
        #expect(other.baseDraftVersion == 11)
    }

    @Test func unboundRolesStopARun() async throws {
        let editor = WorkflowEditorModel(workflowID: "wf-captions", client: DemoWorkflowsClient(delays: false))
        await editor.load()
        #expect(editor.unboundRoles.map(\.key) == ["captioner", "checker"])
        #expect(!editor.canRun)
        await editor.bind(role: "captioner", agentID: "home")
        await editor.bind(role: "checker", agentID: "finance")
        #expect(editor.unboundRoles.isEmpty && editor.canRun)
    }

    /// The host's check from before an agent was chosen says "Choose an agent
    /// for …"; choosing one clears it at once, and roles no stage uses don't count.
    @Test func choosingAnAgentClearsTheOldRoleProblem() async throws {
        let editor = WorkflowEditorModel(workflowID: "wf-captions", client: DemoWorkflowsClient(delays: false))
        await editor.load()
        #expect(editor.issues.filter { $0.code == "role_unbound" }.count == 2)
        await editor.bind(role: "captioner", agentID: "home")
        await editor.bind(role: "checker", agentID: "finance")
        #expect(!editor.issues.contains { $0.code == "role_unbound" })
        #expect(editor.canRun)
        editor.addRole(named: "Spare")
        #expect(editor.unboundRoles.isEmpty && editor.canRun, "A role no stage uses doesn't stop a run")
    }

    /// Picking an agent on a new stage makes its role, saves it, and chooses the agent for it.
    @Test func pickingAnAgentOnAStageMakesItsRole() async throws {
        let editor = WorkflowEditorModel(workflowID: "wf-captions", client: DemoWorkflowsClient(delays: false),
                                         canEditFlow: true)
        await editor.load()
        await editor.bind(role: "captioner", agentID: "home")
        await editor.bind(role: "checker", agentID: "finance")
        var stage = try #require(editor.addStage(.agent, after: nil))
        stage.title = "Polish"
        stage.instructions = "Polish the captions."
        let shared = stage.role
        stage = await editor.assign(agentID: "work", to: stage)
        #expect(editor.message == nil)
        #expect(stage.role != shared, "Another stage's role isn't taken over")
        #expect(editor.definition?.role(stage.role)?.label == "Polish")
        #expect(editor.agentID(for: stage.role) == "work")
        // The same agent on another stage shares its role.
        var next = try #require(editor.addStage(.agent, after: nil))
        next = await editor.assign(agentID: "work", to: next)
        #expect(next.role == stage.role)
        #expect(!editor.issues.contains { $0.code == "role_unbound" })
    }

    /// A schedule saves through the trigger route: the draft is published first, and
    /// a workflow that never ran can't be scheduled without that.
    @Test func schedulingPublishesTheDraftThenSavesTheTrigger() async throws {
        let demo = DemoWorkflowsClient(delays: false)
        let editor = WorkflowEditorModel(workflowID: "wf-research", client: demo)
        await editor.load()
        #expect(editor.trigger == .manual)
        editor.definition?.stages[0].title = "Research well"
        let schedule = WorkflowTrigger.schedule("0 9 * * 1-5", inputs: ["topic": .string("Made-up topic")])
        #expect(await editor.setTrigger(schedule))
        #expect(editor.trigger == schedule)
        #expect(!editor.isDirty && editor.detail?.latestRevision == 5, "What's on screen is what runs")
        #expect(await editor.setTrigger(.schedule("tomorrow", inputs: [:])) == false)
        #expect(editor.message?.contains("schedule") == true)
        #expect(await editor.setTrigger(.manual))
        #expect(try await demo.workflow(id: "wf-research", revision: .draft).trigger == .manual)
    }

    @Test func triggersDecodeAndStageDetailsCarryWhatTheyUsed() throws {
        #expect(WorkflowTrigger(json: ["kind": .string("manual")]) == .manual)
        let scheduled = WorkflowTrigger(json: ["kind": .string("schedule"), "schedule": .string("30 7 * * *"),
                                               "inputs": .object(["topic": .string("x")]), "jobId": .string("j")])
        #expect(scheduled == .schedule("30 7 * * *", inputs: ["topic": .string("x")]))
        #expect(WorkflowTrigger(json: ["kind": .string("webhook")]) == nil, "Unknown kinds aren't guessed")
        #expect(WorkflowTrigger(json: scheduled?.json) == scheduled)
        let stage = try #require(WorkflowRunStage(json: [
            "key": .string("signoff"), "kind": .string("signoff"), "uses": .array([.string("draft.draft")]),
            "decisions": .array([.object(["iteration": .integer(2), "decision": .string("approve"),
                                          "notes": .string(""), "decidedAt": .string("2026-01-02T03:04:05Z")])]),
        ]))
        #expect(stage.uses == ["draft.draft"] && stage.decisions.first?.decision == "approve")
        #expect(WorkflowRunStagePage.signoffWords(try #require(stage.decisions.first)) == "Approved by you (version 2)")
    }

    @Test func pickerSchedulesComeBackFromTheirCronExpressions() throws {
        let zone = "UTC"
        let time = DateComponents(hour: 9, minute: 30)
        for input in [ScheduleInput.daily(time: time, timeZoneID: zone),
                      .repeating(days: [.monday, .tuesday, .wednesday, .thursday, .friday], time: time, timeZoneID: zone),
                      .repeating(days: [.sunday, .saturday], time: time, timeZoneID: zone),
                      .monthly(day: 15, time: time, timeZoneID: zone)] {
            let cron = try ScheduleRequestBuilder.hermesRequest(for: input)
            let back = try #require(ScheduleRequestBuilder.input(forCron: cron, timeZoneID: zone))
            #expect(try ScheduleRequestBuilder.hermesRequest(for: back) == cron)
        }
        #expect(ScheduleRequestBuilder.input(forCron: "*/5 * * * *", timeZoneID: zone) == nil)
        #expect(ScheduleRequestBuilder.input(forCron: "0 9 * * 1-5", timeZoneID: zone)
                == .repeating(days: [.monday, .tuesday, .wednesday, .thursday, .friday], time: time.with(minute: 0),
                              timeZoneID: zone))
    }

    @Test func theTriggerRouteIsAPluginRoute() {
        #expect(DirectHermesNativePluginClient.supports(.workflowsTriggerSet))
        #expect(DirectHermesNativePluginClient.workflowsTriggerFeature == "native-workflows-trigger-v1")
    }

    /// Workflows is remembered per computer: coming back keeps the row, another computer asks again.
    @Test func availabilityIsPerHost() async throws {
        let defaults = try #require(UserDefaults(suiteName: "workflows-availability-\(UUID().uuidString)"))
        let availability = WorkflowsAvailability(defaults: defaults, retryDelays: [])
        availability.use(host: "host-a")
        await availability.check { .available(canEdit: true) }
        #expect(availability.isAvailable == true && availability.support?.canEdit == true)
        #expect(availability.use(host: "host-b"))
        #expect(availability.isAvailable == nil)
        await availability.check { throw WorkspaceClientError.transportUnavailable }
        #expect(availability.isAvailable == nil, "A failed check doesn't decide")
        availability.use(host: "host-a")
        #expect(availability.isAvailable == true)
        #expect(availability.use(host: "host-a") == false)
    }

    /// A stage's own chat belongs to its run: Sessions, recents and widgets leave it out.
    @Test func workflowStageChatsStayOutOfChatLists() async throws {
        let chat = SessionRecord(id: "chat", kind: .direct, agentIDs: ["finance"], title: "A chat",
                                 remoteSource: "tui", updatedAt: Date(timeIntervalSince1970: 10), hasAcceptedMessage: true)
        let stage = SessionRecord(id: "stage", kind: .direct, agentIDs: ["finance"], title: "Draft stage",
                                  remoteSource: "workflow", updatedAt: Date(timeIntervalSince1970: 20), hasAcceptedMessage: true)
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [chat, stage])
        #expect(catalog.recentSummaries.map(\.id) == ["chat"])
        #expect(catalog.recentSummaries(includeCronSessions: true).map(\.id) == ["chat"])
        let sessions = SessionsModel(fixtures: [chat, stage], calendar: Calendar(identifier: .gregorian))
        #expect(sessions.filteredSections.flatMap(\.sessions).map(\.id) == ["chat"])

        var writes: [BighelpWidgetSnapshot] = []
        let agents = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
                                         defaults: isolatedDefaults())
        try await agents.load()
        let publisher = BighelpWidgetSnapshotPublisher(sessions: catalog, scheduledTasks: nil, agents: agents,
                                                       interval: .milliseconds(1), write: { writes.append($0) })
        publisher.publishNow()
        #expect(writes.last?.sessions.map(\.id) == ["chat"])
        publisher.retire()
    }

    /// Demo mode has runs in every state, so screens and UI tests work without a host.
    @Test func demoCoversEveryRunState() async throws {
        let demo = DemoWorkflowsClient(delays: false)
        let all = try await demo.runs(workflowID: nil, filter: .all, before: nil, limit: 50).runs
        let states = Set(all.map(\.state))
        for state: WorkflowRunState in [.planned, .running, .checkingOutput, .waitingForYou, .needsAttention,
                                        .succeeded, .failed, .cancelled] {
            #expect(states.contains(state), "\(state)")
        }
        // A run started in the app goes through launched, running, checking and accepted on its own.
        let run = try await demo.startRun(workflowID: "wf-research", revision: 4, inputs: [:], clientRunToken: "t")
        var seen: Set<WorkflowRunState> = []
        for _ in 0..<40 {
            let detail = try await demo.run(id: run.id)
            seen.insert(detail.summary.state)
            if detail.summary.state == .waitingForYou { break }
        }
        #expect(seen.isSuperset(of: [.running, .checkingOutput, .accepted, .waitingForYou]))
    }
}

// MARK: - Fakes

@MainActor
enum Samples {
    static let sha = "4f1c" + String(repeating: "0", count: 56) + "9a2e"
    static let previous = "1b2c" + String(repeating: "1", count: 56) + "3d4e"

    static let definition: WorkflowJSON = DemoWorkflowsClient.researchDraftReview.json

    static let status: WorkflowJSON = [
        "coordinator": .object(["state": .string("online"), "heartbeatAt": .string("2026-10-04T10:57:12Z"),
                                "epoch": .integer(7)]),
        "slots": .object(["used": .integer(1), "total": .integer(2)]),
        "survivesAppClose": .boolean(true), "runner": .object(["available": .boolean(true)]),
        "hostName": .string("studio"),
    ]

    static let list: WorkflowJSON = [
        "workflows": .array([
            .object(["id": .string("wf-1"), "name": .string("Research, draft, review"), "revision": .integer(4),
                     "hasDraft": .boolean(false), "stageCount": .integer(6), "needsSetupRoles": .array([]),
                     "valid": .boolean(true), "lastRunAt": .integer(1_790_000_000)]),
            .object(["id": .string("wf-2"), "name": .string("Photo set captions"), "revision": .null,
                     "hasDraft": .boolean(true), "stageCount": .integer(4),
                     "needsSetupRoles": .array([.string("captioner"), .string("checker")]),
                     "valid": .boolean(false), "lastRunAt": .null]),
        ]),
        "waiting": .array([.object(["id": .string("run-14"), "number": .integer(14), "workflowId": .string("wf-1"),
                                    "state": .string("waiting_for_you"),
                                    "waiting": .object(["kind": .string("signoff"), "stageKey": .string("signoff"),
                                                        "since": .string("2026-10-04T10:00:00.250Z")])])]),
        "active": .array([.object(["id": .string("run-15"), "number": .integer(15), "state": .string("running"),
                                   "stageKey": .string("draft"), "stageTitle": .string("Draft")])]),
    ]

    static let runDetail: WorkflowJSON = [
        "run": .object([
            "id": .string("run-14"), "number": .integer(14), "workflowId": .string("wf-1"),
            "workflowName": .string("Research, draft, review"), "revision": .integer(4),
            "state": .string("waiting_for_you"), "stageKey": .string("signoff"), "version": .integer(3),
            "waiting": .object(["kind": .string("signoff"), "stageKey": .string("signoff")]),
            "inputs": .object(["topic": .string("Made up")]),
            "stages": .array([
                .object(["key": .string("draft"), "kind": .string("agent"), "title": .string("Draft"),
                         "iteration": .integer(2), "state": .string("accepted"), "agentId": .string("home"),
                         "attempts": .array([.object(["id": .integer(9), "number": .integer(1), "state": .string("accepted"),
                                                      "tokens": .object(["in": .integer(200), "out": .integer(100)])])])]),
                .object(["key": .string("signoff"), "kind": .string("signoff"), "title": .string("Sign-off"),
                         "state": .string("waiting_for_you")]),
            ]),
            "outputs": .array([
                .object(["stageKey": .string("draft"), "iteration": .integer(1), "name": .string("draft"),
                         "type": .string("markdown_file"), "sha256": .string(previous), "bytes": .integer(10)]),
                .object(["stageKey": .string("draft"), "iteration": .integer(2), "name": .string("draft"),
                         "type": .string("markdown_file"), "sha256": .string(sha), "bytes": .integer(12),
                         "wordCount": .integer(912)]),
            ]),
            "signoff": .object([
                "stageKey": .string("signoff"),
                "artifact": .object(["stageKey": .string("draft"), "name": .string("draft"), "sha256": .string(sha),
                                     "iteration": .integer(2)]),
                "reviewNotes": .object(["decision": .string("pass"), "notes": .array([
                    .object(["severity": .string("minor"), "text": .string("Tighten the intro.")]),
                    .object(["severity": .string("minor"), "text": .string("Define host.")]),
                ])]),
                "history": .array([.object(["stageKey": .string("review"), "title": .string("Review v1"),
                                            "outcome": .string("changes")])]),
            ]),
            "tokens": .object(["in": .integer(200), "out": .integer(100)]),
            "allowedActions": .array([.string("cancel")]),
        ]),
    ]
}

/// Checks one contract vector by the shape its top-level keys say it has.
@MainActor
enum WorkflowVectorCheck {
    static func check(_ value: BighelpJSONValue, name: String) throws {
        guard let object = value.object else { return }
        // A vector may wrap the body: {"request": …, "response": …}.
        let body = object["response"]?.object ?? object["body"]?.object ?? object
        if body["coordinator"] != nil { _ = WorkflowStatus(json: body) }
        if let workflows = body["workflows"]?.array {
            #expect(WorkflowsList(json: body).workflows.count == workflows.count, "\(name)")
        }
        if body["workflow"] != nil { _ = try WorkflowDetail(json: body) }
        if let runs = body["runs"]?.array {
            #expect(WorkflowRunPage(json: body).runs.count == runs.count, "\(name)")
        }
        if let run = body["run"]?.object {
            if run["stages"] != nil { _ = try WorkflowRunDetail(json: body) }
            #expect(WorkflowRunSummary(json: run) != nil, "\(name)")
        }
        if let events = body["events"]?.array {
            #expect(WorkflowEventPage(json: body, after: 0).events.count == events.count, "\(name)")
        }
        if body["data"] != nil, body["sha256"] != nil { _ = try WorkflowArtifactChunk(json: body) }
        if let definition = body["definition"]?.object { _ = WorkflowDefinition(json: definition) }
        if let templates = body["templates"]?.array {
            #expect(templates.compactMap { $0.object.flatMap(WorkflowTemplate.init(json:)) }.count == templates.count, "\(name)")
        }
    }
}

@MainActor
final class WorkflowPerformer: WorkspaceOperationPerforming {
    var owner: WorkspaceOwner? = WorkspaceOwner(authority: try! .fixture(id: "workflows"),
                                                authenticationGeneration: UUID(), connectionGeneration: UUID())
    var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [:]) }
    var answers: [WorkspaceOperation: WorkflowJSON] = [:]
    var failures: [WorkspaceOperation: [any Error]] = [:]
    private(set) var log: [(WorkspaceOperation, WorkflowJSON)] = []

    func calls(_ operation: WorkspaceOperation) -> Int { log.filter { $0.0 == operation }.count }
    func payloads(_ operation: WorkspaceOperation) -> [WorkflowJSON] { log.filter { $0.0 == operation }.map(\.1) }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        log.append((operation, payload))
        if var queue = failures[operation], !queue.isEmpty {
            let error = queue.removeFirst()
            failures[operation] = queue
            throw error
        }
        guard let answer = answers[operation] else { throw WorkspaceClientError.invalidResponse }
        return answer
    }
}

/// Serves stored files in pieces, like artifacts/read.
@MainActor
private final class ChunkClient: WorkflowsClient {
    let files: [String: Data]
    var reads: [(offset: Int, length: Int)] = []
    init(files: [String: Data]) { self.files = files }

    func readArtifact(runID: String, sha256: String, offset: Int, length: Int) async throws -> WorkflowArtifactChunk {
        reads.append((offset, length))
        guard let data = files[sha256] else { throw WorkspaceClientError.rejected(code: "not_found") }
        let end = min(data.count, offset + length)
        return WorkflowArtifactChunk(sha256: sha256, offset: offset, total: data.count,
                                     data: data.subdata(in: offset..<end), done: end >= data.count)
    }

    func support() async throws -> WorkflowsSupport { .available(canEdit: true) }
    func saveTemplate(workflowID: String, name: String, description: String?) async throws -> String { "" }
    func deleteTemplate(id: String) async throws {}
    func pin(workflowID: String, pinned: Bool) async throws -> Bool { pinned }
    func unarchive(workflowID: String) async throws {}
    func setTrigger(workflowID: String, trigger: WorkflowTrigger) async throws -> WorkflowTrigger { trigger }
    func status() async throws -> WorkflowStatus { throw WorkspaceClientError.invalidResponse }
    func list(includeArchived: Bool) async throws -> WorkflowsList { throw WorkspaceClientError.invalidResponse }
    func workflow(id: String, revision: WorkflowRevisionRef) async throws -> WorkflowDetail { throw WorkspaceClientError.invalidResponse }
    func saveDraft(workflowID: String?, baseDraftVersion: Int, definition: WorkflowDefinition) async throws
        -> (workflowID: String, draftVersion: Int, validation: WorkflowValidation) { throw WorkspaceClientError.invalidResponse }
    func validate(workflowID: String) async throws -> WorkflowValidation { throw WorkspaceClientError.invalidResponse }
    func publish(workflowID: String, draftVersion: Int) async throws -> Int { throw WorkspaceClientError.invalidResponse }
    func bind(workflowID: String, role: String, agentID: String?) async throws -> [WorkflowBinding] { [] }
    func archive(workflowID: String) async throws {}
    func startRun(workflowID: String, revision: Int, inputs: WorkflowJSON, clientRunToken: String) async throws
        -> WorkflowRunSummary { throw WorkspaceClientError.invalidResponse }
    func runs(workflowID: String?, filter: WorkflowRunFilter, before: String?, limit: Int) async throws -> WorkflowRunPage {
        WorkflowRunPage(runs: [], hasMore: false)
    }
    func run(id: String) async throws -> WorkflowRunDetail { throw WorkspaceClientError.invalidResponse }
    func events(runID: String, after: Int, limit: Int) async throws -> WorkflowEventPage {
        WorkflowEventPage(events: [], cursor: after, hasMore: false)
    }
    func control(runID: String, action: WorkflowRunAction, expectedVersion: Int) async throws -> WorkflowRunSummary {
        throw WorkspaceClientError.invalidResponse
    }
    func signoff(runID: String, stageKey: String, decision: WorkflowSignoffDecision, artifactSHA256: String,
                 notes: String) async throws -> WorkflowRunSummary { throw WorkspaceClientError.invalidResponse }
    func templates() async throws -> [WorkflowTemplate] { [] }
    func useTemplate(id: String) async throws -> String { "" }
}

/// Counts what the screens ask for; its one run is in whatever state the test sets.
@MainActor
private final class CountingClient: WorkflowsClient {
    let demo = DemoWorkflowsClient(delays: false)
    var listCalls = 0
    var runCalls = 0
    var runState: WorkflowRunState = .running
    var controlError: (any Error)?
    var controls: [(action: WorkflowRunAction, version: Int)] = []

    func support() async throws -> WorkflowsSupport { .available(canEdit: true) }
    func saveTemplate(workflowID: String, name: String, description: String?) async throws -> String { "" }
    func deleteTemplate(id: String) async throws {}
    func pin(workflowID: String, pinned: Bool) async throws -> Bool { pinned }
    func unarchive(workflowID: String) async throws {}
    func setTrigger(workflowID: String, trigger: WorkflowTrigger) async throws -> WorkflowTrigger { trigger }
    func status() async throws -> WorkflowStatus { try await demo.status() }
    func list(includeArchived: Bool) async throws -> WorkflowsList {
        listCalls += 1
        return try await demo.list(includeArchived: includeArchived)
    }
    func workflow(id: String, revision: WorkflowRevisionRef) async throws -> WorkflowDetail {
        try await demo.workflow(id: id, revision: revision)
    }
    func saveDraft(workflowID: String?, baseDraftVersion: Int, definition: WorkflowDefinition) async throws
        -> (workflowID: String, draftVersion: Int, validation: WorkflowValidation) {
        try await demo.saveDraft(workflowID: workflowID, baseDraftVersion: baseDraftVersion, definition: definition)
    }
    func validate(workflowID: String) async throws -> WorkflowValidation { try await demo.validate(workflowID: workflowID) }
    func publish(workflowID: String, draftVersion: Int) async throws -> Int {
        try await demo.publish(workflowID: workflowID, draftVersion: draftVersion)
    }
    func bind(workflowID: String, role: String, agentID: String?) async throws -> [WorkflowBinding] { [] }
    func archive(workflowID: String) async throws {}
    func startRun(workflowID: String, revision: Int, inputs: WorkflowJSON, clientRunToken: String) async throws
        -> WorkflowRunSummary {
        try await demo.startRun(workflowID: workflowID, revision: revision, inputs: inputs, clientRunToken: clientRunToken)
    }
    func runs(workflowID: String?, filter: WorkflowRunFilter, before: String?, limit: Int) async throws -> WorkflowRunPage {
        try await demo.runs(workflowID: workflowID, filter: filter, before: before, limit: limit)
    }
    func run(id: String) async throws -> WorkflowRunDetail {
        runCalls += 1
        var detail = try WorkflowRunDetail(json: Samples.runDetail)
        detail.summary.state = runState
        return detail
    }
    func events(runID: String, after: Int, limit: Int) async throws -> WorkflowEventPage {
        WorkflowEventPage(events: [], cursor: after, hasMore: false)
    }
    func control(runID: String, action: WorkflowRunAction, expectedVersion: Int) async throws -> WorkflowRunSummary {
        controls.append((action, expectedVersion))
        if let controlError { throw controlError }
        return try await run(id: runID).summary
    }
    func signoff(runID: String, stageKey: String, decision: WorkflowSignoffDecision, artifactSHA256: String,
                 notes: String) async throws -> WorkflowRunSummary { throw WorkspaceClientError.invalidResponse }
    func readArtifact(runID: String, sha256: String, offset: Int, length: Int) async throws -> WorkflowArtifactChunk {
        throw WorkspaceClientError.invalidResponse
    }
    func templates() async throws -> [WorkflowTemplate] { [] }
    func useTemplate(id: String) async throws -> String { "" }
}

/// The demo, except the file changed on the host after it was read.
@MainActor
private final class StaleSignoffClient: WorkflowsClient {
    let base: DemoWorkflowsClient
    init(base: DemoWorkflowsClient) { self.base = base }

    func signoff(runID: String, stageKey: String, decision: WorkflowSignoffDecision, artifactSHA256: String,
                 notes: String) async throws -> WorkflowRunSummary {
        throw WorkspaceClientError.rejected(code: "approval_stale")
    }
    func support() async throws -> WorkflowsSupport { .available(canEdit: true) }
    func saveTemplate(workflowID: String, name: String, description: String?) async throws -> String { "" }
    func deleteTemplate(id: String) async throws {}
    func pin(workflowID: String, pinned: Bool) async throws -> Bool { pinned }
    func unarchive(workflowID: String) async throws {}
    func setTrigger(workflowID: String, trigger: WorkflowTrigger) async throws -> WorkflowTrigger { trigger }
    func status() async throws -> WorkflowStatus { try await base.status() }
    func list(includeArchived: Bool) async throws -> WorkflowsList { try await base.list(includeArchived: includeArchived) }
    func workflow(id: String, revision: WorkflowRevisionRef) async throws -> WorkflowDetail {
        try await base.workflow(id: id, revision: revision)
    }
    func saveDraft(workflowID: String?, baseDraftVersion: Int, definition: WorkflowDefinition) async throws
        -> (workflowID: String, draftVersion: Int, validation: WorkflowValidation) {
        try await base.saveDraft(workflowID: workflowID, baseDraftVersion: baseDraftVersion, definition: definition)
    }
    func validate(workflowID: String) async throws -> WorkflowValidation { try await base.validate(workflowID: workflowID) }
    func publish(workflowID: String, draftVersion: Int) async throws -> Int { 1 }
    func bind(workflowID: String, role: String, agentID: String?) async throws -> [WorkflowBinding] { [] }
    func archive(workflowID: String) async throws {}
    func startRun(workflowID: String, revision: Int, inputs: WorkflowJSON, clientRunToken: String) async throws
        -> WorkflowRunSummary { throw WorkspaceClientError.invalidResponse }
    func runs(workflowID: String?, filter: WorkflowRunFilter, before: String?, limit: Int) async throws -> WorkflowRunPage {
        try await base.runs(workflowID: workflowID, filter: filter, before: before, limit: limit)
    }
    func run(id: String) async throws -> WorkflowRunDetail { try await base.run(id: id) }
    func events(runID: String, after: Int, limit: Int) async throws -> WorkflowEventPage {
        try await base.events(runID: runID, after: after, limit: limit)
    }
    func control(runID: String, action: WorkflowRunAction, expectedVersion: Int) async throws -> WorkflowRunSummary {
        try await base.control(runID: runID, action: action, expectedVersion: expectedVersion)
    }
    func readArtifact(runID: String, sha256: String, offset: Int, length: Int) async throws -> WorkflowArtifactChunk {
        try await base.readArtifact(runID: runID, sha256: sha256, offset: offset, length: length)
    }
    func templates() async throws -> [WorkflowTemplate] { [] }
    func useTemplate(id: String) async throws -> String { "" }
}

/// The plugin's HTTP side, for route tests.
@MainActor
final class NativeHTTP: DirectHermesNativeHTTP {
    struct Call {
        let request: DirectHermesHTTPRequest
        let guardValue: DirectHermesNativeRequestGuard?
    }
    var calls: [Call] = []
    var handler: ((DirectHermesHTTPRequest, DirectHermesNativeRequestGuard?) throws -> DirectHermesHTTP.Response)?

    func nativeResponse(_ request: DirectHermesHTTPRequest,
                        requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response {
        calls.append(Call(request: request, guardValue: requestGuard))
        guard let handler else { throw WorkspaceClientError.transportUnavailable }
        return try handler(request, requestGuard)
    }

    static let etag = "\"sha256:" + String(repeating: "a", count: 64) + "\""

    static func owner() throws -> WorkspaceOwner {
        WorkspaceOwner(authority: try .direct(endpointIdentity: "https://host.example", providerID: "basic", userID: "person"),
                       authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    static func context(features: [String]) -> [String: BighelpJSONValue] {
        [
            "schemaVersion": .integer(1), "pluginVersion": .string("test"), "runtimeId": .string("runtime-test"),
            "servingProfileId": .string("default"),
            "principal": .object(["provider": .string("basic"), "userId": .string("person"), "displayName": .null]),
            "features": .array((["native-context-v1", "serving-profile-v1"] + features).map(BighelpJSONValue.string)),
        ]
    }

    static func response(_ request: DirectHermesHTTPRequest, status: Int = 200,
                         body: [String: BighelpJSONValue], headers: [String: String]? = nil) throws -> DirectHermesHTTP.Response {
        let url = try #require(URL(string: "https://host.example" + request.path))
        var fields = headers ?? ["ETag": etag]
        fields["Cache-Control"] = "no-store"
        if fields["ETag"] == nil { fields["ETag"] = etag }
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                    headerFields: fields))
        return .init(http: response, body: try JSONEncoder().encode(BighelpJSONValue.object(body)))
    }
}

private extension DateComponents {
    func with(minute: Int) -> DateComponents { DateComponents(hour: hour, minute: minute) }
}
