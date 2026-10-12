import Foundation
import Observation

enum NativeSessionHistoryMutationKind: Equatable, Sendable {
    case compression
    case undo
    case rollback(hash: String, filePath: String?)

    var label: String {
        switch self {
        case .compression: "Compression"
        case .undo: "Undo"
        case .rollback: "Rollback restore"
        }
    }
}

struct NativeSessionHistoryReconciliation: Equatable, Sendable {
    enum Confirmation: Equatable, Sendable {
        case acknowledged
        case outcomeUnknown
    }

    let kind: NativeSessionHistoryMutationKind
    let confirmation: Confirmation
    let readback: DirectHermesSessionMutationReadback?
}

typealias NativeSessionHistoryReconciliationHandler = @MainActor (
    _ originalClient: DirectHermesConversationClient,
    _ mutation: NativeSessionHistoryReconciliation
) async throws -> Void

struct NativeSessionActionsOwner: Equatable {
    let clientID: ObjectIdentifier
    let connectionGeneration: UUID
}

enum NativeSessionControlsOperation: Hashable {
    case overview
    case controlRead
    case controlMutation
    case background
    case btw
    case compression
    case undo
    case save
    case workingDirectory
    case redirect
    case rollbackList
    case rollbackDiff
    case rollbackRestore
    case delegationRead
    case delegationMutation
    case spawnTreeList
    case spawnTreeLoad
    case spawnTreeSave
    case verification
    case historyReconciliation
    case skillsReload
    case toolsetsRead
    case toolConfiguration
}

@MainActor
@Observable
final class NativeSessionControlsModel {
    private(set) var owner: NativeSessionActionsOwner
    private(set) var ownsOriginalClient = true
    private(set) var busyOperations: Set<NativeSessionControlsOperation> = []
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?

    private(set) var status: DirectHermesSessionStatus?
    private(set) var usage: DirectHermesSessionUsage?
    private(set) var contextBreakdown: DirectHermesContextBreakdown?
    private(set) var control: DirectHermesSessionControlSnapshot?
    private(set) var lastControlDispatch: DirectHermesSessionControlDispatch?
    private(set) var lastCompression: DirectHermesCompressionResult?
    private(set) var lastUndo: DirectHermesUndoResult?
    private(set) var lastSave: DirectHermesSaveResult?
    private(set) var lastWorkingDirectory: DirectHermesWorkingDirectoryResult?
    private(set) var lastRedirect: DirectHermesRedirectResult?
    private(set) var rollbackList: DirectHermesRollbackList?
    private(set) var selectedRollback: DirectHermesRollbackCheckpoint?
    private(set) var rollbackDiff: DirectHermesRollbackDiff?
    private(set) var lastRollbackRestore: DirectHermesRollbackRestoreResult?
    private(set) var delegationStatus: DirectHermesDelegationStatus?
    private(set) var spawnTrees: [DirectHermesSpawnTreeEntry] = []
    private(set) var selectedSpawnTreePath: String?
    private(set) var loadedSpawnTree: DirectHermesSpawnTreeSnapshot?
    private(set) var lastSpawnTreeSave: DirectHermesSpawnTreeSaveResult?
    private(set) var verificationStatus: DirectHermesVerificationStatus?
    private(set) var verificationIsUnsupported = false
    private(set) var pendingHistoryReconciliation: NativeSessionHistoryReconciliation?
    private(set) var lastSkillsReload: DirectHermesSkillsReloadResult?
    private(set) var reloadedCommandCount: Int?
    private(set) var toolsets: [DirectHermesToolset] = []
    private(set) var lastToolsConfiguration: DirectHermesToolsConfigurationResult?
    private(set) var toolsetReadbackRequired = false
    enum ToolsetLoadState: Equatable { case notLoaded, loading, loaded, failed }
    private(set) var toolsetLoadState = ToolsetLoadState.notLoaded

