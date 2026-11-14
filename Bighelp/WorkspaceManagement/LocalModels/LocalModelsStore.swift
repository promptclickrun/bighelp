import Foundation
import Observation

enum LocalModelsHostSupport: Equatable, Sendable {
    case unknown
    case available
    case unavailable(String)
}

@MainActor
@Observable
final class LocalModelsStore {
    enum Review: Identifiable, Equatable {
        case installRuntime(backend: String?, status: HermesLocalModelsStatus)
        case quickstart(HermesLocalCatalogModel?)
        case download(HermesLocalCatalogModel)
        case downloadBrowsed(repository: String, group: HermesLocalModelFileGroup)
        case sideload(hostPath: String)
        case activate(HermesLocalStagedModel)
        case eject(HermesLocalStagedModel)
        case delete(HermesLocalStagedModel)
        case server(HermesLocalServerAction)

        var id: String {
            switch self {
            case .installRuntime(let backend, _): "runtime\u{1f}\(backend ?? "auto")"
            case .quickstart(let model): "quickstart\u{1f}\(model?.id ?? "recommended")"
            case .download(let model): "download\u{1f}\(model.id)"
            case .downloadBrowsed(let repository, let group): "browse\u{1f}\(repository)\u{1f}\(group.id)"
            case .sideload(let path): "sideload\u{1f}\(path)"
            case .activate(let model): "activate\u{1f}\(model.id)"
            case .eject(let model): "eject\u{1f}\(model.id)"
            case .delete(let model): "delete\u{1f}\(model.id)"
            case .server(let action): "server\u{1f}\(action.rawValue)"
            }
        }

        var title: String {
            switch self {
            case .installRuntime: "Install the local runtime?"
            case .quickstart: "Start local-model setup?"
            case .download: "Download this model?"
            case .downloadBrowsed: "Download these host model files?"
            case .sideload: "Register this host-local model?"
            case .activate: "Use this model for new chats?"
            case .eject: "Eject this model from host memory?"
            case .delete: "Delete this managed model?"
            case .server(.start): "Start the host’s local model server?"
            case .server(.stop): "Stop the host’s local model server?"
            }
        }

        var buttonTitle: String {
            switch self {
            case .installRuntime: "Install Runtime"
            case .quickstart: "Start Setup"
            case .download: "Start Download"
            case .downloadBrowsed: "Download Files"
            case .sideload: "Register Model"
            case .activate: "Use for New Chats"
            case .eject: "Eject from Memory"
            case .delete: "Delete Model"
            case .server(.start): "Start Server"
            case .server(.stop): "Stop Server"
            }
        }

        var isDestructive: Bool {
            switch self {
            case .delete, .eject, .server(.stop): true
            default: false
            }
        }

        var message: String {
            switch self {
            case .installRuntime(let backend, _):
                return "Hermes will download and install the \(backend ?? "automatically selected") llama.cpp runtime on the selected host. This can use network bandwidth and host disk space."
            case .quickstart(let model):
                let choice = model?.displayName ?? "the host’s recommended model"
                return "Hermes will prepare \(choice), installing a runtime and downloading model files when needed. The host reports the download size and job progress; Bighelp will not repeat an uncertain request."
            case .download(let model):
                return "Hermes will download \(model.displayName) (\(model.sizeLabel)) to the selected host. This can incur network transfer and consume host disk space."
            case .downloadBrowsed(let repository, let group):
                return "Hermes will download \(group.label) from \(repository) to the selected host (\(LocalModelsStore.byteLabel(group.totalBytes))). This is an uncurated Hugging Face selection."
            case .sideload(let path):
                return "Hermes will register the existing .gguf at \(path) on the host. This is a host filesystem path, not an \(BighelpPlatform.isMac ? "upload from this Mac" : "iPhone upload"); Hermes may link or copy it into managed storage."
            case .activate(let model):
                return "Hermes will start the host server if needed and make \(model.id) the default for new chats. The model loads into memory on first inference, not from this \(BighelpPlatform.isMac ? "click" : "tap") alone."
            case .eject(let model):
                return "Hermes will unload \(model.id) from host GPU/system memory. The managed model file remains available and demand may load it again."
            case .delete(let model):
                return "Hermes will permanently remove its managed files for \(model.id) and clear related growth state. The original of a sideloaded link remains outside managed storage."
            case .server(.start):
                return "Hermes will enable and start its local model server on the selected host. \(BighelpPlatform.isMac ? "Bighelp itself starts no server." : "No server is started on this iPhone or iPad.")"
            case .server(.stop):
                return "Hermes will stop the selected host’s local model server, unload all resident models, and disable automatic start until it is turned on again."
            }
        }
    }

