import Testing
@testable import Bighelp

@MainActor
struct LiveVoiceUnavailableTests {
    /// The voice screen names what actually stopped live voice. It once said "your computer doesn't
    /// support live voice yet" for every reason, even a plugin that was installed but not loaded.
    @Test func eachMissingPieceHasItsOwnReason() {
        func reason(connected: Bool = true,
                    features: Set<String>? = ["native-context-v1", LiveVoiceUnavailable.feature],
                    plugin: NativeWorkspaceRuntime.PluginState = .running,
                    direct: Bool = true, ready: Bool = true) -> LiveVoiceUnavailable? {
            LiveVoiceUnavailable.reason(connected: connected, features: features, plugin: plugin,
                                        isDirectChat: direct, chatReady: ready)
        }
        #expect(reason() == nil)
        #expect(reason(connected: false, features: nil, plugin: .unknown) == .connecting)
        // Connected, but the plugin's list isn't read on this connection yet.
        #expect(reason(features: nil, plugin: .unknown) == .connecting)
        #expect(reason(features: nil, plugin: .notInstalled) == .pluginNotInstalled)
        #expect(reason(features: nil, plugin: .notLoaded) == .pluginNotLoaded)
        #expect(reason(features: nil, plugin: .unreachable) == .pluginUnreachable)
        #expect(reason(features: ["native-context-v1"]) == .voiceNotOffered)
        #expect(reason(ready: false) == .chatOpening)
        #expect(reason(direct: false) == .groupChat)
    }

    /// Voice waits only for what comes by itself a moment after a chat opens.
    @Test func onlyTheConnectionAndTheChatPassByThemselves() {
        #expect(LiveVoiceUnavailable.connecting.passesByItself)
        #expect(LiveVoiceUnavailable.chatOpening.passesByItself)
        for reason in [LiveVoiceUnavailable.groupChat, .pluginNotInstalled, .pluginNotLoaded, .pluginUnreachable,
                       .voiceNotOffered, .demo] {
            #expect(!reason.passesByItself)
        }
    }

    @Test func onlyReasonsAStepCanFixOfferTryAgain() {
        #expect(LiveVoiceUnavailable.pluginNotLoaded.canTryAgain)
        #expect(LiveVoiceUnavailable.connecting.canTryAgain)
        #expect(!LiveVoiceUnavailable.groupChat.canTryAgain)
        #expect(!LiveVoiceUnavailable.demo.canTryAgain)
    }
}
