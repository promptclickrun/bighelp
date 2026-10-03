import SwiftUI

/// The mark beside an action: bighelp's own line glyph, an SF Symbol where
/// bighelp has none, or the thinking orb with its blinking eyes.
enum BighelpActivityGlyph: Hashable, Sendable {
    case glyph(BighelpGlyph)
    case symbol(String)
    case thinking
    case done
}

/// What a tool is doing, in plain words.
struct BighelpToolActivity: Equatable, Sendable {
    let glyph: BighelpActivityGlyph
    /// Present tense, for the live row: "Reading a file…".
    let label: String
    /// Past tense, for a finished step: "Read a file".
    let doneLabel: String
}

/// One catalog from real Hermes tool names (and the bighelp plugin's) to a
/// glyph and friendly words. Names are matched exactly first, then by family
/// (`browser_*`, `kanban_*`, `ha_*`); anything else is "Using tools…".
enum BighelpToolActivityCatalog {
    static let fallback = BighelpToolActivity(glyph: .glyph(.tools), label: "Using tools…", doneLabel: "Used tools")
    static let thinking = BighelpToolActivity(glyph: .thinking, label: "Thinking", doneLabel: "Thought")

    /// The activity for a Hermes tool name. Unknown, empty or missing names are `fallback`.
    static func activity(forTool name: String?) -> BighelpToolActivity {
        guard let name = normalized(name) else { return fallback }
        if let exact = exact[name] { return exact }
        for (prefix, activity) in families where name.hasPrefix(prefix) {
            return activity(name)
        }
        return fallback
    }

    /// The bighelp plugin was called loopdy; its older tools keep that prefix.
    private static func normalized(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        return trimmed.hasPrefix("loopdy_") ? "bighelp_" + trimmed.dropFirst("loopdy_".count) : trimmed
    }

    private static func make(_ glyph: BighelpActivityGlyph, _ label: String, _ doneLabel: String) -> BighelpToolActivity {
        BighelpToolActivity(glyph: glyph, label: label, doneLabel: doneLabel)
    }

    private static let runningCommand = make(.glyph(.terminal), "Running a command…", "Ran a command")
    private static let checkingCommand = make(.glyph(.terminal), "Checking a running command…", "Checked a running command")
    private static let scheduling = make(.glyph(.scheduled), "Scheduling a task…", "Scheduled a task")
    private static let todo = make(.glyph(.checklist), "Updating the to-do list…", "Updated the to-do list")
    private static let webSearch = make(.symbol("magnifyingglass"), "Searching the web…", "Searched the web")
    private static let reacting = make(.symbol("face.smiling"), "Reacting…", "Reacted")
    private static let makingCard = make(.glyph(.docRich), "Making a card…", "Made a card")

    private static let exact: [String: BighelpToolActivity] = [
        // Files and code
        "read_file": make(.glyph(.doc), "Reading a file…", "Read a file"),
        "write_file": make(.glyph(.docRich), "Writing a file…", "Wrote a file"),
        "patch": make(.glyph(.compose), "Editing a file…", "Edited a file"),
        "search_files": make(.glyph(.folder), "Searching files…", "Searched files"),
        "terminal": runningCommand,
        "process": checkingCommand,
        "process_manage": checkingCommand,
        "read_terminal": make(.glyph(.terminal), "Reading the terminal…", "Read the terminal"),
        "close_terminal": make(.glyph(.terminal), "Closing the terminal…", "Closed the terminal"),
        "execute_code": make(.glyph(.terminal), "Running code…", "Ran code"),
        // The web
        "web_search": webSearch,
        "web_extract": make(.symbol("globe"), "Reading a web page…", "Read a web page"),
        "x_search": make(.symbol("magnifyingglass"), "Searching posts on X…", "Searched posts on X"),
        // Pictures, video and sound
        "image_generate": make(.glyph(.sparkles), "Making an image…", "Made an image"),
        "video_generate": make(.glyph(.sparkles), "Making a video…", "Made a video"),
        "vision_analyze": make(.symbol("eye"), "Looking at an image…", "Looked at an image"),
        "video_analyze": make(.symbol("eye"), "Watching a video…", "Watched a video"),
        "text_to_speech": make(.glyph(.wave), "Making a voice clip…", "Made a voice clip"),
        // Memory, skills and plans
        "memory": make(.glyph(.notebook), "Updating memory…", "Updated memory"),
        "session_search": make(.glyph(.chats), "Searching past chats…", "Searched past chats"),
        "skill_view": make(.glyph(.book), "Reading a skill…", "Read a skill"),
        "skills_list": make(.glyph(.book), "Looking through skills…", "Looked through skills"),
        "skill_manage": make(.glyph(.book), "Updating a skill…", "Updated a skill"),
        "todo": todo,
        "todo_list": todo,
        "cronjob": scheduling,
        "cronjob_manage": scheduling,
        // People and other agents
        "clarify": make(.glyph(.question), "Asking you a question…", "Asked you a question"),
        "delegate_task": make(.glyph(.agents), "Asking another agent…", "Asked another agent"),
        "mixture_of_agents": make(.glyph(.group), "Asking several models…", "Asked several models"),
        "send_message": make(.glyph(.plane), "Sending a message…", "Sent a message"),
        "react_to_message": reacting,
        "computer_use": make(.symbol("cursorarrow"), "Using the computer…", "Used the computer"),
        // The bighelp plugin
        "bighelp_board": make(.symbol("pin"), "Posting an update…", "Posted an update"),
        "bighelp_render_card": makingCard,
        "bighelp_react_to_message": reacting,
        "bighelp_request_secure_input": make(.glyph(.lock), "Asking for secure input…", "Asked for secure input"),
        "iphone_location": make(.symbol("location"), "Checking where you are…", "Checked where you are"),
    ]

    private static let families: [(String, @Sendable (String) -> BighelpToolActivity)] = [
        // The plugin's older one-card-per-kind renderers (`loopdy_render_weather_forecast`).
        ("bighelp_render_", { _ in makingCard }),
        ("browser_vault_", { _ in make(.glyph(.key), "Using a saved login…", "Used a saved login") }),
        ("browser_", { _ in make(.symbol("globe"), "Browsing the web…", "Browsed the web") }),
        ("kanban_", { name in
            name == "kanban_list" || name == "kanban_show"
                ? make(.glyph(.kanban), "Checking the board…", "Checked the board")
                : make(.glyph(.kanban), "Updating the board…", "Updated the board")
        }),
        ("ha_", { name in
            name == "ha_call_service"
                ? make(.symbol("house"), "Controlling a device…", "Controlled a device")
                : make(.symbol("house"), "Checking your home…", "Checked your home")
        }),
        ("schedule_", { _ in scheduling }),
    ]
}
