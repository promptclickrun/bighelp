import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ProjectChangesStoreTests {
    @Test func gitFileDiffSidesDistinguishUntrackedStagedAndMixedChanges() {
        let untracked = ProjectGitFileChange(
            path: "New.swift",
            originalPath: nil,
            indexStatus: "?",
            worktreeStatus: "?",
            kind: .untracked,
            insertions: 1,
            deletions: 0,
            isBinary: false
        )
        let mixed = ProjectGitFileChange(
            path: "Mixed.swift",
            originalPath: nil,
            indexStatus: "M",
            worktreeStatus: "M",
            kind: .ordinary,
            insertions: 2,
            deletions: 1,
            isBinary: false
        )

        #expect(untracked.availableDiffSides == [.worktree])
        #expect(mixed.availableDiffSides == [.staged, .worktree])
    }

    @Test func reopenedSessionWorkspaceSeedsProjectChangesBeforeWorkspaceReload() {
        let target = ProjectChangesTargetResolver.target(
            agentID: "default",
            sessionID: "session-project-reopen",
            restoredWorkspaceID: "project-loopdy",
            restoredWorkspaceName: "bighelp iOS",
            loadedWorkspaceID: nil,
            loadedWorkspaceName: nil
        )

        #expect(target == ProjectGitTarget(
            agentID: "default",
            sessionID: "session-project-reopen",
            workspaceID: "project-loopdy",
            workspaceName: "bighelp iOS"
        ))
    }

    @Test func replacingAnInitialBindWhileItLoadsRetriesInsteadOfStrandingTheRail() async throws {
        let target = ProjectGitTarget(
            agentID: "default",
            sessionID: "session-project-reopen",
            workspaceID: "project-loopdy",
            workspaceName: "bighelp iOS"
        )
        let client = DeferredProjectGitClient()
        let store = ProjectChangesStore(client: client, refreshDebounce: .milliseconds(1))
        let initialBind = Task { await store.bind(target: target, enabled: true) }
        await client.waitForStatusRequest("project-loopdy")

        await store.bind(target: target, enabled: true)
        client.rejectStatus(CancellationError(), workspaceID: "project-loopdy")
        await initialBind.value
        try await Task.sleep(for: .milliseconds(20))

        #expect(client.totalStatusRequestCount == 2)
        guard client.totalStatusRequestCount == 2 else { return }
        client.resolveStatus(projectGitStatus(
            workspaceID: "project-loopdy",
            files: 2,
            insertions: 62,
            deletions: 5
        ))
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.railSummary?.state == .dirty)
    }

    @Test func bindProjectsDirtyStatusIntoTheRailSummary() async {
        let client = ImmediateProjectGitClient(status: projectGitStatus(
            workspaceID: "project-loopdy",
            files: 2,
            insertions: 62,
            deletions: 5
        ))
        let store = ProjectChangesStore(client: client)

        await store.bind(
            target: ProjectGitTarget(
                agentID: "default",
                sessionID: "session-project-git",
                workspaceID: "project-loopdy",
                workspaceName: "bighelp iOS"
            ),
            enabled: true
        )

        #expect(store.railSummary == ProjectChangesRailSummary(
            fileCount: 2,
            insertions: 62,
            deletions: 5,
            workspaceName: "bighelp iOS",
            branch: "main"
        ))
        #expect(client.statusRequests == ["project-loopdy"])
    }

    @Test func railPrefixesAffectedFileCountBeforeInsertionAndDeletionCounts() {
        let summary = ProjectChangesRailSummary(
            fileCount: 12,
            insertions: 100,
            deletions: 8,
            workspaceName: "bighelp AI V2",
            branch: "main"
        )

        #expect(ProjectChangesRailPresentation.visibleLabels(for: summary) == ["12 files", "+100", "−8"])
        #expect(!ProjectChangesRailPresentation.accessibilityLabel(for: summary).contains("bighelp AI V2"))
        #expect(ProjectChangesRailPresentation.accessibilityLabel(for: summary).contains("12 files"))
    }

    @Test func railUsesSingularFileLabelForOneAffectedFile() {
        let summary = ProjectChangesRailSummary(
            fileCount: 1,
            insertions: 7,
            deletions: 2
        )

        #expect(ProjectChangesRailPresentation.visibleLabels(for: summary) == ["1 file", "+7", "−2"])
        #expect(ProjectChangesRailPresentation.accessibilityLabel(for: summary).contains("1 file"))
    }

    @Test func railRemainsReachableWhileLoadingCleanAndFailed() async throws {
        let target = ProjectGitTarget(
            agentID: "default",
            sessionID: "session-project-git",
            workspaceID: "project-loopdy",
            workspaceName: "bighelp iOS"
        )
        let loadingClient = DeferredProjectGitClient()
        let loadingStore = ProjectChangesStore(client: loadingClient)
        let load = Task { await loadingStore.bind(target: target, enabled: true) }
        await loadingClient.waitForStatusRequest("project-loopdy")
        #expect(loadingStore.railSummary?.state == .loading)
        loadingClient.resolveStatus(projectGitStatus(
            workspaceID: "project-loopdy",
            files: 0,
            insertions: 0,
            deletions: 0
        ))
        await load.value
        #expect(loadingStore.railSummary?.state == .clean)
        #expect(loadingStore.railSummary?.branch == "main")

        let failingStore = ProjectChangesStore(client: FailingStatusProjectGitClient())
        await failingStore.bind(target: target, enabled: true)
        #expect(failingStore.railSummary?.state == .failed)
        let failedSummary = try #require(failingStore.railSummary)
        #expect(ProjectChangesRailPresentation.visibleLabels(for: failedSummary) == ["Changes unavailable · Retry"])
    }

    @Test func nonGitProjectDoesNotSurfaceGitUnavailableAsARetryFailure() async throws {
        let target = ProjectGitTarget(
            agentID: "default",
            sessionID: "session-project-git",
            workspaceID: "project-not-git",
            workspaceName: "Notes"
        )
        let store = ProjectChangesStore(client: NonRepositoryProjectGitClient())

        await store.bind(target: target, enabled: true)

        #expect(store.status == nil)
        #expect(store.errorMessage == nil)
        #expect(store.railSummary?.state != .failed)
        let summary = try #require(store.railSummary)
        #expect(ProjectChangesRailPresentation.visibleLabels(for: summary) == ["N/A"])
        #expect(ProjectChangesRailPresentation.accessibilityLabel(for: summary).contains("not available"))
    }

    @Test func confirmedNonRepositoryBindDoesNotRepeatUntilExplicitRefresh() async {
        let client = CountingNonRepositoryProjectGitClient()
        let store = ProjectChangesStore(client: client)
        let target = projectGitTarget(workspaceID: "project-not-git")

        await store.bind(target: target, enabled: true)
        #expect(store.railSummary?.state == .unavailable)

        await store.bind(target: target, enabled: true)

        #expect(client.capabilitiesRequestCount == 1)
        #expect(store.railSummary?.state == .unavailable)
    }

    @Test func explicitRefreshKeepsConfirmedNonRepositoryRailUnavailableWhileRechecking() async {
        let client = DeferredNonRepositoryProjectGitClient()
        let store = ProjectChangesStore(client: client)
        let target = projectGitTarget(workspaceID: "project-not-git")

        await store.bind(target: target, enabled: true)
        #expect(store.railSummary?.state == .unavailable)

        let refresh = Task { await store.refresh() }
        await client.waitForSecondCapabilitiesRequest()
        #expect(store.railSummary?.state == .unavailable)
        client.resolveAsNonRepository()
        await refresh.value

        #expect(store.railSummary?.state == .unavailable)
    }

    @Test func explicitRefreshRecoversWhenAProjectBecomesAGitRepository() async {
        let expected = projectGitStatus(
            workspaceID: "project-not-git",
            files: 1,
            insertions: 4,
            deletions: 2
        )
        let client = RecheckingProjectGitClient(outcomes: [
            .nonRepository,
            .status(expected),
        ])
        let store = ProjectChangesStore(client: client)
        let target = projectGitTarget(workspaceID: "project-not-git")

        await store.bind(target: target, enabled: true)
        #expect(store.railSummary?.state == .unavailable)

        await store.refresh()

        #expect(store.errorMessage == nil)
        #expect(store.railSummary?.state == .dirty)
        #expect(store.status == expected)
    }

    @Test func explicitRefreshPreservesRetryForARealFailureAfterNonRepositoryState() async throws {
        let client = RecheckingProjectGitClient(outcomes: [
            .nonRepository,
            .failure(BighelpLinkWorkspaceClientError.invalidResponse),
        ])
        let store = ProjectChangesStore(client: client)
        let target = projectGitTarget(workspaceID: "project-not-git")

        await store.bind(target: target, enabled: true)
        #expect(store.railSummary?.state == .unavailable)

        await store.refresh()

        let summary = try #require(store.railSummary)
        #expect(summary.state == .failed)
        #expect(ProjectChangesRailPresentation.visibleLabels(for: summary) == ["Changes unavailable · Retry"])
    }

    @Test func refreshRequestsDebounceAndPreserveTheLastConfirmedStatus() async {
        let client = SequencedProjectGitClient(statuses: [
            projectGitStatus(workspaceID: "project-loopdy", files: 1, insertions: 2, deletions: 0),
            projectGitStatus(workspaceID: "project-loopdy", files: 2, insertions: 3, deletions: 1),
        ])
        let store = ProjectChangesStore(client: client, refreshDebounce: .milliseconds(20))
        await store.bind(
            target: ProjectGitTarget(
                agentID: "default",
                sessionID: "session-project-git",
                workspaceID: "project-loopdy"
            ),
            enabled: true
        )

        store.requestRefresh()
        store.requestRefresh()
        store.requestRefresh()
        #expect(store.railSummary?.fileCount == 1)
        await client.waitForStatusRequestCount(2)

        #expect(client.statusRequestCount == 2)
        #expect(store.railSummary?.fileCount == 2)
    }

    @Test func disabledSettingClearsProjectStateWithoutCallingHermes() async {
        let client = ImmediateProjectGitClient(status: projectGitStatus(
            workspaceID: "project-loopdy",
            files: 1,
            insertions: 1,
            deletions: 0
        ))
        let store = ProjectChangesStore(client: client)

        await store.bind(
            target: ProjectGitTarget(
                agentID: "default",
                sessionID: "session-project-git",
                workspaceID: "project-loopdy"
            ),
            enabled: false
        )

        #expect(store.target == nil)
        #expect(store.status == nil)
        #expect(client.statusRequests.isEmpty)
    }

    @Test func aLateStatusFromThePreviousProjectCannotReplaceTheNewTarget() async {
        let client = DeferredProjectGitClient()
        let store = ProjectChangesStore(client: client)
        let first = ProjectGitTarget(
            agentID: "default",
            sessionID: "session-project-git",
            workspaceID: "project-first"
        )
        let second = ProjectGitTarget(
            agentID: "default",
            sessionID: "session-project-git",
            workspaceID: "project-second"
        )

        let firstTask = Task { await store.bind(target: first, enabled: true) }
        await client.waitForStatusRequest("project-first")
        let secondTask = Task { await store.bind(target: second, enabled: true) }
        await client.waitForStatusRequest("project-second")

        client.resolveStatus(projectGitStatus(
            workspaceID: "project-second",
            files: 3,
            insertions: 9,
            deletions: 1
        ))
        client.resolveStatus(projectGitStatus(
            workspaceID: "project-first",
            files: 99,
            insertions: 999,
            deletions: 999
        ))
        await firstTask.value
        await secondTask.value

        #expect(store.target == second)
        #expect(store.status?.workspaceID == "project-second")
        #expect(store.railSummary?.fileCount == 3)
    }

    @Test func aLateDiffCannotReplaceTheMoreRecentlySelectedFile() async {
        let client = DeferredDiffProjectGitClient(status: projectGitStatus(
            workspaceID: "project-loopdy",
            files: 2,
            insertions: 4,
            deletions: 1
        ))
        let store = ProjectChangesStore(client: client)
        await store.bind(
            target: ProjectGitTarget(
                agentID: "default",
                sessionID: "session-project-git",
                workspaceID: "project-loopdy"
            ),
            enabled: true
        )

        let first = Task {
            await store.loadDiff(path: "First.swift", side: .worktree)
        }
        await client.waitForDiffRequest("First.swift")
        let second = Task {
            await store.loadDiff(path: "Second.swift", side: .worktree)
        }
        await client.waitForDiffRequest("Second.swift")

        client.resolveDiff(path: "Second.swift")
        client.resolveDiff(path: "First.swift")
        await first.value
        await second.value

        #expect(store.diff?.path == "Second.swift")
        #expect(!store.isLoadingDiff)
    }

    @Test func staleStatusRefreshesOnceAndRetriesTheSelectedMarkdownDiff() async {
        let oldToken = "sha256:\(String(repeating: "a", count: 64))"
        let newToken = "sha256:\(String(repeating: "c", count: 64))"
        let client = StaleThenSuccessfulDiffProjectGitClient(
            statuses: [
                projectGitStatus(
                    workspaceID: "project-loopdy",
                    files: [projectGitFile(path: "README.md")],
                    statusToken: oldToken
                ),
                projectGitStatus(
                    workspaceID: "project-loopdy",
                    files: [projectGitFile(path: "README.md")],
                    statusToken: newToken
                ),
            ],
            successfulPage: ProjectGitDiffPage(
                path: "README.md",
                side: .worktree,
                availability: .available,
                offset: 0,
                lines: [ProjectGitDiffLine(
                    offset: 0,
                    kind: .addition,
                    oldLine: nil,
                    newLine: 1,
                    content: "# bighelp"
                )],
                nextOffset: nil,
                previewContent: "# bighelp"
            )
        )
        let store = ProjectChangesStore(client: client)
        await store.bind(
            target: ProjectGitTarget(
                agentID: "default",
                sessionID: "session-project-git",
                workspaceID: "project-loopdy"
            ),
            enabled: true
        )

        await store.loadDiff(path: "README.md", side: .worktree)

        #expect(client.statusTokensUsedForDiff == [oldToken, newToken])
        #expect(client.statusRequestCount == 2)
        #expect(store.diff?.path == "README.md")
        #expect(store.diff?.previewContent == "# bighelp")
        #expect(store.errorMessage == nil)
    }

    @Test func staleRecoveryIsBoundedToOneRetry() async {
        let client = StaleThenSuccessfulDiffProjectGitClient(
            statuses: [
                projectGitStatus(
                    workspaceID: "project-loopdy",
                    files: [projectGitFile(path: "README.md")],
                    statusToken: "sha256:\(String(repeating: "a", count: 64))"
                ),
                projectGitStatus(
                    workspaceID: "project-loopdy",
                    files: [projectGitFile(path: "README.md")],
                    statusToken: "sha256:\(String(repeating: "c", count: 64))"
                ),
            ],
            staleDiffRequestCount: 2,
            successfulPage: emptyDiffPage(path: "README.md")
        )
        let store = ProjectChangesStore(client: client)
        await store.bind(target: projectGitTarget(), enabled: true)

        await store.loadDiff(path: "README.md", side: .worktree)

        #expect(client.statusTokensUsedForDiff.count == 2)
        #expect(client.statusRequestCount == 2)
        #expect(store.diff == nil)
        #expect(store.errorMessage != nil)
    }

    @Test func nonStatusChangedDiffFailureDoesNotRefreshOrRetry() async {
        let status = projectGitStatus(
            workspaceID: "project-loopdy",
            files: [projectGitFile(path: "README.md")],
            statusToken: "sha256:\(String(repeating: "a", count: 64))"
        )
        let client = FailingDiffProjectGitClient(status: status)
        let store = ProjectChangesStore(client: client)
        await store.bind(target: projectGitTarget(), enabled: true)

        await store.loadDiff(path: "README.md", side: .worktree)

        #expect(client.statusRequestCount == 1)
        #expect(client.diffRequestCount == 1)
        #expect(store.errorMessage != nil)
    }

    @Test func staleRecoveryDoesNotRetryWhenTheRequestedSideDisappears() async {
        let stagedOnly = ProjectGitFileChange(
            path: "README.md",
            originalPath: nil,
            indexStatus: "M",
            worktreeStatus: ".",
            kind: .ordinary,
            insertions: 1,
            deletions: 0,
            isBinary: false
        )
        let client = StaleThenSuccessfulDiffProjectGitClient(
            statuses: [
                projectGitStatus(
                    workspaceID: "project-loopdy",
                    files: [projectGitFile(path: "README.md")],
                    statusToken: "sha256:\(String(repeating: "a", count: 64))"
                ),
                projectGitStatus(
                    workspaceID: "project-loopdy",
                    files: [stagedOnly],
                    statusToken: "sha256:\(String(repeating: "c", count: 64))"
                ),
            ],
            successfulPage: emptyDiffPage(path: "README.md")
        )
        let store = ProjectChangesStore(client: client)
        await store.bind(target: projectGitTarget(), enabled: true)

        await store.loadDiff(path: "README.md", side: .worktree)

        #expect(client.statusTokensUsedForDiff.count == 1)
        #expect(store.status?.files.first?.availableDiffSides == [.staged])
        #expect(store.diff == nil)
        #expect(store.errorMessage != nil)
    }

    @Test func stalePagedDiffRestartsAtZeroAndReplacesTheOldSnapshot() async {
        let client = PagingStaleProjectGitClient()
        let store = ProjectChangesStore(client: client)
        await store.bind(target: projectGitTarget(), enabled: true)
        await store.loadDiff(path: "README.md", side: .worktree, offset: 0, limit: 1)
        await store.prepare(.fetch(remote: "origin"))
        #expect(store.preparedOperation != nil)

        await store.loadDiff(path: "README.md", side: .worktree, offset: 1, limit: 1)

        #expect(client.diffOffsets == [0, 1, 0])
        #expect(client.diffLimits == [1, 1, 1])
        #expect(store.diff?.lines.map(\.content) == ["# bighelp refreshed"])
        #expect(store.diff?.previewContent == "# bighelp refreshed")
        #expect(store.diff?.nextOffset == 1)
        #expect(store.preparedOperation == nil)
        #expect(store.pendingMutation == nil)
    }

    @Test func staleRecoveryCannotReplaceASupersedingProject() async {
        let client = SupersededStaleRecoveryProjectGitClient()
        let store = ProjectChangesStore(client: client)
        await store.bind(target: projectGitTarget(workspaceID: "project-first"), enabled: true)
        let load = Task { await store.loadDiff(path: "README.md", side: .worktree) }
        await client.waitForRecoveryStatusRequest()

        await store.bind(target: projectGitTarget(workspaceID: "project-second"), enabled: true)
        client.resolveRecoveryStatus()
        await load.value

        #expect(store.target?.workspaceID == "project-second")
        #expect(store.status?.workspaceID == "project-second")
        #expect(client.diffRequestCount == 1)
        #expect(store.diff == nil)
    }

    @Test func failedExecutionClearsTheExpiredConfirmationSoItCanBePreparedAgain() async {
        let client = FailingMutationProjectGitClient(status: projectGitStatus(
            workspaceID: "project-loopdy",
            files: 1,
            insertions: 1,
            deletions: 0
        ))
        let store = ProjectChangesStore(client: client)
        await store.bind(
            target: ProjectGitTarget(
                agentID: "default",
                sessionID: "session-project-git",
                workspaceID: "project-loopdy"
            ),
            enabled: true
        )

        await store.prepare(.fetch(remote: "origin"))
        #expect(store.preparedOperation != nil)
        await store.executePrepared()

        #expect(store.preparedOperation == nil)
        #expect(store.pendingMutation == nil)
        #expect(store.errorMessage != nil)
    }
}

