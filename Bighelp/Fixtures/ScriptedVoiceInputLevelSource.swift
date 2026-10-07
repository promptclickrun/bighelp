#if DEBUG
import Foundation

/// `-test-voice-partial`: demo voice hears a long sentence still in progress,
/// so Send now can be seen and tapped without a microphone. Send finishes the
/// sentence as the final words.
@MainActor
final class ScriptedVoiceInputLevelSource: VoiceInputLevelSource {
    static let launchArgument = "-test-voice-partial"
    static let partial = "I'm planning a trip to Denver next month and"
    static let final = "I'm planning a trip to Denver next month and I'd love ideas for day trips."

    var onLevel: ((Float, UInt64) -> Void)?
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)?
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)?
    private var generation: UInt64 = 0
    /// The sentence is heard once; listening again after it's sent hears nothing.
    private var hasSpoken = false

    func start(generation: UInt64) async throws {
        self.generation = generation
        guard !hasSpoken else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.generation == generation else { return }
            self.onLevel?(0.3, generation)
            self.onTranscript?(.init(text: Self.partial, isFinal: false), generation)
        }
    }

    func finishNow() {
        hasSpoken = true
        onTranscript?(.init(text: Self.final, isFinal: true), generation)
    }

    func stop() {
        generation &+= 1
    }
}
#endif
