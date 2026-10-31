import Observation

/// Settings › Voice › Debug, which shows only in Nerd Mode: what a call screen shows of the call's sound
/// report (`LiveVoiceAudioReporting`). Both switches start off, so Nerd Mode alone shows nothing on the call
/// screen, and turning Nerd Mode off hides it all again. The `LiveVoiceAudio` log keeps the report either way.
enum LiveVoiceDebug {
    static let showsReportKey = "bighelp.voice.debug.call-report"
    static let showsCopyKey = "bighelp.voice.debug.copy-report"

    struct Parts: Equatable {
        var report = false
        var copy = false
        var any: Bool { report || copy }
    }

    static func parts(nerdMode: Bool, showsReport: Bool = false, showsCopy: Bool = false) -> Parts {
        nerdMode ? Parts(report: showsReport, copy: showsCopy) : Parts()
    }
}

/// The live call in progress, for Settings › Voice › Debug's Restart sound. Weak, so Settings never keeps a
/// call alive; the call sets it as it starts and clears it as it stops.
@MainActor
@Observable
final class LiveVoiceCurrentCall {
    static let shared = LiveVoiceCurrentCall()

    @ObservationIgnored private weak var stored: LiveVoiceModel?
    /// Observed stand-in for `stored`: a weak property can't be observed.
    private var changes = 0

    var call: LiveVoiceModel? {
        _ = changes
        return stored
    }

    func began(_ call: LiveVoiceModel) {
        stored = call
        changes &+= 1
    }

    func ended(_ call: LiveVoiceModel) {
        guard stored === call else { return }
        stored = nil
        changes &+= 1
    }

    /// Only a Gemini Live call can: the phone plays its sound with a player of its own.
    var canRestartSound: Bool { call?.canRestartPlayback == true }

    /// Stops and starts the call's player. Does nothing without a Gemini Live call in progress.
    @discardableResult
    func restartSound() -> Bool {
        guard let call, call.canRestartPlayback else { return false }
        call.restartPlayback()
        return true
    }
}
