import Foundation

enum BighelpInterfaceVersion: String, CaseIterable, Identifiable, Sendable {
    case v1, v2, v3

    var id: Self { self }
    var title: String { rawValue.uppercased() }
    var detail: String {
        switch self {
        case .v1: "The original bighelp interface."
        case .v2: "Coordinated controls and native glass."
        case .v3: "A cleaner conversation, compact composer, and coordinated native controls."
        }
    }
}

enum VoiceSpeed: String, CaseIterable, Identifiable {
    case slow
    case normal
    case fast

    var id: Self { self }

    var speechRate: Float {
        switch self {
        case .slow: 0.44
        case .normal: 0.51
        case .fast: 0.58
        }
    }

    var hermesTTSSpeed: Float {
        switch self {
        case .slow: 0.85
        case .normal: 1
        case .fast: 1.15
        }
    }
}

enum VoiceMode: String, CaseIterable, Identifiable, Sendable {
    case pressToTalk
    case walkieTalkie

    var id: Self { self }

    var title: String {
        switch self {
        case .pressToTalk: "Press to Talk"
        case .walkieTalkie: "Walkie Talkie"
        }
    }

    var detail: String {
        switch self {
        case .pressToTalk:
            "Speak naturally. bighelp sends your message when you pause, and waits longer the longer you talk. \(BighelpPlatform.isMac ? "Click" : "Tap") Send now to send sooner."
        case .walkieTalkie:
            "Hold Speak while talking, then release to send your turn."
        }
    }
}

/// What a quick pinch on your agent in the room does (Vision Pro).
enum SpatialAvatarPinchAction: String, CaseIterable, Identifiable, Sendable {
    case talk
    case type

    var id: Self { self }

    var title: String {
        switch self {
        case .talk: "Talk"
        case .type: "Type"
        }
    }

    var detail: String {
        switch self {
        case .talk: "Your agent starts listening, in the voice mode you picked in Voice."
        case .type: "A message box opens with the keyboard, so you can type and send."
        }
    }

    var systemImage: String {
        switch self {
        case .talk: "waveform"
        case .type: "keyboard"
        }
    }
}

enum VoiceConversationMode: String, CaseIterable, Identifiable, Sendable {
    case codexLive
    case turnBased

    var id: Self { self }

    /// Stored raw values predate these names: `codexLive` is GPT Live 1 and
    /// `turnBased` is TTS.
    var title: String {
        switch self {
        case .codexLive: "GPT Live 1"
        case .turnBased: "TTS"
        }
    }

    var detail: String {
        switch self {
        case .codexLive:
            "A natural, back-and-forth conversation with OpenAI's GPT Live 1. It can keep talking while your agent works. Uses your Codex subscription or an OpenAI API key."
        case .turnBased:
            "This device turns your words into text on its own, and your agent's speech provider reads each reply aloud. The provider can run on your own computer."
        }
    }
}

enum ChatBrowserPreference: String, CaseIterable, Identifiable, Sendable {
    case systemDefault
    case chrome
    case firefox
    case brave

    var id: Self { self }

    var title: String {
        switch self {
        case .systemDefault: "System Default"
        case .chrome: "Google Chrome"
        case .firefox: "Firefox"
        case .brave: "Brave"
        }
    }

    var systemImage: String {
        switch self {
        case .systemDefault: "arrow.up.right.square"
        case .chrome, .firefox, .brave: "globe"
        }
    }

    var availabilityProbeURL: URL? {
        switch self {
        case .systemDefault: nil
        case .chrome: URL(string: "googlechrome://")
        case .firefox: URL(string: "firefox://")
        case .brave: URL(string: "brave://")
        }
    }

    static func available(
        canOpenURL: (URL) -> Bool
    ) -> [ChatBrowserPreference] {
        allCases.filter { browser in
            guard let probeURL = browser.availabilityProbeURL else { return true }
            return canOpenURL(probeURL)
        }
    }

    func targetURL(for originalURL: URL) -> URL? {
        guard
            let originalScheme = originalURL.scheme?.lowercased(),
            originalScheme == "http" || originalScheme == "https"
        else { return nil }

        switch self {
        case .systemDefault:
            return originalURL
        case .chrome:
            guard var components = URLComponents(
                url: originalURL,
                resolvingAgainstBaseURL: false
            ) else { return nil }
            components.scheme = originalScheme == "https" ? "googlechromes" : "googlechrome"
            return components.url
        case .firefox, .brave:
            var components = URLComponents()
            components.scheme = rawValue
            components.host = "open-url"
            components.queryItems = [
                URLQueryItem(name: "url", value: originalURL.absoluteString)
            ]
            return components.url
        }
    }
}

