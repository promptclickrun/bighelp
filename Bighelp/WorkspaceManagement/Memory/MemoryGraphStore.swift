import Foundation
import Observation

@MainActor
@Observable
final class MemoryGraphStore {
    enum NodeFilter: String, CaseIterable, Identifiable {
        case all, memories, skills
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    let hostName: String
    let profileName: String

    private(set) var memoryStatus: HermesMemoryStatus?
    private(set) var graph: HermesLearningGraph?
    private(set) var curator: HermesCuratorStatus?
    private(set) var insights: HermesInsights?
    private(set) var selectedDetail: HermesLearningNodeDetail?
    private(set) var providerConfiguration: HermesMemoryProviderConfiguration?
    private(set) var providerOAuth: [String: HermesMemoryOAuthStatus] = [:]
    private(set) var isLoading = false
    private(set) var isLoadingDetail = false
    private(set) var isLoadingProvider = false
    private(set) var isMutating = false
    private(set) var isRetired = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var curatorRunReceipt: HermesCuratorRunReceipt?
    private(set) var curatorActionStatus: HermesHostActionStatus?

    var search = ""
    var nodeFilter: NodeFilter = .all

    @ObservationIgnored private let client: DirectHermesMemoryClient
    @ObservationIgnored private let actionStatusClient: (any HermesHostActionStatusClient)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var detailGeneration = UUID()
    @ObservationIgnored private var curatorActionGeneration = UUID()
    @ObservationIgnored private var curatorTrackingTask: Task<Void, Never>?

    init(
        hostName: String,
        profileName: String,
        client: DirectHermesMemoryClient,
        actionStatusClient: (any HermesHostActionStatusClient)? = nil
    ) {
        self.hostName = hostName
        self.profileName = profileName
        self.client = client
        self.actionStatusClient = actionStatusClient ?? client.actionStatusClient
    }

    var ownsScope: Bool { !isRetired && client.owner != nil }

