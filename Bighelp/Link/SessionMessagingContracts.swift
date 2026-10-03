import Foundation

// Shared session/picker and injected fixture contracts, not a chat transport.
enum BighelpLinkLiveSocketError: Error, Equatable, LocalizedError {
    case signedOut
    case busy
    case timedOut
    case disconnected
    case binaryMessage
    case stopped
    case interrupted
    case invalidVoiceResponse
    case voiceUnavailable
    case invalidPickerResponse
    case pickerOpenFailed(message: String)
    case invalidCommandCatalogResponse
    case requestFailed(code: String, message: String)
    case hostUpdateRequired
    case directHostSetupRequired

    var errorDescription: String? {
        switch self {
        case .pickerOpenFailed(let message): return message
        case .requestFailed(_, let message): return message
        case .hostUpdateRequired:
            return "Update the bighelp plugin on this Hermes host to use this feature, then reconnect."
        case .directHostSetupRequired:
            return "Direct connection is unavailable on this host. Check Direct settings and connection status in the host’s bighelp plugin, then reconnect."
        default: return nil
        }
    }
}

struct BighelpLinkVoiceAudio: Equatable, Sendable {
    let audio: Data
    let mimeType: String
    let provider: String
}

@MainActor
protocol BighelpLinkVoiceMessaging: AnyObject {
    func synthesize(_ request: BighelpLinkVoiceSpeakRequest) async throws -> BighelpLinkVoiceAudio
}

@MainActor
protocol BighelpLinkSessionControlMessaging: AnyObject {
    func openPicker(_ request: BighelpLinkPickerOpenRequest) async throws -> BighelpLinkPicker
    func selectPicker(_ selection: BighelpLinkPickerSelection) async throws -> BighelpLinkPickerResult
}

@MainActor
protocol BighelpLinkSessionForkMessaging: AnyObject {
    func forkSession(
        _ request: BighelpLinkSessionForkRequest
    ) async throws -> BighelpLinkSessionForkResult
}

@MainActor
protocol BighelpLinkSlashCommandCatalogMessaging: AnyObject {
    func loadSlashCommandCatalog(
        _ request: BighelpLinkSlashCommandCatalogRequest
    ) async throws -> BighelpLinkSlashCommandCatalog
}

@MainActor
protocol BighelpLinkGenerativeUIFormMessaging: AnyObject {
    func submitGenerativeUIForm(
        _ request: BighelpLinkGenerativeUIFormSubmission
    ) async throws -> BighelpLinkGenerativeUIFormResult
}

@MainActor
protocol BighelpLinkWorkspaceMessaging: AnyObject {
    var workspaceOwnerIdentity: String { get }
    func prepareSessionStateSupport() async throws -> Bool
    func performWorkspaceRequest(
        _ request: BighelpLinkWorkspaceRequest
    ) async throws -> BighelpLinkWorkspaceResult
    func performPreparedWorkspaceRequest(
        _ request: BighelpLinkWorkspaceRequest
    ) async throws -> BighelpLinkWorkspaceResult
}

extension BighelpLinkWorkspaceMessaging {
    var workspaceOwnerIdentity: String { "legacy-provider" }
    func prepareSessionStateSupport() async throws -> Bool { false }
    /// Injected compatibility clients retain their explicitly supplied request path.
    func performPreparedWorkspaceRequest(
        _ request: BighelpLinkWorkspaceRequest
    ) async throws -> BighelpLinkWorkspaceResult {
        try await performWorkspaceRequest(request)
    }
}

enum BighelpLinkConversationError: Error, Equatable {
    case invalidMessage
    case mismatchedSession
}

enum BighelpLinkSessionForkError: Error, Equatable {
    case rejected
    case mismatchedResult
}

enum BighelpLinkSlashCommandCatalogError: Error, Equatable {
    case mismatchedResult
}

@MainActor
protocol BighelpLinkChatMessaging: AnyObject {
    func submit(_ message: BighelpLinkUserMessage) async throws

    func send(
        _ message: BighelpLinkUserMessage,
        onEvent: @escaping (BighelpLinkAssistantMessage) -> Void
    ) async throws -> BighelpLinkAssistantMessage
}

@MainActor
protocol BighelpLinkInactiveSessionReconciliationMessaging: AnyObject {
    func reconcileInactiveSession(conversationID: String)
}

extension BighelpLinkChatMessaging {
    func submit(_ message: BighelpLinkUserMessage) async throws {
        _ = try await send(message, onEvent: { _ in })
    }
}

@MainActor
protocol BighelpLinkAttachmentMessaging: AnyObject {
    func uploadAttachmentChunks(_ chunks: [BighelpLinkAttachmentChunk]) async throws
}
