import Foundation

/// Work Hermes ran in the background and reported back: helpers from `delegate_task`
/// (`async_delegation_complete`) or a background command (`process_complete`). Hermes saves
/// the report as a user row written for the model, which starts the agent's next turn; the
/// chat shows it as a small card (`ChatBackgroundResultCard`) instead of the report.
///
/// Rows are read once, when the history is read; the card draws only these fields, and
/// the report is laid out only when someone opens it.
struct ChatBackgroundResult: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case helpers, command }

    enum Outcome: String, Codable, Sendable {
        case finished, failed, stoppedEarly, stopped

        /// Hermes' task status; a finished helper that hit its step limit stopped early.
        init(hermesStatus status: Substring, truncated: Bool) {
            switch status.lowercased() {
            case "completed", "success": self = truncated ? .stoppedEarly : .finished
            case "interrupted", "cancelled", "canceled": self = .stopped
            default: self = .failed
            }
        }
    }

    struct Task: Codable, Equatable, Sendable {
        let goal: String
        let outcome: Outcome
        let seconds: Double?
    }

    let kind: Kind
    let tasks: [Task]
    /// The whole run's time, when Hermes reports it.
    let seconds: Double?
    /// One helper failed while the others still work; their results arrive later.
    let isEarlyWarning: Bool
    /// The report as the model read it.
    let report: String

    static let helpersKind = "async_delegation_complete"
    static let commandKind = "process_complete"

    /// The result a user row from Hermes holds, or nil for a person's message. Hermes before
    /// `display_kind` saved helper reports untyped, so those are known by their first line.
    init?(displayKind: String?, metadata: [String: BighelpJSONValue]?, text: String) {
        let title = metadata?["display_text"]?.string
        switch displayKind {
        case Self.helpersKind:
            self.init(helpersReport: text, title: title, metadata: metadata)
        case Self.commandKind:
            // `message_agent`'s waiter ending is about the message to that agent: the agent-talk rail reads it
            // (`AgentTalkDelivery`), never a command's results.
            guard !(text.contains("bot_mode_dm") && text.contains("--run-delivery")) else { return nil }
            self.init(commandReport: text, title: title)
        case nil, "":
            guard text.hasPrefix("[ASYNC DELEGATION ") else { return nil }
            self.init(helpersReport: text, title: nil, metadata: nil)
        default:
            return nil
        }
    }

    init(kind: Kind, tasks: [Task], seconds: Double?, isEarlyWarning: Bool = false, report: String) {
        self.kind = kind
        self.tasks = tasks
        self.seconds = seconds
        self.isEarlyWarning = isEarlyWarning
        self.report = report
    }

    // MARK: Reading Hermes' report

    /// A batch reports each task as `--- ✓ TASK 1/3: goal  (status=completed, api_calls=22, 553.45s) ---`.
    /// One helper reports `Original goal:` and `Status:` lines; an early warning `Task:` and `Status:`.
    private init(helpersReport text: String, title: String?, metadata: [String: BighelpJSONValue]?) {
        let isEarlyWarning = text.hasPrefix("[ASYNC DELEGATION TASK FAILED")
        var tasks: [Task] = []
        var goal: String?
        var status: (outcome: Outcome, seconds: Double?)?
        var total: Double?
        var inPreamble = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("--- ") {
                if let task = Self.taskHeader(line) {
                    tasks.append(task)
                }
                inPreamble = false
                continue
            }
            guard inPreamble else { continue }
            if goal == nil, let value = Self.value(of: isEarlyWarning ? "Task: " : "Original goal: ", in: line) {
                goal = String(value)
            } else if status == nil, line.hasPrefix("Status: ") {
                status = Self.statusLine(line)
            } else if total == nil, line.hasPrefix("Role: "), let range = line.range(of: "Total duration: ") {
                total = Self.seconds(line[range.upperBound...])
            }
        }
        if tasks.isEmpty {
            tasks = [Task(goal: goal ?? Self.goal(fromTitle: title) ?? "Background task",
                          outcome: status?.outcome ?? (text.contains("\n--- ERROR ---") ? .failed : .finished),
                          seconds: status?.seconds)]
        }
        self.init(kind: .helpers, tasks: tasks,
                  seconds: metadata?["duration_seconds"]?.number ?? total ?? (tasks.count == 1 ? tasks[0].seconds : nil),
                  isEarlyWarning: isEarlyWarning, report: text)
    }

    /// Hermes' title says it all: `Background Process Failed (exit 1): npm run build`.
    private init(commandReport text: String, title: String?) {
        let title = title ?? ""
        let colon = title.range(of: ": ")
        let head = title[..<(colon?.lowerBound ?? title.endIndex)]
        let command = colon.map { String(title[$0.upperBound...]) }
        let outcome: Outcome = head.contains("Failed") || head.contains("Lost") ? .failed
            : head.contains("Terminated") ? .stopped : .finished
        self.init(kind: .command, tasks: [Task(goal: command ?? "Background command", outcome: outcome, seconds: nil)],
                  seconds: nil, report: text)
    }

    private static func taskHeader(_ line: Substring) -> Task? {
        guard line.hasSuffix(") ---"),
              let open = line.range(of: "  (status=", options: .backwards) else { return nil }
        let head = line.dropFirst(4)[..<open.lowerBound].split(separator: " ", maxSplits: 2)
        guard head.count >= 2, head[1] == "TASK" else { return nil }
        let goal = head.count == 3 ? head[2].split(separator: ": ", maxSplits: 1).dropFirst().first : nil
        let fields = line[open.upperBound..<line.index(line.endIndex, offsetBy: -5)].split(separator: ", ")
        guard let status = fields.first else { return nil }
        let truncated = head[0] == "⚠" || fields.contains { $0.hasPrefix("TRUNCATED") }
        return Task(goal: goal.map(String.init) ?? "", outcome: Outcome(hermesStatus: status, truncated: truncated),
                    seconds: fields.dropFirst().lazy.compactMap(seconds).first)
    }

    /// `Status: completed   API calls: 5   Duration: 12.3s [TRUNCATED: …]`.
    private static func statusLine(_ line: Substring) -> (outcome: Outcome, seconds: Double?) {
        let fields = line.split(separator: "   ")
        let status = fields.first?.dropFirst("Status: ".count) ?? ""
        let duration = fields.lazy.compactMap { value(of: "Duration: ", in: $0) }.first
        return (Outcome(hermesStatus: status, truncated: line.contains("[TRUNCATED")),
                duration.flatMap { seconds($0.prefix { $0 != " " }) })
    }

    /// `12.3s` as seconds.
    private static func seconds(_ text: Substring) -> Double? {
        guard text.hasSuffix("s") else { return nil }
        return Double(text.dropLast())
    }

    private static func value(of prefix: String, in line: Substring) -> Substring? {
        line.hasPrefix(prefix) ? line.dropFirst(prefix.count) : nil
    }

    /// `Subagent Task Completed: Fix the tests` gives `Fix the tests`.
    private static func goal(fromTitle title: String?) -> String? {
        guard let title, let colon = title.range(of: ": ") else { return nil }
        return String(title[colon.upperBound...])
    }
}

