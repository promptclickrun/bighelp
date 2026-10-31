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
            // The call modes (voice chat, video chat) play everything at phone-call volume, so
            // replies and the hold music came in quiet on the speaker. The default mode plays at
            // media volume; iPhones that can cancel the speaker's echo there keep the agent
            // from hearing itself. Others keep video chat's echo cancellation, the speakerphone
            // tuning of the call modes.
            try session.setCategory(.playAndRecord, mode: .default, options: Self.conversationOptions)
            if Self.conversationMode(echoCancellationAvailable: canCancelEcho) == .default {
                try enableEchoCancellation()
            } else {
                try session.setCategory(.playAndRecord, mode: .videoChat, options: Self.conversationOptions)
            }
        }
    }

    /// A live call cancels its own echo (WebRTC for GPT-Live, the engine's voice processing for Gemini), so
    /// it gets the speakerphone tuning and the same setup on every call. The turn-based chat's choice by
    /// `isEchoCancelledInputAvailable` changes with the route, and stacked the system's echo cancelling on
    /// the engine's own: Gemini's voice sometimes didn't play.
    static let liveCallMode: AVAudioSession.Mode = .videoChat
    static let liveCallOptions: AVAudioSession.CategoryOptions = [.allowBluetooth, .defaultToSpeaker]

    func configureForLiveCall() throws {
        try session.setCategory(.playAndRecord, mode: Self.liveCallMode, options: Self.liveCallOptions)
    }

    /// Media volume where the microphone can cancel the speaker's echo; else a call mode.
    static func conversationMode(echoCancellationAvailable: Bool) -> AVAudioSession.Mode {
        echoCancellationAvailable ? .default : .videoChat
    }

    /// Echo-cancelled input in the default mode (certain 2024 and later iPhones, iOS 18.2).
    private var canCancelEcho: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 18.2, *) { return session.isEchoCancelledInputAvailable }
        #endif
        return false
    }

    private func enableEchoCancellation() throws {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 18.2, *) { try session.setPrefersEchoCancelledInput(true) }
        #endif
    }

    func setActive(_ active: Bool) throws {
        if active {
            try session.setActive(true, options: [])
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

enum VoiceAudioSessionError: Error, Equatable, Sendable {
    /// A live voice call runs its own audio and owns the session until it ends.
    case heldByLiveCall
}

/// Microphone capture and agent playback share one `AVAudioSession`. Each takes
/// an independent claim; the session is deactivated only once the last claim is
/// released, so stopping the mic can never cut off audio that is still playing.
///
/// A live voice call (WebRTC) sets up and deactivates the session through its own audio
/// session, which this coordinator can't see. While it holds the session (`holdForLiveCall`),
/// every claim is refused, so nothing here configures it or deactivates it under the call.
///
/// Deliberately not actor-isolated: `release` must be reachable from the
/// nonisolated `deinit` teardown paths that own these claims.
final class VoiceAudioSessionCoordinator: @unchecked Sendable {
    static let shared = VoiceAudioSessionCoordinator()

    private let session: any VoiceAudioSessionControlling
    private let lock = NSLock()
    private var activeClaims: [UUID: VoiceAudioUse] = [:]
    private var liveCallLease: UUID?

    init(session: any VoiceAudioSessionControlling = SystemVoiceAudioSession()) {
        self.session = session
    }

    var claimCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeClaims.count
    }

    /// Reserves the session for a live call, which runs its own audio. Refused while any
    /// claim is held or another call holds it. It never touches the session itself.
    func holdForLiveCall() throws -> VoiceAudioSessionLiveCallLease {
        lock.lock()
        defer { lock.unlock() }

        guard activeClaims.isEmpty, liveCallLease == nil else { throw VoiceAudioSessionError.heldByLiveCall }
        let id = UUID()
        liveCallLease = id
        return VoiceAudioSessionLiveCallLease(id: id, coordinator: self)
    }

    /// Activates the shared session if it is not already owned. The claim is
    /// only recorded once activation succeeds, so a throwing activation cannot
    /// strand a claim that would pin the session active forever.
    func acquire(for use: VoiceAudioUse) throws -> VoiceAudioSessionClaim {
        lock.lock()
        defer { lock.unlock() }

        guard liveCallLease == nil else { throw VoiceAudioSessionError.heldByLiveCall }
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

    fileprivate func releaseLiveCall(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        if liveCallLease == id { liveCallLease = nil }
    }
}

/// Idempotent like a claim. Letting go only lifts the refusal: the call deactivates its own audio.
final class VoiceAudioSessionLiveCallLease: @unchecked Sendable {
    private let id: UUID
    private let coordinator: VoiceAudioSessionCoordinator

    fileprivate init(id: UUID, coordinator: VoiceAudioSessionCoordinator) {
        self.id = id
        self.coordinator = coordinator
    }

    func release() {
        coordinator.releaseLiveCall(id)
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
