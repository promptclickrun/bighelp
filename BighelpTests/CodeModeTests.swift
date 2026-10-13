import Foundation
import Testing
@testable import Bighelp

@MainActor
struct CodeModeTests {
    @Test func branchNamesComeFromTheMessageAndNeverCollide() {
        #expect(CodeBranchName.suggested(for: "Make the Kanban lanes scroll on iPad")
            == "code/make-kanban-lanes-scroll-ipad")
        #expect(CodeBranchName.suggested(for: "Fix the widget tap when the host is asleep")
            == "code/fix-widget-tap-host-asleep")
        #expect(CodeBranchName.suggested(for: "Fix the widget tap", taken: ["code/fix-widget-tap"])
            == "code/fix-widget-tap-2")
        #expect(CodeBranchName.suggested(for: "¿¡ 🙂 !?") == "code/session")
        #expect(CodeBranchName.worktreeName(for: "code/fix-widget-tap-2") == "fix-widget-tap-2")
        #expect(CodeBranchName.worktreeName(for: "feat/über wide") == "ber-wide")
    }

    /// A new worktree comes first, then the session starts in it, then the message is sent.
    @Test func newWorktreeSendMakesTheWorktreeThenStartsTheSessionInIt() async throws {
        let git = RecordingCodeGit()
        let sessions = RecordingCodeSessions()
        var steps: [CodeLaunch.Step] = []
        var started: CodeSessionRecord?

        let record = try await CodeLauncher(git: git, sessions: sessions).launch(
            request(placement: .newWorktree),
            progress: { steps.append($0) },
            onSessionStarted: { started = $0 }
        )

        #expect(git.actions == [.addWorktree(name: "fix-widget-tap", branch: "code/fix-widget-tap", base: "main")])
        #expect(sessions.started.count == 1)
        #expect(sessions.started.first?.folder == "/Users/demo/code/app/.worktrees/fix-widget-tap")
        #expect(sessions.sent == ["Fix the widget tap@\(record.id)"])
        #expect(record.branch == "code/fix-widget-tap")
        #expect(started == record)
        #expect(steps == [.makingWorktree, .startingSession, .sending])
    }

    /// The model chip's choice starts the session, so even its first message runs on it.
    @Test func theModelChoiceStartsTheSession() async throws {
        let sessions = RecordingCodeSessions()
        var withModel = request(placement: .local)
        withModel.runtime = CodeRuntimeChoice(providerID: "subscription", modelID: "model-one",
                                              reasoning: "high", fastMode: true)

        _ = try await CodeLauncher(git: RecordingCodeGit(), sessions: sessions).launch(
            withModel, progress: { _ in }, onSessionStarted: { _ in })
        _ = try await CodeLauncher(git: RecordingCodeGit(), sessions: sessions).launch(
            request(placement: .local), progress: { _ in }, onSessionStarted: { _ in })

        #expect(sessions.runtimes == [withModel.runtime, CodeRuntimeChoice()])
    }

    /// Hermes starts one new chat per agent at a time, and each worktree changes the repository the
    /// next send reads: back-to-back sends make their folders and sessions one after another.
    @Test func backToBackSendsStartTheirSessionsOneAtATime() async throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let git = RecordingCodeGit()
        let sessions = RecordingCodeSessions()
        sessions.startDelay = .milliseconds(30)
        let store = CodeHomeStore(scopeID: "computer", agentID: "default", source: DemoCodeProjectSource(),
                                  git: { git }, starter: sessions, defaults: defaults)
        await store.load()

        for message in ["Fix the widget tap", "Tighten the chart spacing", "Rename the settings keys"] {
            #expect(store.send(message))
        }
        for _ in 0..<200 where !store.launches.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        #expect(sessions.started.count == 3)
        #expect(sessions.mostAtOnce == 1)
        #expect(git.actions.count == 3)
    }

    /// Local works in the project's own folder and makes no worktree.
    @Test func localSendStartsTheSessionInTheMainFolder() async throws {
        let git = RecordingCodeGit()
        let sessions = RecordingCodeSessions()

        let record = try await CodeLauncher(git: git, sessions: sessions).launch(
            request(placement: .local), progress: { _ in }, onSessionStarted: { _ in })

        #expect(git.actions.isEmpty)
        #expect(sessions.started.first?.folder == "/Users/demo/code/app")
        #expect(record.branch == "main")
    }

    /// A taken branch name stops the send before anything starts on the host.
    @Test func aTakenBranchNameStartsNothing() async {
        let git = RecordingCodeGit()
        let sessions = RecordingCodeSessions()

        await #expect(throws: CodeLaunchError.branchExists("feat/code-mode")) {
            try await CodeLauncher(git: git, sessions: sessions).launch(
                request(placement: .newWorktree, newBranch: "feat/code-mode"),
                progress: { _ in }, onSessionStarted: { _ in })
        }
        #expect(git.actions.isEmpty)
        #expect(sessions.started.isEmpty)
    }

    /// When the message can't be sent, the session already exists, so its card still opens it.
    @Test func aFailedSendStillReportsTheStartedSession() async {
        let sessions = RecordingCodeSessions()
        sessions.sendError = WorkspaceClientError.transportUnavailable
        var started: CodeSessionRecord?

        await #expect(throws: WorkspaceClientError.transportUnavailable) {
            try await CodeLauncher(git: RecordingCodeGit(), sessions: sessions).launch(
                request(placement: .newWorktree), progress: { _ in }, onSessionStarted: { started = $0 })
        }
        #expect(started?.id == sessions.started.first?.id)
    }

    /// Sends go out back to back: each one is its own session and none waits for another.
    @Test func backToBackSendsEachBecomeASession() async throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let git = RecordingCodeGit()
        let sessions = RecordingCodeSessions()
        let store = CodeHomeStore(scopeID: "computer", agentID: "default", source: DemoCodeProjectSource(),
                                  git: { git }, starter: sessions, defaults: defaults)
        await store.load()

        #expect(store.send("Fix the widget tap"))
        #expect(store.send("Tighten the chart spacing"))
        #expect(store.projectLaunches.count == 2)
        for _ in 0..<100 where !store.launches.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        #expect(Set(store.projectSessions.map(\.title)) == ["Fix the widget tap", "Tighten the chart spacing"])
        #expect(Set(store.projectSessions.compactMap(\.branch)) == ["code/fix-widget-tap", "code/tighten-chart-spacing"])
        #expect(store.launches.isEmpty)
        let reopened = CodeHomeStore(scopeID: "computer", agentID: "default", source: DemoCodeProjectSource(),
                                     git: { git }, starter: sessions, defaults: defaults)
        #expect(reopened.sessions.count == 2)
    }

    /// Plan mode starts the session with Hermes' own `/plan`; a message that is already a command keeps it.
    @Test func planModeSendsTheFirstMessageThroughPlan() async throws {
        let sessions = RecordingCodeSessions()
        var plan = request(placement: .local)
        plan.mode = .plan
        let command = CodeLaunchRequest(message: "/review the branch", agentID: plan.agentID, project: plan.project,
                                        placement: .local, branch: nil, newBranch: nil, mode: .plan)

        let first = try await CodeLauncher(git: RecordingCodeGit(), sessions: sessions).launch(
            plan, progress: { _ in }, onSessionStarted: { _ in })
        let second = try await CodeLauncher(git: RecordingCodeGit(), sessions: sessions).launch(
            command, progress: { _ in }, onSessionStarted: { _ in })

        #expect(sessions.sent == ["/plan Fix the widget tap@\(first.id)", "/review the branch@\(second.id)"])
        #expect(first.mode == .plan)
        // The command isn't part of the session's name.
        #expect(second.title == "the branch")
        #expect(CodeSessionTitle.from("/plan Add a loading state") == "Add a loading state")
        #expect(CodeSessionTitle.from("/compress") == "/compress")
    }

    /// YOLO is on for the session before its first message goes out.
    @Test func yoloIsOnBeforeTheFirstMessage() async throws {
        let sessions = RecordingCodeSessions()
        var yolo = request(placement: .local)
        yolo.mode = .yolo

        let record = try await CodeLauncher(git: RecordingCodeGit(), sessions: sessions).launch(
            yolo, progress: { _ in }, onSessionStarted: { _ in })

        #expect(sessions.events == ["start", "apply yolo@\(record.id)", "send Fix the widget tap@\(record.id)"])
    }

    /// When Hermes refuses YOLO, nothing is sent, and the session's card still opens it.
    @Test func aRefusedYOLOSendsNothingAndKeepsTheSession() async throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sessions = RecordingCodeSessions()
        sessions.applyError = CodeStartError.yoloRefused
        let store = CodeHomeStore(scopeID: "computer", agentID: "default", source: DemoCodeProjectSource(),
                                  git: { RecordingCodeGit() }, starter: sessions, defaults: defaults)
        await store.load()
        store.mode = .yolo

        #expect(store.send("Fix the widget tap"))
        for _ in 0..<100 where store.launches.first?.step.isFailed != true { try await Task.sleep(for: .milliseconds(20)) }

        #expect(sessions.sent.isEmpty)
        #expect(store.projectSessions.count == 1)
        #expect(store.launches.first?.sessionID == store.projectSessions.first?.id)
        #expect(store.launches.first?.step == .failed(CodeStartError.yoloRefused.errorDescription ?? ""))
    }

    /// The mode button stays as it was left, per computer.
    @Test func theModeIsKeptPerComputer() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CodeHomeStore(scopeID: "computer", agentID: "default", source: DemoCodeProjectSource(),
                                  git: { RecordingCodeGit() }, starter: RecordingCodeSessions(), defaults: defaults)
        store.mode = .plan

        let reopened = CodeHomeStore(scopeID: "computer", agentID: "default", source: DemoCodeProjectSource(),
                                     git: { RecordingCodeGit() }, starter: RecordingCodeSessions(), defaults: defaults)
        let other = CodeHomeStore(scopeID: "other", agentID: "default", source: DemoCodeProjectSource(),
                                  git: { RecordingCodeGit() }, starter: RecordingCodeSessions(), defaults: defaults)
        #expect(reopened.mode == .plan)
        #expect(other.mode == .standard)
    }

    /// The / list loads once for an agent and project, again after either changes.
    @Test func commandsLoadOncePerAgentAndProject() async {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var loads: [String] = []
        let store = CodeHomeStore(
            scopeID: "computer", agentID: "default", source: DemoCodeProjectSource(),
            git: { RecordingCodeGit() }, starter: RecordingCodeSessions(),
            loadCommands: { agent, folder in
                loads.append("\(agent)@\(folder ?? "-")")
                return [SlashCommandDescriptor(name: "plan", description: "Plan", category: "Workflow", argsHint: "",
                                               aliases: [], argumentMode: .text, source: .core, requiresArguments: false)]
            },
            defaults: defaults)
        await store.load()
        let folder = store.project?.folder ?? "-"

        await store.loadCommandsIfNeeded()
        await store.loadCommandsIfNeeded()
        await store.selectAgent("coder")
        await store.loadCommandsIfNeeded()

        #expect(loads == ["default@\(folder)", "coder@\(store.project?.folder ?? "-")"])
        #expect(store.commands.map(\.name) == ["plan"])
    }

    private func request(placement: CodePlacement, newBranch: String? = nil) -> CodeLaunchRequest {
        CodeLaunchRequest(message: "Fix the widget tap", agentID: "default",
                          project: CodeProject(id: "app", name: "app", folder: "/Users/demo/code/app"),
                          placement: placement, branch: placement == .newWorktree ? "main" : nil,
                          newBranch: newBranch)
    }
}

