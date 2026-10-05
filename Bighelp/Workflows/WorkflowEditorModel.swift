import CoreGraphics
import Foundation
import Observation

/// One workflow being looked at or changed: its draft, which agent does each
/// role, and whether the host says it can run. Saves send the draft version
/// they started from, so two devices never overwrite each other silently.
@MainActor
@Observable
final class WorkflowEditorModel {
    private(set) var detail: WorkflowDetail?
    var definition: WorkflowDefinition?
    private(set) var baseDraftVersion = 0
    private(set) var validation: WorkflowValidation?
    private(set) var bindings: [WorkflowBinding] = []
    private(set) var state: WorkflowsLoadState = .idle
    private(set) var isSaving = false
    /// True while the draft has changes the published revision doesn't.
    private(set) var hasUnpublishedDraft = false
    var message: String?

    let workflowID: String
    let client: any WorkflowsClient
    /// The plugin has `native-workflows-edit-v1`: connections and places can change.
    /// Older plugins show the flow as it is.
    let canEditFlow: Bool
    /// One token per Run tap: a start that is tried again is the same start.
    @ObservationIgnored private var pendingRunToken: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let saveDelay: Duration

    init(workflowID: String, client: any WorkflowsClient, hasDraft: Bool = false, canEditFlow: Bool = false,
         saveDelay: Duration = .milliseconds(700)) {
        self.workflowID = workflowID
        self.client = client
        self.canEditFlow = canEditFlow
        self.saveDelay = saveDelay
        hasUnpublishedDraft = hasDraft
    }

    var isDirty: Bool { definition != nil && definition != detail?.definition }
    var name: String { definition?.name.isEmpty == false ? definition!.name : detail?.name ?? "Workflow" }

    /// The roles agent stages use now.
    var usedRoleKeys: Set<String> {
        Set((definition?.stages ?? []).filter { $0.kind == .agent }.compactMap(\.role))
    }

    /// Roles a stage uses that no agent does yet. Roles no stage uses don't count.
    var unboundRoles: [WorkflowDefinition.Role] {
        let used = usedRoleKeys
        return (definition?.roles ?? []).filter { used.contains($0.key) && agentID(for: $0.key) == nil }
    }

    /// Runs when nothing on screen is wrong. Which agent does each role is
    /// known here (`bindings`), so the host's answer from before the last
    /// choice can't keep Run off.
    var canRun: Bool {
        validation != nil && !isSaving && definition?.stages.isEmpty == false
            && !issues.contains { $0.isError }
    }

    func load() async {
        if detail == nil { state = .loading }
        do {
            let value: WorkflowDetail
            do {
                value = try await client.workflow(id: workflowID, revision: .draft)
            } catch WorkspaceClientError.rejected {
                value = try await client.workflow(id: workflowID, revision: .latest)
            }
            apply(value)
            state = .loaded
        } catch {
            state = WorkflowsLoadState.from(error, hasContent: detail != nil)
        }
    }

    private func apply(_ value: WorkflowDetail) {
        detail = value
        definition = value.definition
        baseDraftVersion = value.draftVersion
        validation = value.validation
        bindings = value.bindings
        if value.latestRevision == nil { hasUnpublishedDraft = true }
    }

    func agentID(for role: String?) -> String? {
        guard let role else { return nil }
        return bindings.first { $0.role == role }?.agentID
    }

    // MARK: Changing the draft

    func update(_ stage: WorkflowStage) {
        guard let index = definition?.stages.firstIndex(where: { $0.key == stage.key }) else { return }
        definition?.stages[index] = stage
    }

    /// A new agent stage (the stage editor opens on it; Done saves).
    func addStage(after key: String?) -> WorkflowStage? {
        addStage(.agent, after: key)
    }

