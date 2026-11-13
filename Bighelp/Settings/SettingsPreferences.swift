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
        case .pressToTalk: String(localized: "Press to talk")
        case .walkieTalkie: String(localized: "Walkie-talkie")
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
        case .talk: "Your bot starts listening, in the voice mode you picked in Voice."
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

    /// Stored raw values predate these names: `codexLive` is Live (GPT-Live or
    /// Gemini Live, `LiveVoiceProvider`) and `turnBased` is Take turns.
    var title: String {
        switch self {
        case .codexLive: String(localized: "Live")
        case .turnBased: String(localized: "Take turns")
        }
    }

    var detail: String {
        switch self {
        case .codexLive:
            "A natural conversation, like a phone call: you can talk over each other, and the bot keeps talking while it works. Each bot can use its own live voice provider."
        case .turnBased:
            "This device turns your words into text on its own, and your bot's speech provider reads each reply aloud. The provider can run on your own computer."
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
        case .systemDefault: String(localized: "System Default")
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

/// Where a link tapped in a chat opens. A link that belongs to an app opens in that app, as it does
/// everywhere on iOS: Apple's own apps always, any other app that claims it when it's installed.
/// Only web pages go to the browser picked in Settings › Chat.
enum ChatLinkRoute: Equatable, Sendable {
    /// iOS opens it: the app it belongs to, else the default browser.
    case system
    /// An installed app that claims the link (a universal link) opens it; else this, the link
    /// in the picked browser.
    case appElseBrowser(URL)

    static func route(_ url: URL, browser: ChatBrowserPreference, browserIsInstalled: Bool) -> ChatLinkRoute {
        guard browser != .systemDefault, browserIsInstalled, !opensInAppleApp(url),
              let target = browser.targetURL(for: url) else { return .system }
        return .appElseBrowser(target)
    }

    /// Maps, Music, the App Store, Podcasts, TV, Books and News answer these, whatever browser is set.
    static let appleAppHosts: Set<String> = [
        "maps.apple.com", "music.apple.com", "classical.music.apple.com", "itunes.apple.com", "apps.apple.com",
        "podcasts.apple.com", "tv.apple.com", "books.apple.com", "apple.news",
    ]

    static func opensInAppleApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        return appleAppHosts.contains(host)
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
            String(localized: "Send context into the live turn so the bot can adjust its response.")
        case .queued:
            String(localized: "Wait for the live turn to finish, then send this as the next message.")
        case .interruptAndSend:
            String(localized: "Stop the live turn and immediately continue with this message.")
        }
    }
}

/// What tapping an agent on Agents opens, with one gateway or several
/// (Settings › Chat › A bot opens).
enum BotChatExperience: String, CaseIterable, Identifiable, Sendable {
    /// The agent's one ongoing Bot Chat; its latest chat or a new one when the host has none to give.
    case botChat
    case lastChat
    case newChat

    var id: Self { self }

    var title: String {
        switch self {
        case .botChat: String(localized: "Its ongoing chat")
        case .lastChat: String(localized: "Your last chat")
        case .newChat: String(localized: "A new chat")
        }
    }
}

/// How a one-to-one chat shows its agent's work (Settings › Chat › A bot's work › Shows as). Show thinking and
/// Show tool calls decide what's in it; Fold finished turns, whether a finished turn's work starts closed.
/// Group chats keep their own folders.
enum ChatWorkStyle: String, CaseIterable, Identifiable, Sendable {
    /// One line while the agent works, its newest note under it; a receipt under the answer when it's done.
    case minimal
    /// One card with the newest steps while the agent works; "Worked for…" when it's done.
    case card
    /// Every step in order, open, while the agent works; folded under "Worked for…" when it's done.
    case full

    var id: Self { self }

    /// The running turn's work is one block (`ChatLiveWork`) instead of rows in the chat.
    var gathersLiveWork: Bool { self != .full }

    var title: String {
        switch self {
        // The row's second line is the choice, so each name says what the chat shows.
        case .minimal: String(localized: "One line")
        case .card: String(localized: "Card")
        case .full: String(localized: "Everything")
        }
    }

    /// Before this choice there were two switches that kept folders open; either one asked to see everything.
    static func migrated(from defaults: UserDefaults) -> Self {
        let expandedBefore = ["loopdy.chat.expandReasoningByDefault", "loopdy.chat.expandToolCallsByDefault"]
            .contains { defaults.bool(forKey: $0) }
        return expandedBefore ? .full : .card
    }
}

/// Where a one-to-one chat shows its agent's reasoning (Settings › Chat › A bot's work › Thinking, #943).
/// Show thinking still decides whether a chat shows any. Saved on this device (`@AppStorage`);
/// the chat reads it directly. Group chats keep reasoning in the steps.
enum ChatReasoningPlacement: String, CaseIterable, Identifiable, Sendable {
    /// One outlined message above the turn's work, so the steps hold only tool calls.
    case ownMessage
    /// Rows between the tool calls, inside the turn's work.
    case steps

    var id: Self { self }

    var title: String {
        switch self {
        case .ownMessage: String(localized: "Above the work")
        case .steps: String(localized: "Between steps")
        }
    }

    static let storageKey = "bighelp.chat.reasoning-placement"
    static let defaultPlacement = ChatReasoningPlacement.ownMessage
    /// Settings › Chat › Keep thinking open: finished reasoning keeps its words in view.
    static let staysOpenKey = "bighelp.chat.reasoning-stays-open"
    static let staysOpenByDefault = true
}

/// What a swipe from the screen's left or right edge does (Settings › Chat › Advanced › Edge swipes).
enum WorkspaceSwipeAction: String, CaseIterable, Identifiable, Sendable {
    case quickWorkspace
    case newChat
    case sessions
    case agents
    case home
    case profile
    case none

    /// In the picker's order. "Bot page or Settings" is this bot's page in a chat and Settings elsewhere;
    /// "Sidebar" opens it where there is one, else Chats.
    static let allCases: [WorkspaceSwipeAction] = [
        .newChat, .sessions, .agents, .home, .profile, .quickWorkspace, .none,
    ]

    /// Saved values no action has any more: Inbox, and the swipes that switched between the three modes.
    static let retiredRawValues: Set<String> = ["inbox", "nextMode", "botsMode", "chatMode", "codeMode"]

    /// What a saved value does now. Inbox is Home and Bots mode is Bots; the other mode swipes, and
    /// anything unknown, are the edge's default.
    static func saved(_ raw: String?, edgeDefault: WorkspaceSwipeAction) -> WorkspaceSwipeAction {
        switch raw {
        case "inbox": .home
        case "botsMode": .agents
        default: raw.flatMap(WorkspaceSwipeAction.init(rawValue:)) ?? edgeDefault
        }
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .quickWorkspace: String(localized: "Sidebar")
        case .newChat: String(localized: "New chat")
        case .sessions: String(localized: "Chats")
        case .agents: String(localized: "Bots")
        case .home: String(localized: "Home")
        case .profile: String(localized: "Bot page or Settings")
        case .none: String(localized: "Off")
        }
    }

    var systemImage: String {
        switch self {
        case .quickWorkspace: "sidebar.left"
        case .newChat: "square.and.pencil"
        case .sessions: "clock.arrow.circlepath"
        case .agents: "person.2"
        case .home: "house"
        case .profile: "person.crop.circle"
        case .none: "hand.raised.slash"
        }
    }
}
