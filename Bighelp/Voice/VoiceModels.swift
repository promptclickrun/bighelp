import Foundation

enum VoiceStatus: String, CaseIterable, Identifiable, Sendable {
    case listening
    case working
    case speaking
    case paused
    case unavailable

    var id: Self { self }

    var label: String {
        switch self {
        case .listening:
            "Listening"
        case .working:
            "Working"
        case .speaking:
            "Speaking"
        case .paused:
            "Paused"
        case .unavailable:
            "Unavailable"
        }
    }
}

enum VoiceOrbPresentation {
    static let usesExplicitOrbSurface = true

    static func scenario(for status: VoiceStatus) -> BighelpThinkingOrbScenario {
        switch status {
        case .listening:
            .listening
        case .working:
            .reasoning
        case .speaking:
            .waiting
        case .paused:
            .waiting
        case .unavailable:
            .working
        }
    }
}

/// The lifter in the voice pill acts out the call: he waits while it listens, thinks and
/// announces along, naps while paused, muted or ended, and sweats when something went wrong.
enum VoiceLifter {
    static func motion(_ state: AgentLiveState) -> BighelpLifterMotion {
        switch state {
        case .listening, .nudge: .idle
        case .thinking: .thinking
        case .speaking: .replying
        case .idle: .sleeping
        case .happy: .success
        }
    }

    static func motion(turnBased status: VoiceStatus, live: AgentLiveState) -> BighelpLifterMotion {
        switch status {
        case .listening, .working, .speaking: motion(live)
        case .paused: .sleeping
        case .unavailable: .error
        }
    }

    static func motion(livePhase phase: LiveVoiceModel.Phase, live: AgentLiveState) -> BighelpLifterMotion {
        switch phase {
        case .live: motion(live)
        case .preparing, .connecting, .idle: .idle
        case .interrupted, .ended: .sleeping
        case .failed: .error
        }
    }
}

enum VoiceViewPresentation {
    /// Voice mode keeps the state cue compact so the orb remains the visual focus.
    static let statusUsesFullWidthSurface = false
    static let statusVerticalPadding: CGFloat = 8
    static let controlMinimumHeight: CGFloat = 64
    static let controlIconDiameter: CGFloat = 52
    static let transcriptMinimumHeight: CGFloat = 64
}

struct VoiceInputLevelSmoother: Sendable {
    private(set) var value: Float = 0

    mutating func update(target: Float) -> Float {
        let boundedTarget = min(max(target, 0), 1)
        let coefficient: Float = boundedTarget >= value ? 0.42 : 0.16
        value += (boundedTarget - value) * coefficient
        value = min(max(value, 0), 1)
        return value
    }

    mutating func reset() {
        value = 0
    }
}

struct VoiceTranscriptRow: Identifiable, Equatable, Sendable {
    let id: String
    let speaker: String
    let time: String
    let text: String
}

struct VoiceRecognitionUpdate: Equatable, Sendable {
    let text: String
    let isFinal: Bool
}

struct VoiceAgentReply: Equatable, Sendable {
    let speaker: String
    let text: String
    let timelineItems: [TimelineItem]
}

enum VoiceSessionError: Error, Equatable, Sendable {
    case unsupported
    case emptyResponse
}

enum VoicePlaybackEvent: Equatable, Sendable {
    case started
    case level(Double)
    case finished
    case failed
}

@MainActor
protocol VoiceSessionClient {
    func respond(
        to transcript: String,
        conversationID: String,
        onDraft: @escaping (String) -> Void
    ) async throws -> VoiceAgentReply
    func steer(_ transcript: String, conversationID: String) async throws
    func speak(_ text: String) async throws
    func speak(
        _ text: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws
    func stopSpeaking()
    func endSession(conversationID: String) async throws
    /// A spoken turn's audio (16 kHz mono WAV) as text, from the host's
    /// speech-to-text provider.
    func transcribe(_ audio: Data) async throws -> String
}

@MainActor
extension VoiceSessionClient {
    func respond(
        to transcript: String,
        conversationID: String,
        onDraft: @escaping (String) -> Void
    ) async throws -> VoiceAgentReply {
        throw VoiceSessionError.unsupported
    }

    func steer(_ transcript: String, conversationID: String) async throws {
        throw VoiceSessionError.unsupported
    }

    func speak(_ text: String) async throws {}
    func speak(
        _ text: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        onPlayback(.started)
        do {
            try await speak(text)
            onPlayback(.finished)
        } catch {
            onPlayback(.failed)
            throw error
        }
    }
    func stopSpeaking() {}

    func transcribe(_ audio: Data) async throws -> String {
        throw VoiceSessionError.unsupported
    }
}
