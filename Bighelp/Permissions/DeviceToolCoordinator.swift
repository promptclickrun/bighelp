import Foundation
import CryptoKit

struct DeviceToolRequest: Codable, Equatable, Sendable {
    let version: Int
    let type: String
    let requestId: String
    let deviceId: String
    let hostId: String
    let authorizationEpoch: Int
    let sessionId: String
    let agentId: String
    let turnId: String
    let operation: String
    let arguments: [String: BighelpJSONValue]
    let sentAt: Int
    let expiresAt: Int

    var scope: DeviceToolScope {
        DeviceToolScope(deviceID: deviceId, authorizationEpoch: authorizationEpoch, hostID: hostId)
    }
}

struct DeviceToolResult: Codable, Equatable, Sendable {
    let version: Int
    let type: String
    let requestId: String
    let deviceId: String
    let hostId: String
    let authorizationEpoch: Int
    let sessionId: String
    let agentId: String
    let turnId: String
    let operation: String
    let status: String
    let code: String?
    let payload: [String: BighelpJSONValue]
    let sentAt: Int

    init(request: DeviceToolRequest, status: String, code: String? = nil,
         payload: [String: BighelpJSONValue] = [:], sentAt: Int) {
        version = 1; type = "device.tool.result"
        requestId = request.requestId; deviceId = request.deviceId; hostId = request.hostId
        authorizationEpoch = request.authorizationEpoch; sessionId = request.sessionId
        agentId = request.agentId; turnId = request.turnId; operation = request.operation
        self.status = status; self.code = code; self.payload = payload; self.sentAt = sentAt
    }
}

struct DeviceToolJournalEntry: Codable, Equatable, Sendable {
    let fingerprint: String
    let expiresAt: Int
    let result: DeviceToolResult?
}

@MainActor
protocol DeviceToolJournal: AnyObject {
    func entry(requestID: String, scope: DeviceToolScope) throws -> DeviceToolJournalEntry?
    func save(_ entry: DeviceToolJournalEntry, requestID: String, scope: DeviceToolScope) throws
}

@MainActor
final class DeviceToolCoordinator {
    typealias Execute = @MainActor (String, [String: BighelpJSONValue], @escaping @MainActor () throws -> Void) async throws -> [String: BighelpJSONValue]
    private struct Failure: Error { let code: String }
    private let permissions: DeviceToolPermissions
    private let journal: any DeviceToolJournal
    private let clock: () -> Int
    private let available: () -> Bool
    private let execute: Execute
    private var activeRequests = 0
    private var mutationInFlight = false

    init(permissions: DeviceToolPermissions, journal: any DeviceToolJournal,
         clock: @escaping () -> Int, available: @escaping () -> Bool,
         execute: @escaping Execute) {
        self.permissions = permissions; self.journal = journal; self.clock = clock
        self.available = available; self.execute = execute
    }

    func handle(_ request: DeviceToolRequest, owner: DeviceToolScope,
                isCurrent: @escaping @MainActor () -> Bool) async -> DeviceToolResult {
        func failed(_ code: String) -> DeviceToolResult {
            DeviceToolResult(request: request, status: "failed", code: code, sentAt: clock())
        }
        guard request.expiresAt >= clock() else { return failed("request_expired") }
        guard request.version == 1, request.type == "device.tool.request",
              request.authorizationEpoch > 0, request.sentAt > 0,
              request.expiresAt > request.sentAt,
              request.expiresAt - request.sentAt <= 120,
              request.sentAt <= clock() + 5,
              [request.requestId, request.deviceId, request.hostId, request.sessionId,
               request.agentId, request.turnId].allSatisfy(Self.validIdentifier),
              let capability = Self.capability(for: request.operation),
              let encoded = try? Self.encoder.encode(request), encoded.count <= 20_480
        else { return failed("invalid_request") }

        let grantRevision = permissions.revision
        let authorize: @MainActor () throws -> Void = { [self] in
            guard owner == request.scope, permissions.scope == owner, isCurrent() else {
                throw Failure(code: "owner_changed")
            }
            guard permissions.isEnabled(capability), permissions.revision == grantRevision else {
                throw Failure(code: "permission_disabled")
            }
            guard available() else { throw Failure(code: "device_unavailable") }
            guard !Task.isCancelled else { throw Failure(code: "request_cancelled") }
            guard request.expiresAt >= clock() else { throw Failure(code: "request_expired") }
        }
        do { try authorize() } catch let error as Failure { return failed(error.code) }
        catch { return failed("unavailable") }

        let mutation = !Self.readOperations.contains(request.operation)
        let fingerprint = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        if mutation {
            do {
                if let prior = try journal.entry(requestID: request.requestId, scope: owner) {
                    guard prior.fingerprint == fingerprint else { return failed("request_conflict") }
                    return prior.result ?? failed("outcome_unknown")
                }
            } catch { return failed("persistence_unavailable") }
        }
        guard activeRequests < 4, !mutation || !mutationInFlight else { return failed("device_busy") }
        activeRequests += 1
        if mutation { mutationInFlight = true }
        defer {
            activeRequests -= 1
            if mutation { mutationInFlight = false }
        }
        if mutation {
            do {
                try journal.save(DeviceToolJournalEntry(fingerprint: fingerprint,
                    expiresAt: request.expiresAt, result: nil), requestID: request.requestId, scope: owner)
            } catch { return failed("persistence_unavailable") }
        }

        let result: DeviceToolResult
        do {
            try authorize()
            let payload = try await execute(request.operation, request.arguments, authorize)
            try authorize()
            guard (try Self.encoder.encode(payload)).count <= 128_000 else {
                throw Failure(code: "result_limit_exceeded")
            }
            // Durable outcomes never include event contents or health/read data.
            if mutation, !Set(payload.keys).isSubset(of: ["id", "revision", "deleted"]) {
                throw Failure(code: "invalid_result")
            }
            result = DeviceToolResult(request: request, status: "completed", payload: payload, sentAt: clock())
        } catch {
            // Prefer a current authorization failure to a stale native callback error.
            do { try authorize() }
            catch let current as Failure { return failed(current.code) }
            catch { return failed("unavailable") }
            let nativeCode = (error as? Failure)?.code ?? (error as? AppleDeviceToolError)?.code ?? "native_failure"
            // A native commit can finish before a callback/identity error is
            // reported. Do not tell the agent a retry is a fresh safe write.
            let code = mutation && ["native_failure", "identity_mismatch", "invalid_result"].contains(nativeCode)
                ? "outcome_unknown" : nativeCode
            result = failed(code)
        }
        if mutation {
            do {
                let entry = DeviceToolJournalEntry(fingerprint: fingerprint, expiresAt: request.expiresAt, result: result)
                try journal.save(entry, requestID: request.requestId, scope: owner)
                guard try journal.entry(requestID: request.requestId, scope: owner) == entry else {
                    return failed("outcome_unknown")
                }
            } catch { return failed("outcome_unknown") }
        }
        return result
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Reads are never journaled: their results (health, events, where someone is) stay off disk.
    private static let readOperations: Set<String> = ["health.read", "calendar.list", "reminders.list", "location.current"]

    private static func capability(for operation: String) -> DeviceToolCapability? {
        switch operation {
        case "health.read": .health
        case "calendar.list", "calendar.create", "calendar.update", "calendar.delete": .calendar
        case "reminders.list", "reminders.create", "reminders.update", "reminders.delete": .reminders
        case "location.current": .location
        default: nil
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