enum MidSessionChatBehavior: String, CaseIterable, Identifiable, Sendable {
    case steer
    case queued
    case interruptAndSend

    var id: Self { self }

    var title: String {
        switch self {
        case .steer: String(localized: "Steer")
        case .queued: String(localized: "Queued")
        case .interruptAndSend: String(localized: "Interrupt and Send")
        }
    }

    var detail: String {
        switch self {
        case .steer:
            String(localized: "Send context into the live turn so the agent can adjust its response.")
        case .queued:
            String(localized: "Wait for the live turn to finish, then send this as the next message.")
        case .interruptAndSend:
            String(localized: "Stop the live turn and immediately continue with this message.")
        }
    }
}

/// What tapping an agent on Agents opens, with one gateway or several
/// (Settings › Chat › Bot chat experience).
enum BotChatExperience: String, CaseIterable, Identifiable, Sendable {
    /// The agent's one ongoing Bot Chat; its latest chat or a new one when the host has none to give.
    case botChat
    case lastChat
    case newChat

    var id: Self { self }

    var title: String {
        switch self {
        case .botChat: "Persistent Bot Chat"
        case .lastChat: "Open last chat"
        case .newChat: "Open new chat"
        }
    }

    var detail: String {
        switch self {
        case .botChat: "Tapping an agent opens its one ongoing Bot Chat."
        case .lastChat: "Tapping an agent opens your most recent chat with it."
        case .newChat: "Tapping an agent starts a new chat with it."
        }
    }
}

/// Which home bighelp shows: the everyday agent chat, or Code mode's coding
/// sessions (Settings › Code mode; ☰ switches between them).
enum BighelpExperience: String, CaseIterable, Identifiable, Sendable {
    case bighelp
    case code

    var id: Self { self }

    var title: String {
        switch self {
        case .bighelp: String(localized: "Chat")
        case .code: String(localized: "Code")
        }
    }
}

/// The three ways bighelp opens: Bots mode (`simpleBotsEnabled`), Chat, and Code
/// (`experience`, once Settings › Code mode is on). The Unified Mode Toggle and the
/// mode edge swipes switch between them.
enum BighelpMode: String, CaseIterable, Identifiable, Sendable {
    case bots
    case chat
    case code

    var id: Self { self }

    var title: String {
        switch self {
        case .bots: String(localized: "Bots")
        case .chat: String(localized: "Chat")
        case .code: String(localized: "Code")
        }
    }
}

/// The Unified Mode Toggle in a home's header: the modes on offer, the one showing, and the switch.
struct BighelpModeSwitch {
    let modes: [BighelpMode]
    let current: BighelpMode
    let select: @MainActor (BighelpMode) -> Void
}

enum WorkspaceSwipeAction: String, CaseIterable, Identifiable, Sendable {
    case quickWorkspace
    case newChat
    case sessions
    case agents
    case home
    case inbox
    case profile
    case nextMode
    case botsMode
    case chatMode
    case codeMode
    case none

    static let allCases: [WorkspaceSwipeAction] = [
        .quickWorkspace,
        .newChat,
        .sessions,
        .agents,
        .home,
        .profile,
        .nextMode,
        .botsMode,
        .chatMode,
        .codeMode,
        .none,
    ]

    /// Switches mode instead of opening a place, so it works in Bots mode too.
    var mode: BighelpMode? {
        switch self {
        case .botsMode: .bots
        case .chatMode: .chat
        case .codeMode: .code
        default: nil
        }
    }

    var switchesMode: Bool { self == .nextMode || mode != nil }

    var id: Self { self }

    var title: String {
        switch self {
        case .quickWorkspace: "Menu"
        case .newChat: "New Chat"
        case .sessions: "Sessions"
        case .agents: "Agents"
        case .home: "Home"
        case .inbox: "Inbox"
        case .profile: "Profile & Settings"
        case .nextMode: "Next mode"
        case .botsMode: "Bots mode"
        case .chatMode: "Chat mode"
        case .codeMode: "Code mode"
        case .none: "Off"
        }
    }

    var systemImage: String {
        switch self {
        case .quickWorkspace: "sidebar.left"
        case .newChat: "square.and.pencil"
        case .sessions: "clock.arrow.circlepath"
        case .agents: "person.2"
        case .home: "house"
        case .inbox: "tray"
        case .profile: "person.crop.circle"
        case .nextMode: "arrow.left.arrow.right"
        case .botsMode: "bubble.left.and.bubble.right"
        case .chatMode: "message"
        case .codeMode: "chevron.left.forwardslash.chevron.right"
        case .none: "hand.raised.slash"
        }
    }
}
