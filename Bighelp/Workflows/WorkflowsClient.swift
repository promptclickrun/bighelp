import CryptoKit
import Foundation

/// Which version of a workflow to read: the draft being edited or a published revision.
enum WorkflowRevisionRef: Equatable, Sendable {
    case draft
    case latest
    case revision(Int)
}

enum WorkflowRunAction: String, Sendable {
    case pause, resume, cancel, retry
}

enum WorkflowSignoffDecision: String, Sendable {
    case approve, changes
}

/// The host's Workflows: definitions, runs and sign-offs. Everything lives on
/// the computer; the app reads and asks.
@MainActor
protocol WorkflowsClient: AnyObject {
    /// Whether the host's plugin has Workflows (`native-workflows-v1`), can edit
    /// them (`native-workflows-edit-v1`), or says why this computer can't run them.
    func support() async throws -> WorkflowsSupport
    func status() async throws -> WorkflowStatus
    func list(includeArchived: Bool) async throws -> WorkflowsList
    func workflow(id: String, revision: WorkflowRevisionRef) async throws -> WorkflowDetail
    func saveDraft(workflowID: String?, baseDraftVersion: Int,
                   definition: WorkflowDefinition) async throws -> (workflowID: String, draftVersion: Int, validation: WorkflowValidation)
    func validate(workflowID: String) async throws -> WorkflowValidation
    func publish(workflowID: String, draftVersion: Int) async throws -> Int
    func bind(workflowID: String, role: String, agentID: String?) async throws -> [WorkflowBinding]
    func archive(workflowID: String) async throws
    func startRun(workflowID: String, revision: Int, inputs: WorkflowJSON,
                  clientRunToken: String) async throws -> WorkflowRunSummary
    func runs(workflowID: String?, filter: WorkflowRunFilter, before: String?, limit: Int) async throws -> WorkflowRunPage
    func run(id: String) async throws -> WorkflowRunDetail
    func events(runID: String, after: Int, limit: Int) async throws -> WorkflowEventPage
    func control(runID: String, action: WorkflowRunAction, expectedVersion: Int) async throws -> WorkflowRunSummary
    func signoff(runID: String, stageKey: String, decision: WorkflowSignoffDecision,
                 artifactSHA256: String, notes: String) async throws -> WorkflowRunSummary
    func readArtifact(runID: String, sha256: String, offset: Int, length: Int) async throws -> WorkflowArtifactChunk
    func templates() async throws -> [WorkflowTemplate]
    func useTemplate(id: String) async throws -> String
    // Editing (`native-workflows-edit-v1`).
    func saveTemplate(workflowID: String, name: String, description: String?) async throws -> String
    func deleteTemplate(id: String) async throws
    func pin(workflowID: String, pinned: Bool) async throws -> Bool
    func unarchive(workflowID: String) async throws
}

extension WorkflowsClient {
    /// The plugin's own check, read like the rest: true when Workflows run here.
    func isAvailable() async throws -> Bool {
        if case .available = try await support() { return true }
        return false
    }
}

/// The bighelp plugin's Workflows routes, read through whichever connection is
/// current (bighelp reconnects every time it comes back), like
/// `DirectHermesProviderUsageClient`.
@MainActor
final class DirectHermesWorkflowsClient: WorkflowsClient {
    private let currentWorkspace: @MainActor () -> (any WorkspaceOperationPerforming)?
    private let reconnectWait: Duration
    private let reconnectAttempts: Int

    init(currentWorkspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?,
         reconnectWait: Duration = .milliseconds(500), reconnectAttempts: Int = 20) {
        self.currentWorkspace = currentWorkspace
        self.reconnectWait = reconnectWait
        self.reconnectAttempts = reconnectAttempts
    }

    func support() async throws -> WorkflowsSupport {
        let (workspace, owner) = try await connection()
        return WorkflowsSupport(context: try await workspace.perform(.nativeContext, payload: [:], owner: owner))
    }

    func status() async throws -> WorkflowStatus {
        WorkflowStatus(json: try await perform(.workflowsStatus, [:]))
    }

    func list(includeArchived: Bool) async throws -> WorkflowsList {
        WorkflowsList(json: try await perform(.workflowsList, ["includeArchived": .boolean(includeArchived)]))
    }

    func workflow(id: String, revision: WorkflowRevisionRef) async throws -> WorkflowDetail {
        var payload: WorkflowJSON = ["workflowId": .string(id)]
        switch revision {
        case .draft: payload["revision"] = .string("draft")
        case .latest: break
        case .revision(let number): payload["revision"] = .integer(number)
        }
        return try WorkflowDetail(json: try await perform(.workflowsGet, payload))
    }

