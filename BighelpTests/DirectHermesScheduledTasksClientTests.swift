import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesScheduledTasksClientTests {
    @Test func allProfilesAreReadIndividuallyWithoutSuppressingFailures() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.profilesList] = [.success(["profiles": .array([
            .object(["name": .string("research")]), .object(["name": .string("writing")])
        ])])]
        transport.responses[.scheduledTasksList] = [
            .success(["jobs": .array([.object(job())])]),
            .success(["jobs": .array([.object(job(id: "job-2", profile: "writing"))])])
        ]
        let tasks = try await client(transport).list(agentID: nil)
        #expect(tasks.map(\.agentID) == ["research", "writing"])
        #expect(transport.calls.map(\.payload) == [
            ["include_sessions": .boolean(false)], ["profile": .string("research")], ["profile": .string("writing")]
        ])
    }

    @Test func failedProfileDoesNotBecomeSuccessfulPartialCatalog() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.profilesList] = [.success(["profiles": .array([
            .object(["name": .string("research")]), .object(["name": .string("writing")])
        ])])]
        transport.responses[.scheduledTasksList] = [.success(["jobs": .array([])]), .failure(.transportUnavailable)]
        await #expect(throws: WorkspaceClientError.transportUnavailable) { try await client(transport).list(agentID: nil) }
    }

    @Test func duplicateNativeIDsAcrossProfilesKeepBothRowsAndExactMutationOwner() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.profilesList] = [.success(["profiles": .array([
            .object(["name": .string("research")]), .object(["name": .string("writing")])
        ])])]
        transport.responses[.scheduledTasksList] = [
            .success(["jobs": .array([.object(job())])]),
            .success(["jobs": .array([.object(job(profile: "writing"))])])
        ]
        let adapter = client(transport)
        let tasks = try await adapter.list(agentID: nil)
        #expect(tasks.count == 2)
        #expect(tasks.allSatisfy { $0.id == "job-1" })
        #expect(Set(tasks.map(\.identity)).count == 2)
        #expect(transport.calls.map(\.operation) == [.profilesList, .scheduledTasksList, .scheduledTasksList])
        #expect(transport.calls[1].payload == ["profile": .string("research")])
        #expect(transport.calls[2].payload == ["profile": .string("writing")])
        transport.responses[.scheduledTaskPause] = [.success(job(profile: "writing", enabled: false, state: "paused"))]
        let updated = try await adapter.setPaused(true, id: "job-1", agentID: "writing")
        #expect(updated.id == "job-1")
        #expect(updated.agentID == "writing")
        #expect(transport.calls.last?.payload == ["profile": .string("writing"), "id": .string("job-1")])
    }

    @Test func scopedReadRejectsAnotherProfilesTask() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.scheduledTasksList] = [.success(["jobs": .array([.object(job(profile: "writing"))])])]
        await #expect(throws: WorkspaceClientError.invalidResponse) { try await client(transport).list(agentID: "research") }
    }

    @Test func createUsesCanonicalScheduleAndNativeFields() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.scheduledTaskDeliveryTargets] = [.success(targets())]
        transport.responses[.scheduledTaskCreate] = [.success(job())]
        let result = try await client(transport).create(draft())
        #expect(result.id == "job-1")
        #expect(transport.calls.last?.payload == [
            "profile": .string("research"), "name": .string("Morning brief"), "prompt": .string("Summarize the day."),
            "schedule": .string("0 8 * * *"), "deliver": .string("local")
        ])
        #expect(result.schedule.requestedTimeZoneID == nil)
    }

    @Test func updateKeepsProfileOutsideNativeUpdatesObject() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.scheduledTaskDeliveryTargets] = [.success(targets())]
        transport.responses[.scheduledTaskUpdate] = [.success(job())]
        let changes = ScheduledTaskChanges(name: "Morning brief", instructions: "Summarize the day.",
            schedule: schedule, deliveryTarget: "local")
        _ = try await client(transport).update(id: "job-1", agentID: "research", changes: changes)
        #expect(transport.calls.last?.payload["profile"] == .string("research"))
        #expect(transport.calls.last?.payload["id"] == .string("job-1"))
        #expect(transport.calls.last?.payload["updates"]?.object?["profile"] == nil)
        #expect(transport.calls.last?.payload["updates"]?.object?["prompt"] == .string("Summarize the day."))
    }

    @Test func partialCreateFailureIsNeverRetriedOrReportedAsSuccess() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.scheduledTaskDeliveryTargets] = [.success(targets())]
        transport.responses[.scheduledTaskCreate] = [.failure(.outcomeUnknown)]
        await #expect(throws: WorkspaceClientError.outcomeUnknown) { try await client(transport).create(draft()) }
        #expect(transport.calls.filter { $0.operation == .scheduledTaskCreate }.count == 1)
    }

    @Test func mutationRejectsChangedIdentityAndUnappliedContent() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.scheduledTaskPause] = [.success(job(id: "other", enabled: false, state: "paused"))]
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client(transport).setPaused(true, id: "job-1", agentID: "research")
        }
        transport.responses[.scheduledTaskDeliveryTargets] = [.success(targets())]
        var unchanged = job()
        unchanged["prompt"] = .string("A different instruction")
        transport.responses[.scheduledTaskCreate] = [.success(unchanged)]
        await #expect(throws: WorkspaceClientError.outcomeUnknown) { try await client(transport).create(draft()) }
    }

    @Test func pauseMustActuallyBePausedAndResumeMustBeActive() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.scheduledTaskPause] = [.success(job())]
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client(transport).setPaused(true, id: "job-1", agentID: "research")
        }
        transport.responses[.scheduledTaskResume] = [.success(job(enabled: false, state: "paused"))]
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client(transport).setPaused(false, id: "job-1", agentID: "research")
        }
    }

    @Test func runReturnsActualResumedAndCompletedState() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.scheduledTaskRun] = [
            .success(job()),
            .success(job(enabled: false, state: "completed"))
        ]
        let adapter = client(transport)
        #expect(try await adapter.runNow(id: "job-1", agentID: "research").status == .active)
        let completed = try await adapter.runNow(id: "job-1", agentID: "research")
        #expect(completed.status == .completed)
        #expect(!completed.isPaused)
        let presentation = ScheduledTaskPresentation(task: completed, agentName: "Research")
        #expect(!presentation.action(.runNow).isEnabled)
        #expect(!presentation.action(.pauseOrResume).isEnabled)
        #expect(!presentation.action(.edit).isEnabled)
        #expect(presentation.nextRunCopy.contains("Completed"))
    }

    @Test func aScriptJobShowsTheScriptsNameAndOnlyBlocksDuplicating() throws {
        var payload = job(state: "error")
        payload["no_agent"] = .boolean(true)
        payload["script"] = .string("/private/synthetic-script.sh")
        let task = try DirectHermesScheduledTaskCodec.task(.object(payload), profile: "research")
        #expect(task.status == .failed)
        #expect(task.usesHostManagedExecution)
        // The host path stays on the host; the app shows the file's name in Advanced.
        #expect(task.scriptName == "synthetic-script.sh")
        #expect(!String(describing: task).contains("/private/synthetic-script.sh"))
        let presentation = ScheduledTaskPresentation(task: task, agentName: "Research")
        // Editing name, schedule or delivery is safe: the editor payload carries only those and
        // Hermes merges the update, so the script and its flags survive. A duplicate is built from
        // the draft and would lose the script, so that stays blocked.
        #expect(presentation.action(.edit).isEnabled)
        #expect(!presentation.action(.duplicate).isEnabled)
    }

    @Test func implicitHomeDeliveryRequiresServingProfileProof() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.scheduledTaskDeliveryTargets] = [.success(targets())]
        var requested = draft()
        requested.deliveryTarget = "loopdy"
        await #expect(throws: WorkspaceClientError.unavailable(.identityContextUnavailable)) {
            try await client(transport, servingProfile: nil).create(requested)
        }
        #expect(!transport.calls.contains { $0.operation == .scheduledTaskCreate })
    }

    @Test func explicitDeliveryIsNativeCatalogValidatedNotSilentlyReplaced() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.scheduledTaskDeliveryTargets] = [.success(targets()), .success(targets())]
        var requested = draft()
        requested.deliveryTarget = "unknown:channel"
        await #expect(throws: ScheduledTasksError.invalidDeliveryTarget) { try await client(transport).create(requested) }
        requested.deliveryTarget = "loopdy:sample-channel"
        var created = job()
        created["deliver"] = .string(requested.deliveryTarget)
        transport.responses[.scheduledTaskCreate] = [.success(created)]
        let result = try await client(transport, servingProfile: nil).create(requested)
        #expect(result.deliveryTarget == "loopdy:sample-channel")
    }

    @Test func deletionRequiresExactProfileReadbackAbsence() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.scheduledTaskDelete] = [.success(["ok": .boolean(true)])]
        transport.responses[.scheduledTasksList] = [.success(["jobs": .array([.object(job())])])]
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client(transport).delete(id: "job-1", agentID: "research")
        }
        #expect(transport.calls.last?.payload == ["profile": .string("research")])
    }

    @Test func ownerChangeBeforeMutationDoesNotSend() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.scheduledTaskDeliveryTargets] = [.success(targets())]
        transport.replaceOwnerAfterResponse = true
        await #expect(throws: WorkspaceClientError.ownerChanged) { try await client(transport).create(draft()) }
        #expect(transport.calls.map(\.operation) == [.scheduledTaskDeliveryTargets])
    }

    @Test func missingMutationCapabilityDoesNotProbeByWriting() async throws {
        let transport = try SchedulerPerformer()
        transport.allowMutations = false
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            try await client(transport).runNow(id: "job-1", agentID: "research")
        }
        #expect(transport.calls.isEmpty)
    }

    @Test func opaqueMutationIdentityMustMatchExactUTF8NotJustCanonicalText() async throws {
        let transport = try SchedulerPerformer()
        transport.responses[.scheduledTaskPause] = [.success(job(id: "cafe\u{0301}", enabled: false, state: "paused"))]
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client(transport).setPaused(true, id: "caf\u{00E9}", agentID: "research")
        }
    }

    /// Recent runs said "Hermes returned an unsupported or invalid response." for every task (#809):
    /// Hermes names a run `local-…` since its unified runtime, and a script-only run is a
    /// `cron_output:…` row without a profile. Answers captured from stock Hermes (`Fixtures/HermesCron`).
    @Test(arguments: ["runs-agent", "runs-script-only"])
    func recentRunsReadWhatHermesSends(_ vector: String) async throws {
        let transport = try SchedulerPerformer()
        let (jobID, response) = try Self.vector(vector)
        let http = CronHTTP(response)
        let runs = try await client(transport, http: http).runs(id: jobID, agentID: "default", limit: 20)
        #expect(runs.count == 1)
        #expect(runs.allSatisfy { $0.agentID == "default" && !$0.isActive && $0.endedAt != nil })
        #expect(http.paths == ["/api/cron/jobs/\(jobID)/runs"])
    }

    /// One row the app can't read leaves out that row, not the whole history.
    @Test func aRunRowThatDoesntReadIsLeftOut() async throws {
        let transport = try SchedulerPerformer()
        let (jobID, response) = try Self.vector("runs-agent")
        var payload = try #require(response.object)
        let row = try #require(payload["runs"]?.array?.first)
        payload["runs"] = .array([row, .object(["id": .string("broken")]), .string("not a row"), row])
        let runs = try await client(transport, http: CronHTTP(.object(payload)))
            .runs(id: jobID, agentID: "default", limit: 20)
        #expect(runs.map(\.id) == [row.object?["id"]?.string], "The broken row and the repeat are left out")
    }

    @Test func aJobsDetailCarriesItsLastRun() async throws {
        let transport = try SchedulerPerformer()
        let (_, response) = try Self.vector("job-detail")
        let task = try await client(transport, http: CronHTTP(response)).detail(id: "9980bf2edc0e", agentID: "default")
        #expect(task.lastResult == "ok")
        let ran = try #require(task.lastRun)
        #expect(abs(ran.timeIntervalSince(try #require(ISO8601DateFormatter().date(from: "2026-11-05T02:30:35Z")))) < 1)
    }

    /// "Last run: No runs yet" sat over a task whose last status was "ok" (#809). Without a time from
    /// Hermes, the newest run in the task's history gives it.
    @Test func lastRunFallsBackToTheNewestRun() async throws {
        let transport = try SchedulerPerformer()
        let (jobID, response) = try Self.vector("runs-agent")
        transport.responses[.profilesList] = [.success(["profiles": .array([.object(["name": .string("default")])])])]
        transport.responses[.scheduledTasksList] = [.success(["jobs": .array([.object(job(id: jobID, profile: "default"))])])]
        let store = ScheduledTasksStore(client: client(transport, http: CronHTTP(response)), initialAgentID: nil)
        await store.load()
        let task = try #require(store.task(id: jobID, agentID: "default"))
        #expect(store.lastRun(for: task) == nil)
        await store.loadRuns(id: jobID, agentID: "default")
        let newest = try #require(store.runs(for: task).first)
        #expect(store.lastRun(for: task) == newest.startedAt)
    }

    private static func vector(_ name: String) throws -> (jobID: String, response: BighelpJSONValue) {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/HermesCron/\(name).json")
        let vector = try JSONDecoder().decode([String: BighelpJSONValue].self, from: Data(contentsOf: url))
        return (vector["jobID"]?.string ?? "", try #require(vector["response"]))
    }

    private var schedule: ScheduleInput { .daily(time: .init(hour: 8, minute: 0), timeZoneID: "UTC") }

    private func draft() -> ScheduledTaskDraft {
        .init(agentID: "research", name: "Morning brief", instructions: "Summarize the day.", schedule: schedule, deliveryTarget: "local")
    }

    private func client(_ transport: SchedulerPerformer, servingProfile: String? = "research",
                        http: CronHTTP? = nil) -> DirectHermesScheduledTasksClient {
        .init(workspace: transport, owner: transport.owner!, currentOwner: { transport.owner }, servingProfileID: servingProfile,
              http: http)
    }

    private func targets() -> [String: BighelpJSONValue] {
        ["targets": .array([
            .object(["id": .string("local"), "name": .string("Local"), "home_target_set": .boolean(true)]),
            .object(["id": .string("loopdy"), "name": .string("bighelp"), "home_target_set": .boolean(true)])
        ])]
    }

    private func job(id: String = "job-1", profile: String = "research", enabled: Bool = true, state: String = "scheduled") -> [String: BighelpJSONValue] {
        ["id": .string(id), "profile": .string(profile), "name": .string("Morning brief"),
         "prompt": .string("Summarize the day."), "deliver": .string("local"),
         "schedule": .object(["kind": .string("cron"), "expr": .string("0 8 * * *")]),
         "schedule_display": .string("0 8 * * *"), "enabled": .boolean(enabled), "state": .string(state),
         "next_run_at": .null, "last_status": .null, "skills": .array([]), "script": .null, "no_agent": .boolean(false)]
    }
}