    /// A new stage of one kind after another one (nil: at the end of the flow),
    /// filled in from the stages before it, wired in, and placed where nothing
    /// else is. The stage editor opens on it; Done saves.
    /// `inputs` as the key puts it first.
    func addStage(_ kind: WorkflowStage.Kind, after key: String?) -> WorkflowStage? {
        guard var definition else { return nil }
        let atStart = key == WorkflowCanvasLayout.inputsKey
        let anchor = atStart ? nil : key ?? (canEditFlow ? nil : definition.stages.last?.key)
        let earlier = atStart ? [] : earlierStages(than: anchor, in: definition)
        var stage = WorkflowStage(new: kind, existing: definition.stages)
        WorkflowStageDefaults.fill(&stage, earlier: earlier, definition: &definition)
        if canEditFlow {
            let before = WorkflowCanvasLayout.positions(definition)
            if atStart {
                definition.insertFirst(stage)
            } else {
                definition.insert(stage, after: anchor)
            }
            let placedAfter = atStart ? WorkflowCanvasLayout.inputsKey
                : anchor ?? definition.graph.exits.first { $0.value.primary == stage.key }?.key
            let kinds = Dictionary(definition.stages.map { ($0.key, $0.kind) }, uniquingKeysWith: { first, _ in first })
            var layout = definition.layout ?? WorkflowLayout()
            Self.materialize(&layout, from: before, keys: definition.stages.map(\.key))
            layout.stages[stage.key] = WorkflowCanvasLayout.place(after: placedAfter, kind: kind, in: before, kinds: kinds)
            definition.layout = layout
            definition.schemaVersion = max(definition.schemaVersion, 2)
        } else {
            let index = atStart ? 0 : anchor.flatMap { key in definition.stages.firstIndex { $0.key == key } }.map { $0 + 1 }
                ?? definition.stages.count
            definition.stages.insert(stage, at: index)
        }
        self.definition = definition
        return self.definition?.stage(stage.key)
    }

    /// The stages that run before a new one placed after `anchor`.
    private func earlierStages(than anchor: String?, in definition: WorkflowDefinition) -> [WorkflowStage] {
        guard let anchor, let index = definition.stages.firstIndex(where: { $0.key == anchor }) else {
            return definition.stages
        }
        return Array(definition.stages.prefix(through: index))
    }

    func deleteStage(_ key: String) {
        if canEditFlow {
            definition?.remove(key)
            definition?.layout?.stages[key] = nil
        } else {
            definition?.stages.removeAll { $0.key == key }
        }
    }

    // MARK: Changing the flow (native-workflows-edit-v1)

    /// Points one way out of a stage at another (nil: the flow ends after it), then saves.
    func connect(_ from: String, _ port: WorkflowPort, to target: String?) {
        guard canEditFlow, definition != nil else { return }
        if from == WorkflowCanvasLayout.inputsKey {
            if let target { definition?.makeStart(target) }
        } else {
            definition?.connect(from, port, to: target)
        }
        scheduleSave()
    }

    /// Moves a stage to a gap in the list (0 is above the first stage), then saves.
    func move(_ key: String, toGap gap: Int) {
        guard canEditFlow, let stages = definition?.stages, let from = stages.firstIndex(where: { $0.key == key }) else { return }
        let index = gap > from ? gap - 1 : gap
        guard index != from else { return }
        definition?.move(key, toIndex: index)
        scheduleSave()
    }

    /// Puts a node somewhere on the canvas, on the grid, then saves.
    func place(_ key: String, at point: CGPoint) {
        guard canEditFlow, let definition else { return }
        var layout = definition.layout ?? WorkflowLayout()
        // The first move keeps every other node where it's drawn now.
        Self.materialize(&layout, from: WorkflowCanvasLayout.positions(definition), keys: definition.stages.map(\.key))
        let snapped = WorkflowLayout.clamped(WorkflowCanvasLayout.snap(point))
        if key == WorkflowCanvasLayout.inputsKey {
            layout.inputs = snapped
        } else {
            layout.stages[key] = snapped
        }
        guard layout != definition.layout else { return }
        self.definition?.layout = layout
        self.definition?.schemaVersion = max(definition.schemaVersion, 2)
        scheduleSave()
    }

    private static func materialize(_ layout: inout WorkflowLayout, from positions: [String: CGPoint], keys: [String]) {
        if layout.inputs == nil { layout.inputs = positions[WorkflowCanvasLayout.inputsKey] }
        for key in keys where layout.stages[key] == nil {
            if let point = positions[key] { layout.stages[key] = point }
        }
        layout.stages = layout.stages.filter { keys.contains($0.key) }
    }

    /// What's wrong, for the canvas: the flow's own problems as they are now,
    /// then the host's other ones from the last save.
    var issues: [WorkflowValidation.Issue] {
        guard let definition else { return validation?.issues ?? [] }
        let local = definition.graph.issues(definition)
        let host = (validation?.issues ?? []).filter {
            !WorkflowFlowGraph.graphCodes.contains($0.code) && !Self.roleCodes.contains($0.code)
        }
        let roles = unboundRoles.map {
            WorkflowValidation.Issue(stageKey: nil, code: Self.roleUnbound, message: "Choose an agent for \($0.label).",
                                     isError: true)
        }
        return local + roles + host
    }

    static let roleUnbound = "role_unbound"
    /// Role problems worked out here from the roles and agents as they are now.
    private static let roleCodes: Set<String> = [roleUnbound, "role_unused"]

