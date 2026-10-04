import CryptoKit
import Foundation

// MARK: - Client

/// Owner-bound client for Hermes host operations. It controls the messaging
/// gateway only; there is deliberately no API or label for restarting
/// `hermes serve` from the connection it hosts.
@MainActor
final class DirectHermesHostOperationsClient: HermesHostActionStatusClient {
    nonisolated static let maximumRawConfigurationBytes = 256 * 1_024
    nonisolated static let maximumImportUploadBytes = 16 * 1_024 * 1_024

    let owner: WorkspaceOwner

    let rpc: any DirectHermesRPC
    let http: any DirectHermesAuthenticatedHTTP
    private let currentOwner: @MainActor () -> WorkspaceOwner?

    init(
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.rpc = rpc
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func receipt(forActionName name: String) throws -> HermesHostActionReceipt {
        try requireOwner()
        return try .actionSlot(named: name)
    }

    func status(for receipt: HermesHostActionReceipt) async throws -> HermesHostActionStatus {
        try requireOwner()
        let value = try await json(
            .init(
                path: "/api/actions/\(receipt.action.rawValue)/status",
                method: .get,
                query: [.init(name: "lines", value: "1")],
                maximumResponseBytes: 320 * 1_024
            ),
            feature: "background-action status"
        )
        let object = try DirectHermesHostPayload.object(value)
        guard object["name"]?.string == receipt.action.rawValue,
              let running = object["running"]?.boolean else {
            throw HostOperationsError.invalidResponse
        }
        let pid = try DirectHermesHostPayload.optionalInteger(object["pid"], range: 1...Int.max)
        let exitCode = try DirectHermesHostPayload.optionalInteger(object["exit_code"], range: Int.min...Int.max)
        let actionID = try DirectHermesHostPayload.optionalText(object["action_id"], maximumBytes: 128)

        if let expected = receipt.processID, let pid, expected != pid {
            throw HostOperationsError.reviewChanged
        }
        if let expected = receipt.actionID, let actionID,
           !actionID.utf8.elementsEqual(expected.utf8) {
            throw HostOperationsError.reviewChanged
        }

        let phase: HermesHostActionStatus.Phase
        if running {
            guard exitCode == nil else { throw HostOperationsError.invalidResponse }
            phase = .running
        } else if let exitCode {
            phase = exitCode == 0 ? .succeeded : .failed(exitCode: exitCode)
        } else {
            phase = .outcomeUnknown
        }

        let correlation: HermesHostActionStatus.Correlation
        if let expected = receipt.actionID, actionID?.utf8.elementsEqual(expected.utf8) == true {
            correlation = .exactActionID
        } else if let expected = receipt.processID, pid == expected {
            correlation = .matchingProcess
        } else if receipt.admission == .actionSlotOnly {
            correlation = .actionSlotOnly
        } else {
            correlation = .pendingIdentity
        }
        let updateSummary = try object["receipt"].map { try DirectHermesHostPayload.updateSummary($0) }
        return .init(
            action: receipt.action, phase: phase, processID: pid,
            actionID: actionID, correlation: correlation,
            updateSummary: updateSummary
        )
    }

    func launch(
        _ request: DirectHermesHTTPRequest,
        expectedAction: HermesHostAction,
        feature: String
    ) async throws -> HermesHostActionReceipt {
        let object = try DirectHermesHostPayload.object(try await json(request, feature: feature, mutation: true))
        return try launchReceipt(object, expectedAction: expectedAction)
    }

    func launchReceipt(
        _ object: [String: BighelpJSONValue],
        expectedAction: HermesHostAction
    ) throws -> HermesHostActionReceipt {
        guard object["ok"]?.boolean == true,
              let name = object["name"]?.string,
              name == expectedAction.rawValue else {
            throw HostOperationsError.outcomeUnknown
        }
        let pid = try DirectHermesHostPayload.optionalInteger(object["pid"], range: 1...Int.max)
        let actionID = try DirectHermesHostPayload.optionalText(object["action_id"], maximumBytes: 128)
        if expectedAction == .hermesUpdate,
           let actionID,
           !DirectHermesHostPayload.isLowerHex(actionID, count: 32) {
            throw HostOperationsError.outcomeUnknown
        }
        let archive = expectedAction == .backup
            ? try DirectHermesHostPayload.optionalText(object["archive"], maximumBytes: 4_096)
            : nil
        guard pid != nil || actionID != nil else { throw HostOperationsError.outcomeUnknown }
        return .init(
            action: expectedAction, processID: pid, actionID: actionID,
            archivePath: archive, admittedAt: Date(), admission: .launchAcknowledged
        )
    }

    func json(
        _ request: DirectHermesHTTPRequest,
        feature: String,
        mutation: Bool = false
    ) async throws -> BighelpJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: requireOwner, mapError: { error in
            if case DirectHermesError.unsupportedAuthentication = error {
                return HostOperationsError.unavailable(feature)
            }
            return mutation ? HostOperationsError.outcomeUnknown : error
        }) {
            try await http.request(request)
        }
    }

    func requireOwner() throws {
        try Task.checkCancellation()
        try requireOwnerIdentity()
    }

    func requireOwnerIdentity() throws {
        guard owner.authority.kind == .direct, currentOwner() == owner else {
            throw HostOperationsError.ownerChanged
        }
    }
}
