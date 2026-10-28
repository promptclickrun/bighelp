import Foundation

/// One answer an Advanced Options setting can take. The `detail` is the one line shown in its
/// tappable tooltip.
struct AdvancedChoice: Equatable, Sendable, Identifiable {
    let value: BighelpJSONValue
    let title: String
    let detail: String
    /// Other values Hermes (or YAML) may store for the same answer, such as an unquoted `off`.
    var aliases: [BighelpJSONValue] = []

    var id: String { title }

    func matches(_ other: BighelpJSONValue) -> Bool {
        AdvancedValue.same(value, other) || aliases.contains { AdvancedValue.same($0, other) }
    }
}

/// How a setting is shown: a pick between a few named answers, or a plain switch.
enum AdvancedKind: Equatable, Sendable {
    case choice([AdvancedChoice])
    case toggle
}

/// One config.yaml setting, in plain words. `path` is the key in the saved config, for example
/// `["approvals", "mode"]`; `defaultValue` is what Hermes does when the key was never saved.
struct AdvancedOption: Equatable, Sendable, Identifiable {
    let path: [String]
    let title: String
    let detail: String
    let kind: AdvancedKind
    let defaultValue: BighelpJSONValue

    var id: String { path.joined(separator: ".") }
}

struct AdvancedGroup: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let symbol: String
    let options: [AdvancedOption]
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
}

/// The settings people most often want to change, laid out simply. Every key exists in Hermes'
/// default config; anything else stays in the raw config.yaml editor.
enum AdvancedOptionsCatalog {
    static let groups: [AdvancedGroup] = [safety, working, memory, notices, more]

    private static func text(_ value: String, _ title: String, _ detail: String,
                             aliases: [BighelpJSONValue] = []) -> AdvancedChoice {
        AdvancedChoice(value: .string(value), title: title, detail: detail, aliases: aliases)
    }

    private static func seconds(_ value: Int, _ title: String, _ detail: String) -> AdvancedChoice {
        AdvancedChoice(value: .integer(value), title: title, detail: detail)
    }

    private static let safety = AdvancedGroup(
        id: "safety",
        title: String(localized: "Safety"),
        symbol: "lock.shield",
        options: [
            AdvancedOption(
                path: ["approvals", "mode"],
                title: String(localized: "Approvals"),
                detail: String(localized: "What your bot does before it runs a risky command, like deleting files."),
                kind: .choice([
                    text("smart", String(localized: "Smart"),
                         String(localized: "An AI checks each risky command. Safe ones run, dangerous ones are blocked, and unsure ones ask you.")),
                    text("manual", String(localized: "Manual"),
                         String(localized: "Always asks you before a risky command runs.")),
                    text("off", String(localized: "Off"),
                         String(localized: "Never asks. Only for a throwaway or sandboxed computer."),
                         aliases: [.boolean(false), .string("false")]),
                ]),
                defaultValue: .string("smart")),
            AdvancedOption(
                path: ["approvals", "timeout"],
                title: String(localized: "Wait for your answer"),
                detail: String(localized: "How long your bot waits for you before it blocks the command."),
                kind: .choice([
                    seconds(60, String(localized: "1 minute"),
                            String(localized: "Blocks the command if you haven't answered in a minute.")),
                    seconds(120, String(localized: "2 minutes"),
                            String(localized: "Blocks the command if you haven't answered in two minutes.")),
                    seconds(300, String(localized: "5 minutes"),
                            String(localized: "Blocks the command if you haven't answered in five minutes.")),
                    seconds(600, String(localized: "10 minutes"),
                            String(localized: "Blocks the command if you haven't answered in ten minutes.")),
                ]),
                defaultValue: .integer(300)),
            AdvancedOption(
                path: ["approvals", "cron_mode"],
                title: String(localized: "Scheduled tasks"),
                detail: String(localized: "What a task that runs on its own does when it hits a risky command."),
                kind: .choice([
                    text("deny", String(localized: "Block"),
                         String(localized: "Stops the command. Nobody is there to ask.")),
                    text("approve", String(localized: "Allow"),
                         String(localized: "Runs the command without asking.")),
                ]),
                defaultValue: .string("deny")),
        ])

