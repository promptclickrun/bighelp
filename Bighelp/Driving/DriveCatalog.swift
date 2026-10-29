import Foundation

/// Every place an agent's drive can open, with its playbook per mode. It lists only places the
/// navigator can reach for real: a route, a tab, a bot profile tab or sheet, or a Settings page.
/// Places that open only from a view's own state join as they get a way in (#662).
/// `navigation.places` searches it; the plugin never holds a copy, so new places ship with the app.
enum DriveCatalog {
    static func place(_ id: String) -> DrivePlace? { byID[id] }

    /// The places that fit the person's words, best first. Every word must appear in the place's
    /// title, description, keywords or trail. No words lists every place in `mode`.
    static func search(_ query: String, mode: BighelpMode, nerdMode: Bool, limit: Int) -> [DrivePlace] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !stopWords.contains($0) }
        let reachable = places.filter { $0.playbooks[mode] != nil && (nerdMode || !$0.needs.contains(.nerdMode)) }
        guard !words.isEmpty else { return Array(reachable.prefix(limit)) }
        let scored = reachable.compactMap { place -> (DrivePlace, Int)? in
            let title = place.title.lowercased()
            let keywords = place.keywords.joined(separator: " ").lowercased()
            let rest = (place.what + " " + (place.playbooks[mode] ?? []).map(\.label).joined(separator: " ")).lowercased()
            var score = 0
            for word in words {
                let stem = word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
                if title.contains(stem) { score += 4 }
                else if keywords.contains(stem) { score += 3 }
                else if rest.contains(stem) { score += 1 }
                else { return nil }
            }
            return (place, score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Words that say nothing about a place ("how do I see what my Feed can do").
    private static let stopWords: Set<String> = [
        "a", "an", "the", "my", "me", "i", "how", "do", "can", "to", "see", "show", "where", "is", "what",
        "find", "open", "of", "for", "in", "on", "and", "it", "page", "set", "up", "change", "turn",
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })

    static let places: [DrivePlace] = botPlaces + boardPlaces + workPlaces + settingsPlaces + hermesPlaces

    // MARK: - Bots mode: a bot's profile

    private static let profile = DriveStep.go("{Bot}'s profile", .botProfile(BotProfileOpening()))

    private static func profileTab(_ tab: SimpleBotProfileTab, _ label: String) -> [DriveStep] {
        [.go("{Bot}'s profile", .botProfile(BotProfileOpening(tab: tab))),
         .shows(label, "simple-bots.profile.tab.\(tab.rawValue)")]
    }

    /// Profile › Dashboard › Templates › one page of the deck.
    private static func templates(_ kind: AgentBoardItem.Kind, _ page: String) -> [DriveStep] {
        profileTab(.dashboard, String(localized: "Dashboard")) + [
            .go(String(localized: "Templates"), .botProfile(BotProfileOpening(sheet: .templates(kind))),
                tap: "dashboard.templates"),
            // The deck opens on this page; the spotlight marks its cards, what the page can do.
            .point(page, at: "dashboard.templates.deck"),
        ]
    }

    /// Profile › Info › one row of it, pointed at.
    private static func infoRow(_ label: String, _ target: String) -> [DriveStep] {
        profileTab(.info, String(localized: "Info")) + [.point(label, at: target)]
    }

    private static let botPlaces: [DrivePlace] = [
        DrivePlace("bot.profile", String(localized: "Bot profile"),
                   String(localized: "A bot's own page: its look, Dashboard, settings, files and screen."),
                   keywords: ["profile", "about", "bot page"], needs: [.bot], playbooks: [.bots: [profile]]),
        DrivePlace("bot.dashboard", String(localized: "Dashboard"),
                   String(localized: "The bot's Feed, Ideas and Goals as piles you swipe, with Templates on top."),
                   keywords: ["dashboard", "piles", "cards", "feed", "ideas", "goals"], needs: [.bot],
                   playbooks: [.bots: profileTab(.dashboard, String(localized: "Dashboard"))]),
        DrivePlace("bot.dashboard.templates.feed", String(localized: "Feed templates"),
                   String(localized: "Ready-made jobs the bot can do for your Feed. Swipe right to use one."),
                   keywords: ["feed", "templates", "what can feed do", "starter", "ideas for feed", "blueprints"],
                   needs: [.bot], playbooks: [.bots: templates(.feed, String(localized: "Feed"))]),
        DrivePlace("bot.dashboard.templates.ideas", String(localized: "Ideas templates"),
                   String(localized: "Ready-made prompts that fill the bot's Ideas."),
                   keywords: ["ideas", "templates", "starter", "suggestions", "blueprints"],
                   needs: [.bot], playbooks: [.bots: templates(.idea, String(localized: "Ideas"))]),
        DrivePlace("bot.dashboard.templates.goals", String(localized: "Goals templates"),
                   String(localized: "Ready-made goals the bot can track for you."),
                   keywords: ["goals", "templates", "habits", "starter", "blueprints"],
                   needs: [.bot], playbooks: [.bots: templates(.goal, String(localized: "Goals"))]),
        DrivePlace("bot.info", String(localized: "Info"),
                   String(localized: "The bot's look, instructions, model, voice and routines."),
                   keywords: ["info", "bot settings", "settings for bot"], needs: [.bot],
                   playbooks: [.bots: profileTab(.info, String(localized: "Info"))]),
        DrivePlace("bot.info.character", String(localized: "Character"),
                   String(localized: "The bot's shape and color, or a character, pet or photo."),
                   keywords: ["look", "avatar", "shape", "color", "picture", "face"], needs: [.bot],
                   playbooks: [.bots: infoRow(String(localized: "Character"), "simple-bots.profile.character")]),
        DrivePlace("bot.info.instructions", String(localized: "Instructions"),
                   String(localized: "What the bot is told to be and do."),
                   keywords: ["instructions", "personality", "soul", "prompt", "rules", "behave"], needs: [.bot],
                   playbooks: [.bots: infoRow(String(localized: "Instructions"), "simple-bots.profile.instructions")]),
        DrivePlace("bot.info.photo-actions", String(localized: "Photo actions"),
                   String(localized: "Turn photos of business cards and posters into contacts and events."),
                   keywords: ["photo", "business card", "poster", "contact", "event"], needs: [.bot],
                   playbooks: [.bots: infoRow(String(localized: "Photo actions"), "simple-bots.profile.photo-actions")]),
        DrivePlace("bot.info.default-model", String(localized: "Default Model"),
                   String(localized: "The AI model and reasoning the bot uses for its chats."),
                   keywords: ["model", "ai model", "reasoning", "smarter", "faster"], needs: [.bot],
                   playbooks: [.bots: infoRow(String(localized: "Default Model"), "simple-bots.profile.default-model")]),
        DrivePlace("bot.info.default-voice", String(localized: "Default Voice"),
                   String(localized: "How the bot sounds in voice chats."),
                   keywords: ["voice", "speech", "talk", "sound"], needs: [.bot],
                   playbooks: [.bots: infoRow(String(localized: "Default Voice"), "simple-bots.profile.default-voice")]),
        DrivePlace("bot.info.advanced-options", String(localized: "Advanced Options"),
                   String(localized: "Safety, memory, notices and what happens while the bot works."),
                   keywords: ["advanced", "approvals", "memory", "safety", "permissions"], needs: [.bot],
                   playbooks: [.bots: infoRow(String(localized: "Advanced Options"), "simple-bots.profile.advanced-options")]),
        DrivePlace("bot.info.routines", String(localized: "Routines"),
                   String(localized: "Jobs the bot does on a schedule. Add one here."),
                   keywords: ["routines", "schedule", "scheduled", "every day", "reminder", "recurring"], needs: [.bot],
                   playbooks: [.bots: infoRow(String(localized: "Add routine"), "simple-bots.profile.add-routine")]),
        DrivePlace("bot.computer", String(localized: "Computer"),
                   String(localized: "The bot's own screen: watch it work or take control."),
                   keywords: ["computer", "screen", "browser", "desktop", "watch"], needs: [.bot],
                   playbooks: [.bots: profileTab(.computer, String(localized: "Computer"))]),
        DrivePlace("bot.files", String(localized: "Files"),
                   String(localized: "The bot's folder on your computer."),
                   keywords: ["files", "folder", "documents", "downloads"], needs: [.bot],
                   playbooks: [.bots: profileTab(.files, String(localized: "Files"))]),
        DrivePlace("bot.media", String(localized: "Media"),
                   String(localized: "Photos and videos from your chats with the bot."),
                   keywords: ["media", "photos", "videos", "pictures"], needs: [.bot],
                   playbooks: [.bots: profileTab(.media, String(localized: "Media"))]),
    ]

    // MARK: - Chat and Code: the agent's boards and work pages, pushed over the chat

    private static func both(_ steps: [DriveStep]) -> [BighelpMode: [DriveStep]] { [.chat: steps, .code: steps] }

    private static func page(_ id: String, _ title: String, _ what: String, keywords: [String],
                             needs: Set<DriveNeed> = [], _ route: AppRoute,
                             modes: [BighelpMode] = [.chat, .code]) -> DrivePlace {
        let steps = [DriveStep.go(title, .push(route))]
        return DrivePlace(id, title, what, keywords: keywords, needs: needs,
                          playbooks: Dictionary(uniqueKeysWithValues: modes.map { ($0, steps) }))
    }

    private static let boardPlaces: [DrivePlace] = [
        page("boards.feed", String(localized: "Feed"), String(localized: "Posts and updates from your agent."),
             keywords: ["feed", "posts", "updates", "news"], .board(.feed)),
        page("boards.ideas", String(localized: "Ideas"), String(localized: "Things your agent offers to do for you."),
             keywords: ["ideas", "suggestions"], .board(.ideas)),
        page("boards.goals", String(localized: "Goals"), String(localized: "Goals your agent tracks for you."),
             keywords: ["goals", "habits", "progress"], .board(.goals)),
        page("boards.files", String(localized: "Files"), String(localized: "Files, pages, pictures and videos your agent made."),
             keywords: ["files", "artifacts", "media", "apps"], .board(.apps)),
    ]

    private static let workPlaces: [DrivePlace] = [
        DrivePlace("agents", String(localized: "Agents"), String(localized: "Every agent and group chat on this computer."),
                   keywords: ["agents", "bots", "group chats", "team"],
                   playbooks: [.chat: [.go(String(localized: "Agents"), .tab(.agents))]]),
        DrivePlace("sessions", String(localized: "Sessions"), String(localized: "Every chat on this computer, to search and reopen."),
                   keywords: ["sessions", "chats", "history", "conversations", "old chats"],
                   playbooks: [.chat: [.go(String(localized: "Sessions"), .tab(.sessionList))]]),
        page("projects", String(localized: "Projects"), String(localized: "Related chats and folders together."),
             keywords: ["projects", "folders", "workspaces"], .projects),
        page("kanban", String(localized: "Kanban"), String(localized: "Your agents' task board, from Later to Done."),
             keywords: ["kanban", "board", "tasks", "cards", "todo"], .kanban),
        page("workflows", String(localized: "Workflows"), String(localized: "Multi-step jobs agents run, with your sign-off."),
             keywords: ["workflows", "automation", "pipelines", "runs"], .workflows, modes: [.chat]),
        page("scheduled-tasks", String(localized: "Scheduled tasks"), String(localized: "Work your agents do on a schedule."),
             keywords: ["scheduled", "tasks", "routines", "cron", "every day", "reminders"], .scheduledTasks, modes: [.chat]),
        page("usage", String(localized: "Usage"), String(localized: "Your plans, limits, and how much each agent used."),
             keywords: ["usage", "limits", "plan", "cost", "tokens", "quota"], .usage, modes: [.bots, .chat, .code]),
        page("skills", String(localized: "Skills & tools"), String(localized: "The skills and tools your agent can use."),
             keywords: ["skills", "tools", "abilities", "plugins"], .skillsAndTools, modes: [.chat]),
        page("models", String(localized: "Default model"), String(localized: "The AI model new chats start with."),
             keywords: ["model", "default model", "ai model", "llm"], .workspaceManagement(.models)),
        page("ai-providers", String(localized: "AI providers"), String(localized: "Sign in to AI providers or add their keys."),
             keywords: ["providers", "api key", "keys", "sign in", "accounts"], .workspaceManagement(.keys)),
        page("dev-factory", String(localized: "Dev Factory"), String(localized: "Coding recipes that run across projects, and their runs."),
             keywords: ["dev factory", "recipes", "automation"], .devFactory, modes: [.code]),
    ]

    // MARK: - Settings

    /// Settings opens from your circle in Bots mode and from ☰ in Chat and Code. In Bots mode the
    /// full list is behind All Settings.
    private static func settings(_ id: String, _ title: String, _ what: String, keywords: [String],
                                 needs: Set<DriveNeed> = [], full pages: [(String, SettingsDestination, String?)],
                                 bots: [(String, SettingsDestination, String?)]? = nil,
                                 point: (String, String)? = nil) -> DrivePlace {
        func steps(_ trail: [(String, SettingsDestination, String?)], start: [SettingsDestination]) -> [DriveStep] {
            var path = start
            var built = [DriveStep.go(String(localized: "Settings"), .settings(path))]
            for (label, page, tap) in trail {
                path.append(page)
                built.append(.go(label, .settings(path), tap: tap))
            }
            if let point { built.append(.point(point.0, at: point.1)) }
            return built
        }
        let all = (String(localized: "All Settings"), SettingsDestination.allSettings, Optional("simple-bots.settings.all"))
        let botSteps = bots.map { steps($0, start: []) } ?? steps([all] + pages, start: [])
        return DrivePlace(id, title, what, keywords: keywords, needs: needs,
                          playbooks: [.bots: botSteps, .chat: steps(pages, start: []), .code: steps(pages, start: [])])
    }

    private static func section(_ section: SettingsMenuSection) -> (String, SettingsDestination, String?) {
        (section.title, .section(section), section.accessibilityIdentifier)
    }

    private static var settingsPlaces: [DrivePlace] {
        [
            settings("settings", String(localized: "Settings"), String(localized: "All of bighelp's settings."),
                     keywords: ["settings", "preferences", "options"], full: []),
            settings("settings.appearance", String(localized: "Appearance"),
                     String(localized: "Colors, light and dark mode, text size and layout."),
                     keywords: ["appearance", "theme", "color", "dark mode", "light mode", "text size", "look"],
                     full: [section(.appearance)],
                     bots: [(String(localized: "Appearance"), .bots(.appearance), "simple-bots.settings.appearance")]),
            settings("settings.appearance.chat-layout", String(localized: "Chat layout"),
                     String(localized: "Avatar size, names, message text size and spacing in chats."),
                     keywords: ["chat layout", "message size", "spacing", "avatar size", "font"],
                     full: [section(.appearance), (String(localized: "Chat layout"), .chatLayout, "settings.appearance.chat-layout")]),
            settings("settings.appearance.app-layout", String(localized: "App layout"),
                     String(localized: "What the bottom bar holds and the order of the menu."),
                     keywords: ["app layout", "bottom bar", "tab bar", "tabs", "menu order", "pin"],
                     full: [section(.appearance), (String(localized: "App layout"), .appLayout, "settings.appearance.app-layout")]),
            settings("settings.chat", String(localized: "Chat"),
                     String(localized: "Where the app opens, how chats behave, haptics and Return."),
                     keywords: ["chat settings", "haptics", "reactions", "open on", "start screen"],
                     full: [section(.chat)],
                     bots: [(String(localized: "Chat"), .bots(.chat), "simple-bots.settings.chat")]),
            settings("settings.chat.return-sends", String(localized: "Return sends"),
                     String(localized: "With a keyboard, Return sends the message instead of adding a line."),
                     keywords: ["return", "enter key", "keyboard", "send", "new line"],
                     full: [section(.chat)], point: (String(localized: "Return sends"), "settings.chat.return-sends")),
            settings("settings.voice", String(localized: "Voice"), String(localized: "How voice chats sound."),
                     keywords: ["voice", "speech", "talk", "tts", "live voice"], full: [section(.voice)]),
            settings("settings.notifications", String(localized: "Notifications"), String(localized: "Alerts from your agents."),
                     keywords: ["notifications", "alerts", "push", "sounds", "badges"], full: [section(.notifications)],
                     bots: [(String(localized: "Notifications"), .bots(.notifications), "simple-bots.settings.notifications")]),
            settings("settings.permissions", String(localized: "Permissions"),
                     String(localized: "Which iPhone features your agents may use, and usage sharing."),
                     keywords: ["permissions", "device access", "privacy", "calendar", "location", "contacts", "photos"],
                     full: [section(.permissions)]),
            settings("settings.permissions.navigation", String(localized: "Let agents show you around bighelp"),
                     String(localized: "The switch for this: agents opening pages and pointing at settings."),
                     keywords: ["show me around", "driving", "agents open pages"],
                     full: [section(.permissions)],
                     point: (String(localized: "Let agents show you around bighelp"), "permissions.device-tools.navigation")),
            settings("settings.permissions.appearance", String(localized: "Let agents change how bighelp looks"),
                     String(localized: "The switch that lets agents change light or dark mode and your chat color."),
                     keywords: ["agent appearance", "agents change theme"],
                     full: [section(.permissions)],
                     point: (String(localized: "Let agents change how bighelp looks"), "permissions.device-tools.appearance")),
            settings("settings.apps", String(localized: "Apps"),
                     String(localized: "Let your agents use your other apps, like email and notes."),
                     keywords: ["apps", "connect", "connectors", "integrations", "email", "gmail", "composio"],
                     full: [(String(localized: "Apps"), .apps, "settings.apps")],
                     bots: [(String(localized: "Connect apps"), .bots(.apps), "simple-bots.settings.apps")]),
            settings("settings.you", String(localized: "You"),
                     String(localized: "Your name and photo on your messages."),
                     keywords: ["my name", "my photo", "profile", "me"], full: [],
                     bots: [(String(localized: "You"), .bots(.you), "simple-bots.settings.you")]),
            settings("settings.system", String(localized: "System"),
                     String(localized: "Your computers, Hermes updates and restarts."),
                     keywords: ["system", "computers", "hosts", "update hermes", "plugin", "restart"],
                     full: [section(.connectivityAndNotifications)]),
            settings("settings.companion", String(localized: "Companion pet"),
                     String(localized: "An optional little pet that keeps you company."),
                     keywords: ["pet", "companion", "mascot"], full: [section(.companion)]),
            settings("settings.help", String(localized: "Help & feedback"),
                     String(localized: "Report a problem, read guides and see the app's version."),
                     keywords: ["help", "feedback", "bug", "version", "about", "support"], full: [section(.help)]),
        ]
    }

    // MARK: - Hermes (Nerd Mode)

    private static let hermesPlaces: [DrivePlace] = [
        page("hermes.tools", String(localized: "Hermes tools"),
             String(localized: "Your computer's Hermes tools: files, skills, memory, logs and more."),
             keywords: ["hermes", "tools", "admin", "nerd"], needs: [.nerdMode], .workspaceHub),
        page("hermes.memory", String(localized: "Memory"), String(localized: "What your agent remembers."),
             keywords: ["memory", "remember", "forget"], .workspaceManagement(.memory)),
        page("hermes.logs", String(localized: "Logs"), String(localized: "The computer's diagnostic logs."),
             keywords: ["logs", "errors", "debug"], needs: [.nerdMode], .workspaceManagement(.logs)),
        page("hermes.plugins", String(localized: "Plugins"), String(localized: "Add-ons installed on this computer."),
             keywords: ["plugins", "add-ons", "extensions"], needs: [.nerdMode], .workspaceManagement(.plugins)),
        page("hermes.mcp", String(localized: "MCP Servers"), String(localized: "Tool servers connected through Hermes."),
             keywords: ["mcp", "servers", "tool servers"], needs: [.nerdMode], .workspaceManagement(.mcp)),
    ]
}