    @ObservationIgnored private weak var originalClient: DirectHermesConversationClient?
    @ObservationIgnored private var actions: DirectHermesSessionActions
    @ObservationIgnored private let reconcileHistory: NativeSessionHistoryReconciliationHandler
    @ObservationIgnored private var operationTokens: [NativeSessionControlsOperation: UUID] = [:]

    init(
        client: DirectHermesConversationClient,
        connectionGeneration: UUID,
        reconcileHistory: @escaping NativeSessionHistoryReconciliationHandler
    ) {
        originalClient = client
        actions = client.sessionActions
        owner = NativeSessionActionsOwner(
            clientID: ObjectIdentifier(client),
            connectionGeneration: connectionGeneration
        )
        self.reconcileHistory = reconcileHistory
    }

    var canRunHistoryMutation: Bool {
        ownsOriginalClient
            && pendingHistoryReconciliation == nil
            && !isBusy(.historyReconciliation)
    }

    func isBusy(_ operation: NativeSessionControlsOperation) -> Bool {
        busyOperations.contains(operation)
    }

    private var hasLiveConfigurationOperation: Bool {
        busyOperations.contains(.skillsReload)
            || busyOperations.contains(.toolsetsRead)
            || busyOperations.contains(.toolConfiguration)
    }

    /// Refreshes the action facade only for the same captured client and the exact
    /// parent-supplied transport generation. A replacement client must get a new view identity.
    @discardableResult
    func refreshActions(
        client: DirectHermesConversationClient,
        connectionGeneration: UUID
    ) -> Bool {
        guard ObjectIdentifier(client) == owner.clientID,
              ObjectIdentifier(client) == originalClient.map({ ObjectIdentifier($0) }) else {
            ownsOriginalClient = false
            errorMessage = "This session changed while its controls were open. Close the controls and reopen them from the current chat."
            invalidateRequests()
            return false
        }

        ownsOriginalClient = true
        guard connectionGeneration != owner.connectionGeneration else { return true }
        invalidateRequests()
        toolsetLoadState = .notLoaded
        lastSkillsReload = nil
        owner = NativeSessionActionsOwner(
            clientID: owner.clientID,
            connectionGeneration: connectionGeneration
        )
        actions = client.sessionActions
        noticeMessage = "Connection refreshed. Session actions now use the current connection."
        return true
    }

    func loadInitialState() async {
        guard ownsOriginalClient else { return }
        toolsetLoadState = .loading
        await refreshOverview()
        await refreshControl()
        await refreshToolsets()
        await refreshRollbacks()
        await refreshDelegation()
        await refreshSpawnTrees(crossSession: false, limit: 50)
        await refreshVerification(workingDirectory: nil)
    }

    func clearFeedback() {
        errorMessage = nil
        noticeMessage = nil
    }

    func refreshOverview() async {
        guard let request = begin(.overview) else { return }
        do {
            let nextStatus = try await request.actions.status()
            guard accepts(request) else { return }
            status = nextStatus

            let nextUsage = try await request.actions.usage()
            guard accepts(request) else { return }
            usage = nextUsage

            let nextContext = try await request.actions.contextBreakdown()
            guard accepts(request) else { return }
            contextBreakdown = nextContext
            finish(request)
        } catch {
            fail(request, error: error,
                 fallback: "Hermes could not load the current session status, usage, and context.")
        }
    }

    func reloadSkills() async {
        guard !hasLiveConfigurationOperation,
              let request = begin(.skillsReload), let client = originalClient else { return }
        do {
            let result = try await request.actions.reloadSkills()
            guard accepts(request), ObjectIdentifier(client) == request.owner.clientID else { return }
            let commandCount = await client.model?.reloadSlashCommandCatalogAfterSkillsChange()
            guard accepts(request), ObjectIdentifier(client) == request.owner.clientID else { return }
            lastSkillsReload = result
            reloadedCommandCount = commandCount
            noticeMessage = commandCount.map {
                "Reloaded \(result.total) skills and read back \($0) live commands."
            } ?? "Reloaded \(result.total) skills. The composer command catalog could not be read back."
            finish(request)
        } catch {
            fail(request, error: error,
                 fallback: "Hermes could not confirm the live skill reload.")
        }
    }

