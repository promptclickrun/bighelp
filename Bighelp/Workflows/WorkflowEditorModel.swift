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
    /// One token per Run tap: a start that is tried again is the same start.
    @ObservationIgnored private var pendingRunToken: String?

    init(workflowID: String, client: any WorkflowsClient, hasDraft: Bool = false) {
        self.workflowID = workflowID
        self.client = client
        hasUnpublishedDraft = hasDraft
    }

    var isDirty: Bool { definition != nil && definition != detail?.definition }
    var name: String { definition?.name.isEmpty == false ? definition!.name : detail?.name ?? "Workflow" }

    /// Roles no agent does yet.
    var unboundRoles: [WorkflowDefinition.Role] {
        (definition?.roles ?? []).filter { role in
            bindings.first { $0.role == role.key }?.agentID == nil
        }
    }

    var canRun: Bool {
        (validation?.valid ?? false) && unboundRoles.isEmpty && !isSaving && definition?.stages.isEmpty == false
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

    func addStage(after key: String?) -> WorkflowStage? {
        guard var stages = definition?.stages else { return nil }
        let stage = WorkflowStage(newAgentStageAfter: stages, role: definition?.roles.first?.key)
        let index = key.flatMap { key in stages.firstIndex { $0.key == key } }.map { $0 + 1 } ?? stages.count
        stages.insert(stage, at: index)
        definition?.stages = stages
        return stage
    }

    func deleteStage(_ key: String) {
        definition?.stages.removeAll { $0.key == key }
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
        do {
            bindings = try await client.bind(workflowID: workflowID, role: role, agentID: agentID)
            message = nil
        } catch WorkspaceClientError.rejected(let code) where code == "profile_not_found" {
            message = "That agent isn't on this computer any more."
        } catch {
            message = WorkflowsStore.reason(error)
        }
    }

    // MARK: Running

    /// Saves and publishes what's on screen if needed, then starts one run.
    func run(inputs: WorkflowJSON) async -> WorkflowRunSummary? {
        guard !isSaving else { return nil }
        if isDirty, await !save() { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            var revision = detail?.latestRevision
            if hasUnpublishedDraft || revision == nil {
                revision = try await client.publish(workflowID: workflowID, draftVersion: baseDraftVersion)
                hasUnpublishedDraft = false
                detail?.latestRevision = revision
            }
            guard let revision else { return nil }
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