extension TimelineItem {
    /// The row that starts the agent's turn about the result. It stays a human row, so the turn,
    /// its work trail and its answer group as they did when it showed as a message.
    static func backgroundResult(_ result: ChatBackgroundResult, id: String, metadata: TimelineMetadata) -> TimelineItem {
        TimelineItem(id: id, role: .human,
                     sender: .system(id: "background-work",
                                     snapshot: .init(name: result.kind == .helpers ? "Helpers" : "Background command")),
                     content: .backgroundResult(result), metadata: metadata)
    }
}

// MARK: Words

extension ChatBackgroundResult {
    /// The card's first line, in plain words.
    var headline: String {
        let outcome = tasks.first?.outcome ?? .finished
        switch kind {
        case .command:
            switch outcome {
            case .failed: return "Command failed"
            case .stopped, .stoppedEarly: return "Command stopped"
            case .finished: return "Command finished"
            }
        case .helpers:
            if isEarlyWarning { return "A helper failed" }
            guard tasks.count > 1 else {
                switch outcome {
                case .finished: return "Helper finished"
                case .failed: return "Helper failed"
                case .stoppedEarly: return "Helper stopped early"
                case .stopped: return "Helper stopped"
                }
            }
            let finished = tasks.lazy.filter { $0.outcome == .finished }.count
            if finished == tasks.count { return "\(tasks.count) helpers finished" }
            if finished == 0 { return "\(tasks.count) helpers didn't finish" }
            return "\(finished) of \(tasks.count) helpers finished"
        }
    }

    /// `9m`, `41s`, `1h 5m`: how long the work took.
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(max(whole, 1))s" }
        if whole < 3_600 { return "\(whole / 60)m" }
        let minutes = (whole % 3_600) / 60
        return minutes == 0 ? "\(whole / 3_600)h" : "\(whole / 3_600)h \(minutes)m"
    }

    /// The report's results without the notes Hermes writes for the model: what each task
    /// said, under "Task 2 of 3". Read only when the details open.
    var reportSections: [(heading: String, body: String)] {
        var sections: [(heading: String, body: [Substring])] = []
        var started = false
        for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("--- ") && line.hasSuffix(" ---") {
                started = true
                sections.append((Self.heading(line.dropFirst(4).dropLast(4)), []))
            } else if started {
                sections[sections.count - 1].body.append(line)
            }
        }
        guard started else {
            // No sections: everything after Hermes' bracketed first line.
            let body = report.hasPrefix("[") ? report.drop { $0 != "\n" } : report[...]
            return [("", body.trimmingCharacters(in: .whitespacesAndNewlines))]
        }
        return sections.map { ($0.heading, $0.body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// `✓ TASK 2/3: goal  (status=…)` reads "Task 2 of 3"; `RESULT` needs none.
    private static func heading(_ marker: Substring) -> String {
        if marker == "RESULT" { return "" }
        if marker == "ERROR" { return "Error" }
        let words = marker.split(separator: " ", maxSplits: 2)
        guard words.count >= 3, words[1] == "TASK" else { return String(marker) }
        let numbers = words[2].prefix { $0 != ":" && $0 != " " }.split(separator: "/")
        return numbers.count == 2 ? "Task \(numbers[0]) of \(numbers[1])" : "Task"
    }
}