    func saveDraft(workflowID: String?, baseDraftVersion: Int,
                   definition: WorkflowDefinition) async throws -> (workflowID: String, draftVersion: Int, validation: WorkflowValidation) {
        var payload: WorkflowJSON = ["baseDraftVersion": .integer(baseDraftVersion), "definition": .object(definition.json)]
        if let workflowID { payload["workflowId"] = .string(workflowID) }
        let result = try await perform(.workflowsDraftSave, payload)
        guard let id = WorkflowDecode.string(result["workflowId"], max: 128),
              let version = WorkflowDecode.int(result["draftVersion"]) else { throw WorkspaceClientError.invalidResponse }
        return (id, version, WorkflowValidation(json: result["validation"]?.object))
    }

    func validate(workflowID: String) async throws -> WorkflowValidation {
        let result = try await perform(.workflowsValidate, ["workflowId": .string(workflowID)])
        return WorkflowValidation(json: result["validation"]?.object ?? result)
    }

    func publish(workflowID: String, draftVersion: Int) async throws -> Int {
        let result = try await perform(.workflowsPublish, ["workflowId": .string(workflowID),
                                                           "draftVersion": .integer(draftVersion)])
        guard let revision = WorkflowDecode.int(result["revision"]) else { throw WorkspaceClientError.invalidResponse }
        return revision
    }

    func bind(workflowID: String, role: String, agentID: String?) async throws -> [WorkflowBinding] {
        let result = try await perform(.workflowsBind, [
            "workflowId": .string(workflowID), "role": .string(role),
            "agentId": agentID.map(BighelpJSONValue.string) ?? .null,
        ])
        return WorkflowBinding.list(result["bindings"])
    }

    func archive(workflowID: String) async throws {
        _ = try await perform(.workflowsArchive, ["workflowId": .string(workflowID)])
    }

    /// The start may reach the host even when its answer doesn't come back.
    /// The token names this one start: the run it made is found, never a second one.
    func startRun(workflowID: String, revision: Int, inputs: WorkflowJSON,
                  clientRunToken: String) async throws -> WorkflowRunSummary {
        let payload: WorkflowJSON = [
            "workflowId": .string(workflowID), "revision": .integer(revision), "inputs": .object(inputs),
            "clientRunToken": .string(clientRunToken), "sample": .boolean(false),
        ]
        do {
            return try Self.run(try await perform(.workflowsRunsStart, payload))
        } catch WorkspaceClientError.outcomeUnknown {
            let page = try await runs(workflowID: workflowID, filter: .all, before: nil, limit: 50)
            if let run = page.runs.first(where: { $0.clientRunToken == clientRunToken }) { return run }
            // Hosts that don't echo the token: the same token returns the same run.
            return try Self.run(try await perform(.workflowsRunsStart, payload))
        }
    }

    func runs(workflowID: String?, filter: WorkflowRunFilter, before: String?, limit: Int) async throws -> WorkflowRunPage {
        var payload: WorkflowJSON = ["filter": .string(filter.rawValue), "limit": .integer(min(max(limit, 1), 50))]
        if let workflowID { payload["workflowId"] = .string(workflowID) }
        if let before { payload["before"] = .string(before) }
        return WorkflowRunPage(json: try await perform(.workflowsRunsList, payload))
    }

    func run(id: String) async throws -> WorkflowRunDetail {
        try WorkflowRunDetail(json: try await perform(.workflowsRunsGet, ["runId": .string(id)]))
    }

    func events(runID: String, after: Int, limit: Int) async throws -> WorkflowEventPage {
        let result = try await perform(.workflowsRunsEvents, [
            "runId": .string(runID), "after": .integer(after), "limit": .integer(min(max(limit, 1), 200)),
        ])
        return WorkflowEventPage(json: result, after: after)
    }

    func control(runID: String, action: WorkflowRunAction, expectedVersion: Int) async throws -> WorkflowRunSummary {
        try Self.run(try await perform(.workflowsRunsControl, [
            "runId": .string(runID), "action": .string(action.rawValue), "expectedVersion": .integer(expectedVersion),
        ]))
    }

    /// A sign-off whose answer is lost is read back from the run: it either
    /// moved on (it counted) or still waits (it didn't).
    func signoff(runID: String, stageKey: String, decision: WorkflowSignoffDecision,
                 artifactSHA256: String, notes: String) async throws -> WorkflowRunSummary {
        do {
            return try Self.run(try await perform(.workflowsRunsSignoff, [
                "runId": .string(runID), "stageKey": .string(stageKey), "decision": .string(decision.rawValue),
                "artifactSha256": .string(artifactSHA256), "notes": .string(String(notes.prefix(2_000))),
            ]))
        } catch WorkspaceClientError.outcomeUnknown {
            return try await run(id: runID).summary
        }
    }