/// Demo git that also records which mutations ran.
@MainActor
private final class RecordingCodeGit: StockGitManaging {
    private let demo = DemoCodeGit()
    private(set) var actions: [StockGitAction] = []

    func snapshot(for target: StockGitProjectTarget, scope: StockGitReviewScope) async throws -> StockGitSnapshot {
        try await demo.snapshot(for: target, scope: scope)
    }

    func diff(for target: StockGitProjectTarget, file: String, scope: StockGitReviewScope,
              staged: Bool) async throws -> StockGitDiff {
        try await demo.diff(for: target, file: file, scope: scope, staged: staged)
    }

    func fileDiffAgainstHead(for target: StockGitProjectTarget, file: String) async throws -> StockGitDiff {
        try await demo.fileDiffAgainstHead(for: target, file: file)
    }

    func prepare(_ action: StockGitAction, target: StockGitProjectTarget) throws -> StockGitPreparedAction {
        try demo.prepare(action, target: target)
    }

    func execute(_ prepared: StockGitPreparedAction, confirmationToken: String) async throws -> StockGitActionResult {
        actions.append(prepared.action)
        return try await demo.execute(prepared, confirmationToken: confirmationToken)
    }
}

@MainActor
private final class RecordingCodeSessions: CodeSessionStarting {
    private(set) var started: [(id: String, folder: String, title: String)] = []
    private(set) var sent: [String] = []
    /// Every call in order: "start", "apply <mode>@<id>", "send <message>@<id>".
    private(set) var events: [String] = []
    var applyError: Error?
    private(set) var runtimes: [CodeRuntimeChoice] = []
    /// The most session starts under way at the same moment.
    private(set) var mostAtOnce = 0
    private var underWay = 0
    var startDelay: Duration?
    var sendError: Error?

