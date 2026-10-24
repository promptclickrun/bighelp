import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesReconnectParityTests {
    @Test func capabilityBooleanIsRequiredAndFalsePreservesReads() throws {
        let invalid: [BighelpJSONValue] = [.object([:]), .object(["per_session_exclusive_submit": .string("true")])]
        for value in invalid {
            #expect(throws: WorkspaceClientError.self) { try DirectHermesCapabilityManifest.decode(value) }
        }
        let no = try DirectHermesCapabilityManifest.decode(.object(["per_session_exclusive_submit": .boolean(false)]))
        #expect(!no.supportedOperations.contains(.chatSend))
        #expect(no.supportedOperations.contains(.sessionsRead))
        #expect(no.supportedOperations.contains(.approvalsRespond))
        let yes = try DirectHermesCapabilityManifest.decode(.object([
            "per_session_exclusive_submit": .boolean(true), "future": .boolean(true)]))
        #expect(yes.supportedOperations.contains(.chatSend))
    }

    @Test func resumeUsesDurableIdentityWithoutPromptSubmission() throws {
        let parameters = DirectHermesReleaseContract.resumeParameters(profile: "research", storedID: "saved")
        #expect(parameters["session_id"] == .string("saved"))
        #expect(parameters["profile"] == .string("research"))
        #expect(parameters["close_on_disconnect"] == .boolean(false))
        #expect(parameters["omit_messages"] == .boolean(true))
        #expect(parameters["text"] == nil)
        let result = try DirectHermesReleaseContract.decodeResumedSession(.object([
            "session_id": .string("replacement-runtime"), "stored_session_id": .string("compaction-successor"),
            "info": .object([:]), "running": .boolean(false)
        ]), profile: "research")
        #expect(result.runtimeID == "replacement-runtime")
        #expect(result.storedID == "compaction-successor")
    }

    @Test func conflictingResumeAliasesAndForeignProfileAreRejected() throws {
        let conflicting: BighelpJSONValue = .object(["session_id": .string("runtime"),
            "stored_session_id": .string("saved"), "session_key": .string("different"), "info": .object([:])])
        #expect(throws: WorkspaceClientError.self) {
            try DirectHermesReleaseContract.decodeResumedSession(conflicting, profile: "research")
        }
        let foreign: BighelpJSONValue = .object(["session_id": .string("runtime"),
            "stored_session_id": .string("saved"), "info": .object(["profile_name": .string("other")])])
        #expect(throws: WorkspaceClientError.self) {
            try DirectHermesReleaseContract.decodeResumedSession(foreign, profile: "research")
        }
    }

    @Test func globalReclaimRevokesOnlyExactOwnerAndStaleActions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = ReconnectParityRPC()
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "research",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        let actions = client.sessionActions
        client.receive(.init(type: "session.reclaimed", sessionID: nil, payload: [
            "session_id": .string("other"), "stored_session_id": .string("saved"), "reason": .string("reassigned")], sequence: nil))
        #expect(client.connected)
        client.receive(.init(type: "session.reclaimed", sessionID: nil, payload: [
            "session_id": .string("runtime"), "stored_session_id": .string("saved"), "reason": .string("reassigned")], sequence: nil))
        #expect(!client.connected)
        #expect(client.needsRecovery)
        #expect(!client.isReadyForSubmission)
        await #expect(throws: (any Error).self) { _ = try await actions.status() }
        #expect(rpc.calls.isEmpty)
    }
}

extension DirectHermesReconnectParityTests {
    @Test func aReclaimDuringCatchUpReleasesAMessageWaitingForIt() async throws {
        @MainActor final class Released { var done = false }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = HeldReplayRPC()
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "research",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        let recovery = Task { try await client.recover(epoch: "epoch") }
        for _ in 0..<100 where !rpc.isHolding { try await Task.sleep(for: .milliseconds(5)) }
        #expect(client.isHydrating)

        // A message sent now waits for the catch-up (`isAwaitingCatchUp` keeps Send off meanwhile).
        let released = Released()
        let waiter = Task {
            defer { released.done = true }
            try await client.awaitHydrationIfNeeded()
        }
        for _ in 0..<10 { await Task.yield() }
        client.receive(.init(type: "session.reclaimed", sessionID: nil, payload: [
            "session_id": .string("runtime"), "stored_session_id": .string("saved"), "reason": .string("reassigned")], sequence: nil))
        for _ in 0..<100 where !released.done { try await Task.sleep(for: .milliseconds(5)) }
        #expect(released.done, "Hermes taking the session back must release the message waiting for the catch-up.")
        if released.done { await #expect(throws: (any Error).self) { try await waiter.value } }
        rpc.release()
        _ = try? await recovery.value
    }
}

/// Holds `session.events.since`, so a catch-up stays under way until `release()`.
@MainActor
private final class HeldReplayRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    private var held: CheckedContinuation<Void, Never>?
    var isHolding: Bool { held != nil }
    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        await withCheckedContinuation { held = $0 }
        throw DirectHermesError.notConnected
    }
    func release() { let pending = held; held = nil; pending?.resume() }
    func disconnect() async {}
}

@MainActor
private final class ReconnectParityRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var calls: [String] = []
    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        calls.append(method)
        throw DirectHermesError.invalidResponse
    }
    func disconnect() async {}
}