    var visibleNodes: [HermesLearningGraph.Node] {
        guard let graph else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return graph.nodes.filter { node in
            let kindMatches = switch nodeFilter {
            case .all: true
            case .memories: node.kind == .memory
            case .skills: node.kind == .skill
            }
            guard kindMatches else { return false }
            guard !query.isEmpty else { return true }
            return [node.label, node.rawID, node.category, node.memoryPreview ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        .sorted {
            switch ($0.timestamp, $1.timestamp) {
            case let (left?, right?) where left != right: left > right
            case (_?, nil): true
            case (nil, _?): false
            default: $0.label.localizedStandardCompare($1.label) == .orderedAscending
            }
        }
    }

    func retire() {
        isRetired = true
        generation = UUID()
        detailGeneration = UUID()
        curatorActionGeneration = UUID()
        curatorTrackingTask?.cancel()
        curatorTrackingTask = nil
        memoryStatus = nil
        graph = nil
        curator = nil
        insights = nil
        selectedDetail = nil
        providerConfiguration = nil
        providerOAuth = [:]
        curatorRunReceipt = nil
        curatorActionStatus = nil
        isLoading = false
        isLoadingDetail = false
        isLoadingProvider = false
        isMutating = false
        errorMessage = nil
        successMessage = nil
    }

    func refresh() async {
        guard ownsScope, !Task.isCancelled, !isMutating else { return }
        let request = UUID()
        generation = request
        detailGeneration = UUID()
        selectedDetail = nil
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == request { isLoading = false } }

        var failures = 0
        do {
            let next = try await client.memoryStatus()
            guard canPublish(request) else { return }
            memoryStatus = next
        } catch is CancellationError {
            return
        } catch {
            guard canPublish(request) else { return }
            failures += 1
        }

        do {
            let next = try await client.learningGraph(profile: profileName)
            guard canPublish(request) else { return }
            graph = next
        } catch is CancellationError {
            return
        } catch {
            guard canPublish(request) else { return }
            failures += 1
        }

        do {
            let next = try await client.curatorStatus()
            guard canPublish(request) else { return }
            curator = next
        } catch is CancellationError {
            return
        } catch {
            guard canPublish(request) else { return }
            failures += 1
        }

        do {
            let next = try await client.insights(profile: profileName)
            guard canPublish(request) else { return }
            insights = next
        } catch is CancellationError {
            return
        } catch {
            guard canPublish(request) else { return }
            failures += 1
        }

        if curatorTrackingTask == nil, curatorActionStatus?.phase == .running {
            await refreshRetainedCuratorAction()
            guard canPublish(request) else { return }
        }

        if failures > 0 {
            errorMessage = failures == 4
                ? "Hermes could not load Memory for this workspace. Check the connection and try again."
                : "Some Memory information is unavailable. Pull to refresh before making changes."
        }
    }

    func refreshGraph() async {
        guard ownsScope, !Task.isCancelled, !isMutating else { return }
        let request = UUID()
        generation = request
        detailGeneration = UUID()
        selectedDetail = nil
        isLoading = true
        errorMessage = nil
        defer { if generation == request { isLoading = false } }
        do {
            let next = try await client.learningGraph(profile: profileName)
            guard canPublish(request) else { return }
            graph = next
        } catch is CancellationError {
        } catch {
            guard canPublish(request) else { return }
            errorMessage = message(for: error)
        }
    }

    func loadNode(_ node: HermesLearningGraph.Node) async {
        guard ownsScope, !Task.isCancelled, !isMutating else { return }
        let request = UUID()
        detailGeneration = request
        isLoadingDetail = true
        selectedDetail = nil
        errorMessage = nil
        defer { if detailGeneration == request { isLoadingDetail = false } }
        do {
            let detail = try await client.learningNode(node.rawID, profile: profileName)
            guard canPublishDetail(request), detail.kind == node.kind else { return }
            selectedDetail = detail
        } catch is CancellationError {
        } catch {
            guard canPublishDetail(request) else { return }
            errorMessage = message(for: error)
        }
    }

    func closeNode() {
        detailGeneration = UUID()
        selectedDetail = nil
        isLoadingDetail = false
    }

    func saveNode(_ detail: HermesLearningNodeDetail, content: String) async -> Bool {
        guard ownsScope, !Task.isCancelled, !isMutating,
              selectedDetail?.rawID.utf8.elementsEqual(detail.rawID.utf8) == true else { return false }
        beginMutation()
        errorMessage = nil
        successMessage = nil
        defer { isMutating = false }
        do {
            let readback = try await client.updateLearningNode(detail, content: content, profile: profileName)
            guard ownsScope, !Task.isCancelled else { return false }
            selectedDetail = readback
            graph = try await client.learningGraph(profile: profileName)
            guard ownsScope, !Task.isCancelled else { return false }
            successMessage = readback.kind == .skill ? "Hermes confirmed the skill update." : "Hermes confirmed the memory update."
            return true
        } catch is CancellationError {
            guard ownsScope else { return false }
            errorMessage = "The update was interrupted. Refresh before trying again."
        } catch {
            guard ownsScope else { return false }
            errorMessage = message(for: error)
        }
        return false
    }

    func deleteNode(_ detail: HermesLearningNodeDetail) async -> Bool {
        guard ownsScope, !Task.isCancelled, !isMutating,
              selectedDetail?.rawID.utf8.elementsEqual(detail.rawID.utf8) == true else { return false }
        beginMutation()
        errorMessage = nil
        successMessage = nil
        defer { isMutating = false }
        do {
            graph = try await client.deleteLearningNode(detail, profile: profileName)
            guard ownsScope, !Task.isCancelled else { return false }
            closeNode()
            successMessage = detail.kind == .skill
                ? "Hermes archived the skill. The Curator can restore it."
                : "Hermes permanently deleted the selected memory."
            return true
        } catch is CancellationError {
            guard ownsScope else { return false }
            errorMessage = "The operation was interrupted. Refresh to confirm the current graph before trying again."
        } catch {
            guard ownsScope else { return false }
            errorMessage = message(for: error)
        }
        return false
    }

    func loadProviderConfiguration(_ provider: HermesMemoryProvider) async {
        guard ownsScope, !Task.isCancelled, !isMutating else { return }
        isLoadingProvider = true
        providerConfiguration = nil
        errorMessage = nil
        defer { isLoadingProvider = false }
        do {
            providerConfiguration = try await client.providerConfiguration(provider.name, profile: profileName)
            if provider.name == "honcho" {
                providerOAuth[provider.name] = try? await client.providerOAuthStatus(provider.name, profile: profileName)
            }
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = message(for: error)
        }
    }

    func closeProviderConfiguration() {
        providerConfiguration = nil
        isLoadingProvider = false
    }

    func saveProviderConfiguration(_ configuration: HermesMemoryProviderConfiguration, drafts: [String: String]) async -> Bool {
        guard ownsScope, !Task.isCancelled, !isMutating,
              providerConfiguration?.provider == configuration.provider else { return false }
        beginMutation()
        errorMessage = nil
        successMessage = nil
        defer { isMutating = false }
        do {
            providerConfiguration = try await client.saveProviderConfiguration(
                configuration,
                drafts: drafts,
                profile: profileName
            )
            memoryStatus = try await client.memoryStatus()
            guard ownsScope, !Task.isCancelled else { return false }
            successMessage = "Hermes confirmed the provider configuration. Secret values were not read back."
            return true
        } catch is CancellationError {
            guard ownsScope else { return false }
            errorMessage = "The save was interrupted. Refresh provider settings before trying again."
        } catch {
            guard ownsScope else { return false }
            errorMessage = message(for: error)
        }
        return false
    }

    func selectProvider(_ provider: HermesMemoryProvider?) async {
        guard ownsScope, !Task.isCancelled, !isMutating else { return }
        beginMutation()
        errorMessage = nil
        successMessage = nil
        defer { isMutating = false }
        do {
            memoryStatus = try await client.setProvider(provider?.name ?? "built-in")
            guard ownsScope, !Task.isCancelled else { return }
            successMessage = provider == nil
                ? "Hermes is using built-in memory."
                : "Hermes confirmed \(provider!.name) as the active memory provider."
        } catch is CancellationError {
            guard ownsScope else { return }
            errorMessage = "The provider change was interrupted. Refresh to confirm the active provider."
        } catch {
            guard ownsScope else { return }
            errorMessage = message(for: error)
        }
    }

    func setupProvider(_ provider: HermesMemoryProvider) async {
        guard ownsScope, !Task.isCancelled, !isMutating else { return }
        beginMutation()
        errorMessage = nil
        successMessage = nil
        defer { isMutating = false }
        do {
            let result = try await client.setupProvider(provider.name)
            memoryStatus = try await client.memoryStatus()
            guard ownsScope, !Task.isCancelled else { return }
            successMessage = result.steps.isEmpty
                ? "Hermes found no declared provider setup steps."
                : "Hermes confirmed the provider setup steps."
        } catch is CancellationError {
            guard ownsScope else { return }
            errorMessage = "Provider setup was interrupted. Refresh its status before running setup again."
        } catch {
            guard ownsScope else { return }
            errorMessage = message(for: error)
        }
    }

    func startOAuth(_ provider: HermesMemoryProvider) async {
        guard ownsScope, !Task.isCancelled, !isMutating else { return }
        beginMutation()
        errorMessage = nil
        successMessage = nil
        defer { isMutating = false }
        do {
            let status = try await client.startProviderOAuth(provider.name, profile: profileName)
            guard ownsScope, !Task.isCancelled else { return }
            providerOAuth[provider.name] = status
            successMessage = status.isConnected
                ? "Hermes confirmed the provider connection."
                : "Hermes started the provider sign-in on the host. Check the host browser, then refresh status."
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = message(for: error)
        }
    }

    func refreshOAuth(_ provider: HermesMemoryProvider) async {
        guard ownsScope, !Task.isCancelled, !isMutating else { return }
        do {
            let status = try await client.providerOAuthStatus(provider.name, profile: profileName)
            guard ownsScope, !Task.isCancelled else { return }
            providerOAuth[provider.name] = status
            if status.isConnected {
                memoryStatus = try await client.memoryStatus()
                successMessage = "Hermes confirmed the provider connection."
            }
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = message(for: error)
        }
    }

    func reset(_ target: HermesMemoryResetTarget) async {
        guard ownsScope, !Task.isCancelled, !isMutating else { return }
        beginMutation()
        errorMessage = nil
        successMessage = nil
        defer { isMutating = false }
        do {
            memoryStatus = try await client.reset(target)
            graph = try await client.learningGraph(profile: profileName)
            guard ownsScope, !Task.isCancelled else { return }
            selectedDetail = nil
            successMessage = "Hermes confirmed the built-in memory reset."
        } catch is CancellationError {
            guard ownsScope else { return }
            errorMessage = "The reset was interrupted. Refresh before attempting another reset."
        } catch {
            guard ownsScope else { return }
            errorMessage = message(for: error)
        }
    }

    func setCuratorPaused(_ paused: Bool) async {
        guard ownsScope, !Task.isCancelled, !isMutating else { return }
        beginMutation()
        errorMessage = nil
        successMessage = nil
        defer { isMutating = false }
        do {
            curator = try await client.setCuratorPaused(paused)
            guard ownsScope, !Task.isCancelled else { return }
            successMessage = paused ? "Hermes paused automatic curation." : "Hermes resumed automatic curation."
        } catch is CancellationError {
            guard ownsScope else { return }
            errorMessage = "The Curator change was interrupted. Refresh to confirm its current state."
        } catch {
            guard ownsScope else { return }
            errorMessage = message(for: error)
        }
    }

    func runCurator() async {
        guard ownsScope, !Task.isCancelled, !isMutating else { return }
        guard curatorActionStatus?.phase != .running, curatorTrackingTask == nil else {
            errorMessage = "The retained Curator run is still pending. Refresh its status instead of starting it again."
            return
        }
        beginMutation()
        errorMessage = nil
        successMessage = nil
        defer { isMutating = false }
        do {
            let receipt = try await client.runCurator()
            guard ownsScope, !Task.isCancelled else { return }
            curatorRunReceipt = receipt
            curatorActionStatus = nil
            let token = UUID()
            curatorActionGeneration = token
            guard let actionStatusClient else {
                successMessage = "Hermes admitted the Curator run and Bighelp retained its launch process, but completion tracking is unavailable until the parent injects the shared Host Operations status client."
                return
            }
            let hostReceipt: HermesHostActionReceipt
            do {
                hostReceipt = try receipt.hostReceipt(using: actionStatusClient)
            } catch {
                successMessage = nil
                errorMessage = "Hermes admitted the Curator run, but the shared Host Operations client rejected its exact action slot. The launch receipt is retained; refresh Curator and Knowledge instead of starting it again."
                return
            }
            curatorActionStatus = .init(
                action: hostReceipt.action,
                phase: .running,
                processID: hostReceipt.processID,
                actionID: hostReceipt.actionID,
                correlation: .pendingIdentity,
                updateSummary: nil
            )
            successMessage = "Hermes admitted the Curator run. Completion is pending; Bighelp retained the host’s per-run launch identity."
            curatorTrackingTask?.cancel()
            curatorTrackingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let status = try await actionStatusClient.poll(hostReceipt)
                    guard self.canPublishCuratorAction(token) else { return }
                    self.curatorActionStatus = status
                    self.curatorTrackingTask = nil
                    await self.finishCuratorAction(status, token: token)
                } catch is CancellationError {
                } catch {
                    guard self.canPublishCuratorAction(token) else { return }
                    self.curatorTrackingTask = nil
                    self.successMessage = nil
                    self.errorMessage = "Bighelp could not confirm the Curator run. Its exact launch receipt is retained; refresh Curator and Knowledge instead of starting it again."
                }
            }
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = message(for: error)
        }
    }