    private static let working = AdvancedGroup(
        id: "working",
        title: String(localized: "While it works"),
        symbol: "bolt",
        options: [
            AdvancedOption(
                path: ["display", "busy_input_mode"],
                title: String(localized: "If you send a message"),
                detail: String(localized: "What happens when you write to your bot while it is still working."),
                kind: .choice([
                    text("interrupt", String(localized: "Switch"),
                         String(localized: "Stops the current work and moves on to your new message.")),
                    text("queue", String(localized: "Wait"),
                         String(localized: "Finishes the current work first, then reads your message.")),
                    text("steer", String(localized: "Steer"),
                         String(localized: "Slips your message into the current work without stopping it.")),
                ]),
                defaultValue: .string("interrupt")),
            AdvancedOption(
                path: ["display", "show_reasoning"],
                title: String(localized: "Show its thinking"),
                detail: String(localized: "Watch your bot think as it works."),
                kind: .toggle,
                defaultValue: .boolean(true)),
        ])

    private static let memory = AdvancedGroup(
        id: "memory",
        title: String(localized: "Memory"),
        symbol: "brain",
        options: [
            AdvancedOption(
                path: ["memory", "memory_enabled"],
                title: String(localized: "Remember things"),
                detail: String(localized: "Lets your bot save notes to use in later chats."),
                kind: .toggle,
                defaultValue: .boolean(true)),
            AdvancedOption(
                path: ["memory", "user_profile_enabled"],
                title: String(localized: "Remember you"),
                detail: String(localized: "Keeps a short profile of you and what you like."),
                kind: .toggle,
                defaultValue: .boolean(true)),
            AdvancedOption(
                path: ["memory", "write_approval"],
                title: String(localized: "Ask before saving"),
                detail: String(localized: "Your bot asks you before it saves a memory. Saves made in the background wait for your OK."),
                kind: .toggle,
                defaultValue: .boolean(false)),
        ])

    private static let notices = AdvancedGroup(
        id: "notices",
        title: String(localized: "Notices"),
        symbol: "bell",
        options: [
            AdvancedOption(
                path: ["display", "memory_notifications"],
                title: String(localized: "When it saves a memory"),
                detail: String(localized: "Whether you hear about new memories."),
                kind: .choice([
                    text("off", String(localized: "Off"),
                         String(localized: "No notice. Your bot still saves memories."),
                         aliases: [.boolean(false), .string("false")]),
                    text("on", String(localized: "On"),
                         String(localized: "A short \"Memory updated\" notice.")),
                    text("verbose", String(localized: "Details"),
                         String(localized: "A notice that shows what was saved.")),
                ]),
                defaultValue: .string("on")),
            AdvancedOption(
                path: ["display", "background_process_notifications"],
                title: String(localized: "Background jobs"),
                detail: String(localized: "What you hear when a job running in the background makes progress."),
                kind: .choice([
                    text("concise", String(localized: "Short"),
                         String(localized: "One line when a job finishes. A failure adds the end of its output.")),
                    text("all", String(localized: "Everything"),
                         String(localized: "Progress updates while it runs, then the full output.")),
                    text("result", String(localized: "Result"),
                         String(localized: "Only the final output.")),
                    text("error", String(localized: "Errors only"),
                         String(localized: "The output, but only when a job fails.")),
                    text("off", String(localized: "Off"),
                         String(localized: "No notices about background jobs."),
                         aliases: [.boolean(false), .string("false")]),
                ]),
                defaultValue: .string("concise")),
        ])

    private static let more = AdvancedGroup(
        id: "more",
        title: String(localized: "More"),
        symbol: "slider.horizontal.3",
        options: [
            AdvancedOption(
                path: ["compression", "enabled"],
                title: String(localized: "Shorten long chats"),
                detail: String(localized: "Summarizes older messages so a long chat keeps working."),
                kind: .toggle,
                defaultValue: .boolean(true)),
            AdvancedOption(
                path: ["checkpoints", "enabled"],
                title: String(localized: "Save restore points"),
                detail: String(localized: "Takes a snapshot of your files before your bot changes them, so you can go back."),
                kind: .toggle,
                defaultValue: .boolean(false)),
            AdvancedOption(
                path: ["display", "friendly_tool_labels"],
                title: String(localized: "Plain tool names"),
                detail: String(localized: "Shows tools in everyday words instead of technical names."),
                kind: .toggle,
                defaultValue: .boolean(true)),
        ])
}