    /// Saves a moment after the last change, so a drag or a few quick changes are one save.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled, let self else { return }
            await self.saveWhileDirty()
        }
    }

    /// Saves now if a change is waiting (leaving the screen).
    func flushSave() async {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        await saveWhileDirty()
    }

    private func saveWhileDirty() async {
        // A save that's still on its way saves the newest changes after it.
        while isSaving { try? await Task.sleep(for: .milliseconds(50)) }
        var attempts = 0
        while isDirty, attempts < 3 {
            attempts += 1
            guard await save() else { return }
        }
    }

    /// Saves the draft; the host checks it and says what's wrong.
    @discardableResult
    func save() async -> Bool {
        guard let definition, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await client.saveDraft(workflowID: workflowID, baseDraftVersion: baseDraftVersion,
                                                   definition: definition)
            baseDraftVersion = saved.draftVersion
            validation = saved.validation
            hasUnpublishedDraft = true
            if var detail {
                // What was sent is saved; a change made meanwhile still waits.
                detail.definition = definition
                detail.draftVersion = saved.draftVersion
                detail.validation = saved.validation
                self.detail = detail
            }
            message = nil
            return true
        } catch WorkspaceClientError.rejected(let code) where code == "draft_conflict" {
            message = "This workflow changed on another device. Here is the newest version; make your change again."
            await load()
        } catch {
            message = WorkflowsStore.reason(error)
        }
        return false
    }

    /// Chooses which agent does a role on this computer.
    func bind(role: String, agentID: String?) async {
        // The computer only takes an agent for a role its saved draft has.
        if isDirty { await flushSaveNow() }
        do {
            bindings = try await client.bind(workflowID: workflowID, role: role, agentID: agentID)
            message = nil
            if let validation = try? await client.validate(workflowID: workflowID) { self.validation = validation }
        } catch WorkspaceClientError.rejected(let code) where code == "profile_not_found" {
            message = "That agent isn't on this computer any more."
        } catch {
            message = WorkflowsStore.reason(error)
        }
    }

    /// The role an agent stage should use so `agentID` does it: a role that
    /// agent already does, else the stage's own role when no other stage
    /// shares it, else a new role named after the stage. New roles are added
    /// to the draft.
    func role(for stage: WorkflowStage, agentID: String) -> String? {
        guard let definition else { return nil }
        let used = usedRoleKeys
        if let shared = definition.roles.first(where: { used.contains($0.key) && self.agentID(for: $0.key) == agentID }) {
            return shared.key
        }
        if let own = stage.role, definition.role(own) != nil,
           !definition.stages.contains(where: { $0.key != stage.key && $0.kind == .agent && $0.role == own }) {
            return own
        }
        return addRole(named: stage.title)
    }

    /// Adds a role to the draft and gives its key.
    @discardableResult
    func addRole(named name: String) -> String? {
        let label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard definition != nil else { return nil }
        let shown = label.isEmpty ? "Agent" : label
        let key = WorkflowInputKey.make(from: shown, existing: definition?.roles.map(\.key) ?? [])
        definition?.roles.append(.init(key: key, label: shown))
        return key
    }

    /// Has `agentID` do one agent stage: picks or makes its role, saves the
    /// draft so the computer knows the role, then chooses the agent for it.
    func assign(agentID: String, to stage: WorkflowStage) async -> WorkflowStage {
        var stage = stage
        guard let role = role(for: stage, agentID: agentID) else { return stage }
        stage.role = role
        update(stage)
        await bind(role: role, agentID: agentID)
        return stage
    }

    /// Renames a role (the agent stays).
    func renameRole(_ key: String, to name: String) {
        let label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !label.isEmpty, let index = definition?.roles.firstIndex(where: { $0.key == key }) else { return }
        definition?.roles[index].label = label
        scheduleSave()
    }

    /// Removes a role no stage uses.
    func removeRole(_ key: String) {
        guard !usedRoleKeys.contains(key) else { return }
        definition?.roles.removeAll { $0.key == key }
        scheduleSave()
    }

    private func flushSaveNow() async {
        saveTask?.cancel()
        saveTask = nil
        await saveWhileDirty()
    }

    // MARK: Running

    /// How runs start: by hand, or on a schedule. Nil while the plugin predates triggers.
    var trigger: WorkflowTrigger? { detail?.trigger }

    /// Saves the trigger. A schedule runs the newest published version, so what's on screen is
    /// saved and published first. Returns true when the computer took it.
    func setTrigger(_ trigger: WorkflowTrigger) async -> Bool {
        guard !isSaving else { return false }
        if trigger.isScheduled {
            if isDirty, await !save() { return false }
        }
        isSaving = true
        defer { isSaving = false }
        do {
            if trigger.isScheduled { _ = try await publishIfNeeded() }
            let saved = try await client.setTrigger(workflowID: workflowID, trigger: trigger)
            detail?.trigger = saved
            message = nil
            return true
        } catch WorkspaceClientError.rejected(let code) where code == "schedule_invalid" {
            message = "Your computer couldn't use that schedule. Choose another time."
        } catch WorkspaceClientError.rejected(let code) where code == "not_valid" {
            message = "Fix the problems in this workflow, then schedule it."
        } catch WorkspaceClientError.rejected(let code) where code == "inputs_invalid" {
            message = "Fill in what each run needs, then save again."
        } catch WorkspaceClientError.unavailable(.unsupportedOperation) {
            message = "Update the bighelp plugin on your computer to schedule workflows."
        } catch {
            message = WorkflowsStore.reason(error)
        }
        return false
    }

    /// Publishes the draft when it has changes the published version doesn't. Returns the newest revision.
    private func publishIfNeeded() async throws -> Int? {
        var revision = detail?.latestRevision
        if hasUnpublishedDraft || revision == nil {
            revision = try await client.publish(workflowID: workflowID, draftVersion: baseDraftVersion)
            hasUnpublishedDraft = false
            detail?.latestRevision = revision
        }
        return revision
    }

    /// Saves and publishes what's on screen if needed, then starts one run.
    func run(inputs: WorkflowJSON) async -> WorkflowRunSummary? {
        guard !isSaving else { return nil }
        if isDirty, await !save() { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            guard let revision = try await publishIfNeeded() else { return nil }
            let token = pendingRunToken ?? UUID().uuidString.lowercased()
            pendingRunToken = token
            let run = try await client.startRun(workflowID: workflowID, revision: revision, inputs: inputs,
                                                clientRunToken: token)
            pendingRunToken = nil
            message = nil
            return run
        } catch WorkspaceClientError.rejected(let code) where code == "not_valid" {
            message = "Your computer found a problem with this workflow. Fix it, then run it again."
            if let validation = try? await client.validate(workflowID: workflowID) { self.validation = validation }
        } catch WorkspaceClientError.rejected(let code) where code == "queue_full" {
            pendingRunToken = nil
            message = "Too many runs are waiting to start. Try again when some have finished."
        } catch {
            message = WorkflowsStore.reason(error)
        }
        return nil
    }
}