    func startSession(agentID: String, folder: String, title: String,
                      runtime: CodeRuntimeChoice) async throws -> String {
        underWay += 1
        mostAtOnce = max(mostAtOnce, underWay)
        defer { underWay -= 1 }
        if let startDelay { try await Task.sleep(for: startDelay) }
        let id = "session-\(started.count + 1)"
        started.append((id, folder, title))
        runtimes.append(runtime)
        events.append("start")
        return id
    }

    func apply(_ mode: CodeSessionMode, toSession sessionID: String, agentID: String) async throws {
        if let applyError { throw applyError }
        if mode != .standard { events.append("apply \(mode.rawValue)@\(sessionID)") }
    }

    func send(_ message: String, toSession sessionID: String) async throws {
        if let sendError { throw sendError }
        sent.append("\(message)@\(sessionID)")
        events.append("send \(message)@\(sessionID)")
    }
}

/// Git may act in a project's linked worktrees, and only in the ones Hermes's own
/// worktree list for the project's main folder names.
@MainActor
struct StockGitWorktreeTargetTests {
    private let main = StockGitProjectTarget(profileID: "default", projectID: "app", cwd: "/repo", projectName: "app")

    private func target(_ cwd: String) -> StockGitProjectTarget {
        StockGitProjectTarget(profileID: "default", projectID: "app", cwd: cwd, projectName: "app")
    }

