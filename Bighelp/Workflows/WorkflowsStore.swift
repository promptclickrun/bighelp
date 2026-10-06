import Foundation
import Observation

/// What a Workflows screen shows while it loads or can't.
enum WorkflowsLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    /// The host's bighelp plugin predates Workflows.
    case needsPluginUpdate
    /// The plugin has Workflows, but this Hermes can't run them.
    case needsHermesUpdate
    /// The plugin says this computer can't run workflows, with a fixed code.
    case cantRunHere(String)
    case unavailable(String)

    @MainActor
    static func from(_ error: any Error, hasContent: Bool) -> WorkflowsLoadState {
        switch error {
        case WorkspaceClientError.unavailable(.unsupportedOperation), WorkspaceClientError.unavailable(.pluginRequired):
            return .needsPluginUpdate
        case WorkspaceClientError.rejected(let code?) where WorkflowsSupport.unavailableCodes.contains(code):
            return .cantRunHere(code)
        default:
            return .unavailable(hasContent ? "Couldn't refresh. Showing the last result." : WorkflowsStore.reason(error))
        }
    }
}

/// ☰ › Workflows home: the host's status, what waits for you, active runs and
/// your workflows. One per computer. It asks the host every 15 seconds while
/// the home is on screen, and never when it isn't.
@MainActor
@Observable
final class WorkflowsStore {
    private(set) var state: WorkflowsLoadState = .idle
    private(set) var status: WorkflowStatus?
    private(set) var list: WorkflowsList?
    private(set) var recentRuns: [WorkflowRunSummary] = []
    private(set) var templates: [WorkflowTemplate] = []
    /// Waiting runs moved out of the way with Later, until the app closes.
    private(set) var later: Set<String> = []
    private(set) var isOnScreen = false
    /// What the computer's plugin says about Workflows; nil until it's asked.
    private(set) var support: WorkflowsSupport?
    /// What the plugin adds (parallel blocks, delivery, outcomes): the editor offers only these.
    private(set) var features: WorkflowFeatures = []
    /// Asked once per visit, apart from `support`: the ☰ menu's check fills that before this screen opens.
    @ObservationIgnored private var askedFeatures = false
    var canParallel: Bool { features.contains(.parallel) }
    /// A change from a long-press menu that didn't work, in plain words.
    var message: String?

    let client: any WorkflowsClient
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(client: any WorkflowsClient, support: WorkflowsSupport? = nil, pollInterval: Duration = .seconds(15)) {
        self.client = client
        self.support = support
        self.pollInterval = pollInterval
    }

    /// Connections, places, your templates and pins need `native-workflows-edit-v1`.
    var canEdit: Bool { support?.canEdit == true }
    var builtinTemplates: [WorkflowTemplate] { templates.filter { $0.source == .builtin } }
    var yourTemplates: [WorkflowTemplate] { templates.filter { $0.source == .yours } }

    var waiting: [WorkflowRunSummary] { (list?.waiting ?? []).filter { !later.contains($0.id) } }
    /// Active runs, then runs set aside with Later.
    var active: [WorkflowRunSummary] {
        (list?.waiting ?? []).filter { later.contains($0.id) } + (list?.active ?? [])
    }
    var workflows: [WorkflowSummary] { list?.workflows ?? [] }

    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen else { return }
        isOnScreen = onScreen
        // A plugin updated meanwhile shows its features on the next visit.
        if onScreen { askedFeatures = false }
        pollTask?.cancel()
        pollTask = nil
        guard onScreen else { return }
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                await self?.load()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    func load() async {
        if list == nil { state = .loading }
        if support == nil || state == .needsPluginUpdate || isCantRunHere {
            if let answer = try? await client.support() { support = answer }
        }
        if !askedFeatures || state == .needsPluginUpdate {
            features = await client.features()
            askedFeatures = true
        }
        if case .unavailable(let code)? = support {
            state = .cantRunHere(code)
            return
        }
        do {
            let statusValue = try await client.status()
            let listValue = try await client.list(includeArchived: false)
            let recentValue = try await client.runs(workflowID: nil, filter: .all, before: nil, limit: 20)
            guard !Task.isCancelled else { return }
            self.status = statusValue
            self.list = listValue
            recentRuns = recentValue.runs
            state = statusValue.runnerAvailable ? .loaded : .needsHermesUpdate
        } catch is CancellationError {
            return
        } catch {
            state = WorkflowsLoadState.from(error, hasContent: list != nil)
        }
        if templates.isEmpty, state == .loaded {
            await loadTemplates()
        }
    }

