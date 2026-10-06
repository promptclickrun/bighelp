import Foundation

/// A chat's voice client that finds the computer's own client when it's needed, not when voice opens.
/// Right after launch, voice can open before the connection is ready; a client chosen then could only
/// fail, so the first answer and End both failed until the app was reopened. Each call waits a moment
/// for the connection, and a new connection (after the app was away) gets a new client.
@MainActor
final class DeferredVoiceSessionClient: VoiceSessionClient {
    private let currentKey: @MainActor () -> AnyHashable?
    private let make: @MainActor () -> (any VoiceSessionClient)?
    private let wait: Duration
    private let attempts: Int
    /// The client for the connection it was made on; it speaks, and End and Stop reach it.
    private var current: (key: AnyHashable, client: any VoiceSessionClient)?

    /// `currentKey` names the connection (nil while there's none); `make` builds the computer's client
    /// for it (nil while the chat isn't bound to it yet). Waits `attempts` × `wait` at most.
    init(wait: Duration = .milliseconds(250), attempts: Int = 60,
         currentKey: @escaping @MainActor () -> AnyHashable?,
         make: @escaping @MainActor () -> (any VoiceSessionClient)?) {
        self.wait = wait
        self.attempts = attempts
        self.currentKey = currentKey
        self.make = make
    }

    private func client() async throws -> any VoiceSessionClient {
        for attempt in 0...attempts {
            if let key = currentKey() {
                if let current, current.key == key { return current.client }
                if let made = make() {
                    // The old connection's speech can't go on: its replies would come from nowhere.
                    current?.client.stopSpeaking()
                    current = (key, made)
                    return made
                }
            }
            if attempt < attempts { try await Task.sleep(for: wait) }
        }
        throw WorkspaceClientError.transportUnavailable
    }

    func respond(to transcript: String, conversationID: String,
                 onDraft: @escaping (String) -> Void) async throws -> VoiceAgentReply {
        try await client().respond(to: transcript, conversationID: conversationID, onDraft: onDraft)
    }

    func steer(_ transcript: String, conversationID: String) async throws {
        try await client().steer(transcript, conversationID: conversationID)
    }

    func speak(_ text: String) async throws {
        try await client().speak(text)
    }

    func speak(_ text: String, onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void) async throws {
        try await client().speak(text, onPlayback: onPlayback)
    }

    func stopSpeaking() {
        current?.client.stopSpeaking()
    }

    /// Nothing reached the computer yet: there's nothing to end, so voice just closes.
    func endSession(conversationID: String) async throws {
        try await current?.client.endSession(conversationID: conversationID)
    }

    func transcribe(_ audio: Data) async throws -> String {
        try await client().transcribe(audio)
    }
}
