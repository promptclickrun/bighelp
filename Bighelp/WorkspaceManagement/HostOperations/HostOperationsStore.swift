import Foundation
import Observation

@MainActor
@Observable
final class HostOperationsStore {
    let hostName: String
    let profileID: String
    /// Exact profile home used by unscoped `/api/ops/*` routes. This must come
    /// from the connected backend's serving-profile discovery, not a picker label.
    private(set) var operationTargetProfileID: String?
    let rawConfiguration: RawConfigurationStore

    private(set) var overview: HermesHostOverview?
    private(set) var systemStats: HermesSystemStats?
    private(set) var egress: HermesEgressStatus?
    private(set) var updateCheck: HermesUpdateCheck?
    private(set) var updateReceipt: HermesUpdateReceipt?
    private(set) var checkpoints: HermesCheckpointSnapshot?
    private(set) var migrationPlan: HermesGatewayMigrationPlan?
    private(set) var shellHooks: HermesShellHooksSnapshot?
    private(set) var hookCreateReview: HermesShellHookCreateReview?
    private(set) var hookDeleteReview: HermesShellHookDeleteReview?
    private(set) var importReview: HermesHostImportReview?
    private(set) var importOutcomeNeedsReview = false
    private(set) var actionReceipts: [HermesHostActionReceipt] = []
    private(set) var actionStatuses: [String: HermesHostActionStatus] = [:]
    private(set) var diagnosticsShare: HermesDiagnosticsShareReceipt?
    private(set) var downloadedBackup: HermesBackupDownload?
    private(set) var unavailableFeatures: [String] = []
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var isRetired = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?

    /// Called when a gateway start or restart finished: the gateway runs its own copy of the bighelp
    /// plugin, so the app reads the computer again (`BighelpHostRegistry.noteServicesChanged`).
    @ObservationIgnored var onServicesChanged: (@MainActor () -> Void)?
    @ObservationIgnored private let client: DirectHermesHostOperationsClient
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private let suppliedOperationTargetProfileID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var trackingTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var operationTargetResolutionTask: Task<String, any Error>?
    @ObservationIgnored private var operationTargetResolutionID: UUID?
    @ObservationIgnored private var operationTargetDiscoveryDriver: Task<Void, Never>?
    @ObservationIgnored private var automaticOperationTargetResolutionAttempted = false

    init(
        hostName: String,
        profileID: String,
        operationTargetProfileID: String? = nil,
        client: DirectHermesHostOperationsClient,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.hostName = hostName
        self.profileID = profileID
        self.operationTargetProfileID = nil
        suppliedOperationTargetProfileID = operationTargetProfileID
        self.client = client
        self.isCurrent = isCurrent
        rawConfiguration = RawConfigurationStore(
            hostName: hostName, profileID: profileID, client: client, isCurrent: isCurrent
        )
    }

    var ownsScope: Bool { !isRetired && isCurrent() }
    var canAct: Bool { ownsScope && !isLoading && !isMutating }
    var importActionReceipt: HermesHostActionReceipt? {
        actionReceipts.last { $0.action == .importArchive }
    }
    var importHasUnresolvedAction: Bool {
        guard let receipt = importActionReceipt,
              let phase = actionStatuses[receipt.id]?.phase else { return false }
        return phase == .running || phase == .outcomeUnknown
    }
    var canPrepareImport: Bool {
        scheduleOperationTargetResolutionIfNeeded()
        return canAct && operationTargetProfileID != nil
            && !importOutcomeNeedsReview && !importHasUnresolvedAction
    }

    var lastBackupReceipt: HermesHostActionReceipt? {
        actionReceipts.last { $0.action == .backup }
    }

    var canDownloadLastBackup: Bool {
        guard let receipt = lastBackupReceipt,
              let status = actionStatuses[receipt.id],
              status.phase == .succeeded else { return false }
        return receipt.archivePath != nil
    }

