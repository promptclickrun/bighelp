import Foundation
import Testing
@testable import Bighelp

@MainActor
struct AgentVoiceChoicesTests {
    private let suite = "bighelp.tests.agent-voice.\(UUID().uuidString)"

    private func make() throws -> (SettingsStore, AgentVoiceChoices, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (SettingsStore(defaults: defaults), AgentVoiceChoices(defaults: defaults), defaults)
    }

    @Test func anAgentWithoutItsOwnUsesTheDefaultForEveryAgent() throws {
        let (settings, choices, defaults) = try make()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.voiceConversationMode = .turnBased

        let voice = settings.voicePreference(computer: "computer-a", agentID: "finance", choices: choices)

        #expect(voice.mode == .turnBased)
        #expect(!voice.hasOwnMode)
        #expect(voice.liveVoice == settings.liveVoice(for: settings.liveVoiceProvider))
    }

    @Test func anAgentsOwnVoiceTypeIsKeptByComputerAndAgent() throws {
        let (settings, choices, defaults) = try make()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.voiceConversationMode = .turnBased
        choices.setMode(.codexLive, computer: "computer-a", agentID: "finance")

        func mode(_ computer: String?, _ agent: String) -> VoiceConversationMode {
            settings.voicePreference(computer: computer, agentID: agent, choices: choices).mode
        }
        #expect(mode("computer-a", "finance") == .codexLive)
        #expect(settings.voicePreference(computer: "computer-a", agentID: "finance", choices: choices).hasOwnMode)
        #expect(mode("computer-a", "travel") == .turnBased)
        #expect(mode("computer-b", "finance") == .turnBased, "Another computer's agent is another agent")
        #expect(mode(nil, "finance") == .turnBased, "Without a computer nothing can be kept")

        settings.voiceConversationMode = .codexLive
        choices.setMode(.turnBased, computer: "computer-a", agentID: "finance")
        #expect(mode("computer-a", "finance") == .turnBased, "Its own choice wins over the default")
        #expect(AgentVoiceChoices(defaults: defaults).mode(computer: "computer-a", agentID: "finance") == .turnBased,
                "Kept on the device")

        choices.setMode(nil, computer: "computer-a", agentID: "finance")
        #expect(mode("computer-a", "finance") == .codexLive)
    }

    @Test func gptLiveVoiceIsPerAgentAndPerSignIn() throws {
        let (settings, choices, defaults) = try make()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.liveVoiceProvider = .codexSubscription
        choices.setLiveVoice("maple", for: .codexSubscription, computer: "computer-a", agentID: "finance")
        choices.setLiveVoice("not-a-voice", for: .apiKey, computer: "computer-a", agentID: "finance")

        #expect(settings.voicePreference(computer: "computer-a", agentID: "finance", choices: choices).liveVoice == "maple")
        #expect(settings.voicePreference(computer: "computer-a", agentID: "travel", choices: choices).liveVoice
                == settings.liveVoice(for: .codexSubscription))
        settings.liveVoiceProvider = .apiKey
        #expect(settings.voicePreference(computer: "computer-a", agentID: "finance", choices: choices).liveVoice
                == settings.liveVoice(for: .apiKey), "Each sign-in has voices of its own")
    }

    @Test func gptLiveFailingFallsBackWhereTheVoiceTypeComesFrom() throws {
        let (settings, choices, defaults) = try make()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.voiceConversationMode = .codexLive

        settings.useTurnBasedVoice(computer: "computer-a", agentID: "finance", choices: choices)
        #expect(settings.voiceConversationMode == .turnBased, "No choice of its own: the default changes, as before")

        settings.voiceConversationMode = .codexLive
        choices.setMode(.codexLive, computer: "computer-a", agentID: "travel")
        settings.useTurnBasedVoice(computer: "computer-a", agentID: "travel", choices: choices)
        #expect(choices.mode(computer: "computer-a", agentID: "travel") == .turnBased)
        #expect(settings.voiceConversationMode == .codexLive, "Other agents keep the default")
    }

    @Test func pickingAVoiceTypeForOneBotLeavesTheDefaultAlone() throws {
        let (settings, choices, defaults) = try make()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.voiceConversationMode = .codexLive

        settings.setVoiceConversationMode(.turnBased, computer: "computer-a", agentID: "finance", choices: choices)
        #expect(choices.mode(computer: "computer-a", agentID: "finance") == .turnBased)
        #expect(settings.voiceConversationMode == .codexLive)

        settings.setVoiceConversationMode(.turnBased, computer: nil, agentID: "finance", choices: choices)
        #expect(settings.voiceConversationMode == .turnBased, "No agent to keep it for: the default")
    }

    @Test func aVoiceTypeThisVersionDoesntKnowReadsAsNoChoice() throws {
        let (settings, choices, defaults) = try make()
        defer { defaults.removePersistentDomain(forName: suite) }
        choices.setMode(.codexLive, computer: "computer-a", agentID: "finance")
        choices.setLiveVoice("maple", for: .codexSubscription, computer: "computer-a", agentID: "finance")
        let saved = try #require(defaults.data(forKey: AgentVoiceChoices.key))
        let later = try #require(String(data: saved, encoding: .utf8)?
            .replacingOccurrences(of: "codexLive", with: "someLaterMode"))
        defaults.set(Data(later.utf8), forKey: AgentVoiceChoices.key)
        settings.voiceConversationMode = .turnBased

        let reopened = AgentVoiceChoices(defaults: defaults)
        let voice = settings.voicePreference(computer: "computer-a", agentID: "finance", choices: reopened)

        #expect(voice.mode == .turnBased)
        #expect(!voice.hasOwnMode)
        #expect(voice.liveVoice == "maple", "The rest of its choice still reads")
    }
}