@MainActor
private final class ImmediateProjectGitClient: ProjectGitClient {
    let returnedStatus: ProjectGitStatus
    private(set) var statusRequests: [String] = []

    init(status: ProjectGitStatus) {
        returnedStatus = status
    }

    func capabilities(
        agentID: String,
        sessionID: String,
        workspaceID: String
    ) async throws -> ProjectGitCapabilities {
        projectGitCapabilities(workspaceID: workspaceID)
    }

    func status(
        agentID: String,
        sessionID: String,
        workspaceID: String
    ) async throws -> ProjectGitStatus {
        statusRequests.append(workspaceID)
        return returnedStatus
    }

    func diff(
        agentID: String,
        sessionID: String,
        workspaceID: String,
        path: String,
        side: ProjectGitDiffSide,
        statusToken: String,
        offset: Int,
        limit: Int
    ) async throws -> ProjectGitDiffPage {
        throw CancellationError()
    }

    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation {
        throw CancellationError()
    }

    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult {
        throw CancellationError()
    }
}

@MainActor
private final class FailingStatusProjectGitClient: ProjectGitClient {
    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        projectGitCapabilities(workspaceID: workspaceID)
    }

    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func diff(agentID: String, sessionID: String, workspaceID: String, path: String, side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage { throw CancellationError() }
    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation { throw CancellationError() }
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult { throw CancellationError() }
}