    private func client(_ host: WorktreeHost) throws -> DirectHermesStockGitClient {
        let owner = WorkspaceOwner(
            authority: try .direct(endpointIdentity: "https://hermes.example", providerID: "password", userID: "fixture"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        return DirectHermesStockGitClient(rpc: host, http: host, owner: owner, currentOwner: { owner },
                                          resolveTarget: { _, _, _ in nil },
                                          // The project's only registered folder is its main one.
                                          validateTarget: { $0.cwd == "/repo" && $0.projectID == "app" })
    }

    @Test func aWorktreeIsATargetOnlyOnceTheMainFolderListsIt() async throws {
        let host = WorktreeHost()
        let git = try client(host)

        await #expect(throws: WorkspaceClientError.ownerChanged) {
            _ = try await git.snapshot(for: target("/repo/.worktrees/fix"), scope: .uncommitted)
        }
        #expect(host.paths.isEmpty)

        _ = try await git.snapshot(for: main, scope: .uncommitted)
        let worktree = try await git.snapshot(for: target("/repo/.worktrees/fix"), scope: .branch)
        #expect(worktree.target.cwd == "/repo/.worktrees/fix")
        #expect(host.paths.contains("/repo/.worktrees/fix"))

        await #expect(throws: WorkspaceClientError.ownerChanged) {
            _ = try await git.snapshot(for: target("/elsewhere"), scope: .uncommitted)
        }
        #expect(!host.paths.contains("/elsewhere"))
    }