    func refreshToolsets() async {
        guard !hasLiveConfigurationOperation, let request = begin(.toolsetsRead) else { return }
        toolsetLoadState = .loading
        do {
            let snapshot = try await request.actions.toolsets()
            guard accepts(request) else { return }
            toolsets = snapshot.toolsets
            toolsetLoadState = .loaded
            toolsetReadbackRequired = false
            finish(request)
        } catch {
            if accepts(request) { toolsetLoadState = .failed }
            fail(request, error: error,
                 fallback: "Hermes could not read the current live-session tool configuration.")
        }
    }

    func configureToolset(_ name: String, enabled: Bool) async {
        guard !toolsetReadbackRequired,
              !hasLiveConfigurationOperation,
              toolsets.contains(where: { $0.name == name }),
              let request = begin(.toolConfiguration) else { return }
        do {
            toolsetLoadState = .loading
            let result = try await request.actions.configureToolset(
                name,
                action: enabled ? .enable : .disable
            )
            guard accepts(request) else { return }
            lastToolsConfiguration = result
            if let readback = result.readback {
                toolsets = readback.toolsets
                toolsetLoadState = .loaded
                if readback.toolsets.first(where: { $0.name == name })?.enabled == enabled {
                    toolsetReadbackRequired = false
                    noticeMessage = "\(name) is \(enabled ? "enabled" : "disabled"). Hermes rebuilt the idle live session and the current tool state was read back."
                } else {
                    toolsetReadbackRequired = true
                    errorMessage = "Hermes rebuilt the live session, but authoritative readback did not confirm \(name) as \(enabled ? "enabled" : "disabled"). Refresh before another change."
                }
            } else {
                toolsetLoadState = .failed
                toolsetReadbackRequired = true
                noticeMessage = "Hermes accepted the \(name) change, but live-session readback failed. Refresh tool configuration before another change."
            }
            finish(request)
        } catch {
            if accepts(request) { toolsetLoadState = .failed }
            fail(request, error: error,
                 fallback: "Hermes could not confirm the live-session tool change. Refresh before trying again.")
        }
    }

    func startBackgroundTask(_ text: String) async -> Bool {
        guard let request = begin(.background) else { return false }
        do {
            let receipt = try await request.actions.startBackgroundTask(text)
            guard accepts(request) else { return false }
            noticeMessage = "Background task accepted (\(receipt.taskID)). Its progress and result will appear in the canonical chat."
            finish(request)
            return true
        } catch {
            fail(request, error: error,
                 fallback: "Hermes could not confirm the background task. Check this chat before submitting it again.")
            return false
        }
    }

    func askBTW(_ text: String) async -> Bool {
        guard let request = begin(.btw) else { return false }
        do {
            let receipt = try await request.actions.askBTW(text)
            guard accepts(request) else { return false }
            noticeMessage = "BTW question accepted (\(receipt.taskID)). Its answer will appear in the canonical chat."
            finish(request)
            return true
        } catch {
            fail(request, error: error,
                 fallback: "Hermes could not confirm the BTW question. Check this chat before submitting it again.")
            return false
        }
    }

    func compress(focusTopic: String?) async {
        let kind = NativeSessionHistoryMutationKind.compression
        guard canRunHistoryMutation, let request = begin(.compression) else { return }
        do {
            let result = try await request.actions.compress(focusTopic: focusTopic)
            guard accepts(request) else { return }
            lastCompression = result
            finish(request)
            await reconcileAcknowledged(kind: kind, readback: result.readback)
        } catch {
            finish(request)
            if isOutcomeUnknown(error) {
                await reconcileUnknown(kind: kind, error: error)
            } else {
                publish(error, fallback: "Hermes could not compress this session.")
            }
        }
    }