    func load() async {
        guard ownsScope, !isMutating else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        successMessage = nil
        unavailableFeatures = []
        defer { if generation == token { isLoading = false } }

        var failures = 0
        await capture(token, feature: "Host status", failures: &failures) {
            let next = try await client.overview(profileID: profileID)
            guard accepts(token) else { return }
            overview = next
        }
        await capture(token, feature: "System statistics", failures: &failures) {
            let next = try await client.systemStats()
            guard accepts(token) else { return }
            systemStats = next
        }
        await capture(token, feature: "Egress status", failures: &failures) {
            let next = try await client.egressStatus()
            guard accepts(token) else { return }
            egress = next
        }
        await capture(token, feature: "Update checks", failures: &failures) {
            let next = try await client.checkForUpdate()
            guard accepts(token) else { return }
            updateCheck = next
        }
        await capture(token, feature: "Update receipts", failures: &failures) {
            let next = try await client.latestUpdateReceipt()
            guard accepts(token) else { return }
            updateReceipt = next
        }
        await capture(token, feature: "Checkpoint inventory", failures: &failures) {
            let next = try await client.checkpoints()
            guard accepts(token) else { return }
            checkpoints = next
        }
        await capture(token, feature: "Gateway migration plan", failures: &failures) {
            let next = try await client.gatewayMigrationPlan()
            guard accepts(token) else { return }
            migrationPlan = next
        }

        guard accepts(token) else { return }
        if failures > 0, unavailableFeatures.isEmpty {
            errorMessage = failures == 7
                ? "Hermes did not return Host Operations data. Check the connection and try again."
                : "Some Host Operations data could not be refreshed. Existing readbacks remain visible."
        }
    }

    func refreshOverview() async {
        guard ownsScope, !isMutating else { return }
        let token = UUID()
        generation = token
        do {
            let next = try await client.overview(profileID: profileID)
            guard accepts(token) else { return }
            overview = next
        } catch { publish(error, token: token) }
    }

