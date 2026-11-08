import Foundation
import Observation

// What one Activities item did, for its read-out on the Dashboard: a subagent's steps in order and its
// answer, a command's output, a routine run's status and output. From the plugin's `agents/today/detail`
// (`native-agents-today-detail-v1`), which redacts it and shows file names, never host paths.

/// One Activities item as the computer reports it, with what it did.
struct AgentTodayDetail: Equatable, Sendable {
    static let feature = "native-agents-today-detail-v1"
    static let maximumSteps = 300
    static let maximumGoalLength = 4_000
    static let maximumPreviewLength = 400
    static let maximumTextLength = 16_000
    static let maximumErrorLength = 300

    /// One thing a subagent did: a tool call, a message it wrote between calls, or saved thinking.
    struct Step: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable { case tool, message, thinking }
        enum State: String, Sendable { case done, failed, running }

        /// Its place in the subagent's work.
        let id: Int
        let at: Date?
        let kind: Kind
        let tool: String?
        let preview: String?
        let state: State?
    }

    struct Subagent: Equatable, Sendable {
        let goal: String?
        let model: String?
        /// The subagent's answer, as Markdown.
        let summary: String?
        let error: String?
        let steps: [Step]
        /// The host kept only the newest steps.
        let stepsTruncated: Bool
    }

    struct Command: Equatable, Sendable {
        let command: String?
        let exitCode: Int?
        let output: String?
        /// The output is its newest part.
        let outputTruncated: Bool
    }

    struct Scheduled: Equatable, Sendable {
        let job: String?
        /// The run's status as the cron ledger says it.
        let status: String?
        /// The run's output, as Markdown.
        let output: String?
        let error: String?
    }

    enum Body: Equatable, Sendable {
        case subagent(Subagent)
        case command(Command)
        case scheduled(Scheduled)
        /// The host had nothing more to say than the list row.
        case none
    }

    let item: AgentTodayItem
    let body: Body

    init(item: AgentTodayItem, body: Body) {
        self.item = item
        self.body = body
    }

    /// Leniently: each part the host leaves out or this build can't read hides one row. The item falls
    /// back to the list's own row, so the read-out never shows less than the list did.
    init(json value: BighelpJSONValue, listed: AgentTodayItem) {
        let object = value.object ?? [:]
        let item = object["item"].flatMap(AgentTodayItem.init(json:)).flatMap { $0.id == listed.id ? $0 : nil } ?? listed
        let body: Body
        if let subagent = object["subagent"]?.object {
            let steps = (subagent["steps"]?.array ?? []).suffix(Self.maximumSteps).enumerated().compactMap { index, step in
                Self.step(step, index: index)
            }
            body = .subagent(Subagent(
                goal: Self.text(subagent["goal"], limit: Self.maximumGoalLength),
                model: Self.text(subagent["model"], limit: 120),
                summary: Self.text(subagent["summary"], limit: Self.maximumTextLength),
                error: Self.text(subagent["error"], limit: Self.maximumErrorLength),
                steps: steps,
                stepsTruncated: subagent["stepsTruncated"]?.boolean == true
                    || (subagent["steps"]?.array?.count ?? 0) > Self.maximumSteps))
        } else if let command = object["command"]?.object {
            body = .command(Command(
                command: Self.text(command["command"], limit: Self.maximumGoalLength),
                exitCode: command["exitCode"]?.integer,
                output: Self.text(command["output"], limit: Self.maximumTextLength, keepsEdges: true),
                outputTruncated: command["outputTruncated"]?.boolean == true))
        } else if let scheduled = object["scheduled"]?.object {
            body = .scheduled(Scheduled(
                job: Self.text(scheduled["job"], limit: 200),
                status: Self.text(scheduled["status"], limit: 40),
                output: Self.text(scheduled["output"], limit: Self.maximumTextLength),
                error: Self.text(scheduled["error"], limit: Self.maximumErrorLength)))
        } else {
            body = .none
        }
        self.init(item: item, body: body)
    }

    private static func step(_ value: BighelpJSONValue, index: Int) -> Step? {
        guard let row = value.object, let kind = row["kind"]?.string.flatMap(Step.Kind.init(rawValue:)) else { return nil }
        let tool = text(row["tool"], limit: 120)
        let preview = text(row["preview"], limit: maximumPreviewLength)
        // A step with nothing to show isn't one.
        guard kind == .tool ? tool != nil : preview != nil else { return nil }
        return Step(id: index, at: row["at"]?.number.flatMap(date), kind: kind, tool: tool, preview: preview,
                    state: row["state"]?.string.flatMap(Step.State.init(rawValue:)))
    }

    /// Trimmed and bounded; empty is nil. Output keeps its line breaks and indentation.
    private static func text(_ value: BighelpJSONValue?, limit: Int, keepsEdges: Bool = false) -> String? {
        guard let raw = value?.string else { return nil }
        let text = keepsEdges ? raw.trimmingCharacters(in: .newlines) : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    private static func date(_ seconds: Double) -> Date? {
        guard seconds.isFinite, seconds > 1_000_000_000, seconds < 10_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

extension AgentTodayDetail.Scheduled {
    /// A routine's saved output is often Hermes' whole run record ("# Cron Job: …", "## Prompt",
    /// "## Response"). The read-out leads with the response; the rest stays behind a disclosure.
    var response: (answer: String, record: String?)? {
        guard let output else { return nil }
        guard let heading = output.range(of: "\n## Response\n") ?? output.range(of: "## Response\n", options: .anchored)
        else { return (output, nil) }
        let answer = output[heading.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return (output, nil) }
        return (answer, output[..<heading.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension AgentTodayDetail.Command {
    /// The output as it reads best: JSON laid out with indentation, anything else as it came.
    var readableOutput: String? {
        guard let output else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[", trimmed.utf8.count <= 262_144,
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return output }
        return text
    }
}

/// One item's read-out while it shows: read once, and again every few seconds while it runs.
@MainActor
@Observable
final class AgentTodayDetailModel {
    enum Phase: Equatable {
        case loading
        case loaded(AgentTodayDetail)
        /// The computer's plugin predates the route.
        case unsupported
        /// The computer no longer has it.
        case gone
        case failed
    }

    static let runningInterval: Duration = .seconds(3)

    let listed: AgentTodayItem
    private(set) var phase: Phase = .loading
    private let client: (any AgentBoardClient)?
    private let agentID: String

    init(item: AgentTodayItem, agentID: String, client: (any AgentBoardClient)?) {
        listed = item
        self.agentID = agentID
        self.client = client
        if client?.supportsTodayDetail != true { phase = .unsupported }
    }

    /// The item as the latest read has it, else as the list had it.
    var item: AgentTodayItem {
        if case .loaded(let detail) = phase { return detail.item }
        return listed
    }

    var isRunning: Bool { item.state == .running }

    /// Reads until the sheet closes: every few seconds while the work runs, then once more when it ends.
    func follow() async {
        while !Task.isCancelled {
            await refresh()
            guard isRunning, !Task.isCancelled else { return }
            try? await Task.sleep(for: Self.runningInterval)
        }
    }

    func refresh() async {
        guard let client, client.supportsTodayDetail else { return }
        do {
            let detail = try await client.todayDetail(agentID: agentID, item: listed)
            if phase != .loaded(detail) { phase = .loaded(detail) }
        } catch is CancellationError {
            return
        } catch WorkspaceClientError.rejected(code: "activity_not_found", _) {
            phase = .gone
        } catch {
            // What it showed stays through a passing failure.
            if case .loaded = phase { return }
            switch error as? WorkspaceClientError {
            case .unavailable(.unsupportedOperation)?, .unavailable(.pluginRequired)?: phase = .unsupported
            default: phase = .failed
            }
        }
    }
}