    func readArtifact(runID: String, sha256: String, offset: Int, length: Int) async throws -> WorkflowArtifactChunk {
        try WorkflowArtifactChunk(json: try await perform(.workflowsArtifactsRead, [
            "runId": .string(runID), "sha256": .string(sha256), "offset": .integer(offset),
            "length": .integer(min(max(length, 1), WorkflowArtifactReader.chunkBytes)),
        ]))
    }

    func templates() async throws -> [WorkflowTemplate] {
        let result = try await perform(.workflowsTemplatesList, [:])
        // Built-in ones and at most 100 of yours.
        return WorkflowDecode.objects(result["templates"], max: 150).compactMap(WorkflowTemplate.init(json:))
    }

    func useTemplate(id: String) async throws -> String {
        let result = try await perform(.workflowsTemplatesUse, ["templateId": .string(id)])
        guard let workflowID = WorkflowDecode.string(result["workflowId"], max: 128) else {
            throw WorkspaceClientError.invalidResponse
        }
        return workflowID
    }

    func saveTemplate(workflowID: String, name: String, description: String?) async throws -> String {
        var payload: WorkflowJSON = ["workflowId": .string(workflowID),
                                     "name": .string(String(name.prefix(WorkflowTemplate.nameLimit)))]
        if let description { payload["description"] = .string(String(description.prefix(1_000))) }
        let result = try await perform(.workflowsTemplatesSave, payload)
        guard let id = WorkflowDecode.string(result["templateId"], max: 128) else {
            throw WorkspaceClientError.invalidResponse
        }
        return id
    }

    func deleteTemplate(id: String) async throws {
        _ = try await perform(.workflowsTemplatesDelete, ["templateId": .string(id)])
    }

    func pin(workflowID: String, pinned: Bool) async throws -> Bool {
        let result = try await perform(.workflowsPin, ["workflowId": .string(workflowID), "pinned": .boolean(pinned)])
        return WorkflowDecode.bool(result["pinned"]) ?? pinned
    }

    func unarchive(workflowID: String) async throws {
        _ = try await perform(.workflowsUnarchive, ["workflowId": .string(workflowID)])
    }

    // MARK: Plumbing

    private static func run(_ json: WorkflowJSON) throws -> WorkflowRunSummary {
        guard let run = json["run"]?.object, let summary = WorkflowRunSummary(json: run) else {
            throw WorkspaceClientError.invalidResponse
        }
        return summary
    }

    /// One call; when the plugin's context changed (412), once more with the new one.
    private func perform(_ operation: WorkspaceOperation, _ payload: WorkflowJSON) async throws -> WorkflowJSON {
        let (workspace, owner) = try await connection()
        do {
            return try await workspace.perform(operation, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict {
            return try await workspace.perform(operation, payload: payload, owner: owner)
        }
    }

    /// Waits a few seconds for a connection that's on its way back.
    private func connection() async throws -> (any WorkspaceOperationPerforming, WorkspaceOwner) {
        for attempt in 0...reconnectAttempts {
            if let workspace = currentWorkspace(), let owner = workspace.owner { return (workspace, owner) }
            if attempt < reconnectAttempts { try await Task.sleep(for: reconnectWait) }
        }
        throw WorkspaceClientError.transportUnavailable
    }
}

/// Downloads one stored file in pieces and checks it is exactly the file asked for.
enum WorkflowArtifactReader {
    static let chunkBytes = 98_304
    /// Workflow files are at most 512 KB of text; anything far bigger isn't one.
    static let maximumBytes = 4 * 1_024 * 1_024

    @MainActor
    static func read(client: any WorkflowsClient, runID: String, sha256: String) async throws -> Data {
        var data = Data()
        var offset = 0
        while true {
            let chunk = try await client.readArtifact(runID: runID, sha256: sha256, offset: offset, length: chunkBytes)
            guard chunk.sha256 == sha256, chunk.offset == offset, chunk.total <= maximumBytes,
                  offset + chunk.data.count <= chunk.total else { throw WorkspaceClientError.invalidResponse }
            data.append(chunk.data)
            offset += chunk.data.count
            if chunk.done || offset >= chunk.total { break }
            guard !chunk.data.isEmpty else { throw WorkspaceClientError.invalidResponse }
        }
        guard WorkflowArtifactReader.sha256(data) == sha256 else { throw WorkspaceClientError.invalidResponse }
        return data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
