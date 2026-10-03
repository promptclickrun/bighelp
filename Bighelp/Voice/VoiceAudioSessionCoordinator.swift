import AVFoundation
import Foundation

/// What a claim needs the shared audio session for.
enum VoiceAudioUse: Equatable, Sendable {
    /// Playing with nothing listening, like a voice sample in Settings.
    case playback
    /// A voice chat: the microphone, and the agent's replies around it.
    case conversation
}

/// Seam over the process-wide audio session so ownership can be observed in
/// tests without real audio hardware.
protocol VoiceAudioSessionControlling: AnyObject, Sendable {
    func configure(for use: VoiceAudioUse) throws
    func setActive(_ active: Bool) throws
}

final class SystemVoiceAudioSession: VoiceAudioSessionControlling, @unchecked Sendable {
    /// A voice chat pauses other audio (music resumes when it ends, through
    /// `notifyOthersOnDeactivation`) instead of playing it underneath: with the
    /// microphone on, a car or headset switches to its phone-call channel, and
    /// music mixed into that sounds like an old radio.
    static let conversationOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]

    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func configure(for use: VoiceAudioUse) throws {
        switch use {
        case .playback:
            // Nothing listens, so it plays at the phone's normal media volume.
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        case .conversation:
            // Voice-chat mode is tuned for holding the phone to your ear: on
            // the speaker, replies were close to inaudible. Video-chat mode is
            // the speakerphone tuning: the same voice-tuned microphone, with
            // replies at speaker volume.
            try session.setCategory(.playAndRecord, mode: .videoChat, options: Self.conversationOptions)
        }
    }

    func setActive(_ active: Bool) throws {
        if active {
            try session.setActive(true, options: [])
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Microphone capture and agent playback share one `AVAudioSession`. Each takes
/// an independent claim; the session is deactivated only once the last claim is
/// released, so stopping the mic can never cut off audio that is still playing.
///
/// Deliberately not actor-isolated: `release` must be reachable from the
/// nonisolated `deinit` teardown paths that own these claims.
final class VoiceAudioSessionCoordinator: @unchecked Sendable {
    static let shared = VoiceAudioSessionCoordinator()

    private let session: any VoiceAudioSessionControlling
    private let lock = NSLock()
    private var activeClaims: [UUID: VoiceAudioUse] = [:]

    init(session: any VoiceAudioSessionControlling = SystemVoiceAudioSession()) {
        self.session = session
    }

    var isSessionActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !activeClaims.isEmpty
    }

    var claimCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeClaims.count
    }

    /// Activates the shared session if it is not already owned. The claim is
    /// only recorded once activation succeeds, so a throwing activation cannot
    /// strand a claim that would pin the session active forever.
    func acquire(for use: VoiceAudioUse) throws -> VoiceAudioSessionClaim {
        lock.lock()
        defer { lock.unlock() }

        if activeClaims.isEmpty {
            try session.configure(for: use)
            try session.setActive(true)
        } else if use == .conversation, !activeClaims.values.contains(.conversation) {
            // Something was only playing; the microphone needs the chat setup.
            try session.configure(for: .conversation)
        }
        let id = UUID()
        activeClaims[id] = use
        return VoiceAudioSessionClaim(id: id, coordinator: self)
    }

    fileprivate func release(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        guard activeClaims.removeValue(forKey: id) != nil else { return }
        guard activeClaims.isEmpty else { return }
        try? session.setActive(false)
    }
}

/// Releasing is idempotent: the coordinator drops unknown identifiers, so a
/// double release can never deactivate a session a later claim now owns.
final class VoiceAudioSessionClaim: @unchecked Sendable {
    private let id: UUID
    private let coordinator: VoiceAudioSessionCoordinator

    fileprivate init(id: UUID, coordinator: VoiceAudioSessionCoordinator) {
        self.id = id
        self.coordinator = coordinator
    }

    func release() {
        coordinator.release(id)
    }
}
