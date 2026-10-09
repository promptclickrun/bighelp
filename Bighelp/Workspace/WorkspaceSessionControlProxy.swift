import Foundation

@MainActor
final class WorkspaceSessionControlProxy: SessionRuntimeControlConfirming, SessionRuntimeControlSupporting, SessionFastModeControlling {
    private let box: WorkspaceOwnedClientBox<DirectHermesSessionControlClient>

    init(box: WorkspaceOwnedClientBox<DirectHermesSessionControlClient>) { self.box = box }

    func cachedModelProviders(agentID: String) -> [BighelpLinkModelProvider] {
        (try? box.value().cachedModelProviders(agentID: agentID)) ?? []
    }

    func loadFastMode(sessionID: String, agentID: String) async throws -> SessionFastMode {
        try await box.value().loadFastMode(sessionID: sessionID, agentID: agentID)
    }

    func setFastMode(_ mode: FastMode, sessionID: String, agentID: String) async throws -> SessionFastMode {
        try await box.value().setFastMode(mode, sessionID: sessionID, agentID: agentID)
    }

    func openPicker(_ request: BighelpLinkPickerOpenRequest) async throws -> BighelpLinkPicker {
        try await box.value().openPicker(request)
    }

    func selectPicker(_ selection: BighelpLinkPickerSelection) async throws -> BighelpLinkPickerResult {
        try await box.value().selectPicker(selection)
    }

    func selectionSupport(sessionID: String, agentID: String) -> SessionRuntimeControlSupport {
        guard box.hasCurrentCapabilities else {
            return SessionRuntimeControlSupport(
                modelUnavailableReason: "Checking what this host supports.",
                reasoningUnavailableReason: "Checking what this host supports."
            )
        }
        do { return try box.value().selectionSupport(sessionID: sessionID, agentID: agentID) }
        catch {
            return SessionRuntimeControlSupport(
                modelUnavailableReason: "Connect to this host before changing this session's model.",
                reasoningUnavailableReason: "Reconnect to this host before changing this session's reasoning level."
            )
        }
    }

    func confirmPicker(_ confirmation: SessionRuntimeModelConfirmation) async throws -> BighelpLinkPickerResult {
        try await box.value().confirmPicker(confirmation)
    }

    func cancelPickerConfirmation(_ confirmation: SessionRuntimeModelConfirmation) {
        // A replaced owner already fences the old token. Cancellation never
        // opens another connection or dispatches a native mutation.
        guard let client = try? box.value() else { return }
        client.cancelPickerConfirmation(confirmation)
    }
}
