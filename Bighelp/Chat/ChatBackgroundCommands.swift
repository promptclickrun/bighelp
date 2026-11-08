import Foundation

/// A command the agent left running in this chat (`terminal(background=true)`: a preview server, a
/// long script, a watcher), as Hermes' `process.list` reports it. Finished ones stay listed for a
/// while, with how they ended.
struct ChatBackgroundCommand: Identifiable, Equatable, Sendable {
    static let maximumCommands = 64
    static let maximumCommandLength = 200
    static let maximumOutputLength = 4_000

    /// Hermes' process ID (`proc_…`), what `process.kill` takes.
    let id: String
    let command: String
    let isRunning: Bool
    let startedAt: Date?
    let exitCode: Int?
    /// `exited`, `killed`, `lost`… once it ended.
    let completionReason: String?
    /// The newest output, at most 4,000 characters.
    let output: String

    init(id: String, command: String, isRunning: Bool, startedAt: Date? = nil, exitCode: Int? = nil,
         completionReason: String? = nil, output: String = "") {
        self.id = id
        self.command = command
        self.isRunning = isRunning
        self.startedAt = startedAt
        self.exitCode = exitCode
        self.completionReason = completionReason
        self.output = output
    }

    /// One `process.list` row, leniently. Hermes' `started_at` is the host's local time with no
    /// zone, so the start comes from `uptime_seconds` instead.
    init?(json value: BighelpJSONValue, now: Date) {
        guard let row = value.object, let id = row["session_id"]?.string, !id.isEmpty, id.utf8.count <= 128,
              !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let command = (row["command"]?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !command.isEmpty else { return nil }
        let uptime = row["uptime_seconds"]?.number.flatMap { $0.isFinite && $0 >= 0 && $0 < 31_536_000 ? $0 : nil }
        let output = row["output_tail"]?.string ?? row["output_preview"]?.string ?? ""
        self.init(id: id, command: String(command.prefix(Self.maximumCommandLength)),
                  isRunning: row["status"]?.string != "exited",
                  startedAt: uptime.map { now.addingTimeInterval(-$0) },
                  exitCode: row["exit_code"]?.integer,
                  completionReason: row["completion_reason"]?.string.map { String($0.prefix(32)) },
                  output: String(output.suffix(Self.maximumOutputLength)))
    }

    /// The `process.list` answer: running first, then the newest. Nil when it isn't one. A
    /// subagent's own commands (`sa-…` tasks) are left out: they're part of that subagent's work,
    /// which the chip already counts.
    static func list(_ response: BighelpJSONValue, now: Date = .now) -> [ChatBackgroundCommand]? {
        guard let rows = response.object?["processes"]?.array else { return nil }
        var seen: Set<String> = []
        let commands = rows.prefix(maximumCommands)
            .filter { $0.object?["owner_task_id"]?.string?.hasPrefix("sa-") != true }
            .compactMap { ChatBackgroundCommand(json: $0, now: now) }
            .filter { seen.insert($0.id).inserted }
        return commands.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
    }

    /// How it ended, in plain words.
    var outcome: String {
        guard !isRunning else { return String(localized: "Running") }
        switch completionReason {
        case "killed": return String(localized: "Stopped")
        case "lost": return String(localized: "Lost track of it")
        default:
            guard let exitCode else { return String(localized: "Finished") }
            return exitCode == 0 ? String(localized: "Finished") : String(localized: "Failed · exit \(exitCode)")
        }
    }
}

/// What the "In the background" chip counts: the chat's live subagents and running commands.
struct ChatBackgroundSummary: Equatable, Sendable {
    let subagents: Int
    let commands: Int

    var isEmpty: Bool { subagents == 0 && commands == 0 }

    /// "2 subagents · 1 command".
    var detail: String {
        var parts: [String] = []
        if subagents > 0 {
            parts.append(subagents == 1 ? String(localized: "1 subagent") : String(localized: "\(subagents) subagents"))
        }
        if commands > 0 {
            parts.append(commands == 1 ? String(localized: "1 command") : String(localized: "\(commands) commands"))
        }
        return parts.joined(separator: " · ")
    }
}
