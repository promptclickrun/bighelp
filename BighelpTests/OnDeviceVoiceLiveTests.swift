import Foundation
import Testing
@testable import Bighelp

/// The real Phonon model, end to end: download, checksum, unpack, load and play. It downloads
/// about 137 MB, so it runs only with `TEST_RUNNER_BIGHELP_PHONON_LIVE=1`.
@MainActor
struct OnDeviceVoiceLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BIGHELP_PHONON_LIVE"] == "1"
                   && OnDeviceSpeechEngine.isSupported),
          .timeLimit(.minutes(15)))
    func phononDownloadsAndSpeaksAVoice() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phonon-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = OnDeviceVoiceInstaller(root: root)
        installer.install(.phonon)
        while isBusy(installer.state(of: .phonon)) {
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(installer.state(of: .phonon) == .installed)
        let voices = installer.voices(for: .phonon)
        #expect(voices.first == "default")
        #expect(voices.count == 38)
        #expect(OnDeviceVoiceModel.phonon.characterVoices.isSubset(of: Set(voices)))

        let engine = OnDeviceSpeechEngine(installer: installer)
        let events = PlaybackLog()
        let owner = NSObject()
        try await engine.speak("Hello. This is **Zoey**, speaking on this phone.", model: .phonon, voice: "Zoey",
                               rate: 1, use: .playback, owner: owner) { events.items.append($0) }
        #expect(events.items.first == .started)
        #expect(events.items.last == .finished)
        #expect(events.items.contains { if case .level(let value) = $0 { value > 0 } else { false } })

        // A team call: each member's piece in its own voice, never the last speaker's.
        let zoey = try await engine.synthesize("Team call check.", model: .phonon, voice: "Zoey")
        let hugh = try await engine.synthesize("Team call check.", model: .phonon, voice: "Hugh")
        let zoeyAgain = try await engine.synthesize("Team call check.", model: .phonon, voice: "Zoey")
        #expect(zoey.count > 44 && hugh.count > 44)
        #expect(zoey != hugh, "Two members spoke in one voice")
        #expect(zoey == zoeyAgain || zoeyAgain != hugh)
    }

    private func isBusy(_ state: OnDeviceVoiceInstaller.State) -> Bool {
        if case .downloading = state { return true }
        return state == .installing
    }
}

@MainActor
private final class PlaybackLog {
    var items: [VoicePlaybackEvent] = []
}