    func undo() async {
        let kind = NativeSessionHistoryMutationKind.undo
        guard canRunHistoryMutation, let request = begin(.undo) else { return }
        do {
            let result = try await request.actions.undo()
            guard accepts(request) else { return }
            lastUndo = result
            finish(request)
            await reconcileAcknowledged(kind: kind, readback: result.readback)
        } catch {
            finish(request)
            if isOutcomeUnknown(error) {
                await reconcileUnknown(kind: kind, error: error)
            } else {
                publish(error, fallback: "Hermes could not undo the latest session message.")
            }
        }
    }

    func save() async {
        guard let request = begin(.save) else { return }
        do {
            let result = try await request.actions.save()
            guard accepts(request) else { return }
            lastSave = result
            noticeMessage = result.file.map { "Session saved to \($0)." } ?? "Session save acknowledged."
            finish(request)
        } catch {
            fail(request, error: error,
                 fallback: "Hermes could not confirm the session save. Check before saving again.")
        }
    }

    func setWorkingDirectory(_ path: String) async -> Bool {
        guard let request = begin(.workingDirectory) else { return false }
        do {
            let result = try await request.actions.setWorkingDirectory(path)
            guard accepts(request) else { return false }
            lastWorkingDirectory = result
            noticeMessage = "Working directory changed to \(result.workingDirectory)."
            finish(request)
            return true
        } catch {
            fail(request, error: error,
                 fallback: "Hermes could not confirm the working-directory change. Check the current directory before trying again.")
            return false
        }
    }

    func refreshControl() async {
        guard let request = begin(.controlRead) else { return }
        do {
            let snapshot = try await request.actions.readControl()
            guard accepts(request) else { return }
            control = snapshot
            finish(request)
        } catch {
            fail(request, error: error, fallback: "Hermes could not load session control state.")
        }
    }

    func applyControl(_ action: DirectHermesSessionControlAction) async -> Bool {
        guard let request = begin(.controlMutation) else { return false }
        do {
            let result = try await request.actions.applyControl(action)
            guard accepts(request) else { return false }
            control = result.control
            lastControlDispatch = result.dispatch
            noticeMessage = controlDispatchMessage(result.dispatch) ?? "Session control updated."
            finish(request)
            return true
        } catch {
            fail(request, error: error,
                 fallback: "Hermes could not confirm the session-control change. Refresh its current state before trying again.")
            return false
        }
    }

    func redirect(_ text: String) async -> Bool {
        guard let request = begin(.redirect) else { return false }
        do {
            let result = try await request.actions.redirect(text)
            guard accepts(request) else { return false }
            lastRedirect = result
            switch result.status {
            case .queued: noticeMessage = "Redirect queued for the active turn."
            case .redirected: noticeMessage = "The active turn was redirected."
            case .rejected: errorMessage = "Hermes rejected this redirect. The text remains available to edit."
            }
            finish(request)
            return result.status != .rejected
        } catch {
            fail(request, error: error,
                 fallback: "Hermes could not confirm the redirect. Check the active turn before submitting it again.")
            return false
        }
    }

    func refreshRollbacks() async {
        guard let request = begin(.rollbackList) else { return }
        do {
            let list = try await request.actions.rollbacks()
            guard accepts(request) else { return }
            rollbackList = list
            finish(request)
        } catch {
            fail(request, error: error, fallback: "Hermes could not load rollback checkpoints.")
        }
    }

    func loadRollbackDiff(_ checkpoint: DirectHermesRollbackCheckpoint) async {
        selectedRollback = checkpoint
        rollbackDiff = nil
        guard let request = begin(.rollbackDiff) else { return }
        do {
            let diff = try await request.actions.rollbackDiff(hash: checkpoint.hash)
            guard accepts(request), selectedRollback?.hash == checkpoint.hash else { return }
            rollbackDiff = diff
            finish(request)
        } catch {
            fail(request, error: error, fallback: "Hermes could not load this rollback review.")
        }
    }

    func closeRollbackReview() {
        selectedRollback = nil
        rollbackDiff = nil
    }