    /// Git names an untracked folder with a trailing "/". A worktree's own `.worktrees/` folder is
    /// one, so the main folder must still read after the first worktree (on a real host it didn't).
    @Test func anUntrackedFolderDoesNotBreakTheMainFolder() async throws {
        let host = WorktreeHost()
        host.untracked = [".worktrees/"]
        let git = try client(host)

        let snapshot = try await git.snapshot(for: main, scope: .uncommitted)

        #expect(snapshot.status.files.map(\.path) == [".worktrees/"])
        #expect(snapshot.review.files.map(\.path) == [".worktrees/"])
    }

    /// A worktree removed on the host stops being a target at the next look at the main folder.
    @Test func aRemovedWorktreeStopsBeingATarget() async throws {
        let host = WorktreeHost()
        let git = try client(host)
        _ = try await git.snapshot(for: main, scope: .uncommitted)
        host.linked = []
        _ = try await git.snapshot(for: main, scope: .uncommitted)

        await #expect(throws: WorkspaceClientError.ownerChanged) {
            _ = try await git.snapshot(for: target("/repo/.worktrees/fix"), scope: .uncommitted)
        }
    }
}

/// A Hermes host's stock git routes for one repository at `/repo`.
private final class WorktreeHost: DirectHermesRPC, DirectHermesAuthenticatedHTTP {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var linked = ["/repo/.worktrees/fix"]
    var untracked: [String] = []
    /// The folder each git request named.
    private(set) var paths: [String] = []

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        throw DirectHermesError.invalidResponse
    }

    func disconnect() async {}

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        if let path = request.query.first(where: { $0.name == "path" })?.value { paths.append(path) }
        switch request.path {
        case "/api/git/status":
            return .object(["branch": .string("main"), "detached": .boolean(false), "ahead": .integer(0),
                            "behind": .integer(0), "changed": .integer(untracked.count), "added": .integer(0),
                            "removed": .integer(0), "files": .array(untracked.map {
                                .object(["path": .string($0), "staged": .boolean(false), "unstaged": .boolean(true),
                                         "untracked": .boolean(true), "conflicted": .boolean(false)])
                            })])
        case "/api/git/review/list":
            return .object(["files": .array(untracked.map {
                .object(["path": .string($0), "added": .integer(0), "removed": .integer(0), "status": .string("?"),
                         "staged": .boolean(false)])
            })])
        case "/api/git/branches", "/api/git/base-branches":
            return .object(["branches": .array([.object(["name": .string("main"), "isDefault": .boolean(true),
                                                         "isRemote": .boolean(false)])])])
        case "/api/git/worktrees":
            let main = BighelpJSONValue.object(["path": .string("/repo"), "branch": .string("main"), "isMain": .boolean(true),
                                                "detached": .boolean(false), "locked": .boolean(false)])
            return .object(["worktrees": .array([main] + linked.map {
                .object(["path": .string($0), "branch": .string("code/fix"), "isMain": .boolean(false),
                         "detached": .boolean(false), "locked": .boolean(false)])
            })])
        case "/api/git/gh-auth":
            return .object(["available": .boolean(true), "authenticated": .boolean(true)])
        case "/api/git/review/ship-info":
            return .object(["ghReady": .boolean(true), "pr": .null])
        case "/api/git/review/commit-context":
            return .object(["diff": .string(""), "recent": .string("")])
        case "/api/git/review/pr-list":
            return .object(["ghReady": .boolean(true), "prs": .array([])])
        default:
            throw DirectHermesError.invalidResponse
        }
    }
}

