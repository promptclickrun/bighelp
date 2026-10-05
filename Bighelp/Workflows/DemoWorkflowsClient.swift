import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Demo mode: made-up workflows and runs in every state, held in memory so
/// sign-off, Cancel, Try again and new runs behave like the real host. A run
/// you start moves one step each time it's read (with demo delays on, at
/// most every 3 seconds). Nothing here talks to a computer.
@MainActor
final class DemoWorkflowsClient: WorkflowsClient {
    static let shared = DemoWorkflowsClient()
    /// The second demo computer ("Studio Hermes", `-use-multi-host-fixtures`)
    /// has a plugin with Workflows, but its Hermes can't run them.
    static let cantRun = DemoWorkflowsClient(support: .unavailable(code: "chat_runner_missing"))

    /// The demo computer's client: `-demo-workflows-unavailable <code>` makes the
    /// first one say why it can't run workflows, and `-demo-workflows-read-only`
    /// gives it an older plugin without editing.
    static func forHost(_ hostID: String?) -> DemoWorkflowsClient {
        if hostID == "host-2" { return cantRun }
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-demo-workflows-unavailable"), arguments.indices.contains(flag + 1) {
            cantRun.supportValue = .unavailable(code: arguments[flag + 1])
            return cantRun
        }
        if arguments.contains("-demo-workflows-read-only") { shared.supportValue = .available(canEdit: false) }
        return shared
    }

    private struct Workflow {
        var id: String
        var definition: WorkflowDefinition
        var revision: Int?
        var draftVersion: Int
        var hasDraft: Bool
        var bindings: [String: String]
        var lastRunAt: Date?
        var archived = false
        var pinned = false
        var trigger: WorkflowTrigger = .manual
    }

    private struct Template {
        var template: WorkflowTemplate
        var definition: WorkflowDefinition
    }

    private struct Run {
        var summary: WorkflowRunSummary
        var stageIndex: Int
        var iteration: Int
        var inputs: WorkflowJSON
        var outputs: [WorkflowOutput]
        var history: [WorkflowSignoff.Step]
        var reviewNotes: [WorkflowSignoff.Note]
        var events: [WorkflowEvent]
        var scripted: Bool
        var lastStep: Date
        /// Ran on Hermes' fallback runner, which can't count tokens.
        var fallbackRunner = false
        /// A decision that ended the run on purpose, how, and its note.
        var ended: (stage: String, outcome: WorkflowStage.Ending.Outcome, note: String)?
    }

    private var workflows: [String: Workflow] = [:]
    private var order: [String] = []
    private var runs: [String: Run] = [:]
    private var files: [String: Data] = [:]
    private var nextRunNumber = 18
    private var nextEvent = 1_000
    private var nextWorkflow = 1
    private var yourTemplates: [Template] = []
    private let delays: Bool
    private let now = Date.now
    private var supportValue: WorkflowsSupport

    init(delays: Bool = !ProcessInfo.processInfo.arguments.contains("-disable-demo-delays"),
         support: WorkflowsSupport = .available(canEdit: true)) {
        self.delays = delays
        supportValue = support
        seed()
    }

    // MARK: WorkflowsClient

    func support() async throws -> WorkflowsSupport { supportValue }

    /// Like the plugin, routes this computer can't serve aren't there.
    private func requireRunnable() throws {
        guard case .available = supportValue else { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
    }

    private func requireEditing() throws {
        guard supportValue.canEdit else { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
    }

    func status() async throws -> WorkflowStatus {
        try requireRunnable()
        await pause()
        let busy = runs.values.filter { [.launched, .running].contains($0.summary.state) }.count
        return WorkflowStatus(coordinator: .online, heartbeatAt: Date.now.addingTimeInterval(-2), epoch: 7,
                              slotsUsed: min(busy, 2), slotsTotal: 2, runnerMode: .stream, hostName: Self.hostName)
    }

    /// `-demo-workflows-host-name <name>`: the name the computer gives itself (a long one, for layout tests).
    private static var hostName: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-demo-workflows-host-name"), arguments.indices.contains(flag + 1) else {
            return nil
        }
        return arguments[flag + 1]
    }

    func list(includeArchived: Bool) async throws -> WorkflowsList {
        await pause()
        try requireRunnable()
        let summaries = order.compactMap { workflows[$0] }.filter { includeArchived || !$0.archived }.map(summary)
        let all = runs.values.map(\.summary).sorted { $0.number > $1.number }
        return WorkflowsList(workflows: summaries,
                             waiting: all.filter { $0.state == .waitingForYou },
                             active: all.filter { $0.state.isWorking || $0.state == .needsAttention })
    }

    func workflow(id: String, revision: WorkflowRevisionRef) async throws -> WorkflowDetail {
        await pause()
        guard let workflow = workflows[id] else { throw WorkspaceClientError.rejected(code: "not_found") }
        return WorkflowDetail(id: id, name: workflow.definition.name, revision: workflow.revision,
                              draftVersion: workflow.draftVersion, definition: workflow.definition,
                              bindings: workflow.definition.roles.map {
                                  WorkflowBinding(role: $0.key, agentID: workflow.bindings[$0.key],
                                                  approvedAt: workflow.bindings[$0.key] == nil ? nil : now)
                              },
                              validation: validation(workflow), pinned: workflow.pinned, trigger: workflow.trigger)
    }

    func saveDraft(workflowID: String?, baseDraftVersion: Int,
                   definition: WorkflowDefinition) async throws -> (workflowID: String, draftVersion: Int, validation: WorkflowValidation) {
        await pause()
        guard let id = workflowID else {
            // Create from scratch.
            try requireEditing()
            nextWorkflow += 1
            let newID = "wf-new-\(nextWorkflow)"
            let workflow = Workflow(id: newID, definition: definition, revision: nil, draftVersion: 1, hasDraft: true,
                                    bindings: [:])
            workflows[newID] = workflow
            order.append(newID)
            return (newID, 1, validation(workflow))
        }
        guard var workflow = workflows[id] else { throw WorkspaceClientError.rejected(code: "not_found") }
        guard workflow.draftVersion == baseDraftVersion else { throw WorkspaceClientError.rejected(code: "draft_conflict") }
        workflow.definition = definition
        workflow.draftVersion += 1
        workflow.hasDraft = true
        workflows[id] = workflow
        return (id, workflow.draftVersion, validation(workflow))
    }

    func validate(workflowID: String) async throws -> WorkflowValidation {
        guard let workflow = workflows[workflowID] else { throw WorkspaceClientError.rejected(code: "not_found") }
        return validation(workflow)
    }

    func publish(workflowID: String, draftVersion: Int) async throws -> Int {
        await pause()
        guard var workflow = workflows[workflowID] else { throw WorkspaceClientError.rejected(code: "not_found") }
        guard workflow.draftVersion == draftVersion else { throw WorkspaceClientError.rejected(code: "draft_conflict") }
        guard validation(workflow).valid else { throw WorkspaceClientError.rejected(code: "not_valid") }
        workflow.revision = (workflow.revision ?? 0) + 1
        workflow.hasDraft = false
        workflows[workflowID] = workflow
        return workflow.revision ?? 1
    }

    func bind(workflowID: String, role: String, agentID: String?) async throws -> [WorkflowBinding] {
        await pause()
        guard var workflow = workflows[workflowID] else { throw WorkspaceClientError.rejected(code: "not_found") }
        // Like the host: only a role in the saved draft can have an agent.
        guard workflow.definition.role(role) != nil else { throw WorkspaceClientError.rejected(code: "role_not_found") }
        workflow.bindings[role] = agentID
        workflows[workflowID] = workflow
        return workflow.definition.roles.map { WorkflowBinding(role: $0.key, agentID: workflow.bindings[$0.key]) }
    }

    func archive(workflowID: String) async throws {
        workflows[workflowID]?.archived = true
    }

    func unarchive(workflowID: String) async throws {
        try requireEditing()
        await pause()
        guard workflows[workflowID] != nil else { throw WorkspaceClientError.rejected(code: "workflow_not_found") }
        workflows[workflowID]?.archived = false
    }

    func setTrigger(workflowID: String, trigger: WorkflowTrigger) async throws -> WorkflowTrigger {
        await pause()
        guard let workflow = workflows[workflowID] else { throw WorkspaceClientError.rejected(code: "workflow_not_found") }
        if case .schedule(let schedule, _) = trigger {
            // Like the host: a repeating cron schedule, for a workflow that has run before.
            guard schedule.split(separator: " ").count == 5 else { throw WorkspaceClientError.rejected(code: "schedule_invalid") }
            guard workflow.revision != nil else { throw WorkspaceClientError.rejected(code: "not_published") }
        }
        workflows[workflowID]?.trigger = trigger
        return trigger
    }

    func pin(workflowID: String, pinned: Bool) async throws -> Bool {
        try requireEditing()
        await pause()
        guard workflows[workflowID] != nil else { throw WorkspaceClientError.rejected(code: "workflow_not_found") }
        workflows[workflowID]?.pinned = pinned
        return pinned
    }

    func startRun(workflowID: String, revision: Int, inputs: WorkflowJSON,
                  clientRunToken: String) async throws -> WorkflowRunSummary {
        await pause()
        if let existing = runs.values.first(where: { $0.summary.clientRunToken == clientRunToken }) {
            return existing.summary
        }
        guard let workflow = workflows[workflowID], validation(workflow).valid else {
            throw WorkspaceClientError.rejected(code: "not_valid")
        }
        nextRunNumber += 1
        let id = "run-\(nextRunNumber)"
        let stages = workflow.definition.stages
        var run = Run(summary: WorkflowRunSummary(
            id: id, number: nextRunNumber, workflowID: workflowID, workflowName: workflow.definition.name,
            revision: revision, state: .planned, stageKey: stages.first?.key, stageTitle: stages.first?.title,
            stageState: .planned, stagesDone: 0, stageCount: stages.count, startedAt: .now, updatedAt: .now,
            version: 1, clientRunToken: clientRunToken),
            stageIndex: 0, iteration: 1, inputs: inputs, outputs: [], history: [], reviewNotes: [], events: [],
            scripted: true, lastStep: .now)
        log(&run, "accepted", nil, "Run accepted · rev \(revision) pinned")
        runs[id] = run
        workflows[workflowID]?.lastRunAt = .now
        return run.summary
    }

    func runs(workflowID: String?, filter: WorkflowRunFilter, before: String?, limit: Int) async throws -> WorkflowRunPage {
        await pause()
        let all = runs.values.map(\.summary)
            .filter { workflowID == nil || $0.workflowID == workflowID }
            .filter { run in
                switch filter {
                case .all: true
                case .active: run.state.isWorking
                case .forYou: run.state == .waitingForYou
                case .attention: [.needsAttention, .failed].contains(run.state)
                }
            }
            .sorted { $0.number > $1.number }
        let after = before.flatMap { id in all.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        let page = Array(all.dropFirst(after).prefix(limit))
        return WorkflowRunPage(runs: page, hasMore: after + page.count < all.count)
    }

    func run(id: String) async throws -> WorkflowRunDetail {
        await pause()
        guard var run = runs[id] else { throw WorkspaceClientError.rejected(code: "not_found") }
        if run.scripted, run.summary.state.isWorking, !delays || Date.now.timeIntervalSince(run.lastStep) >= 3 {
            advance(&run)
            runs[id] = run
        }
        return detail(run)
    }

    func events(runID: String, after: Int, limit: Int) async throws -> WorkflowEventPage {
        guard let run = runs[runID] else { throw WorkspaceClientError.rejected(code: "not_found") }
        let newer = run.events.filter { $0.seq > after }.prefix(limit)
        return WorkflowEventPage(events: Array(newer), cursor: newer.last?.seq ?? after,
                                 hasMore: run.events.filter { $0.seq > after }.count > newer.count)
    }

    func control(runID: String, action: WorkflowRunAction, expectedVersion: Int) async throws -> WorkflowRunSummary {
        await pause()
        guard var run = runs[runID] else { throw WorkspaceClientError.rejected(code: "not_found") }
        guard run.summary.version == expectedVersion else { throw WorkspaceClientError.rejected(code: "run_conflict") }
        switch action {
        case .cancel:
            guard !run.summary.state.isFinished else { throw WorkspaceClientError.rejected(code: "not_allowed") }
            run.summary.state = .cancelled
            run.summary.waiting = nil
            log(&run, "cancelled", run.summary.stageKey, "Run cancelled")
        case .retry:
            guard [.needsAttention, .failed].contains(run.summary.state) else {
                throw WorkspaceClientError.rejected(code: "not_allowed")
            }
            run.summary.state = .running
            run.summary.stageState = .running
            run.summary.attention = nil
            run.summary.failure = nil
            run.scripted = true
            run.lastStep = .now
            log(&run, "retry", run.summary.stageKey, "\(run.summary.stageTitle ?? "Stage") attempt 2 running")
        case .pause, .resume:
            throw WorkspaceClientError.rejected(code: "not_allowed")
        }
        run.summary.version += 1
        run.summary.updatedAt = .now
        runs[runID] = run
        return run.summary
    }

    func signoff(runID: String, stageKey: String, decision: WorkflowSignoffDecision,
                 artifactSHA256: String, notes: String) async throws -> WorkflowRunSummary {
        await pause()
        guard var run = runs[runID] else { throw WorkspaceClientError.rejected(code: "not_found") }
        guard run.summary.state == .waitingForYou, run.summary.waiting?.stageKey == stageKey else {
            throw WorkspaceClientError.rejected(code: "not_waiting")
        }
        guard currentFile(run)?.sha256 == artifactSHA256 else { throw WorkspaceClientError.rejected(code: "approval_stale") }
        let stages = workflows[run.summary.workflowID]?.definition.stages ?? []
        run.summary.waiting = nil
        run.summary.version += 1
        run.summary.updatedAt = .now
        switch decision {
        case .approve:
            run.summary.state = .succeeded
            run.summary.stageState = .accepted
            run.summary.stagesDone = run.summary.stageCount
            run.history.append(.init(index: run.history.count, stageKey: stageKey, title: "Approved by you",
                                     iteration: run.iteration, outcome: "approved", agentID: nil, durationMs: nil, notes: []))
            log(&run, "approved", stageKey, "Approved \(currentFile(run)?.name ?? "the file") · sha256 \(WorkflowSHA.short(artifactSHA256))")
        case .changes:
            let draft = stages.firstIndex { $0.key == "draft" } ?? 0
            run.iteration += 1
            run.stageIndex = draft
            run.summary.state = .running
            run.summary.stageKey = stages[safe: draft]?.key
            run.summary.stageTitle = stages[safe: draft]?.title
            run.summary.stageState = .running
            run.summary.stagesDone = draft
            run.reviewNotes = [.init(severity: "major", text: String(notes.prefix(300)))]
            run.history.append(.init(index: run.history.count, stageKey: stageKey, title: "You asked for changes",
                                     iteration: run.iteration - 1, outcome: "changes", agentID: nil, durationMs: nil,
                                     notes: run.reviewNotes))
            run.scripted = true
            run.lastStep = .now
            log(&run, "changes", stageKey, "You asked for changes · draft v\(run.iteration) running")
        }
        runs[runID] = run
        return run.summary
    }

    func readArtifact(runID: String, sha256: String, offset: Int, length: Int) async throws -> WorkflowArtifactChunk {
        guard runs[runID] != nil, let data = files[sha256], offset <= data.count else {
            throw WorkspaceClientError.rejected(code: "not_found")
        }
        let end = min(data.count, offset + min(length, WorkflowArtifactReader.chunkBytes))
        return WorkflowArtifactChunk(sha256: sha256, offset: offset, total: data.count,
                                     data: data.subdata(in: offset..<end), done: end >= data.count)
    }

    /// Like the host: yours first, newest first, then the built-in ones.
    func templates() async throws -> [WorkflowTemplate] {
        yourTemplates.reversed().map(\.template)
            + [WorkflowTemplate(id: "research-draft-review", name: "Research, draft, review",
                                description: "One agent researches, another writes, a third reviews. You approve the result.",
                                stageCount: 6),
               WorkflowTemplate(id: "three-takes", name: "Three takes, one answer",
                                description: "Three agents answer at the same time from different angles. When all three agree, one writes the answer from them, and you sign it off.",
                                stageCount: 4)]
    }

    func features() async -> WorkflowFeatures { .all }

    func deliveryTargets() async throws -> [ScheduledTaskDeliveryTarget] {
        [.local, .init(id: "telegram", name: "Telegram", homeTargetSet: true),
         .init(id: "discord", name: "Discord", homeTargetSet: true),
         .init(id: "slack", name: "Slack", homeTargetSet: false)]
    }

    func useTemplate(id: String) async throws -> String {
        await pause()
        nextWorkflow += 1
        let newID = "wf-\(order.count + 1)-\(nextWorkflow)"
        var definition: WorkflowDefinition
        if let yours = yourTemplates.first(where: { $0.template.id == id }) {
            definition = yours.definition
        } else if id == "three-takes" {
            definition = Self.threeTakes
        } else {
            definition = Self.researchDraftReview
            definition.name = "Research, draft, review \(order.count)"
        }
        workflows[newID] = Workflow(id: newID, definition: definition, revision: nil, draftVersion: 1, hasDraft: true,
                                    bindings: [:])
        order.append(newID)
        return newID
    }

    func saveTemplate(workflowID: String, name: String, description: String?) async throws -> String {
        try requireEditing()
        await pause()
        guard let workflow = workflows[workflowID] else { throw WorkspaceClientError.rejected(code: "workflow_not_found") }
        guard yourTemplates.count < 100 else { throw WorkspaceClientError.rejected(code: "not_allowed") }
        nextWorkflow += 1
        let id = "tpl-\(nextWorkflow)"
        var definition = workflow.definition
        definition.name = String(name.prefix(WorkflowTemplate.nameLimit))
        yourTemplates.append(Template(
            template: WorkflowTemplate(id: id, name: definition.name,
                                       description: description ?? workflow.definition.description,
                                       stageCount: definition.stages.count, source: .yours, updatedAt: .now),
            definition: definition))
        return id
    }

    func deleteTemplate(id: String) async throws {
        try requireEditing()
        await pause()
        guard yourTemplates.contains(where: { $0.template.id == id }) else {
            throw WorkspaceClientError.rejected(code: "not_allowed")
        }
        yourTemplates.removeAll { $0.template.id == id }
    }

    // MARK: Building answers

    private func pause() async {
        if delays { try? await Task.sleep(for: .milliseconds(250)) }
    }

    private func summary(_ workflow: Workflow) -> WorkflowSummary {
        let used = Set(workflow.definition.allStages.filter { $0.kind == .agent }.compactMap(\.role))
        let unbound = workflow.definition.roles.map(\.key).filter { used.contains($0) && workflow.bindings[$0] == nil }
        return WorkflowSummary(id: workflow.id, name: workflow.definition.name, revision: workflow.revision,
                               hasDraft: workflow.hasDraft, stageCount: workflow.definition.stages.count,
                               needsSetupRoles: unbound, valid: validation(workflow).valid,
                               lastRunAt: workflow.lastRunAt, stageKinds: workflow.definition.stages.map(\.kind),
                               pinned: workflow.pinned, archived: workflow.archived, trigger: workflow.trigger)
    }

    private func validation(_ workflow: Workflow) -> WorkflowValidation {
        var issues: [WorkflowValidation.Issue] = []
        for stage in workflow.definition.allStages where stage.kind == .agent {
            if stage.role == nil || workflow.definition.role(stage.role) == nil {
                issues.append(.init(stageKey: stage.key, code: "role_missing",
                                    message: "\(stage.title) needs a role.", isError: true))
            }
            if stage.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(stageKey: stage.key, code: "instructions_missing",
                                    message: "\(stage.title) needs instructions.", isError: true))
            }
            if stage.hasBroadTools {
                issues.append(.init(stageKey: stage.key, code: "broad_tools",
                                    message: "\(stage.title) can use the terminal.", isError: false))
            }
        }
        for stage in workflow.definition.stages where stage.kind == .delivery {
            if stage.deliver.isEmpty {
                issues.append(.init(stageKey: stage.key, code: "delivery_empty",
                                    message: "Choose what \(stage.title) sends.", isError: true))
            }
            if (stage.to ?? "").isEmpty {
                issues.append(.init(stageKey: stage.key, code: "delivery_target",
                                    message: "Choose where \(stage.title) sends it.", isError: true))
            }
        }
        // How the stages connect, as the host checks it.
        issues += workflow.definition.graph.issues(workflow.definition)
        // Like the host: a role a stage uses needs an agent. `valid` leaves
        // this out; it is about the definition, not this computer.
        let used = Set(workflow.definition.allStages.filter { $0.kind == .agent }.compactMap(\.role))
        let valid = !issues.contains(where: \.isError)
        for role in workflow.definition.roles where used.contains(role.key) && workflow.bindings[role.key] == nil {
            issues.append(.init(stageKey: nil, code: "role_unbound", message: "Choose an agent for \(role.label).",
                                isError: true))
        }
        return WorkflowValidation(valid: valid, issues: issues)
    }

    private func currentFile(_ run: Run) -> WorkflowOutput? {
        run.outputs.filter { $0.stageKey == "draft" && $0.isFile }.max { $0.iteration < $1.iteration }
    }

    private func detail(_ run: Run) -> WorkflowRunDetail {
        let workflow = workflows[run.summary.workflowID]
        let definition = workflow?.definition ?? Self.researchDraftReview
        let current = run.summary.stageKey
        let stages = definition.stages.enumerated().map { index, stage -> WorkflowRunStage in
            let state: WorkflowRunState
            let endIndex = run.ended.flatMap { ended in definition.stages.firstIndex { $0.key == ended.stage } }
            if let endIndex, index > endIndex {
                state = .planned
            } else if run.summary.state == .succeeded || index < run.stageIndex {
                state = .accepted
            } else if stage.key == current {
                state = run.summary.state == .cancelled ? .cancelled : run.summary.stageState ?? run.summary.state
            } else {
                state = .planned
            }
            let agent = workflow?.bindings[stage.role ?? ""]
            let doneMinutes = [2.7, 6.0, 0.1, 3.2, 0.0, 0.0]
            let attempts: [WorkflowAttempt] = stage.kind == .agent && state != .planned ? [
                WorkflowAttempt(id: "\(run.summary.id)-\(stage.key)-1", number: 1, state: state, agentID: agent,
                                launchedAt: run.summary.startedAt, endedAt: state == .accepted ? run.summary.updatedAt : nil,
                                durationMs: state == .accepted ? Int((doneMinutes[safe: index] ?? 1) * 60_000) : nil,
                                tokens: run.fallbackRunner ? nil
                                    : WorkflowTokens(input: 4_200 + index * 900, output: 1_800 + index * 400),
                                outcomeCode: state == .accepted ? "passed" : nil),
            ] : []
            var value = WorkflowRunStage(key: stage.key, kind: stage.kind, title: stage.title, role: stage.role,
                                         agentID: agent,
                                         iteration: stage.key == "draft" || stage.key == "review" ? run.iteration : 1,
                                         state: state, minutes: stage.kind == .agent
                                             ? Double(stage.minutes ?? definition.stageMinutes) : nil,
                                         attempts: attempts)
            value.uses = stage.reads
            if let ended = run.ended, ended.stage == stage.key {
                value.outcome = ended.outcome
                value.outcomeNote = ended.note
            }
            if stage.kind == .signoff {
                value.decisions = run.history.filter { $0.stageKey == stage.key }.map {
                    WorkflowStageDecision(iteration: $0.iteration, decision: $0.outcome,
                                          notes: $0.notes.map(\.text).joined(separator: "\n"), decidedAt: nil)
                }
            }
            if state != .planned, let started = run.summary.startedAt {
                let before = doneMinutes.prefix(index).reduce(0, +) * 60
                value.startedAt = started.addingTimeInterval(before)
                if state == .accepted {
                    value.endedAt = value.startedAt?.addingTimeInterval((doneMinutes[safe: index] ?? 1) * 60)
                }
            }
            return value
        }
        var signoff: WorkflowSignoff?
        if run.summary.state == .waitingForYou || run.summary.state == .succeeded, let file = currentFile(run) {
            let previous = run.outputs.filter { $0.stageKey == file.stageKey && $0.iteration == file.iteration - 1 }.first
            signoff = WorkflowSignoff(stageKey: "signoff", artifact: file, previous: previous, reviewDecision: "pass",
                                      reviewNotes: run.reviewNotes, history: run.history)
        }
        var actions: Set<String> = []
        if !run.summary.state.isFinished { actions.insert("cancel") }
        if [.needsAttention, .failed].contains(run.summary.state) { actions.insert("retry") }
        let counted = stages.flatMap(\.attempts).compactMap(\.tokens)
        let tokens = run.fallbackRunner ? nil : counted.reduce(WorkflowTokens(input: 0, output: 0)) {
            WorkflowTokens(input: $0.input + $1.input, output: $0.output + $1.output)
        }
        // Like the host: each parallel block's agents follow it, in the block's state.
        let shown = stages.flatMap { item -> [WorkflowRunStage] in
            guard let block = definition.stage(item.key), block.kind == .parallel else { return [item] }
            return [item] + block.branches.map { branch in
                var agent = WorkflowRunStage(key: branch.key, kind: .agent, title: branch.title, role: branch.role,
                                             agentID: workflow?.bindings[branch.role ?? ""], iteration: item.iteration,
                                             state: item.state, minutes: Double(definition.stageMinutes), attempts: [])
                agent.group = block.key
                agent.uses = branch.reads
                return agent
            }
        }
        return WorkflowRunDetail(summary: run.summary, inputs: run.inputs, stages: shown, outputs: run.outputs,
                                 signoff: signoff, tokens: tokens, allowedActions: actions)
    }

    /// One step forward for a run started in the app.
    private func advance(_ run: inout Run) {
        guard let workflow = workflows[run.summary.workflowID] else { return }
        let stages = workflow.definition.stages
        guard let stage = stages[safe: run.stageIndex] else { return }
        run.lastStep = .now
        run.summary.version += 1
        run.summary.updatedAt = .now
        switch run.summary.stageState ?? .planned {
        case .planned:
            run.summary.state = .running
            run.summary.stageState = stage.kind == .agent ? .running : .checkingOutput
            log(&run, "running", stage.key, "\(stage.title) attempt 1 running")
            return
        case .running:
            run.summary.state = .checkingOutput
            run.summary.stageState = .checkingOutput
            log(&run, "checking", stage.key, "\(stage.title) checking output")
            return
        default:
            break
        }
        // The stage passed: record what it made and move on.
        if stage.key == "draft" {
            let text = Self.draftText(version: run.iteration, topic: run.inputs["topic"]?.string)
            add(text, as: "draft", stage: "draft", iteration: run.iteration, to: &run)
        } else if stage.key == "review" {
            run.outputs.append(WorkflowOutput(stageKey: "review", iteration: run.iteration, name: "decision",
                                              type: "decision", sha256: nil, bytes: 4, wordCount: nil, value: .string("pass")))
        }
        run.history.append(.init(index: run.history.count, stageKey: stage.key, title: stage.title,
                                 iteration: run.iteration, outcome: "passed", agentID: workflow.bindings[stage.role ?? ""],
                                 durationMs: 60_000, notes: []))
        log(&run, "accepted", stage.key, "\(stage.title) output accepted")
        run.stageIndex += 1
        run.summary.stagesDone = run.stageIndex
        guard let next = stages[safe: run.stageIndex] else {
            run.summary.state = .succeeded
            return
        }
        run.summary.stageKey = next.key
        run.summary.stageTitle = next.title
        if next.kind == .signoff {
            run.summary.state = .waitingForYou
            run.summary.stageState = .waitingForYou
            run.summary.waiting = .init(kind: "signoff", stageKey: next.key, since: .now)
            log(&run, "waiting", next.key, "Waiting for your sign-off")
        } else {
            run.summary.state = .accepted
            run.summary.stageState = .planned
        }
    }

    private func log(_ run: inout Run, _ kind: String, _ stage: String?, _ text: String, at: Date = .now) {
        nextEvent += 1
        run.events.append(WorkflowEvent(seq: nextEvent, at: at, kind: kind, stageKey: stage, attempt: 1, text: text))
    }

    private func add(_ text: String, as name: String, stage: String, iteration: Int, to run: inout Run) {
        let data = Data(text.utf8)
        let sha = WorkflowArtifactReader.sha256(data)
        files[sha] = data
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        run.outputs.append(WorkflowOutput(stageKey: stage, iteration: iteration, name: name, type: "markdown_file",
                                          sha256: sha, bytes: data.count, wordCount: words))
    }

    private func attach(_ data: Data, as name: String, type: String, fileName: String, mimeType: String,
                        stage: String, to run: inout Run) {
        let sha = WorkflowArtifactReader.sha256(data)
        files[sha] = data
        run.outputs.append(WorkflowOutput(stageKey: stage, iteration: 1, name: name, type: type, sha256: sha,
                                          bytes: data.count, wordCount: nil,
                                          value: .object(["fileName": .string(fileName), "mimeType": .string(mimeType)])))
    }

    // MARK: Seed

    private func seed() {
        // Saved places on the canvas, far wider than an iPhone: compact widths line them up instead.
        var laidOut = Self.researchDraftReview
        laidOut.schemaVersion = 2
        laidOut.layout = WorkflowLayout(inputs: CGPoint(x: 40, y: 100), stages: [
            "research": CGPoint(x: 340, y: 100), "draft": CGPoint(x: 640, y: 100), "check": CGPoint(x: 940, y: 100),
            "review": CGPoint(x: 1_240, y: 100), "decide": CGPoint(x: 1_540, y: 160), "signoff": CGPoint(x: 1_840, y: 100),
        ])
        let rdr = Workflow(id: "wf-research", definition: laidOut, revision: 4, draftVersion: 9,
                           hasDraft: false, bindings: ["researcher": "travel", "writer": "home", "reviewer": "finance"],
                           lastRunAt: now.addingTimeInterval(-38 * 60))
        let triage = Workflow(id: "wf-triage", definition: Self.triageDigest, revision: 2, draftVersion: 3, hasDraft: false,
                              bindings: ["triager": "home"], lastRunAt: now.addingTimeInterval(-3_600))
        let captions = Workflow(id: "wf-captions", definition: Self.photoCaptions, revision: nil, draftVersion: 2,
                                hasDraft: true, bindings: [:])
        let morning = Workflow(id: "wf-morning", definition: Self.morningNumbers, revision: 3, draftVersion: 3,
                               hasDraft: false, bindings: ["analyst": "finance"],
                               lastRunAt: now.addingTimeInterval(-60 * 60 * 20))
        for workflow in [rdr, triage, captions, morning] {
            workflows[workflow.id] = workflow
            order.append(workflow.id)
        }
        let topic: WorkflowJSON = ["topic": .string("Why agents should outlive the chat window"),
                                   "audience": .string("Developers"), "length": .integer(900)]

        func run(_ number: Int, _ workflow: Workflow, _ state: WorkflowRunState, stage: Int, stageState: WorkflowRunState? = nil,
                 minutesAgo: Double, updatedAgo: Double = 1, attention: WorkflowRunSummary.Problem? = nil,
                 failure: WorkflowRunSummary.Problem? = nil, iteration: Int = 1) -> Run {
            let stages = workflow.definition.stages
            let current = stages[safe: min(stage, stages.count - 1)]
            return Run(summary: WorkflowRunSummary(
                id: "run-\(number)", number: number, workflowID: workflow.id, workflowName: workflow.definition.name,
                revision: workflow.revision, state: state, stageKey: current?.key, stageTitle: current?.title,
                stageState: stageState ?? state, stagesDone: state == .succeeded ? stages.count : stage,
                stageCount: stages.count, startedAt: now.addingTimeInterval(-minutesAgo * 60),
                updatedAt: now.addingTimeInterval(-updatedAgo * 60), attention: attention, failure: failure,
                waiting: state == .waitingForYou ? .init(kind: "signoff", stageKey: current?.key,
                                                         since: now.addingTimeInterval(-38 * 60)) : nil,
                version: 3), stageIndex: stage, iteration: iteration, inputs: topic, outputs: [], history: [],
                reviewNotes: [], events: [], scripted: false, lastStep: now)
        }

        // 15: running Draft.
        var running = run(15, rdr, .running, stage: 1, minutesAgo: 6, updatedAgo: 0.1)
        add(Self.brief, as: "brief", stage: "research", iteration: 1, to: &running)
        for (offset, text) in [(372.0, "Run accepted · rev 4 pinned"), (360, "Research attempt 1 running"),
                               (200, "Research checking output"), (194, "Research output accepted · brief.md"),
                               (193, "Draft attempt 1 launching"), (191, "Draft attempt 1 running"),
                               (60, "Draft progress · section 3 of 4")] {
            log(&running, "progress", nil, text, at: now.addingTimeInterval(-offset))
        }
        // 14: waiting for your sign-off on draft v2, after one revision.
        var waiting = run(14, rdr, .waitingForYou, stage: 5, minutesAgo: 60, updatedAgo: 38, iteration: 2)
        add(Self.brief, as: "brief", stage: "research", iteration: 1, to: &waiting)
        add(Self.draftText(version: 1, topic: nil), as: "draft", stage: "draft", iteration: 1, to: &waiting)
        add(Self.draftText(version: 2, topic: nil), as: "draft", stage: "draft", iteration: 2, to: &waiting)
        // The review's verdict, which the decision stage read.
        waiting.outputs.append(WorkflowOutput(stageKey: "review", iteration: 2, name: "decision", type: "decision",
                                              sha256: nil, bytes: 4, wordCount: nil, value: .string("pass")))
        waiting.reviewNotes = [.init(severity: "minor", text: "Tighten the intro to two sentences."),
                               .init(severity: "minor", text: "Define \"host\" the first time it appears.")]
        waiting.history = [
            .init(index: 0, stageKey: "research", title: "Research", iteration: 1, outcome: "passed", agentID: "travel",
                  durationMs: 161_000, notes: []),
            .init(index: 1, stageKey: "draft", title: "Draft v1, Check draft", iteration: 1, outcome: "passed",
                  agentID: "home", durationMs: 362_000, notes: []),
            .init(index: 2, stageKey: "review", title: "Review v1 asked for changes", iteration: 1, outcome: "changes",
                  agentID: "finance", durationMs: nil,
                  notes: [.init(severity: "major", text: "Back up the restart claim with a concrete example. Cut the section on pricing.")]),
            .init(index: 3, stageKey: "draft", title: "Draft v2, Check draft", iteration: 2, outcome: "passed",
                  agentID: "home", durationMs: 258_000, notes: []),
            .init(index: 4, stageKey: "review", title: "Review v2 passed", iteration: 2, outcome: "passed",
                  agentID: "finance", durationMs: nil, notes: []),
        ]
        for (offset, text) in [(3_600.0, "Run accepted · rev 4 pinned"), (2_400, "Review asked for changes · draft v2 running"),
                               (2_290, "Review v2 passed"), (2_280, "Waiting for your sign-off")] {
            log(&waiting, "progress", nil, text, at: now.addingTimeInterval(-offset))
        }
        var checking = run(16, triage, .checkingOutput, stage: 0, minutesAgo: 2)
        log(&checking, "checking", "summarize", "Summarize checking output")
        let planned = run(17, rdr, .planned, stage: 0, minutesAgo: 0.5)
        var attention = run(12, triage, .needsAttention, stage: 0, stageState: .unknown("unknown"), minutesAgo: 60,
                            updatedAgo: 55, attention: .init(stageKey: "summarize", code: "host_restarted",
                                                             message: "We don't know how Summarize ended."))
        log(&attention, "attention", "summarize", "The computer restarted during Summarize")
        var succeeded = run(13, Workflow(id: "wf-captions", definition: Self.photoCaptions, revision: 1, draftVersion: 1,
                                         hasDraft: false, bindings: [:]), .succeeded, stage: 3, minutesAgo: 120)
        succeeded.summary.revision = 1
        let older = run(11, triage, .succeeded, stage: 1, minutesAgo: 60 * 30)
        var failed = run(10, rdr, .failed, stage: 2, minutesAgo: 60 * 50,
                         failure: .init(stageKey: "check", code: "contract_word_range",
                                        message: "The draft had 98 words. This workflow needs 150 to 1,100."))
        failed.summary.stageState = .failed
        var cancelled = run(9, Workflow(id: "wf-captions", definition: Self.photoCaptions, revision: 1, draftVersion: 1,
                                        hasDraft: false, bindings: [:]), .cancelled, stage: 1, minutesAgo: 60 * 70)
        cancelled.summary.revision = 1
        // 8: finished on Hermes' fallback runner, which can't count tokens.
        var fallback = run(8, triage, .succeeded, stage: 1, minutesAgo: 60 * 80)
        fallback.fallbackRunner = true
        // 7: made a chart and sent it. 6: nothing new, so the decision ended the run as succeeded.
        var sent = run(7, morning, .succeeded, stage: 2, minutesAgo: 60 * 92)
        sent.inputs = [:]
        sent.outputs.append(WorkflowOutput(stageKey: "make", iteration: 1, name: "summary", type: "text", sha256: nil,
                                           bytes: 62, wordCount: 11,
                                           value: .string("Sign-ups rose 12% on Tuesday. Everything else is steady.")))
        attach(Self.chartPNG(), as: "chart", type: "image", fileName: "chart.png", mimeType: "image/png",
               stage: "make", to: &sent)
        attach(Data("day,signups\nMon,41\nTue,46\nWed,44\n".utf8), as: "data", type: "file", fileName: "numbers.csv",
               mimeType: "text/csv", stage: "make", to: &sent)
        sent.outputs.append(WorkflowOutput(stageKey: "make", iteration: 1, name: "decision", type: "decision",
                                           sha256: nil, bytes: 4, wordCount: nil, value: .string("pass")))
        log(&sent, "delivered", "send", "Send it to me: sent to telegram.", at: now.addingTimeInterval(-60 * 91))
        var quiet = run(6, morning, .succeeded, stage: 1, minutesAgo: 60 * 116)
        quiet.inputs = [:]
        quiet.outputs.append(WorkflowOutput(stageKey: "make", iteration: 1, name: "decision", type: "decision",
                                            sha256: nil, bytes: 7, wordCount: nil, value: .string("changes")))
        quiet.ended = (stage: "anything", outcome: .succeeded, note: "No new numbers since yesterday.")
        quiet.summary.stagesDone = 2
        for value in [running, waiting, checking, planned, attention, succeeded, older, failed, cancelled, fallback,
                      sent, quiet] {
            runs[value.summary.id] = value
        }
    }

    // MARK: Made-up content

    /// Charts yesterday's made-up numbers and sends them. Nothing new: the decision ends the run as succeeded.
    static var morningNumbers: WorkflowDefinition {
        WorkflowDefinition(json: [
            "schemaVersion": .integer(2), "name": .string("Morning numbers"),
            "description": .string("Charts yesterday's numbers and sends them to Telegram. With nothing new, the run ends quietly."),
            "roles": .array([.object(["key": .string("analyst"), "label": .string("Analyst")])]),
            "inputs": .array([]),
            "stages": .array([
                .object(["key": .string("make"), "kind": .string("agent"), "title": .string("Chart the numbers"),
                         "role": .string("analyst"),
                         "instructions": .string("Chart yesterday's sign-ups. Say pass when there are new numbers."),
                         "outputs": .array([
                            .object(["name": .string("summary"), "type": .string("text")]),
                            .object(["name": .string("chart"), "type": .string("image")]),
                            .object(["name": .string("data"), "type": .string("file")]),
                            .object(["name": .string("decision"), "type": .string("decision"),
                                     "values": .array([.string("pass"), .string("changes")])]),
                         ])]),
                .object(["key": .string("anything"), "kind": .string("decision"), "title": .string("Anything new?"),
                         "on": .string("make.decision"), "pass": .string("next"),
                         "changes": .object(["end": .string("succeeded"),
                                             "message": .string("No new numbers since yesterday.")])]),
                .object(["key": .string("send"), "kind": .string("delivery"), "title": .string("Send it to me"),
                         "deliver": .array([.string("make.summary"), .string("make.chart"), .string("make.data")]),
                         "to": .string("telegram"), "message": .string("Morning numbers"), "next": .null]),
            ]),
        ])
    }

    /// A small made-up bar chart, so a picture output has something to show.
    static func chartPNG() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: 600, height: 360)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor(red: 0.98, green: 0.96, blue: 0.93, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, value) in [0.35, 0.5, 0.42, 0.68, 0.6, 0.82, 0.74].enumerated() {
                UIColor(red: 0.45, green: 0.32, blue: 0.86, alpha: 1).setFill()
                let height = CGFloat(value) * 280
                UIBezierPath(roundedRect: CGRect(x: 40 + CGFloat(index) * 78, y: 330 - height, width: 56, height: height),
                             cornerRadius: 8).fill()
            }
        }
        #else
        return Data()
        #endif
    }

    /// Like the plugin's template: a parallel block of three agents, a decision on all three verdicts,
    /// one answer from them, and your sign-off.
    static var threeTakes: WorkflowDefinition {
        func take(_ key: String, _ role: String, _ title: String) -> BighelpJSONValue {
            .object(["key": .string(key), "kind": .string("agent"), "title": .string(title), "role": .string(role),
                     "instructions": .string("Answer the question from this angle: \(title.lowercased())."),
                     "tools": .array([.string("web")]), "uses": .array([.string("inputs.question")]),
                     "outputs": .array([
                        .object(["name": .string("answer"), "type": .string("markdown_file")]),
                        .object(["name": .string("decision"), "type": .string("decision"),
                                 "values": .array([.string("pass"), .string("changes")])]),
                        .object(["name": .string("notes"), "type": .string("notes")]),
                     ])])
        }
        return WorkflowDefinition(json: [
            "schemaVersion": .integer(2),
            "name": .string("Three takes, one answer"),
            "description": .string("Three agents answer at the same time from different angles."),
            "roles": .array([
                .object(["key": .string("researcher"), "label": .string("Researcher")]),
                .object(["key": .string("skeptic"), "label": .string("Skeptic")]),
                .object(["key": .string("practitioner"), "label": .string("Practitioner")]),
                .object(["key": .string("writer"), "label": .string("Writer")]),
            ]),
            "inputs": .array([.object(["key": .string("question"), "label": .string("Question"),
                                       "type": .string("long_text"), "required": .boolean(true)])]),
            "stages": .array([
                .object(["key": .string("takes"), "kind": .string("parallel"), "title": .string("Three takes at once"),
                         "next": .string("agree"),
                         "branches": .array([take("facts", "researcher", "The facts"),
                                             take("risks", "skeptic", "The risks"),
                                             take("practice", "practitioner", "In practice")])]),
                .object(["key": .string("agree"), "kind": .string("decision"), "title": .string("All three agree"),
                         "on": .array([.string("facts.decision"), .string("risks.decision"),
                                       .string("practice.decision")]),
                         "pass": .string("answer"), "changes": .object(["goTo": .string("takes")])]),
                .object(["key": .string("answer"), "kind": .string("agent"), "title": .string("One answer"),
                         "role": .string("writer"), "instructions": .string("Write one answer from the three takes."),
                         "uses": .array([.string("facts.answer"), .string("risks.answer"), .string("practice.answer")]),
                         "outputs": .array([.object(["name": .string("answer"), "type": .string("markdown_file")])]),
                         "next": .string("signoff")]),
                .object(["key": .string("signoff"), "kind": .string("signoff"), "title": .string("Your sign-off"),
                         "file": .string("answer.answer"), "next": .null]),
            ]),
        ])
    }

    static var researchDraftReview: WorkflowDefinition {
        WorkflowDefinition(json: [
            "schemaVersion": .integer(1),
            "name": .string("Research, draft, review"),
            "description": .string("One agent researches, another writes, a third reviews. You approve the result."),
            "roles": .array([
                .object(["key": .string("researcher"), "label": .string("Researcher")]),
                .object(["key": .string("writer"), "label": .string("Writer")]),
                .object(["key": .string("reviewer"), "label": .string("Reviewer")]),
            ]),
            "inputs": .array([
                .object(["key": .string("topic"), "label": .string("Topic"), "type": .string("text"), "required": .boolean(true)]),
                .object(["key": .string("audience"), "label": .string("Audience"), "type": .string("choice"),
                         "required": .boolean(true),
                         "choices": .array([.string("General readers"), .string("Developers"), .string("Executives")])]),
                .object(["key": .string("length"), "label": .string("Length in words"), "type": .string("number"),
                         "required": .boolean(false), "sample": .integer(900)]),
            ]),
            "limits": .object(["stageMinutes": .integer(20), "maxRevisions": .integer(2)]),
            "stages": .array([
                .object(["key": .string("research"), "kind": .string("agent"), "title": .string("Research"),
                         "role": .string("researcher"),
                         "instructions": .string("Research the topic for the audience. Write a short brief with sources."),
                         "tools": .array([.string("web")]),
                         "uses": .array([.string("inputs.topic"), .string("inputs.audience")]),
                         "outputs": .array([.object(["name": .string("brief"), "type": .string("markdown_file")])]),
                         "minutes": .integer(20)]),
                .object(["key": .string("draft"), "kind": .string("agent"), "title": .string("Draft"),
                         "role": .string("writer"),
                         "instructions": .string("Write a first draft from the research brief. Match the audience, stay inside the length limit, and only make claims the brief supports."),
                         "tools": .array([.string("terminal"), .string("web"), .string("file")]),
                         "uses": .array([.string("research.brief"), .string("inputs.audience"), .string("inputs.length")]),
                         "outputs": .array([.object(["name": .string("draft"), "type": .string("markdown_file")]),
                                            .object(["name": .string("word_count"), "type": .string("number")])]),
                         "minutes": .integer(20)]),
                .object(["key": .string("check"), "kind": .string("check"), "title": .string("Check draft"),
                         "rules": .array([
                            .object(["type": .string("word_range"), "of": .string("draft.draft"),
                                     "min": .integer(150), "max": .integer(1_100)]),
                            .object(["type": .string("has_title"), "of": .string("draft.draft")]),
                         ])]),
                .object(["key": .string("review"), "kind": .string("agent"), "title": .string("Review"),
                         "role": .string("reviewer"),
                         "instructions": .string("Review the draft against the brief. Say pass or changes, with short notes."),
                         "tools": .array([]),
                         "uses": .array([.string("draft.draft"), .string("research.brief")]),
                         "outputs": .array([.object(["name": .string("decision"), "type": .string("decision"),
                                                     "values": .array([.string("pass"), .string("changes")])]),
                                            .object(["name": .string("notes"), "type": .string("notes")])])]),
                .object(["key": .string("decide"), "kind": .string("decision"), "title": .string("Decision"),
                         "on": .string("review.decision"), "pass": .string("signoff"),
                         "changes": .object(["goTo": .string("draft"), "maxRevisions": .integer(2)])]),
                .object(["key": .string("signoff"), "kind": .string("signoff"), "title": .string("Sign-off"),
                         "file": .string("draft.draft")]),
            ]),
        ])
    }

    static var triageDigest: WorkflowDefinition {
        WorkflowDefinition(json: [
            "schemaVersion": .integer(1), "name": .string("Repo triage digest"),
            "description": .string("Sorts new issues and writes a short digest."),
            "roles": .array([.object(["key": .string("triager"), "label": .string("Triager")])]),
            "inputs": .array([.object(["key": .string("repo"), "label": .string("Repository"), "type": .string("text"),
                                       "required": .boolean(true)])]),
            "stages": .array([
                .object(["key": .string("summarize"), "kind": .string("agent"), "title": .string("Summarize"),
                         "role": .string("triager"), "instructions": .string("Group new issues and summarize each group."),
                         "tools": .array([.string("web")]), "uses": .array([.string("inputs.repo")]),
                         "outputs": .array([.object(["name": .string("digest"), "type": .string("markdown_file")])])]),
                .object(["key": .string("signoff"), "kind": .string("signoff"), "title": .string("Sign-off"),
                         "file": .string("summarize.digest")]),
            ]),
        ])
    }

    static var photoCaptions: WorkflowDefinition {
        WorkflowDefinition(json: [
            "schemaVersion": .integer(1), "name": .string("Photo set captions"),
            "description": .string("Captions a photo set, checks them and asks you to approve."),
            "roles": .array([.object(["key": .string("captioner"), "label": .string("Captioner")]),
                             .object(["key": .string("checker"), "label": .string("Checker")])]),
            "inputs": .array([.object(["key": .string("album"), "label": .string("Album"), "type": .string("text"),
                                       "required": .boolean(true)])]),
            "stages": .array([
                .object(["key": .string("caption"), "kind": .string("agent"), "title": .string("Caption"),
                         "role": .string("captioner"), "instructions": .string("Write one caption per photo."),
                         "outputs": .array([.object(["name": .string("captions"), "type": .string("markdown_file")])])]),
                .object(["key": .string("check"), "kind": .string("check"), "title": .string("Check captions"),
                         "rules": .array([.object(["type": .string("not_empty"), "of": .string("caption.captions")])])]),
                .object(["key": .string("review"), "kind": .string("agent"), "title": .string("Review"),
                         "role": .string("checker"), "instructions": .string("Check names and places."),
                         "outputs": .array([.object(["name": .string("decision"), "type": .string("decision"),
                                                     "values": .array([.string("pass"), .string("changes")])])])]),
                .object(["key": .string("signoff"), "kind": .string("signoff"), "title": .string("Sign-off"),
                         "file": .string("caption.captions")]),
            ]),
        ])
    }

    static let brief = """
    # Brief: agents that outlive the chat window

    - Long agent work takes an hour or more.
    - People close the app; the work must keep going on their computer.
    - Sources: two made-up blog posts and one made-up talk.
    """

    static func draftText(version: Int, topic: String?) -> String {
        let pricing = version == 1 ? """

        ## What it costs

        Pricing depends on the model, the provider and how long each stage runs.

        """ : "\n"
        let example = version == 1
            ? "When the host restarts in the middle of a stage, the app should say it doesn't know what happened rather than guess."
            : "When the host restarts in the middle of a stage, the app should say it doesn't know what happened rather than guess. Say the computer updates overnight while a review runs: the run says so in the morning and waits for you."
        return """
        # \(topic ?? "Your agents should outlive the chat window")

        Most agent demos stop the moment you close the app. Real work doesn't. A research pass, a draft and a review can take an hour, and nobody wants to babysit a phone for that.

        The fix is boring on purpose. Keep the workflow's state on the host, run each stage as its own supervised process, and check every handoff before the next stage sees it. The phone becomes a window into the work instead of the thing holding it together.
        \(pricing)
        ## Honest beats optimistic

        \(example) A retry is a new attempt, and the old one stays on the record where you can see it.

        Approval should mean something too. You sign off on one specific file. If a single word changes after that, the approval no longer counts and you're asked again.
        """
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
