import Foundation
import Observation

/// One run on screen: its stages, events and sign-off. While the run is
/// working it asks the host every 2 seconds; waiting, finished or off screen,
/// it doesn't. Every control sends the run's version, so a tap on an old
/// screen never acts on a run that already moved on.
@MainActor
@Observable
final class WorkflowRunModel {
    private(set) var detail: WorkflowRunDetail?
    private(set) var events: [WorkflowEvent] = []
    private(set) var state: WorkflowsLoadState = .idle
    private(set) var isWorking = false
    /// A plain sentence after a control or sign-off didn't go through.
    var message: String?
    private(set) var updatedAt: Date?

    /// The sign-off file and the same file one revision earlier, as text.
    private(set) var signoffText: String?
    private(set) var previousText: String?
    private(set) var signoffFileSHA: String?
    private(set) var isLoadingFile = false

    let runID: String
    let client: any WorkflowsClient
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private(set) var isOnScreen = false

    static let maximumEvents = 500

    init(runID: String, client: any WorkflowsClient, pollInterval: Duration = .seconds(2)) {
        self.runID = runID
        self.client = client
        self.pollInterval = pollInterval
    }

    var summary: WorkflowRunSummary? { detail?.summary }
    var isPolling: Bool { pollTask != nil }

    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen else { return }
        isOnScreen = onScreen
        if onScreen {
            Task { await load() }
        } else {
            stopPolling()
        }
    }

    func load() async {
        if detail == nil { state = .loading }
        do {
            let value = try await client.run(id: runID)
            guard !Task.isCancelled else { return }
            detail = value
            updatedAt = .now
            state = .loaded
            await loadEvents()
        } catch is CancellationError {
            return
        } catch {
            state = WorkflowsLoadState.from(error, hasContent: detail != nil)
        }
        updatePolling()
    }

    private func loadEvents() async {
        var pages = 0
        while pages < 5, let page = try? await client.events(runID: runID, after: cursor, limit: 200) {
            pages += 1
            let known = Set(events.map(\.seq))
            events += page.events.filter { !known.contains($0.seq) && $0.seq > cursor }
            if events.count > Self.maximumEvents { events.removeFirst(events.count - Self.maximumEvents) }
            cursor = max(cursor, page.cursor)
            guard page.hasMore, !page.events.isEmpty else { break }
        }
    }

    /// Polls only while the run is working and on screen.
    private func updatePolling() {
        let shouldPoll = isOnScreen && (detail?.summary.state.isWorking ?? false)
        if shouldPoll, pollTask == nil {
            pollTask = Task { [weak self, pollInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: pollInterval)
                    guard !Task.isCancelled, let self else { return }
                    await self.refresh()
                }
            }
        } else if !shouldPoll {
            stopPolling()
        }
    }

    private func refresh() async {
        do {
            let value = try await client.run(id: runID)
            guard !Task.isCancelled else { return }
            detail = value
            updatedAt = .now
            state = .loaded
            await loadEvents()
        } catch is CancellationError {
            return
        } catch {
            state = WorkflowsLoadState.from(error, hasContent: detail != nil)
        }
        if !(detail?.summary.state.isWorking ?? false) || !isOnScreen { stopPolling() }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Controls

    func canDo(_ action: WorkflowRunAction) -> Bool {
        guard let detail else { return false }
        if !detail.allowedActions.isEmpty { return detail.allowedActions.contains(action.rawValue) }
        switch action {
        case .cancel: return !detail.summary.state.isFinished
        case .retry: return [.needsAttention, .failed].contains(detail.summary.state)
        case .pause, .resume: return false
        }
    }

    func perform(_ action: WorkflowRunAction) async {
        guard let detail, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await client.control(runID: runID, action: action, expectedVersion: detail.summary.version)
            message = nil
        } catch WorkspaceClientError.rejected(let code) where code == "run_conflict" || code == "not_allowed" {
            message = "This run changed on your computer. Here is where it is now."
        } catch {
            message = WorkflowsStore.reason(error)
        }
        await load()
    }

    // MARK: Sign-off

    /// Downloads the file waiting for sign-off (and its earlier version).
    func loadSignoffFile() async {
        guard let signoff = detail?.signoff, signoffFileSHA != signoff.artifactSHA256, !isLoadingFile else { return }
        isLoadingFile = true
        defer { isLoadingFile = false }
        do {
            let data = try await WorkflowArtifactReader.read(client: client, runID: runID, sha256: signoff.artifactSHA256)
            signoffText = String(decoding: data, as: UTF8.self)
            signoffFileSHA = signoff.artifactSHA256
            if let previous = detail?.previousVersion(of: signoff), let sha = previous.sha256 {
                previousText = (try? await WorkflowArtifactReader.read(client: client, runID: runID, sha256: sha))
                    .map { String(decoding: $0, as: UTF8.self) }
            } else {
                previousText = nil
            }
        } catch {
            message = "The file couldn't be loaded from your computer. Try again in a moment."
        }
    }

    /// Approves exactly the file on screen, or sends it back with notes.
    /// Returns true when the host took it.
    @discardableResult
    func signoff(_ decision: WorkflowSignoffDecision, notes: String) async -> Bool {
        guard let signoff = detail?.signoff, let sha = signoffFileSHA, sha == signoff.artifactSHA256, !isWorking else {
            return false
        }
        if decision == .changes, notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = "Say what to change, so the agent knows what to do."
            return false
        }
        isWorking = true
        defer { isWorking = false }
        var accepted = false
        do {
            let run = try await client.signoff(runID: runID, stageKey: signoff.stageKey, decision: decision,
                                               artifactSHA256: sha, notes: notes)
            accepted = run.state != .waitingForYou || run.waiting?.stageKey != signoff.stageKey
            message = accepted ? nil : "Your computer didn't confirm it. It still waits for you."
        } catch WorkspaceClientError.rejected(let code) where code == "approval_stale" {
            message = WorkflowWords.problem("approval_stale")
            signoffFileSHA = nil
        } catch WorkspaceClientError.rejected(let code) where code == "not_waiting" {
            message = "This run isn't waiting for you any more."
        } catch {
            message = WorkflowsStore.reason(error)
        }
        await load()
        if signoffFileSHA == nil { await loadSignoffFile() }
        return accepted
    }

    /// The approved file of a finished run, for Share and Save to Files.
    func approvedFile() async -> (name: String, data: Data)? {
        guard let output = detail?.approvedFile, let sha = output.sha256 else { return nil }
        guard let data = try? await WorkflowArtifactReader.read(client: client, runID: runID, sha256: sha) else {
            message = "The file couldn't be loaded from your computer. Try again in a moment."
            return nil
        }
        return (WorkflowSignoff.fileName(output), data)
    }
}