/// Markdown paths in IDE chats open the viewer; everything else stays plain text.
struct HostFileLinkTests {
    @Test func markdownPathsAreFoundAndWebAddressesAreNot() {
        let text = "Saved .hermes/plans/2026-10-13_0915-usage.md and ~/notes/todo.md, see /Users/demo/app/README.markdown. "
            + "Not https://example.com/guide.md, not data.md5 or README.mdx."
        let found = HostFileLink.markdownPathRanges(in: text).map { String(text[$0]) }

        #expect(found == [".hermes/plans/2026-10-13_0915-usage.md", "~/notes/todo.md", "/Users/demo/app/README.markdown"])
    }

    @Test func relativePathsResolveInsideTheSessionFolder() {
        #expect(HostFileLink.resolve(".hermes/plans/a.md", in: "/repo/.worktrees/x") == "/repo/.worktrees/x/.hermes/plans/a.md")
        #expect(HostFileLink.resolve("./docs/b.md", in: "/repo/") == "/repo/docs/b.md")
        #expect(HostFileLink.resolve("/abs/c.md", in: "/repo") == "/abs/c.md")
        #expect(HostFileLink.resolve("~/d.md", in: "/repo") == "~/d.md")
    }

    @Test func aLinkCarriesThePathBothWays() throws {
        let url = try #require(HostFileLink.url(for: "docs/a plan & notes.md"))
        #expect(HostFileLink.path(from: url) == "docs/a plan & notes.md")
        #expect(HostFileLink.path(from: URL(string: "https://example.com/a.md")!) == nil)
    }
}

/// The viewer never overwrites a file that changed on the computer without asking.
@MainActor
struct MarkdownFileModelTests {
    @Test func saveWritesWhenTheFileIsUnchanged() async {
        let files = FakeTextFiles(["/repo/plan.md": "# Plan"])
        let model = MarkdownFileModel(path: "/repo/plan.md", access: files)
        await model.load()
        model.beginEditing()
        model.draft = "# Plan\n\n1. Ship it"

        #expect(await model.save())
        #expect(files.contents["/repo/plan.md"] == "# Plan\n\n1. Ship it")
        #expect(!model.isEditing)
        #expect(model.file?.text == "# Plan\n\n1. Ship it")
    }

    @Test func aFileChangedOnTheComputerAsksFirst() async {
        let files = FakeTextFiles(["/repo/plan.md": "# Plan"])
        let model = MarkdownFileModel(path: "/repo/plan.md", access: files)
        await model.load()
        model.beginEditing()
        model.draft = "# Mine"
        files.contents["/repo/plan.md"] = "# Theirs"

        #expect(await model.save() == false)
        #expect(model.hasConflict)
        #expect(files.contents["/repo/plan.md"] == "# Theirs")

        #expect(await model.save(replacing: true))
        #expect(files.contents["/repo/plan.md"] == "# Mine")
    }

    @Test func aLongFileOpensReadOnly() async {
        let files = FakeTextFiles(["/repo/big.md": "# Big"], truncated: true)
        let model = MarkdownFileModel(path: "/repo/big.md", access: files)
        await model.load()
        model.beginEditing()

        #expect(!model.canEdit)
        #expect(!model.isEditing)
    }
}

@MainActor
private final class FakeTextFiles: HostTextFileAccess {
    var contents: [String: String]
    let truncated: Bool

    init(_ contents: [String: String], truncated: Bool = false) {
        self.contents = contents
        self.truncated = truncated
    }

    func read(_ path: String) async throws -> HostTextFile {
        guard let text = contents[path] else { throw WorkspaceClientError.invalidRequest }
        return HostTextFile(path: path, text: text, isTruncated: truncated, isBinary: false)
    }

    func write(_ path: String, text: String) async throws {
        contents[path] = text
    }
}