@MainActor
private final class NonRepositoryProjectGitClient: ProjectGitClient {
    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        throw BighelpLinkWorkspaceClientError.remote(
            status: .failed,
            code: "project_not_repository",
            message: "This project is not a Git repository."
        )
    }

    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus {
        throw CancellationError()
    }

    func diff(agentID: String, sessionID: String, workspaceID: String, path: String, side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage { throw CancellationError() }
    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation { throw CancellationError() }
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult { throw CancellationError() }
}

@MainActor
private final class CountingNonRepositoryProjectGitClient: ProjectGitClient {
    private(set) var capabilitiesRequestCount = 0

    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        capabilitiesRequestCount += 1
        throw BighelpLinkWorkspaceClientError.remote(
            status: .failed,
            code: "project_not_repository",
            message: "This project is not a Git repository."
        )
    }

    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus { throw CancellationError() }
    func diff(agentID: String, sessionID: String, workspaceID: String, path: String, side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage { throw CancellationError() }
    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation { throw CancellationError() }
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult { throw CancellationError() }
}

@MainActor
private final class DeferredNonRepositoryProjectGitClient: ProjectGitClient {
    private var capabilitiesRequestCount = 0
    private var continuation: CheckedContinuation<ProjectGitCapabilities, Error>?

    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        capabilitiesRequestCount += 1
        if capabilitiesRequestCount == 1 {
            throw BighelpLinkWorkspaceClientError.remote(
                status: .failed,
                code: "project_not_repository",
                message: "This project is not a Git repository."
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitForSecondCapabilitiesRequest() async {
        while capabilitiesRequestCount < 2 { await Task.yield() }
    }

    func resolveAsNonRepository() {
        continuation?.resume(throwing: BighelpLinkWorkspaceClientError.remote(
            status: .failed,
            code: "project_not_repository",
            message: "This project is not a Git repository."
        ))
        continuation = nil
    }

    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus { throw CancellationError() }
    func diff(agentID: String, sessionID: String, workspaceID: String, path: String, side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage { throw CancellationError() }
    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation { throw CancellationError() }
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult { throw CancellationError() }
}

@MainActor
private final class RecheckingProjectGitClient: ProjectGitClient {
    enum Outcome {
        case nonRepository
        case status(ProjectGitStatus)
        case failure(Error)
    }

    private var outcomes: [Outcome]
    private var pendingStatus: ProjectGitStatus?

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        switch outcomes.removeFirst() {
        case .nonRepository:
            throw BighelpLinkWorkspaceClientError.remote(
                status: .failed,
                code: "project_not_repository",
                message: "This project is not a Git repository."
            )
        case .status(let status):
            pendingStatus = status
            return projectGitCapabilities(workspaceID: workspaceID)
        case .failure(let error):
            throw error
        }
    }

    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus {
        guard let pendingStatus else { throw CancellationError() }
        self.pendingStatus = nil
        return pendingStatus
    }

    func diff(agentID: String, sessionID: String, workspaceID: String, path: String, side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage { throw CancellationError() }
    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation { throw CancellationError() }
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult { throw CancellationError() }
}

@MainActor
private final class SequencedProjectGitClient: ProjectGitClient {
    private var statuses: [ProjectGitStatus]
    private(set) var statusRequestCount = 0

    init(statuses: [ProjectGitStatus]) {
        self.statuses = statuses
    }

    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        projectGitCapabilities(workspaceID: workspaceID)
    }

    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus {
        statusRequestCount += 1
        return statuses.removeFirst()
    }

    func waitForStatusRequestCount(_ count: Int) async {
        while statusRequestCount < count { await Task.yield() }
    }

    func diff(agentID: String, sessionID: String, workspaceID: String, path: String, side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage { throw CancellationError() }
    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation { throw CancellationError() }
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult { throw CancellationError() }
}

@MainActor
private final class DeferredProjectGitClient: ProjectGitClient {
    private var requestedWorkspaces: [String] = []
    private var continuations: [CheckedContinuation<ProjectGitStatus, Error>] = []
    private(set) var totalStatusRequestCount = 0

    func capabilities(
        agentID: String,
        sessionID: String,
        workspaceID: String
    ) async throws -> ProjectGitCapabilities {
        projectGitCapabilities(workspaceID: workspaceID)
    }

    func status(
        agentID: String,
        sessionID: String,
        workspaceID: String
    ) async throws -> ProjectGitStatus {
        totalStatusRequestCount += 1
        requestedWorkspaces.append(workspaceID)
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForStatusRequest(_ workspaceID: String) async {
        while !requestedWorkspaces.contains(workspaceID) {
            await Task.yield()
        }
    }

    func resolveStatus(_ status: ProjectGitStatus) {
        let index = requestedWorkspaces.firstIndex(of: status.workspaceID)!
        continuations.remove(at: index).resume(returning: status)
        requestedWorkspaces.remove(at: index)
    }

    func rejectStatus(_ error: Error, workspaceID: String) {
        let index = requestedWorkspaces.firstIndex(of: workspaceID)!
        continuations.remove(at: index).resume(throwing: error)
        requestedWorkspaces.remove(at: index)
    }

    func diff(
        agentID: String,
        sessionID: String,
        workspaceID: String,
        path: String,
        side: ProjectGitDiffSide,
        statusToken: String,
        offset: Int,
        limit: Int
    ) async throws -> ProjectGitDiffPage {
        throw CancellationError()
    }

    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation {
        throw CancellationError()
    }

    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult {
        throw CancellationError()
    }
}

@MainActor
private final class DeferredDiffProjectGitClient: ProjectGitClient {
    private let returnedStatus: ProjectGitStatus
    private var requestedPaths: [String] = []
    private var continuations: [CheckedContinuation<ProjectGitDiffPage, Error>] = []

    init(status: ProjectGitStatus) {
        returnedStatus = status
    }

    func capabilities(
        agentID: String,
        sessionID: String,
        workspaceID: String
    ) async throws -> ProjectGitCapabilities {
        projectGitCapabilities(workspaceID: workspaceID)
    }

    func status(
        agentID: String,
        sessionID: String,
        workspaceID: String
    ) async throws -> ProjectGitStatus {
        returnedStatus
    }

    func diff(
        agentID: String,
        sessionID: String,
        workspaceID: String,
        path: String,
        side: ProjectGitDiffSide,
        statusToken: String,
        offset: Int,
        limit: Int
    ) async throws -> ProjectGitDiffPage {
        requestedPaths.append(path)
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForDiffRequest(_ path: String) async {
        while !requestedPaths.contains(path) {
            await Task.yield()
        }
    }

    func resolveDiff(path: String) {
        let index = requestedPaths.firstIndex(of: path)!
        continuations.remove(at: index).resume(returning: ProjectGitDiffPage(
            path: path,
            side: .worktree,
            availability: .available,
            offset: 0,
            lines: [],
            nextOffset: nil
        ))
        requestedPaths.remove(at: index)
    }

    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation {
        throw CancellationError()
    }

    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult {
        throw CancellationError()
    }
}

@MainActor
private final class StaleThenSuccessfulDiffProjectGitClient: ProjectGitClient {
    private var statuses: [ProjectGitStatus]
    private let staleDiffRequestCount: Int
    private let successfulPage: ProjectGitDiffPage
    private(set) var statusRequestCount = 0
    private(set) var statusTokensUsedForDiff: [String] = []

    init(
        statuses: [ProjectGitStatus],
        staleDiffRequestCount: Int = 1,
        successfulPage: ProjectGitDiffPage
    ) {
        self.statuses = statuses
        self.staleDiffRequestCount = staleDiffRequestCount
        self.successfulPage = successfulPage
    }

    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        projectGitCapabilities(workspaceID: workspaceID)
    }

    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus {
        statusRequestCount += 1
        return statuses.removeFirst()
    }

    func diff(
        agentID: String,
        sessionID: String,
        workspaceID: String,
        path: String,
        side: ProjectGitDiffSide,
        statusToken: String,
        offset: Int,
        limit: Int
    ) async throws -> ProjectGitDiffPage {
        statusTokensUsedForDiff.append(statusToken)
        if statusTokensUsedForDiff.count <= staleDiffRequestCount {
            throw BighelpLinkWorkspaceClientError.remote(
                status: .conflict,
                code: "status_changed",
                message: "Project changes changed. Refresh and try again."
            )
        }
        return successfulPage
    }

    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation { throw CancellationError() }
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult { throw CancellationError() }
}

@MainActor
private final class FailingDiffProjectGitClient: ProjectGitClient {
    private let returnedStatus: ProjectGitStatus
    private(set) var statusRequestCount = 0
    private(set) var diffRequestCount = 0

    init(status: ProjectGitStatus) { returnedStatus = status }

    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        projectGitCapabilities(workspaceID: workspaceID)
    }

    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus {
        statusRequestCount += 1
        return returnedStatus
    }

    func diff(agentID: String, sessionID: String, workspaceID: String, path: String, side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage {
        diffRequestCount += 1
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation { throw CancellationError() }
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult { throw CancellationError() }
}

@MainActor
private final class PagingStaleProjectGitClient: ProjectGitClient {
    private var statusRequestCount = 0
    private(set) var diffOffsets: [Int] = []
    private(set) var diffLimits: [Int] = []

    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        projectGitCapabilities(workspaceID: workspaceID)
    }

    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus {
        statusRequestCount += 1
        return projectGitStatus(
            workspaceID: workspaceID,
            files: [projectGitFile(path: "README.md")],
            statusToken: "sha256:\(String(repeating: statusRequestCount == 1 ? "a" : "c", count: 64))"
        )
    }

    func diff(agentID: String, sessionID: String, workspaceID: String, path: String, side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage {
        diffOffsets.append(offset)
        diffLimits.append(limit)
        if diffOffsets.count == 2 {
            throw BighelpLinkWorkspaceClientError.remote(status: .conflict, code: "status_changed", message: nil)
        }
        if offset == 0 {
            let refreshed = diffOffsets.count > 2
            return ProjectGitDiffPage(
                path: path,
                side: side,
                availability: .available,
                offset: 0,
                lines: [ProjectGitDiffLine(
                    offset: 0,
                    kind: .addition,
                    oldLine: nil,
                    newLine: 1,
                    content: refreshed ? "# bighelp refreshed" : "# bighelp"
                )],
                nextOffset: 1,
                previewContent: refreshed ? "# bighelp refreshed" : "# bighelp\n\nText"
            )
        }
        return ProjectGitDiffPage(
            path: path,
            side: side,
            availability: .available,
            offset: offset,
            lines: [ProjectGitDiffLine(offset: offset, kind: .addition, oldLine: nil, newLine: 2, content: "Text")],
            nextOffset: nil
        )
    }

    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation {
        ProjectGitPreparedOperation(
            operation: request.mutation.operation,
            confirmationToken: "confirmation_token_0123456789",
            operationDigest: "sha256:\(String(repeating: "a", count: 64))",
            expiresAt: .distantFuture,
            preview: ProjectGitOperationPreview(
                summary: "Fetch origin",
                paths: [],
                remote: "origin",
                branch: nil,
                commits: nil
            )
        )
    }
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult { throw CancellationError() }
}

@MainActor
private final class SupersededStaleRecoveryProjectGitClient: ProjectGitClient {
    private var firstStatusReturned = false
    private var recoveryStatusRequested = false
    private var recoveryContinuation: CheckedContinuation<ProjectGitStatus, Never>?
    private(set) var diffRequestCount = 0

    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        projectGitCapabilities(workspaceID: workspaceID)
    }

    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus {
        if workspaceID == "project-second" {
            return status(workspaceID: workspaceID, tokenCharacter: "d")
        }
        if !firstStatusReturned {
            firstStatusReturned = true
            return status(workspaceID: workspaceID, tokenCharacter: "a")
        }
        recoveryStatusRequested = true
        return await withCheckedContinuation { continuation in
            recoveryContinuation = continuation
        }
    }

    func diff(agentID: String, sessionID: String, workspaceID: String, path: String, side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage {
        diffRequestCount += 1
        throw BighelpLinkWorkspaceClientError.remote(status: .conflict, code: "status_changed", message: nil)
    }

    func waitForRecoveryStatusRequest() async {
        while !recoveryStatusRequested { await Task.yield() }
    }

    func resolveRecoveryStatus() {
        recoveryContinuation?.resume(returning: status(workspaceID: "project-first", tokenCharacter: "c"))
        recoveryContinuation = nil
    }

    private func status(workspaceID: String, tokenCharacter: String) -> ProjectGitStatus {
        projectGitStatus(
            workspaceID: workspaceID,
            files: [projectGitFile(path: "README.md")],
            statusToken: "sha256:\(String(repeating: tokenCharacter, count: 64))"
        )
    }

    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation { throw CancellationError() }
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult { throw CancellationError() }
}

@MainActor
private final class FailingMutationProjectGitClient: ProjectGitClient {
    private let returnedStatus: ProjectGitStatus

    init(status: ProjectGitStatus) {
        returnedStatus = status
    }

    func capabilities(
        agentID: String,
        sessionID: String,
        workspaceID: String
    ) async throws -> ProjectGitCapabilities {
        projectGitCapabilities(workspaceID: workspaceID)
    }

    func status(
        agentID: String,
        sessionID: String,
        workspaceID: String
    ) async throws -> ProjectGitStatus {
        returnedStatus
    }

    func diff(
        agentID: String,
        sessionID: String,
        workspaceID: String,
        path: String,
        side: ProjectGitDiffSide,
        statusToken: String,
        offset: Int,
        limit: Int
    ) async throws -> ProjectGitDiffPage {
        throw CancellationError()
    }

    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation {
        ProjectGitPreparedOperation(
            operation: request.mutation.operation,
            confirmationToken: "confirmation_token_0123456789",
            operationDigest: "sha256:\(String(repeating: "a", count: 64))",
            expiresAt: .distantFuture,
            preview: ProjectGitOperationPreview(
                summary: "Fetch origin",
                paths: [],
                remote: "origin",
                branch: nil,
                commits: nil
            )
        )
    }

    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }
}

@MainActor
private func projectGitCapabilities(workspaceID: String) -> ProjectGitCapabilities {
    ProjectGitCapabilities(
        schemaVersion: 1,
        capabilities: ProjectGitCapabilityFlags(
            status: true,
            stage: true,
            commit: true,
            push: true,
            fetch: true,
            pull: true,
            arbitraryCommand: false
        ),
        workspaces: [
            ProjectGitWorkspaceCapabilities(
                workspaceID: workspaceID,
                label: "Project",
                visibility: "private",
                operations: ProjectGitCapabilityOperation.allCases,
                remotes: ["origin"],
                branches: ["main"],
                mutationsEnabled: true
            ),
        ]
    )
}

private func projectGitStatus(
    workspaceID: String,
    files: Int,
    insertions: Int,
    deletions: Int
) -> ProjectGitStatus {
    let fileRows = (0..<files).map { index in
        ProjectGitFileChange(
            path: "File\(index).swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary,
            insertions: index == 0 ? insertions : 0,
            deletions: index == 0 ? deletions : 0,
            isBinary: false
        )
    }
    let page = ProjectGitPageMetadata(
        offset: 0,
        limit: 500,
        returned: files,
        total: files,
        nextOffset: nil,
        isComplete: true
    )
    return ProjectGitStatus(
        workspaceID: workspaceID,
        statusToken: "sha256:\(String(repeating: "a", count: 64))",
        head: ProjectGitHead(
            oid: String(repeating: "b", count: 40),
            branch: "main",
            isDetached: false,
            upstream: "origin/main",
            ahead: 0,
            behind: 0
        ),
        files: fileRows,
        filesPage: page,
        staged: ProjectGitChangeCounts(files: 0, insertions: 0, deletions: 0),
        changes: ProjectGitChangeCounts(
            files: files,
            insertions: insertions,
            deletions: deletions
        ),
        conflicts: [],
        conflictsPage: ProjectGitPageMetadata(
            offset: 0,
            limit: 500,
            returned: 0,
            total: 0,
            nextOffset: nil,
            isComplete: true
        ),
        isDirty: files > 0
    )
}

private func projectGitTarget(workspaceID: String = "project-loopdy") -> ProjectGitTarget {
    ProjectGitTarget(
        agentID: "default",
        sessionID: "session-project-git",
        workspaceID: workspaceID
    )
}

private func emptyDiffPage(path: String) -> ProjectGitDiffPage {
    ProjectGitDiffPage(
        path: path,
        side: .worktree,
        availability: .available,
        offset: 0,
        lines: [],
        nextOffset: nil
    )
}

private func projectGitFile(path: String) -> ProjectGitFileChange {
    ProjectGitFileChange(
        path: path,
        originalPath: nil,
        indexStatus: ".",
        worktreeStatus: "M",
        kind: .ordinary,
        insertions: 1,
        deletions: 0,
        isBinary: false
    )
}

private func projectGitStatus(
    workspaceID: String,
    files: [ProjectGitFileChange],
    statusToken: String
) -> ProjectGitStatus {
    ProjectGitStatus(
        workspaceID: workspaceID,
        statusToken: statusToken,
        head: ProjectGitHead(
            oid: String(repeating: "b", count: 40),
            branch: "main",
            isDetached: false,
            upstream: "origin/main",
            ahead: 0,
            behind: 0
        ),
        files: files,
        filesPage: ProjectGitPageMetadata(
            offset: 0,
            limit: 500,
            returned: files.count,
            total: files.count,
            nextOffset: nil,
            isComplete: true
        ),
        staged: ProjectGitChangeCounts(files: 0, insertions: 0, deletions: 0),
        changes: ProjectGitChangeCounts(
            files: files.count,
            insertions: files.reduce(0) { $0 + $1.insertions },
            deletions: files.reduce(0) { $0 + $1.deletions }
        ),
        conflicts: [],
        conflictsPage: ProjectGitPageMetadata(
            offset: 0,
            limit: 500,
            returned: 0,
            total: 0,
            nextOffset: nil,
            isComplete: true
        ),
        isDirty: !files.isEmpty
    )
}
