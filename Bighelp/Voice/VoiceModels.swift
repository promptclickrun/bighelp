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
    static let usesThinkingOrbsKitSurface = true

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

/// The Noodle in the voice pill acts out the call: it listens, thinks and talks along,
/// rests while paused or muted, and asks when something went wrong.
enum VoiceNoodle {
    static func motion(_ state: AgentLiveState) -> BighelpNoodleMotion {
        switch state {
        case .listening: .listening
        case .thinking: .thinking
        case .speaking: .talking
        case .idle: .resting
        case .happy: .done
        case .nudge: .hello
        }
    }

    static func motion(turnBased status: VoiceStatus, live: AgentLiveState) -> BighelpNoodleMotion {
        switch status {
        case .listening, .working, .speaking: motion(live)
        case .paused: .resting
        case .unavailable: .question
        }
    }

    static func motion(livePhase phase: LiveVoiceModel.Phase, live: AgentLiveState) -> BighelpNoodleMotion {
        switch phase {
        case .live: motion(live)
        case .preparing, .connecting: .launch
        case .interrupted: .resting
        case .idle: .idle
        case .ended: .exit
        case .failed: .question
        }
    }

    /// Connecting repeats its launch with a rest; the rest play as the kit made them.
    static func playback(_ motion: BighelpNoodleMotion) -> BighelpNoodlePlayback {
        motion == .launch ? .loop(pause: 0.6) : .automatic
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