    let hostName: String
    let profileID: String

    private(set) var support: LocalModelsHostSupport = .unknown
    private(set) var status: HermesLocalModelsStatus?
    private(set) var hardware: HermesLocalHardware?
    private(set) var catalog: [HermesLocalCatalogModel] = []
    private(set) var jobs: [HermesLocalRuntimeJob] = []
    private(set) var searchResults: [HermesLocalModelSearchHit] = []
    private(set) var selectedRepository: String?
    private(set) var repositoryFiles: [HermesLocalModelFileGroup] = []
    private(set) var isLoading = false
    private(set) var isSearching = false
    private(set) var isMutating = false
    private(set) var isRetired = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    var review: Review?

    @ObservationIgnored private let client: any HermesLocalModelsManaging
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    init(
        hostName: String,
        profileID: String,
        client: any HermesLocalModelsManaging,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.hostName = hostName
        self.profileID = profileID
        self.client = client
        self.isCurrent = isCurrent
    }

    var ownsScope: Bool { !isRetired && isCurrent() }
    var canAct: Bool { ownsScope && support == .available && !isLoading && !isMutating }

    func load() async {
        guard ownsScope, !isMutating else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if accepts(token) { isLoading = false } }

        do {
            let next = try await client.status()
            guard accepts(token) else { return }
            status = next
            support = .available
        } catch HermesLocalModelsError.unavailable {
            guard accepts(token) else { return }
            support = .unavailable("Managed local models are not installed or exposed by this Hermes host.")
            status = nil
            hardware = nil
            catalog = []
            jobs = []
            return
        } catch {
            publish(error, token: token)
            return
        }

        var partialFailure = false
        do {
            let value = try await client.hardware()
            guard accepts(token) else { return }
            hardware = value
        } catch { partialFailure = true }
        do {
            let value = try await client.catalog()
            guard accepts(token) else { return }
            catalog = value
        } catch { partialFailure = true }
        do {
            let value = try await client.jobs()
            guard accepts(token) else { return }
            jobs = value
        } catch { partialFailure = true }