    func restoreRollback(hash: String, filePath: String?) async -> Bool {
        let kind = NativeSessionHistoryMutationKind.rollback(hash: hash, filePath: filePath)
        guard canRunHistoryMutation, let request = begin(.rollbackRestore) else { return false }
        do {
            let result = try await request.actions.restoreRollback(hash: hash, filePath: filePath)
            guard accepts(request) else { return false }
            lastRollbackRestore = result
            finish(request)
            guard result.success else {
                errorMessage = result.error ?? result.reason ?? "Hermes did not restore this rollback checkpoint."
                return false
            }
            await reconcileAcknowledged(kind: kind, readback: result.readback)
            return pendingHistoryReconciliation == nil
        } catch {
            finish(request)
            if isOutcomeUnknown(error) {
                await reconcileUnknown(kind: kind, error: error)
            } else {
                publish(error, fallback: "Hermes could not restore this rollback checkpoint.")
            }
            return false
        }
    }

    func refreshDelegation() async {
        guard let request = begin(.delegationRead) else { return }
        do {
            let status = try await request.actions.delegationStatus()
            guard accepts(request) else { return }
            delegationStatus = status
            finish(request)
        } catch {
            fail(request, error: error, fallback: "Hermes could not load delegation status.")
        }
    }

    func setDelegationPaused(_ paused: Bool) async {
        guard let request = begin(.delegationMutation) else { return }
        do {
            _ = try await request.actions.setDelegationPaused(paused)
            guard accepts(request) else { return }
            if let current = delegationStatus {
                delegationStatus = DirectHermesDelegationStatus(
                    active: current.active,
                    paused: paused,
                    maxSpawnDepth: current.maxSpawnDepth,
                    maxConcurrentChildren: current.maxConcurrentChildren
                )
            }
            noticeMessage = paused ? "New delegation is paused." : "Delegation is resumed."
            finish(request)
            await refreshDelegation()
        } catch {
            fail(request, error: error,
                 fallback: "Hermes could not confirm the delegation change. Refresh before trying again.")
        }
    }

    func refreshSpawnTrees(crossSession: Bool, limit: Int) async {
        guard let request = begin(.spawnTreeList) else { return }
        do {
            let entries = try await request.actions.spawnTrees(crossSession: crossSession, limit: limit)
            guard accepts(request) else { return }
            spawnTrees = entries
            finish(request)
        } catch {
            fail(request, error: error, fallback: "Hermes could not load saved spawn trees.")
        }
    }

    func loadSpawnTree(path: String) async {
        selectedSpawnTreePath = path
        loadedSpawnTree = nil
        guard let request = begin(.spawnTreeLoad) else { return }
        do {
            let snapshot = try await request.actions.loadSpawnTree(path: path)
            guard accepts(request), selectedSpawnTreePath == path else { return }
            loadedSpawnTree = snapshot
            finish(request)
        } catch {
            fail(request, error: error, fallback: "Hermes could not load this spawn tree.")
        }
    }

    func closeSpawnTree() {
        selectedSpawnTreePath = nil
        loadedSpawnTree = nil
    }

    func saveLoadedSpawnTree(label: String?) async -> Bool {
        guard let snapshot = loadedSpawnTree,
              let request = begin(.spawnTreeSave) else { return false }
        do {
            let result = try await request.actions.saveSpawnTree(snapshot, label: label)
            guard accepts(request) else { return false }
            lastSpawnTreeSave = result
            noticeMessage = "Spawn tree saved to \(result.path)."
            finish(request)
            return true
        } catch {
            fail(request, error: error,
                 fallback: "Hermes could not confirm the spawn-tree save. Check the list before saving again.")
            return false
        }
    }

    func refreshVerification(workingDirectory: String?) async {
        guard let request = begin(.verification) else { return }
        do {
            let status = try await request.actions.verificationStatus(workingDirectory: workingDirectory)
            guard accepts(request) else { return }
            verificationStatus = status
            verificationIsUnsupported = false
            finish(request)
        } catch DirectHermesError.rpcRejected(let code, _) where code == -32601 {
            guard accepts(request) else { return }
            verificationStatus = nil
            verificationIsUnsupported = true
            finish(request)
        } catch {
            fail(request, error: error, fallback: "Hermes could not load verification status.")
        }
    }