    func refreshDiagnostics() async {
        guard ownsScope, !isMutating else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            let nextStats = try await client.systemStats()
            let nextEgress = try await client.egressStatus()
            guard accepts(token) else { return }
            systemStats = nextStats
            egress = nextEgress
        } catch { publish(error, token: token) }
    }

    func refreshBackups() async {
        guard ownsScope, !isMutating else { return }
        let token = UUID()
        generation = token
        do {
            let next = try await client.checkpoints()
            guard accepts(token) else { return }
            checkpoints = next
        } catch { publish(error, token: token) }
    }

    func refreshShellHooks() async {
        guard ownsScope, !isMutating else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            _ = try await resolveOperationTargetProfileID()
            guard accepts(token) else { return }
            let next = try await client.shellHooks()
            guard accepts(token) else { return }
            shellHooks = next
            hookCreateReview = nil
            hookDeleteReview = nil
        } catch { publish(error, token: token) }
    }

    func reviewHookCreation(_ draft: HermesShellHookDraft) async {
        guard canAct, operationTargetProfileID != nil else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            let review = try await client.reviewShellHookCreation(draft)
            guard accepts(token) else { return }
            hookCreateReview = review
        } catch { publish(error, token: token) }
    }

    func createReviewedHook() async {
        guard canAct, let review = hookCreateReview else { return }
        let token = beginMutation()
        defer { finishMutation(token) }
        do {
            let receipt = try await client.createShellHook(reviewed: review)
            guard accepts(token) else { return }
            shellHooks = receipt.snapshot
            hookCreateReview = nil
            successMessage = receipt.consentApproved == true
                ? "Hermes created the hook and confirmed its consent allowlist entry. It takes effect on the next session or messaging-gateway restart."
                : "Hermes created the hook, but did not confirm consent. It remains inactive until approved by the host."
        } catch {
            hookCreateReview = nil
            publish(error, token: token)
        }
    }

    func reviewHookDeletion(_ hook: HermesShellHook) async {
        guard canAct, operationTargetProfileID != nil else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            let review = try await client.reviewShellHookDeletion(hook)
            guard accepts(token) else { return }
            hookDeleteReview = review
        } catch { publish(error, token: token) }
    }

    func deleteReviewedHook() async {
        guard canAct, let review = hookDeleteReview else { return }
        let token = beginMutation()
        defer { finishMutation(token) }
        do {
            let receipt = try await client.deleteShellHook(reviewed: review)
            guard accepts(token) else { return }
            shellHooks = receipt.snapshot
            hookDeleteReview = nil
            successMessage = "Hermes removed every matching event/command hook and revoked that command’s consent entry."
        } catch {
            hookDeleteReview = nil
            publish(error, token: token)
        }
    }

    func cancelHookReview() {
        hookCreateReview = nil
        hookDeleteReview = nil
    }

    /// Hook commands can contain private paths or inline values. Keep the
    /// catalog only while its dedicated screen is presented.
    func closeShellHooks() {
        shellHooks = nil
        hookCreateReview = nil
        hookDeleteReview = nil
    }

    func reviewHostImport(path: String) {
        guard canPrepareImport, let targetProfileID = operationTargetProfileID else { return }
        errorMessage = nil
        successMessage = nil
        do {
            importReview = try client.reviewHostImport(
                path: path, hostName: hostName,
                selectedProfileID: profileID, targetProfileID: targetProfileID
            )
        } catch { publish(error) }
    }

    func reviewUploadedImport(filename: String, bytes: Data) {
        guard canPrepareImport, let targetProfileID = operationTargetProfileID else { return }
        errorMessage = nil
        successMessage = nil
        do {
            importReview = try client.reviewUploadedImport(
                filename: filename, bytes: bytes, hostName: hostName,
                selectedProfileID: profileID, targetProfileID: targetProfileID
            )
        } catch { publish(error) }
    }

    func cancelImportReview() {
        importReview = nil
    }

    func launchReviewedImport() async {
        guard canPrepareImport, let review = importReview else { return }
        let token = beginMutation()
        defer { finishMutation(token) }
        do {
            let receipt = try await client.launchReviewedImport(review)
            guard accepts(token) else { return }
            importReview = nil // immediately release private uploaded bytes
            importOutcomeNeedsReview = false
            register(receipt, title: "backup import")
        } catch {
            guard accepts(token) else { return }
            importReview = nil
            if error as? HostOperationsError == .outcomeUnknown {
                importOutcomeNeedsReview = true
                if let receipt = try? client.receipt(forActionName: HermesHostAction.importArchive.rawValue) {
                    register(receipt, title: "backup import", admitted: false)
                }
                errorMessage = "Hermes did not confirm whether the reviewed import started. Bighelp discarded any uploaded bytes, retained the action slot for read-only status checks, and will not enable another import in this presentation."
            } else {
                publish(error, token: token)
            }
        }
    }

    func checkForUpdates(force: Bool) async {
        guard canAct else { return }
        let token = beginMutation()
        defer { finishMutation(token) }
        do {
            let check = try await client.checkForUpdate(force: force)
            let receipt = try await client.latestUpdateReceipt()
            guard accepts(token) else { return }
            updateCheck = check
            updateReceipt = receipt
            successMessage = check.updateAvailable
                ? "Hermes found an available update. Review it before applying."
                : (check.message ?? "Hermes reported no available update.")
        } catch { publish(error, token: token) }
    }

    func applyReviewedUpdate() async {
        guard canAct, let updateCheck else { return }
        await launch(title: "Hermes update") {
            try await client.launchUpdate(reviewed: updateCheck)
        }
    }

    func createBackup() async {
        guard canAct else { return }
        await launch(title: "Backup") { try await client.launchBackup() }
    }

    func pruneCheckpoints() async {
        guard canAct else { return }
        await launch(title: "Checkpoint prune") { try await client.launchCheckpointPrune() }
    }

    func runDiagnostic(_ action: HermesDiagnosticAction) async {
        guard canAct else { return }
        await launch(title: action.title) { try await client.launchDiagnostic(action) }
    }

    func shareDiagnosticsWithNous() async {
        guard canAct else { return }
        let token = beginMutation()
        diagnosticsShare = nil
        defer { finishMutation(token) }
        do {
            let receipt = try await client.shareDiagnosticsWithNous(logLines: 200)
            guard accepts(token) else { return }
            diagnosticsShare = receipt
            successMessage = "Hermes returned a receipt for the force-redacted diagnostics share."
        } catch { publish(error, token: token) }
    }

    func downloadLastBackup() async {
        guard canAct, canDownloadLastBackup, let receipt = lastBackupReceipt else { return }
        let token = beginMutation()
        downloadedBackup = nil
        defer { finishMutation(token) }
        do {
            let download = try await client.downloadBackup(receipt)
            guard accepts(token) else { return }
            downloadedBackup = download
            successMessage = "The backup is ready to save on this device."
        } catch { publish(error, token: token) }
    }

    func clearDownloadedBackup() {
        downloadedBackup = nil
    }

    func setGatewayDraining(_ draining: Bool) async {
        guard canAct else { return }
        let token = beginMutation()
        defer { finishMutation(token) }
        do {
            let result = try await client.setGatewayDraining(draining)
            guard accepts(token) else { return }
            successMessage = result.action == .drain
                ? "Hermes confirmed the messaging-gateway drain marker. Refreshing runtime state…"
                : "Hermes confirmed the messaging-gateway drain marker was cleared."
            // The gateway watcher owns the asynchronous state transition. Poll a
            // few read-only status snapshots; never repeat the control request.
            for attempt in 0..<5 {
                let next = try await client.overview(profileID: profileID)
                guard accepts(token) else { return }
                overview = next
                let reached = draining ? next.gatewayState == "draining" : next.gatewayState != "draining"
                if reached { break }
                if attempt < 4 { try await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        } catch { publish(error, token: token) }
    }

    func launchGateway(_ command: HermesMessagingGatewayCommand) async {
        guard canAct else { return }
        let title = "Messaging gateway \(command.rawValue)"
        await launch(title: title) {
            try await client.launchMessagingGateway(command, profileID: profileID)
        }
    }

    func migrateGateway() async {
        guard canAct, let migrationPlan else { return }
        await launch(title: "Messaging gateway migration") {
            try await client.launchGatewayMigration(reviewed: migrationPlan)
        }
    }

    func pollAction(_ receipt: HermesHostActionReceipt) async {
        guard ownsScope else { return }
        do {
            let status = try await client.status(for: receipt)
            guard ownsScope else { return }
            actionStatuses[receipt.id] = status
            await refreshAfterTerminal(status, receipt: receipt)
        } catch { publishTrackingError(error, receipt: receipt) }
    }

    func dismissAction(_ receipt: HermesHostActionReceipt) {
        trackingTasks.removeValue(forKey: receipt.id)?.cancel()
        actionReceipts.removeAll { $0.id == receipt.id }
        actionStatuses.removeValue(forKey: receipt.id)
    }

    func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }

    func retire() {
        isRetired = true
        generation = UUID()
        operationTargetDiscoveryDriver?.cancel()
        operationTargetDiscoveryDriver = nil
        operationTargetResolutionTask?.cancel()
        operationTargetResolutionTask = nil
        operationTargetResolutionID = nil
        operationTargetProfileID = nil
        automaticOperationTargetResolutionAttempted = true
        trackingTasks.values.forEach { $0.cancel() }
        trackingTasks = [:]
        overview = nil
        systemStats = nil
        egress = nil
        updateCheck = nil
        updateReceipt = nil
        checkpoints = nil
        migrationPlan = nil
        shellHooks = nil
        hookCreateReview = nil
        hookDeleteReview = nil
        importReview = nil
        importOutcomeNeedsReview = false
        actionReceipts = []
        actionStatuses = [:]
        diagnosticsShare = nil
        downloadedBackup = nil
        unavailableFeatures = []
        isLoading = false
        isMutating = false
        errorMessage = nil
        successMessage = nil
        rawConfiguration.retire()
    }

    private func launch(
        title: String,
        operation: () async throws -> HermesHostActionReceipt
    ) async {
        let token = beginMutation()
        defer { finishMutation(token) }
        do {
            let receipt = try await operation()
            guard accepts(token) else { return }
            register(receipt, title: title)
        } catch { publish(error, token: token) }
    }

    /// Import has no separate load callback in its current view. Its first
    /// `canPrepareImport` evaluation occurs only when that dedicated destination
    /// is rendered, so discovery remains scoped to an explicit Hooks/Import open.
    private func scheduleOperationTargetResolutionIfNeeded() {
        guard ownsScope,
              operationTargetProfileID == nil,
              operationTargetResolutionTask == nil,
              operationTargetDiscoveryDriver == nil,
              !automaticOperationTargetResolutionAttempted else { return }
        automaticOperationTargetResolutionAttempted = true
        operationTargetDiscoveryDriver = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operationTargetDiscoveryDriver = nil }
            do {
                _ = try await self.resolveOperationTargetProfileID()
            } catch is CancellationError {
            } catch {
                guard self.ownsScope else { return }
                self.publish(error)
            }
        }
    }

    private func resolveOperationTargetProfileID() async throws -> String {
        if let operationTargetProfileID { return operationTargetProfileID }
        let request: Task<String, any Error>
        let id: UUID
        if let current = operationTargetResolutionTask,
           let currentID = operationTargetResolutionID {
            request = current
            id = currentID
        } else {
            id = UUID()
            let supplied = suppliedOperationTargetProfileID
            let client = client
            request = Task { @MainActor in
                try await client.servingProfileID(consistentWith: supplied)
            }
            operationTargetResolutionID = id
            operationTargetResolutionTask = request
        }

        do {
            let resolved = try await request.value
            try Task.checkCancellation()
            guard ownsScope else { throw HostOperationsError.ownerChanged }
            if operationTargetResolutionID == id {
                operationTargetProfileID = resolved
                operationTargetResolutionID = nil
                operationTargetResolutionTask = nil
            }
            guard let accepted = operationTargetProfileID,
                  Data(accepted.utf8) == Data(resolved.utf8) else {
                throw HostOperationsError.ownerChanged
            }
            return accepted
        } catch {
            if operationTargetResolutionID == id {
                operationTargetResolutionID = nil
                operationTargetResolutionTask = nil
            }
            throw error
        }
    }

    private func register(
        _ receipt: HermesHostActionReceipt,
        title: String,
        admitted: Bool = true
    ) {
        actionReceipts.removeAll { $0.action == receipt.action }
        actionStatuses = actionStatuses.filter { key, _ in
            actionReceipts.contains(where: { $0.id == key })
        }
        actionReceipts.append(receipt)
        actionStatuses[receipt.id] = .init(
            action: receipt.action, phase: .running,
            processID: receipt.processID, actionID: receipt.actionID,
            correlation: receipt.admission == .actionSlotOnly ? .actionSlotOnly : .pendingIdentity,
            updateSummary: nil
        )
        if admitted {
            successMessage = "Hermes admitted \(title). Completion is still pending."
        }
        startTracking(receipt)
    }

    private func startTracking(_ receipt: HermesHostActionReceipt) {
        trackingTasks.removeValue(forKey: receipt.id)?.cancel()
        trackingTasks[receipt.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await self.client.poll(receipt)
                guard self.ownsScope, !Task.isCancelled else { return }
                self.actionStatuses[receipt.id] = status
                self.trackingTasks.removeValue(forKey: receipt.id)
                await self.refreshAfterTerminal(status, receipt: receipt)
            } catch is CancellationError {
            } catch {
                guard self.ownsScope else { return }
                self.trackingTasks.removeValue(forKey: receipt.id)
                self.publishTrackingError(error, receipt: receipt)
            }
        }
    }

    private func refreshAfterTerminal(
        _ status: HermesHostActionStatus,
        receipt: HermesHostActionReceipt
    ) async {
        guard status.phase != .running, ownsScope else { return }
        if receipt.action == .importArchive,
           receipt.admission == .actionSlotOnly,
           importOutcomeNeedsReview {
            switch status.phase {
            case .succeeded:
                errorMessage = "Hermes reports that the named import action slot last exited successfully, but the lost acknowledgement cannot prove it belongs to the reviewed import. Bighelp will not replay it."
            case .failed(let code):
                errorMessage = "Hermes reports exit code \(code) for the named import action slot, but the lost acknowledgement cannot prove it belongs to the reviewed import. Bighelp will not replay it."
            case .outcomeUnknown:
                errorMessage = "Hermes has no durable result for the named import action slot. The reviewed import outcome remains unknown and Bighelp will not replay it."
            case .running:
                break
            }
            return
        }
        switch status.phase {
        case .succeeded:
            successMessage = "Hermes reported that \(receipt.action.rawValue) completed. Authoritative state was refreshed where available."
            if receipt.action == .gatewayStart || receipt.action == .gatewayRestart { onServicesChanged?() }
        case .failed(let code):
            errorMessage = "Hermes reported that \(receipt.action.rawValue) failed with exit code \(code). The action was not retried."
        case .outcomeUnknown:
            errorMessage = "Hermes no longer reports \(receipt.action.rawValue) as running, but it has no durable exit result. Refresh before deciding whether to act again."
        case .running:
            return
        }

        do {
            switch receipt.action {
            case .gatewayStart, .gatewayStop, .gatewayRestart, .gatewayMigrate:
                overview = try await client.overview(profileID: profileID)
                if receipt.action == .gatewayMigrate {
                    migrationPlan = try await client.gatewayMigrationPlan()
                }
            case .checkpointsPrune:
                checkpoints = try await client.checkpoints()
            case .hermesUpdate:
                updateReceipt = try await client.latestUpdateReceipt()
                updateCheck = try await client.checkForUpdate()
            default:
                break
            }
        } catch {
            guard ownsScope else { return }
            if receipt.action == .gatewayRestart || receipt.action == .hermesUpdate {
                errorMessage = "The action may have interrupted this connection. Reconnect to the same host, then read its action and runtime status; Bighelp did not replay it."
            }
        }
    }

    private func beginMutation() -> UUID {
        let token = UUID()
        generation = token
        isLoading = false
        isMutating = true
        errorMessage = nil
        successMessage = nil
        return token
    }

    private func finishMutation(_ token: UUID) {
        if generation == token { isMutating = false }
    }

    private func accepts(_ token: UUID) -> Bool {
        ownsScope && generation == token && !Task.isCancelled
    }

    private func capture(
        _ token: UUID,
        feature: String,
        failures: inout Int,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
        } catch is CancellationError {
        } catch HostOperationsError.unavailable(_) {
            guard accepts(token) else { return }
            failures += 1
            if !unavailableFeatures.contains(feature) { unavailableFeatures.append(feature) }
        } catch {
            guard accepts(token) else { return }
            failures += 1
        }
    }

    private func publish(_ error: any Error, token: UUID? = nil) {
        if let token, !accepts(token) { return }
        guard ownsScope else { return }
        errorMessage = Self.message(error)
    }

    private func publishTrackingError(_ error: any Error, receipt: HermesHostActionReceipt) {
        guard ownsScope else { return }
        if error is CancellationError { return }
        errorMessage = "Bighelp could not confirm \(receipt.action.rawValue). Its receipt is retained; refresh status instead of launching it again."
    }

    private static func message(_ error: any Error) -> String {
        if let error = error as? HostOperationsError { return error.localizedDescription }
        if let error = error as? WorkspaceClientError { return error.localizedDescription }
        if let error = error as? DirectHermesError { return error.localizedDescription }
        return "Hermes could not complete this Host Operations request. Refresh authoritative state before trying again."
    }
}
