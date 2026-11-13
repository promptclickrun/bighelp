import Foundation
import Testing
@testable import Bighelp

/// Why a Kanban task stopped, in words a person can act on. The app used to
/// replace Hermes' error with "this run failed", which said nothing.
@MainActor
struct KanbanFailureTests {
    @Test func aWorkerThatCantStartSaysWhatsMissing() {
        let error = #"pid 5120 exited with code 1 Worker's last output: "/Users/you/.hermes/tools/python3: Error while finding module specification for 'hermes_cli.main' (ModuleNotFoundError: No module named 'hermes_cli')""#
        let text = KanbanFailure.explain(error)
        #expect(text.contains("couldn't start on your computer"))
        #expect(text.contains("\"hermes_cli\""))
        #expect(!text.contains("/Users/you"), "The plain version leaves the paths to Show details")
    }

    @Test func otherErrorsKeepTheirLastLine() {
        let error = #"pid 7 exited with code 1 Worker's last output: "Traceback ... PermissionError: [Errno 13] Permission denied: 'notes.txt'""#
        #expect(KanbanFailure.explain(error) == "The bot stopped with an error: PermissionError: [Errno 13] Permission denied: 'notes.txt'")
    }

    @Test func timeoutsWorkspacesAndBareExits() {
        #expect(KanbanFailure.explain("run exceeded max runtime (1800s)") == "It ran longer than it's allowed to and was stopped.")
        #expect(KanbanFailure.explain("workspace: task has no workspace_path").hasPrefix("Its folder isn't set up:"))
        #expect(KanbanFailure.explain("pid 9 exited with code 137") == "The bot stopped unexpectedly (exit code 137).")
        #expect(KanbanFailure.explain(String(repeating: "x", count: 500)).count <= 220)
    }

    @Test func runErrorsAndBlockReasonsComeThroughFromHermes() async throws {
        // The demo board's stuck task fails like a broken worker install.
        let detail = try await DemoKanbanService().task("t_domain", board: "launch")
        #expect(detail.runs.allSatisfy { $0.error?.contains("ModuleNotFoundError") == true })
        #expect(KanbanThread.notableEvents(detail).map(\.kind) == ["gave_up"])
        #expect(detail.task.consecutiveFailures == 2)
    }
}