/// Fills a new stage in from the stages before it, so it's ready to use:
/// an agent stage gets a role, a check checks the latest result, a decision
/// reads the latest review (which learns to decide pass or changes), and a
/// sign-off shows the latest file.
enum WorkflowStageDefaults {
    static func fill(_ stage: inout WorkflowStage, earlier: [WorkflowStage], definition: inout WorkflowDefinition) {
        let outputs = earlier.flatMap { stage in stage.outputs.map { (stage: stage, output: $0) } }
        switch stage.kind {
        case .agent:
            if definition.roles.isEmpty {
                definition.roles.append(.init(key: "agent", label: "Agent"))
            }
            stage.role = definition.roles.first?.key
        case .check:
            if let latest = outputs.last(where: { ["markdown_file", "text"].contains($0.output.type) }) {
                stage.rules = [.init(kind: "not_empty", of: "\(latest.stage.key).\(latest.output.name)")]
            }
        case .decision:
            let agents = earlier.filter { $0.kind == .agent }
            if let decided = outputs.last(where: { $0.output.type == "decision" }) {
                stage.on = "\(decided.stage.key).\(decided.output.name)"
            } else if let reviewer = agents.last, let index = definition.stages.firstIndex(where: { $0.key == reviewer.key }) {
                definition.stages[index].outputs.append(.init(name: "decision", type: "decision",
                                                              values: ["pass", "changes"]))
                stage.on = "\(reviewer.key).decision"
            } else {
                stage.on = "\(agents.last?.key ?? "review").decision"
            }
            stage.pass = "next"
            // Changes go back to the agent stage before the one that decides.
            // The host needs a stage named here; with none yet, its check says to choose one.
            stage.changesGoTo = agents.dropLast().last?.key ?? agents.last?.key ?? earlier.first?.key ?? stage.key
            stage.changesMaxRevisions = definition.maxRevisions
        case .signoff:
            if let file = outputs.last(where: { $0.output.type == "markdown_file" }) {
                stage.file = "\(file.stage.key).\(file.output.name)"
            } else {
                stage.file = "\(earlier.last { $0.kind == .agent }?.key ?? "stage1").result"
            }
        case .unknown:
            break
        }
    }
}
