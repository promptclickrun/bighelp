import Foundation
import Observation

/// Each agent's own voice type (TTS or Full Duplex), Full Duplex provider and voice, chosen in its
/// Default Voice (Bots mode) and kept on this device by computer and agent, like `OnDeviceVoiceChoices`.
/// An agent without its own uses Settings › Voice, the default for every agent.
@MainActor
@Observable
final class AgentVoiceChoices {
    /// Raw values, so a value a later version adds reads as "no choice" instead of failing the whole list.
    struct Choice: Codable, Equatable, Sendable {
        /// A `VoiceConversationMode`; nil follows the default for every agent.
        var mode: String?
        /// A `LiveVoiceProvider`; nil follows the default for every agent.
        var liveProvider: String?
        /// The Full Duplex voice by provider (`LiveVoiceProvider`): each provider has voices of its own.
        var liveVoices: [String: String]?

        var isEmpty: Bool { mode == nil && liveProvider == nil && (liveVoices ?? [:]).isEmpty }
    }

    static let shared = AgentVoiceChoices()
    static let key = "bighelp.voice.agent-choices"
    /// A bound, far above real use: past it, one saved entry makes room for the new one.
    static let limit = 256

    @ObservationIgnored private let defaults: UserDefaults
    private var saved: [String: Choice]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saved = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: Choice].self, from: $0) } ?? [:]
    }

    /// The agent's own voice type, if it has one. `computer` is the connection's `cacheScopeID`.
    func mode(computer: String, agentID: String) -> VoiceConversationMode? {
        saved[Self.entry(computer, agentID)]?.mode.flatMap(VoiceConversationMode.init(rawValue:))
    }

    /// nil goes back to the default for every agent.
    func setMode(_ mode: VoiceConversationMode?, computer: String, agentID: String) {
        update(computer, agentID) { $0.mode = mode?.rawValue }
    }

    /// The agent's own Full Duplex provider, if it has one this version knows.
    func liveProvider(computer: String, agentID: String) -> LiveVoiceProvider? {
        saved[Self.entry(computer, agentID)]?.liveProvider.flatMap(LiveVoiceProvider.init(rawValue:))
    }

    /// nil goes back to the default for every agent.
    func setLiveProvider(_ provider: LiveVoiceProvider?, computer: String, agentID: String) {
        update(computer, agentID) { $0.liveProvider = provider?.rawValue }
    }

    /// The agent's own Full Duplex voice for `provider`, if it has one that provider still offers.
    func liveVoice(for provider: LiveVoiceProvider, computer: String, agentID: String) -> String? {
        saved[Self.entry(computer, agentID)]?.liveVoices?[provider.rawValue].flatMap {
            provider.voices.contains($0) ? $0 : nil
        }
    }

    func setLiveVoice(_ voice: String, for provider: LiveVoiceProvider, computer: String, agentID: String) {
        guard provider.voices.contains(voice) else { return }
        update(computer, agentID) {
            var voices = $0.liveVoices ?? [:]
            voices[provider.rawValue] = voice
            $0.liveVoices = voices
        }
    }

    private func update(_ computer: String, _ agentID: String, _ change: (inout Choice) -> Void) {
        let entry = Self.entry(computer, agentID)
        var choice = saved[entry] ?? Choice()
        change(&choice)
        let next: Choice? = choice.isEmpty ? nil : choice
        guard saved[entry] != next else { return }
        saved[entry] = nil
        if let next {
            if saved.count >= Self.limit, let oldest = saved.keys.sorted().first { saved[oldest] = nil }
            saved[entry] = next
        }
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.key)
    }

    private static func entry(_ computer: String, _ agentID: String) -> String {
        "\(computer.utf8.count):\(computer)\(agentID)"
    }
}

/// The voice an agent talks in when voice opens: its own choices where it has them, else Settings › Voice.
struct AgentVoicePreference: Equatable, Sendable {
    let mode: VoiceConversationMode
    /// Who runs Full Duplex for this agent: its own choice, else Settings › Voice.
    let liveProvider: LiveVoiceProvider
    let liveVoice: String
    /// The voice type is the agent's own, not the default for every agent.
    let hasOwnMode: Bool
    /// The Full Duplex provider is the agent's own, not the default for every agent.
    var hasOwnLiveProvider = false
}

extension SettingsStore {
    /// The voice `agentID` on `computer` (its `cacheScopeID`) talks in. Without either, the default for
    /// every agent: nothing can be kept for an agent the app can't name.
    func voicePreference(computer: String?, agentID: String?,
                         choices: AgentVoiceChoices = .shared) -> AgentVoicePreference {
        guard let computer, let agentID, !computer.isEmpty, !agentID.isEmpty else {
            return AgentVoicePreference(mode: voiceConversationMode, liveProvider: liveVoiceProvider,
                                        liveVoice: liveVoice(for: liveVoiceProvider), hasOwnMode: false)
        }
        let own = choices.mode(computer: computer, agentID: agentID)
        let ownProvider = choices.liveProvider(computer: computer, agentID: agentID)
        let provider = ownProvider ?? liveVoiceProvider
        return AgentVoicePreference(
            mode: own ?? voiceConversationMode, liveProvider: provider,
            liveVoice: choices.liveVoice(for: provider, computer: computer, agentID: agentID) ?? liveVoice(for: provider),
            hasOwnMode: own != nil, hasOwnLiveProvider: ownProvider != nil)
    }

    /// Voice opens as TTS from now on, where the agent's voice type comes from: its own choice when it
    /// has one, else the default for every agent. For GPT Live 1 failing to start.
    func useTurnBasedVoice(computer: String?, agentID: String?, choices: AgentVoiceChoices = .shared) {
        if let computer, let agentID, !computer.isEmpty, !agentID.isEmpty,
           choices.mode(computer: computer, agentID: agentID) != nil {
            choices.setMode(.turnBased, computer: computer, agentID: agentID)
        } else {
            voiceConversationMode = .turnBased
        }
    }

    /// The person picked a voice type for one agent (its Default Voice, or the voice bar over its chat):
    /// that agent's own choice. Without an agent to keep it for, the default for every agent.
    func setVoiceConversationMode(_ mode: VoiceConversationMode, computer: String?, agentID: String?,
                                  choices: AgentVoiceChoices = .shared) {
        guard let computer, let agentID, !computer.isEmpty, !agentID.isEmpty else {
            voiceConversationMode = mode
            return
        }
        choices.setMode(mode, computer: computer, agentID: agentID)
    }
}
