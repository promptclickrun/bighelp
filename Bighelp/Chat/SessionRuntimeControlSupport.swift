import Foundation

/// Local picker identity, never a Link wire coordinate. The chat may not have a live
/// session yet: its pickers still list, and a choice waits for one.
struct NativeSessionRuntimePickerCoordinate: Equatable, Sendable {
    let workspace: WorkspaceSessionCoordinate

    init(_ coordinate: WorkspaceSessionCoordinate) throws {
        let identity = try DirectHermesSessionIdentity.decode(coordinate.sessionID, owner: coordinate.owner)
        guard DirectHermesSessionValidation.same(identity.profileID, coordinate.profileID) else {
            throw WorkspaceClientError.invalidRequest
        }
        workspace = coordinate
    }
}

struct SessionRuntimeControlSupport: Equatable, Sendable {
    var modelUnavailableReason: String?
    var reasoningUnavailableReason: String?

    static let available = SessionRuntimeControlSupport()
    static let nativeReasoningReadOnly =
        "This Hermes host does not expose a safe current-chat reasoning change or reset. The current value is read-only."
}

struct SessionRuntimeModelConfirmation: Identifiable, Equatable, Sendable {
    let id: UUID
    let selection: BighelpLinkPickerSelection
    let coordinate: WorkspaceSessionCoordinate
    let message: String
}

struct SessionRuntimeModelConfirmationRequired: Error, Equatable, Sendable {
    let confirmation: SessionRuntimeModelConfirmation
}

struct SessionRuntimeModelDeferred: Error, Equatable, Sendable {
    let selection: BighelpLinkPickerSelection
    let coordinate: WorkspaceSessionCoordinate
    let message: String
}

@MainActor
protocol SessionRuntimeControlSupporting: AnyObject {
    func selectionSupport(sessionID: String, agentID: String) -> SessionRuntimeControlSupport
    func cachedModelProviders(agentID: String) -> [BighelpLinkModelProvider]
}

extension SessionRuntimeControlSupporting {
    func cachedModelProviders(agentID: String) -> [BighelpLinkModelProvider] { [] }
}

@MainActor
protocol SessionRuntimeControlConfirming: BighelpLinkSessionControlMessaging {
    func confirmPicker(_ confirmation: SessionRuntimeModelConfirmation) async throws -> BighelpLinkPickerResult
    func cancelPickerConfirmation(_ confirmation: SessionRuntimeModelConfirmation)
}