    private func refreshRetainedCuratorAction() async {
        guard ownsScope,
              let receipt = curatorRunReceipt,
              let actionStatusClient else { return }
        let token = curatorActionGeneration
        do {
            let hostReceipt = try receipt.hostReceipt(using: actionStatusClient)
            let status = try await actionStatusClient.status(for: hostReceipt)
            guard canPublishCuratorAction(token) else { return }
            curatorActionStatus = status
            await finishCuratorAction(status, token: token)
        } catch is CancellationError {
        } catch {
            guard canPublishCuratorAction(token) else { return }
            successMessage = nil
            errorMessage = "Bighelp could not refresh the retained Curator run. Its exact launch receipt remains available; the action was not repeated."
        }
    }

    private func finishCuratorAction(_ status: HermesHostActionStatus, token: UUID) async {
        guard canPublishCuratorAction(token) else { return }
        guard status.phase != .running else {
            successMessage = "Hermes still reports the Curator run as running. Its exact launch receipt is retained; Bighelp did not repeat the action."
            return
        }

        do {
            let nextCurator = try await client.curatorStatus()
            let nextGraph = try await client.learningGraph(profile: profileName)
            guard canPublishCuratorAction(token) else { return }
            curator = nextCurator
            graph = nextGraph
        } catch {
            guard canPublishCuratorAction(token) else { return }
            successMessage = nil
            switch status.phase {
            case .succeeded:
                errorMessage = "Hermes reported the Curator run succeeded, but Curator and Knowledge could not be read back. Completion is not confirmed in Bighelp. Refresh before acting again."
            case .failed(let code):
                errorMessage = "Hermes reported the Curator run failed with exit code \(code), and Curator and Knowledge could not be refreshed. The action was not retried."
            case .outcomeUnknown:
                errorMessage = "Hermes stopped reporting the Curator run as running without a durable result, and Curator and Knowledge could not be refreshed. The action was not retried."
            case .running:
                break
            }
            return
        }

        let correlation = switch status.correlation {
        case .exactActionID: "the exact host action ID"
        case .matchingProcess: "the retained launch process"
        case .actionSlotOnly: "the named action slot only; this is weaker than per-run correlation"
        case .pendingIdentity: "a host status without a matching per-run identity"
        }
        switch status.phase {
        case .succeeded:
            errorMessage = nil
            successMessage = "Hermes reported the Curator run succeeded for \(correlation), and Bighelp refreshed Curator and Knowledge."
        case .failed(let code):
            successMessage = nil
            errorMessage = "Hermes reported the Curator run failed with exit code \(code) for \(correlation). Bighelp refreshed Curator and Knowledge and did not retry the action."
        case .outcomeUnknown:
            successMessage = nil
            errorMessage = "Hermes stopped reporting the Curator run as running but has no durable exit result for \(correlation). Bighelp refreshed Curator and Knowledge and did not retry the action."
        case .running:
            break
        }
    }

    func dismissMessages() {
        errorMessage = nil
        successMessage = nil
    }

    private func beginMutation() {
        generation = UUID()
        detailGeneration = UUID()
        isLoading = false
        isLoadingDetail = false
        isLoadingProvider = false
        isMutating = true
    }

    private func canPublish(_ request: UUID) -> Bool {
        ownsScope && generation == request && !Task.isCancelled
    }

    private func canPublishDetail(_ request: UUID) -> Bool {
        ownsScope && detailGeneration == request && !Task.isCancelled
    }

    private func canPublishCuratorAction(_ request: UUID) -> Bool {
        ownsScope && curatorActionGeneration == request && !Task.isCancelled
    }

    private func message(for error: any Error) -> String {
        if let error = error as? WorkspaceClientError { return error.localizedDescription }
        if let error = error as? WorkspaceManagementError { return error.localizedDescription }
        return "Hermes could not complete the Memory request. Check the connection and refresh before trying again."
    }
}
