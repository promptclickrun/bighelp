import Foundation

/// One answer a setting can take. The `detail` is its line in the setting's tip.
struct AdvancedChoice: Equatable, Sendable, Identifiable {
    let value: BighelpJSONValue
    let title: String
    let detail: String
    /// Other stored values Hermes reads as this answer: YAML's bare `off` arrives as `false`.
    var aliases: [BighelpJSONValue] = []
    /// Asked before this answer is saved (turning approvals off).
    var confirmation: AdvancedConfirmation?

    var id: String { title }

    func matches(_ other: BighelpJSONValue) -> Bool {
        AdvancedValue.same(value, other) || aliases.contains { AdvancedValue.same($0, other) }
    }
}

/// The question asked before a choice that takes a safety net away.
struct AdvancedConfirmation: Equatable, Sendable {
    let title: String
    let message: String
    let action: String
}

/// A switch whose saved values aren't plain booleans, or that Hermes reads loosely.
struct AdvancedSwitch: Equatable, Sendable {
    let on: BighelpJSONValue
    let off: BighelpJSONValue
    /// Hermes treats only `off` (or `false`) as off and every other value as on.
    var onlyOffIsOff = false

    static let boolean = AdvancedSwitch(on: .boolean(true), off: .boolean(false))

    func isOn(_ value: BighelpJSONValue) -> Bool? {
        guard onlyOffIsOff else { return AdvancedValue.switchState(value) }
        if case .boolean(false) = value { return false }
        return value.string.map(AdvancedValue.normalized) != "off"
    }
}

/// How a setting is shown and saved.
enum AdvancedKind: Equatable, Sendable {
    /// A few named answers, picked from a menu. A saved value none of them names reads as
    /// `unknownMeans` when Hermes falls back to one, else it's shown as it is.
    case choice([AdvancedChoice], unknownMeans: BighelpJSONValue? = nil)
    case toggle(AdvancedSwitch)
    /// Seconds, picked from these, shown in minutes.
    case duration([Int])
    /// Free text, written on a page of its own.
    case text(placeholder: String)
}

/// When a setting shows.
enum AdvancedVisibility: Equatable, Sendable {
    case always
    /// Only while it's on, with this note: something bighelp can't use yet, shown so it can be turned off.
    case whileOn(note: String)
    /// Only while the setting at `path` reads as `equals` (the Smart rules, under Smart).
    case when(path: [String], equals: BighelpJSONValue)
}

/// One config.yaml setting, in plain words. `path` is the key in the saved config, for example
/// `["approvals", "mode"]`; `defaultValue` is what Hermes does when the key was never saved.
struct AdvancedOption: Equatable, Sendable, Identifiable {
    let path: [String]
    let title: String
    let detail: String
    let kind: AdvancedKind
    let defaultValue: BighelpJSONValue
    var visibility: AdvancedVisibility = .always

    var id: String { path.joined(separator: ".") }
}

/// A Nerd Mode page Advanced Options opens for the bot, so everything lives behind one doorway.
enum AdvancedPage: String, CaseIterable, Hashable, Identifiable, Sendable {
    case skillsAndTools, messaging, memory
    case rawConfiguration, skillsHub, toolServers, plugins, webhooks, logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skillsAndTools: String(localized: "Skills and tools")
        case .messaging: String(localized: "Messaging apps")
        case .memory: String(localized: "What it remembers")
        case .rawConfiguration: String(localized: "Edit config.yaml")
        case .skillsHub: String(localized: "Skills Hub")
        case .toolServers: String(localized: "MCP servers")
        case .plugins: String(localized: "Plugins")
        case .webhooks: String(localized: "Webhooks")
        case .logs: String(localized: "Logs")
        }
    }

    /// Pages for the whole computer, not just this bot: their rows say so.
    var isWholeComputer: Bool { [.plugins, .webhooks, .logs].contains(self) }

    /// The Hermes tools page it is, where it has one.
    var destination: WorkspaceDestination? {
        switch self {
        case .skillsAndTools, .rawConfiguration: nil
        case .messaging: .messaging
        case .memory: .memory
        case .skillsHub: .skills
        case .toolServers: .mcp
        case .plugins: .plugins
        case .webhooks: .webhooks
        case .logs: .logs
        }
    }
}