    private var isCantRunHere: Bool {
        if case .cantRunHere = state { return true }
        return false
    }

    func loadTemplates() async {
        if let value = try? await client.templates() { templates = value }
    }

    func setAside(_ run: WorkflowRunSummary) { later.insert(run.id) }

    /// Makes a draft from a template; returns the new workflow's id.
    func use(_ template: WorkflowTemplate) async throws -> String {
        let id = try await client.useTemplate(id: template.id)
        await load()
        return id
    }

    /// Create from scratch: an empty draft with this name; returns its id.
    func create(name: String) async throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = try await client.saveDraft(workflowID: nil, baseDraftVersion: 0,
                                               definition: .empty(name: String((name.isEmpty ? "New workflow" : name).prefix(200))))
        await load()
        return saved.workflowID
    }

    // MARK: Long-press actions

    func setPinned(_ workflow: WorkflowSummary, _ pinned: Bool) async {
        await act { _ = try await self.client.pin(workflowID: workflow.id, pinned: pinned) }
    }

    func archive(_ workflow: WorkflowSummary) async {
        await act { try await self.client.archive(workflowID: workflow.id) }
    }

    func unarchive(_ workflowID: String) async {
        await act { try await self.client.unarchive(workflowID: workflowID) }
    }

    /// Saves a workflow's latest version as one of your templates (without who does each role).
    @discardableResult
    func saveTemplate(workflowID: String, name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        do {
            _ = try await client.saveTemplate(workflowID: workflowID, name: String(name.prefix(WorkflowTemplate.nameLimit)),
                                              description: nil)
            await loadTemplates()
            message = nil
            return true
        } catch WorkspaceClientError.rejected(let code) where code == "not_allowed" {
            // The host keeps at most 100 of yours.
            message = "You have 100 templates. Delete one, then save this one."
        } catch {
            message = Self.reason(error)
        }
        return false
    }

    func deleteTemplate(_ template: WorkflowTemplate) async {
        guard template.source == .yours else { return }
        await act { try await self.client.deleteTemplate(id: template.id) }
        await loadTemplates()
    }

    /// Archived workflows, for the Archived list.
    func archived() async throws -> [WorkflowSummary] {
        try await client.list(includeArchived: true).workflows.filter(\.archived)
    }

    private func act(_ change: @escaping @MainActor () async throws -> Void) async {
        do {
            try await change()
            message = nil
        } catch {
            message = Self.reason(error)
        }
        await load()
    }

    static func reason(_ error: any Error) -> String {
        switch error {
        case WorkspaceClientError.authenticationRequired, DirectHermesError.authenticationRequired:
            "Your computer turned down bighelp's sign-in. Sign in to it again in Hosts."
        case DirectHermesError.timedOut:
            "Your computer took too long to answer. Try again in a moment."
        case _ where ProviderUsageStore.isConnectionHiccup(error):
            "bighelp isn't connected to your computer right now. Try again in a moment."
        case WorkspaceClientError.outcomeUnknown:
            // The host may be busy (503) or the answer was lost: look before trying again.
            "Your computer didn't confirm it. Check the runs before you try again."
        case WorkspaceClientError.capacityExceeded:
            "This workflow is too big to save. Make the instructions shorter."
        case WorkspaceClientError.rejected(let code?):
            WorkflowWords.problem(code)
        default:
            "Workflows couldn't be loaded from your computer. Try again in a moment."
        }
    }
}
