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
    case unavailable(String)

    @MainActor
    static func from(_ error: any Error, hasContent: Bool) -> WorkflowsLoadState {
        switch error {
        case WorkspaceClientError.unavailable(.unsupportedOperation), WorkspaceClientError.unavailable(.pluginRequired):
            return .needsPluginUpdate
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

    let client: any WorkflowsClient
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(client: any WorkflowsClient, pollInterval: Duration = .seconds(15)) {
        self.client = client
        self.pollInterval = pollInterval
    }

    var waiting: [WorkflowRunSummary] { (list?.waiting ?? []).filter { !later.contains($0.id) } }
    /// Active runs, then runs set aside with Later.
    var active: [WorkflowRunSummary] {
        (list?.waiting ?? []).filter { later.contains($0.id) } + (list?.active ?? [])
    }
    var workflows: [WorkflowSummary] { list?.workflows ?? [] }

    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen else { return }
        isOnScreen = onScreen
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
            templates = (try? await client.templates()) ?? []
        }
    }

    func setAside(_ run: WorkflowRunSummary) { later.insert(run.id) }

    /// Makes a draft from a template; returns the new workflow's id.
    func use(_ template: WorkflowTemplate) async throws -> String {
        let id = try await client.useTemplate(id: template.id)
        await load()
        return id
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