    /// Retries only the required parent reconciliation. It never repeats the
    /// already acknowledged or outcome-unknown Hermes mutation.
    func retryHistoryReconciliation() async {
        guard let pending = pendingHistoryReconciliation,
              !isBusy(.historyReconciliation) else { return }
        await reconcile(pending)
    }

    private struct Request {
        let operation: NativeSessionControlsOperation
        let token: UUID
        let owner: NativeSessionActionsOwner
        let actions: DirectHermesSessionActions
    }

    private func begin(_ operation: NativeSessionControlsOperation) -> Request? {
        guard ownsOriginalClient, originalClient != nil,
              !busyOperations.contains(operation) else { return nil }
        let token = UUID()
        busyOperations.insert(operation)
        operationTokens[operation] = token
        errorMessage = nil
        return Request(operation: operation, token: token, owner: owner, actions: actions)
    }

    private func accepts(_ request: Request) -> Bool {
        ownsOriginalClient
            && owner == request.owner
            && operationTokens[request.operation] == request.token
            && !Task.isCancelled
    }

    private func finish(_ request: Request) {
        guard operationTokens[request.operation] == request.token else { return }
        operationTokens[request.operation] = nil
        busyOperations.remove(request.operation)
    }

    private func fail(_ request: Request, error: any Error, fallback: String) {
        guard accepts(request) else { return }
        finish(request)
        publish(error, fallback: fallback)
    }

    private func invalidateRequests() {
        operationTokens.removeAll()
        busyOperations.removeAll()
    }

    private func publish(_ error: any Error, fallback: String) {
        guard !(error is CancellationError) else { return }
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            errorMessage = description
        } else {
            errorMessage = fallback
        }
    }

    private func isOutcomeUnknown(_ error: any Error) -> Bool {
        (error as? DirectHermesError)?.outcomeIsUnknown == true
    }

    private func reconcileAcknowledged(
        kind: NativeSessionHistoryMutationKind,
        readback: DirectHermesSessionMutationReadback?
    ) async {
        let pending = NativeSessionHistoryReconciliation(
            kind: kind,
            confirmation: .acknowledged,
            readback: readback
        )
        pendingHistoryReconciliation = pending
        noticeMessage = "\(kind.label) was acknowledged. Refreshing canonical chat history…"
        await reconcile(pending)
    }

    private func reconcileUnknown(kind: NativeSessionHistoryMutationKind, error: any Error) async {
        let pending = NativeSessionHistoryReconciliation(
            kind: kind,
            confirmation: .outcomeUnknown,
            readback: nil
        )
        pendingHistoryReconciliation = pending
        publish(error, fallback: "The result is unknown. Refresh chat history before deciding what to do next.")
        await reconcile(pending)
    }

    private func reconcile(_ pending: NativeSessionHistoryReconciliation) async {
        guard let client = originalClient,
              ObjectIdentifier(client) == owner.clientID,
              let request = begin(.historyReconciliation) else { return }
        do {
            try await reconcileHistory(client, pending)
            guard ObjectIdentifier(client) == owner.clientID,
                  operationTokens[request.operation] == request.token else { return }
            pendingHistoryReconciliation = nil
            errorMessage = nil
            noticeMessage = pending.confirmation == .acknowledged
                ? "\(pending.kind.label) applied and canonical chat history refreshed."
                : "Canonical chat history refreshed. Review the result before starting another history change."
            finish(request)
        } catch {
            guard operationTokens[request.operation] == request.token else { return }
            finish(request)
            errorMessage = "\(pending.kind.label) was not sent again. Canonical chat refresh failed: \(safeReconciliationMessage(error))"
        }
    }

    private func safeReconciliationMessage(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return "close and reopen this chat, or retry only the chat refresh below."
    }

    private func controlDispatchMessage(_ dispatch: DirectHermesSessionControlDispatch) -> String? {
        [dispatch.display, dispatch.message, dispatch.notice, dispatch.output, dispatch.type]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .first
    }
}