/// A row of the page: a setting on the computer, the app's own send-while-working choice, or a page.
enum AdvancedRow: Equatable, Sendable, Identifiable {
    case option(AdvancedOption)
    case sendWhileWorking
    case page(AdvancedPage)

    var id: String {
        switch self {
        case .option(let option): option.id
        case .sendWhileWorking: "send-while-working"
        case .page(let page): "page.\(page.rawValue)"
        }
    }
}

struct AdvancedGroup: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let rows: [AdvancedRow]

    var options: [AdvancedOption] {
        rows.compactMap { row -> AdvancedOption? in
            if case .option(let option) = row { return option }
            return nil
        }
    }
}

enum AdvancedValue {
    /// Hermes lowercases mode words and the host may send numbers as integers or doubles, so
    /// compare values the way Hermes reads them.
    static func same(_ lhs: BighelpJSONValue, _ rhs: BighelpJSONValue) -> Bool {
        if let left = lhs.number, let right = rhs.number { return left == right }
        if let left = lhs.string, let right = rhs.string { return normalized(left) == normalized(right) }
        return lhs == rhs
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A switch value as the host may store it: a boolean, or YAML-style words.
    static func switchState(_ value: BighelpJSONValue) -> Bool? {
        switch value {
        case .boolean(let flag): return flag
        case .string(let text):
            switch normalized(text) {
            case "true", "yes", "on": return true
            case "false", "no", "off": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// "15 minutes", "1 hour, 30 minutes": a wait as people say it, whatever the computer saved.
    static func duration(_ seconds: Int) -> String {
        Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

/// Advanced Options for one bot: its config.yaml settings in plain words, then every Nerd Mode
/// page for it. Each key is in Hermes' default config (0.22.5); settings that change nothing in
/// bighelp's chats (`display.busy_input_mode`, `display.friendly_tool_labels`) aren't here.
enum AdvancedOptionsCatalog {
    static let groups: [AdvancedGroup] = [safety, working, memory, chats, apps, experts]

    static let approvals = AdvancedOption(
        path: ["approvals", "mode"],
        title: String(localized: "Approvals"),
        detail: String(localized: "What your bot does before a risky command, like deleting files."),
        kind: .choice([
            text("smart", String(localized: "Smart"),
                 String(localized: "A reviewer lets safe commands run and asks you about risky ones.")),
            text("manual", String(localized: "Manual"),
                 String(localized: "Asks you before every risky command."),
                 // Hermes reads a bare `true` as manual.
                 aliases: [.boolean(true)]),
            text("off", String(localized: "Off"),
                 String(localized: "Never asks. Only for a computer you can wipe."),
                 aliases: [.boolean(false)],
                 confirmation: AdvancedConfirmation(
                    title: String(localized: "Turn approvals off?"),
                    message: String(localized: "Your bot will run risky commands, like deleting files, without asking you."),
                    action: String(localized: "Turn Off"))),
        // Hermes runs any other saved value as manual.
        ], unknownMeans: .string("manual")),
        defaultValue: .string("smart"))

    private static func text(_ value: String, _ title: String, _ detail: String,
                             aliases: [BighelpJSONValue] = [],
                             confirmation: AdvancedConfirmation? = nil) -> AdvancedChoice {
        AdvancedChoice(value: .string(value), title: title, detail: detail, aliases: aliases,
                       confirmation: confirmation)
    }

    private static let safety = AdvancedGroup(
        id: "safety",
        title: String(localized: "Safety"),
        rows: [
            .option(approvals),
            .option(AdvancedOption(
                path: ["approvals", "smart_policy"],
                title: String(localized: "Rules for Smart"),
                detail: String(localized: "Tell the reviewer what to always ask you about, in your own words."),
                kind: .text(placeholder: String(localized: "Always ask before deleting files.")),
                defaultValue: .string(""),
                visibility: .when(path: ["approvals", "mode"], equals: .string("smart")))),
            .option(AdvancedOption(
                path: ["approvals", "timeout"],
                title: String(localized: "Wait for your answer"),
                detail: String(localized: "How long your bot waits for you. Then it skips the command."),
                kind: .duration([60, 120, 300, 600, 900, 1_800]),
                defaultValue: .integer(300))),
            .option(AdvancedOption(
                path: ["approvals", "cron_mode"],
                title: String(localized: "Routines"),
                detail: String(localized: "What a routine does at a risky command. Nobody is there to ask."),
                kind: .choice([
                    text("deny", String(localized: "Block"),
                         String(localized: "Skips the command, and the routine finds another way.")),
                    text("approve", String(localized: "Allow"),
                         String(localized: "Runs the command without asking.")),
                ]),
                defaultValue: .string("deny"))),
        ])

    private static let working = AdvancedGroup(
        id: "working",
        title: String(localized: "While it works"),
        rows: [
            .sendWhileWorking,
            .option(AdvancedOption(
                path: ["display", "show_reasoning"],
                title: String(localized: "Show its thinking"),
                detail: String(localized: "Shows your bot's thinking in the chat as it works."),
                kind: .toggle(.boolean),
                defaultValue: .boolean(true))),
            .option(AdvancedOption(
                path: ["display", "background_process_notifications"],
                title: String(localized: "Follow up on background jobs"),
                detail: String(localized: "When a long job your bot started finishes, it picks up where it left off. Off, it waits for you; the job still shows as done."),
                // On is Hermes' default; any other saved value stays until the switch is used.
                kind: .toggle(AdvancedSwitch(on: .string("concise"), off: .string("off"), onlyOffIsOff: true)),
                defaultValue: .string("concise"))),
        ])

    private static let memory = AdvancedGroup(
        id: "memory",
        title: String(localized: "Memory"),
        rows: [
            .option(AdvancedOption(
                path: ["memory", "memory_enabled"],
                title: String(localized: "Remember things"),
                detail: String(localized: "Lets your bot keep notes to use in later chats."),
                kind: .toggle(.boolean),
                defaultValue: .boolean(true))),
            .option(AdvancedOption(
                path: ["memory", "user_profile_enabled"],
                title: String(localized: "Remember you"),
                detail: String(localized: "Keeps a short profile of you and what you like."),
                kind: .toggle(.boolean),
                defaultValue: .boolean(true))),
            .option(AdvancedOption(
                path: ["display", "memory_notifications"],
                title: String(localized: "Memory notes"),
                detail: String(localized: "A note in the chat when your bot learns something."),
                kind: .choice([
                    text("off", String(localized: "Off"),
                         String(localized: "No note. Your bot still learns."),
                         aliases: [.boolean(false)]),
                    text("on", String(localized: "On"),
                         String(localized: "A short \"Memory updated\" note."),
                         aliases: [.boolean(true)]),
                    text("verbose", String(localized: "Details"),
                         String(localized: "A note that shows what it learned.")),
                ]),
                defaultValue: .string("on"))),
            .option(AdvancedOption(
                path: ["memory", "write_approval"],
                title: String(localized: "Ask before saving"),
                detail: String(localized: "Your bot asks before it keeps a note."),
                kind: .toggle(.boolean),
                defaultValue: .boolean(false),
                visibility: .whileOn(note: String(localized: "bighelp can't show notes waiting for your OK yet, so your bot keeps none. Turn this off to let it remember.")))),
            .page(.memory),
        ])

    private static let chats = AdvancedGroup(
        id: "chats",
        title: String(localized: "Chats and files"),
        rows: [
            .option(AdvancedOption(
                path: ["compression", "enabled"],
                title: String(localized: "Shorten long chats"),
                detail: String(localized: "Sums up older messages so a long chat keeps working."),
                kind: .toggle(.boolean),
                defaultValue: .boolean(true))),
            .option(AdvancedOption(
                path: ["checkpoints", "enabled"],
                title: String(localized: "Save restore points"),
                detail: String(localized: "Keeps a copy of your files before your bot changes them, so you can go back."),
                kind: .toggle(.boolean),
                defaultValue: .boolean(false))),
        ])

    private static let apps = AdvancedGroup(
        id: "apps",
        title: String(localized: "Skills and apps"),
        rows: [.page(.skillsAndTools), .page(.messaging)])

    private static let experts = AdvancedGroup(
        id: "experts",
        title: String(localized: "For experts"),
        rows: [.page(.rawConfiguration), .page(.skillsHub), .page(.toolServers), .page(.plugins),
               .page(.webhooks), .page(.logs)])
}
