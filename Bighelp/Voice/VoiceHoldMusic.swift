import AVFoundation
import Foundation

/// Fills a voice chat's dead space, from the end of the person's turn until the reply plays.
@MainActor
protocol VoiceHoldMusicPlaying: AnyObject {
    func start()
    func stop()
}

/// The hold loop, looping quietly under the conversation's audio session. It picks up where it
/// paused, so each wait doesn't restart the tune.
@MainActor
final class AVAudioPlayerHoldMusic: VoiceHoldMusicPlaying {
    static let resourceName = "VoiceHoldLoop"
    /// Under a reply's level: it's a waiting sound, not something to listen to.
    static let volume: Float = 0.35

    private let sessionCoordinator: VoiceAudioSessionCoordinator
    private var player: AVAudioPlayer?
    /// Released from `deinit` too; releasing is thread-safe and idempotent.
    nonisolated(unsafe) private var claim: VoiceAudioSessionClaim?
    private var pausing: Task<Void, Never>?

    var isPlaying: Bool { player?.isPlaying == true }

    init(sessionCoordinator: VoiceAudioSessionCoordinator = .shared) {
        self.sessionCoordinator = sessionCoordinator
    }

    func start() {
        pausing?.cancel()
        pausing = nil
        if claim == nil {
            claim = try? sessionCoordinator.acquire(for: .conversation)
        }
        guard claim != nil, let player = player ?? makePlayer() else { return release() }
        self.player = player
        if !player.isPlaying {
            player.volume = 0
            guard player.play() else { return release() }
        }
        player.setVolume(Self.volume, fadeDuration: 0.3)
    }

    /// A short fade, so it doesn't click off, gone before the reply's first word lands.
    func stop() {
        guard let player, player.isPlaying else { return release() }
        player.setVolume(0, fadeDuration: 0.08)
        pausing?.cancel()
        pausing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let self else { return }
            self.player?.pause()
            self.release()
        }
    }

    private func makePlayer() -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: Self.resourceName, withExtension: "wav"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.numberOfLoops = -1
        player.prepareToPlay()
        return player
    }

    private func release() {
        pausing = nil
        claim?.release()
        claim = nil
    }

    deinit {
        claim?.release()
    }
}