@MainActor
private final class SchedulerPerformer: WorkspaceOperationPerforming {
    struct Call { let operation: WorkspaceOperation; let payload: [String: BighelpJSONValue] }
    var owner: WorkspaceOwner?
    var allowMutations = true
    var replaceOwnerAfterResponse = false
    var capabilities: WorkspaceCapabilities {
        .init(owner: owner, values: allowMutations
              ? [.schedulesRead: .available, .schedulesEdit: .available, .schedulesRun: .available] : [:])
    }
    var calls: [Call] = []
    var responses: [WorkspaceOperation: [Result<[String: BighelpJSONValue], WorkspaceClientError>]] = [:]

    init() throws {
        owner = .init(authority: try .fixture(id: "scheduler-test"), authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue], owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        calls.append(.init(operation: operation, payload: payload))
        guard let response = responses[operation]?.first else { throw WorkspaceClientError.invalidResponse }
        responses[operation]?.removeFirst()
        if replaceOwnerAfterResponse {
            self.owner = .init(authority: owner.authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        }
        return try response.get()
    }
}

/// Answers Hermes' cron REST routes with one saved response.
@MainActor
private final class CronHTTP: DirectHermesAuthenticatedHTTP {
    private let response: BighelpJSONValue
    private(set) var paths: [String] = []

    init(_ response: BighelpJSONValue) { self.response = response }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        paths.append(request.path)
        return response
    }
}