        guard accepts(token) else { return }
        if partialFailure {
            errorMessage = "Some Local Models details could not be refreshed. Existing readbacks remain visible."
        }
        startPollingIfNeeded()
    }

    func refresh() async { await load() }

    func search(_ query: String) async {
        guard canAct, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = UUID()
        generation = token
        isSearching = true
        errorMessage = nil
        defer { if accepts(token) { isSearching = false } }
        do {
            let value = try await client.search(query: query, limit: 20)
            guard accepts(token) else { return }
            searchResults = value
            selectedRepository = nil
            repositoryFiles = []
        } catch { publish(error, token: token) }
    }

    func loadRepository(_ repository: String) async {
        guard canAct else { return }
        let token = UUID()
        generation = token
        isSearching = true
        errorMessage = nil
        defer { if accepts(token) { isSearching = false } }
        do {
            let value = try await client.files(repository: repository)
            guard accepts(token) else { return }
            selectedRepository = repository
            repositoryFiles = value
        } catch { publish(error, token: token) }
    }

    func prepareInstallRuntime(backend: String? = nil) {
        if canAct, let status { review = .installRuntime(backend: backend, status: status) }
    }
    func prepareQuickstart(_ model: HermesLocalCatalogModel?) { if canAct { review = .quickstart(model) } }
    func prepareDownload(_ model: HermesLocalCatalogModel) { if canAct { review = .download(model) } }
    func prepareBrowsedDownload(repository: String, group: HermesLocalModelFileGroup) {
        if canAct { review = .downloadBrowsed(repository: repository, group: group) }
    }
    func prepareSideload(hostPath: String) {
        let path = hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if canAct, !path.isEmpty { review = .sideload(hostPath: path) }
    }
    func prepareActivate(_ model: HermesLocalStagedModel) { if canAct { review = .activate(model) } }
    func prepareEject(_ model: HermesLocalStagedModel) { if canAct { review = .eject(model) } }
    func prepareDelete(_ model: HermesLocalStagedModel) { if canAct { review = .delete(model) } }
    func prepareServer(_ action: HermesLocalServerAction) { if canAct { review = .server(action) } }

    func confirm(_ expected: Review) async {
        guard canAct, review == expected else {
            review = nil
            return
        }
        review = nil
        let token = beginMutation()
        defer { finishMutation(token) }
        do {
            try await validateReview(expected)
            guard accepts(token) else { return }
            switch expected {
            case .installRuntime(let backend, _):
                let job = try await client.installRuntime(backend: backend)
                try accept(job: job, token: token, message: "Hermes admitted the runtime installation. Completion is still pending.")
            case .quickstart(let model):
                let admission = try await client.quickstart(modelID: model?.id)
                try accept(job: admission.job, token: token,
                           message: "Hermes admitted setup for \(admission.displayName). Completion is still pending.")
            case .download(let model):
                let admission = try await client.download(modelID: model.id)
                try accept(admission: admission, token: token)
            case .downloadBrowsed(let repository, let group):
                let admission = try await client.download(repository: repository, paths: group.paths)
                try accept(admission: admission, token: token)
            case .sideload(let path):
                let model = try await client.sideload(hostPath: path)
                guard accepts(token) else { return }
                successMessage = "Hermes readback confirmed \(model.id) in managed model storage."
                await refreshAfterMutation(token)
            case .activate(let model):
                let job = try await client.activate(modelID: model.id)
                try accept(job: job, token: token,
                           message: "Hermes admitted the default-model change. The model will load on first inference.")
            case .eject(let model):
                let readback = try await client.eject(modelID: model.id)
                guard accepts(token) else { return }
                status = readback
                successMessage = "Host readback confirms \(model.id) is no longer resident in memory."
            case .delete(let model):
                let readback = try await client.delete(modelID: model.id)
                guard accepts(token) else { return }
                status = readback
                catalog = try await client.catalog()
                guard accepts(token) else { return }
                successMessage = "Host readback confirms the managed files for \(model.id) were removed."
            case .server(let action):
                let readback = try await client.setServer(action)
                guard accepts(token) else { return }
                status = readback
                successMessage = action == .start
                    ? "Host readback confirms the local model server is running."
                    : "Host readback confirms the local model server is stopped and automatic start is disabled."
            }
        } catch HermesLocalModelsError.outcomeUnknown {
            await reconcileUnknownMutation(expected, token: token)
        } catch { publish(error, token: token) }
    }

    func refreshJob(_ job: HermesLocalRuntimeJob) async {
        guard ownsScope else { return }
        do {
            let next = try await client.job(id: job.id)
            guard ownsScope else { return }
            upsert(next)
            if next.state != .running { await refreshTerminalState() }
        } catch { publish(error) }
    }

    func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }

    func retire() {
        isRetired = true
        generation = UUID()
        pollingTask?.cancel()
        pollingTask = nil
        support = .unknown
        status = nil
        hardware = nil
        catalog = []
        jobs = []
        searchResults = []
        selectedRepository = nil
        repositoryFiles = []
        review = nil
        isLoading = false
        isSearching = false
        isMutating = false
        errorMessage = nil
        successMessage = nil
    }

    nonisolated static func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func accept(admission: HermesLocalDownloadAdmission, token: UUID) throws {
        guard accepts(token) else { throw CancellationError() }
        if let job = admission.job {
            try accept(job: job, token: token,
                       message: "Hermes admitted the model download. Completion is still pending.")
        } else {
            successMessage = "Host readback confirms \(admission.modelID) is already downloaded."
        }
    }

    private func accept(job: HermesLocalRuntimeJob, token: UUID, message: String) throws {
        guard accepts(token) else { throw CancellationError() }
        upsert(job)
        successMessage = message
        startPollingIfNeeded()
    }

    private func startPollingIfNeeded() {
        guard ownsScope, jobs.contains(where: { $0.state == .running }), pollingTask == nil else { return }
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<120 {
                if attempt > 0 {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                    catch { break }
                }
                guard self.ownsScope, !Task.isCancelled else { break }
                do {
                    let readback = try await self.client.jobs()
                    guard self.ownsScope else { break }
                    self.jobs = readback
                    if !readback.contains(where: { $0.state == .running }) {
                        self.pollingTask = nil
                        await self.refreshTerminalState()
                        return
                    }
                } catch is CancellationError {
                    break
                } catch {
                    guard self.ownsScope else { break }
                    self.errorMessage = "Bighelp could not refresh Local Models jobs. Existing job IDs are retained; no operation was repeated."
                    break
                }
            }
            guard self.ownsScope else { return }
            self.pollingTask = nil
            if self.jobs.contains(where: { $0.state == .running }) {
                self.successMessage = "Hermes still reports Local Models work in progress. Pull to refresh later; Bighelp will not repeat it."
            }
        }
    }

    private func refreshAfterMutation(_ token: UUID) async {
        do {
            let nextStatus = try await client.status()
            let nextCatalog = try await client.catalog()
            let nextJobs = try await client.jobs()
            guard accepts(token) else { return }
            status = nextStatus
            catalog = nextCatalog
            jobs = nextJobs
            startPollingIfNeeded()
        } catch {
            guard accepts(token) else { return }
            errorMessage = "The host confirmed the operation, but complete Local Models readback failed. Refresh before acting again."
        }
    }

    private func validateReview(_ review: Review) async throws {
        switch review {
        case .installRuntime(_, let reviewed):
            let current = try await client.status()
            guard current.runtimeTag == reviewed.runtimeTag,
                  current.configuredRuntimeTag == reviewed.configuredRuntimeTag,
                  current.isRuntimeInstalled == reviewed.isRuntimeInstalled,
                  current.isRuntimeUpdateAvailable == reviewed.isRuntimeUpdateAvailable else {
                throw HermesLocalModelsError.reviewChanged
            }
        case .quickstart(let model):
            let current = try await client.catalog()
            if let model {
                guard current.first(where: { $0.id == model.id }) == model else {
                    throw HermesLocalModelsError.reviewChanged
                }
            } else {
                guard current.contains(where: { $0.isRecommended }) else {
                    throw HermesLocalModelsError.reviewChanged
                }
            }
        case .download(let model):
            let current = try await client.catalog()
            guard current.first(where: { $0.id == model.id }) == model else {
                throw HermesLocalModelsError.reviewChanged
            }
        case .downloadBrowsed(let repository, let group):
            let current = try await client.files(repository: repository)
            guard current.contains(group) else {
                throw HermesLocalModelsError.reviewChanged
            }
        case .sideload:
            break
        case .activate(let model):
            let current = try await client.status()
            guard current.stagedModels.contains(model), current.activeModelID != model.id else {
                throw HermesLocalModelsError.reviewChanged
            }
        case .eject(let model):
            let current = try await client.status()
            guard current.stagedModels.contains(model),
                  (current.loadedModels[model.id] != nil || current.loadingModels[model.id] != nil) else {
                throw HermesLocalModelsError.reviewChanged
            }
        case .delete(let model):
            let current = try await client.status()
            guard current.stagedModels.contains(model) else {
                throw HermesLocalModelsError.reviewChanged
            }
        case .server(let action):
            let current = try await client.status()
            guard current.isServerRunning != (action == .start) else {
                throw HermesLocalModelsError.reviewChanged
            }
        }
    }

    private func reconcileUnknownMutation(_ review: Review, token: UUID) async {
        do {
            let nextStatus = try await client.status()
            let nextCatalog = try await client.catalog()
            let nextJobs = try await client.jobs()
            guard accepts(token) else { return }
            status = nextStatus
            catalog = nextCatalog
            jobs = nextJobs

            let confirmed: String?
            switch review {
            case .delete(let model) where nextStatus.stagedModels.allSatisfy({ $0.id != model.id }):
                confirmed = "Host readback confirms the managed model was removed."
            case .eject(let model)
                where nextStatus.loadedModels[model.id] == nil && nextStatus.loadingModels[model.id] == nil:
                confirmed = "Host readback confirms the model is no longer resident."
            case .server(let action) where nextStatus.isServerRunning == (action == .start):
                confirmed = "Host readback confirms the requested server state."
            case .activate(let model) where nextStatus.activeModelID == model.id:
                confirmed = "Host readback confirms the model is the new-chat default."
            case .download(let model)
                where nextCatalog.first(where: { $0.id == model.id })?.isDownloaded == true:
                confirmed = "Host readback confirms the selected catalog model is downloaded."
            default:
                confirmed = nil
            }
            if let confirmed {
                successMessage = confirmed
            } else {
                errorMessage = "The request outcome is unknown. Jobs, status, and catalog were refreshed, but they do not uniquely confirm this operation. Bighelp did not repeat it."
            }
            startPollingIfNeeded()
        } catch {
            guard accepts(token) else { return }
            errorMessage = "The request outcome is unknown and authoritative Local Models readback failed. Do not repeat it until the host is checked."
        }
    }

    private func refreshTerminalState() async {
        guard ownsScope else { return }
        do {
            async let nextStatus = client.status()
            async let nextCatalog = client.catalog()
            async let nextHardware = client.hardware()
            let values = try await (nextStatus, nextCatalog, nextHardware)
            guard ownsScope else { return }
            status = values.0
            catalog = values.1
            hardware = values.2
            let failed = jobs.filter { $0.state == .error }
            if let last = failed.first {
                errorMessage = "Hermes reports that \(last.kind.rawValue) failed. Review host status before trying again."
            } else {
                successMessage = "Hermes reports Local Models work completed. Status and catalog were read back."
            }
        } catch {
            guard ownsScope else { return }
            errorMessage = "Local Models work stopped running, but authoritative status could not be refreshed. Do not repeat it until the host is checked."
        }
    }

    private func upsert(_ job: HermesLocalRuntimeJob) {
        jobs.removeAll { $0.id == job.id }
        jobs.insert(job, at: 0)
        if jobs.count > 20 { jobs.removeLast(jobs.count - 20) }
    }

    private func beginMutation() -> UUID {
        let token = UUID()
        generation = token
        isLoading = false
        isSearching = false
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

    private func publish(_ error: any Error, token: UUID? = nil) {
        if let token, !accepts(token) { return }
        guard ownsScope else { return }
        if error is CancellationError { return }
        if let error = error as? HermesLocalModelsError { errorMessage = error.localizedDescription }
        else if let error = error as? DirectHermesError { errorMessage = error.localizedDescription }
        else { errorMessage = "Hermes could not complete this Local Models request. Refresh authoritative state before trying again." }
    }
}
