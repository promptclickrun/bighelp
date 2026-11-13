import Foundation

/// Why live voice can't start in a chat, as the voice screen says it (`LiveVoiceUnavailableView`).
/// Worked out when voice opens, from what the app knows about the computer and the chat then.
enum LiveVoiceUnavailable: String, Error, Equatable, Sendable {
    /// No connection to the computer yet, or its plugin wasn't read on this connection yet.
    case connecting
    /// The chat has no session on the computer yet.
    case chatOpening
    /// Live voice talks with one agent; a group chat has several.
    case groupChat
    /// The computer has no bighelp plugin turned on.
    case pluginNotInstalled
    /// The plugin is installed, but the Hermes dashboard serving the app hasn't loaded it.
    case pluginNotLoaded
    /// The plugin didn't answer for another reason: a dropped answer, a refused sign-in.
    case pluginUnreachable
    /// The plugin runs, but this Hermes or plugin doesn't offer live voice.
    case voiceNotOffered
    /// Demo mode has no computer.
    case demo

    static let feature = "native-voice-v1"

    /// Nil when live voice can start: the chat is one agent's, the computer is connected, its
    /// plugin offers live voice and the chat has a session there. `features` is nil until the
    /// plugin's list was read on this connection; `plugin` then says why it wasn't.
    static func reason(connected: Bool, features: Set<String>?, plugin: NativeWorkspaceRuntime.PluginState,
                       isDirectChat: Bool, chatReady: Bool) -> Self? {
        guard isDirectChat else { return .groupChat }
        guard connected else { return .connecting }
        guard let features else {
            return switch plugin {
            case .unknown: .connecting
            case .notInstalled: .pluginNotInstalled
            case .notLoaded: .pluginNotLoaded
            case .unreachable, .running: .pluginUnreachable
            }
        }
        guard features.contains(feature) else { return .voiceNotOffered }
        return chatReady ? nil : .chatOpening
    }

    var title: String {
        switch self {
        case .connecting: "Not connected yet"
        case .chatOpening: "This chat is still opening"
        case .pluginNotInstalled: "The bighelp plugin is missing"
        case .pluginNotLoaded: "Restart Hermes to finish"
        case .groupChat, .pluginUnreachable, .voiceNotOffered, .demo: "Live voice isn't available"
        }
    }

    var message: String {
        switch self {
        case .connecting:
            "bighelp is still connecting to your computer. Try again in a moment."
        case .chatOpening:
            "bighelp is still opening this chat on your computer. Try again in a moment."
        case .groupChat:
            "Live voice talks with one bot, and this chat has more than one."
        case .pluginNotInstalled:
            "Live voice needs the bighelp plugin on your computer. Set it up in Settings › Voice, then try again."
        case .pluginNotLoaded:
            "The bighelp plugin is installed, but the Hermes dashboard on your computer hasn't loaded it yet. Restart the dashboard and the messaging gateway on your computer, then try again."
        case .pluginUnreachable:
            "bighelp couldn't reach the bighelp plugin on your computer just now. Try again in a moment."
        case .voiceNotOffered:
            "The Hermes on your computer doesn't offer live voice. Update Hermes and the bighelp plugin in Settings, on your computer's page, then try again."
        case .demo:
            "Demo mode has no computer for live voice."
        }
    }

    /// The connection and the chat's session come by themselves a moment after a chat opens, so voice
    /// waits for them (`ShellFeatureStore.waitForLiveVoice`) before it says it can't start.
    var passesByItself: Bool { self == .connecting || self == .chatOpening }

    /// Trying again helps once the computer or the chat is ready, or after a step on the computer.
    var canTryAgain: Bool { self != .groupChat && self != .demo }
}
