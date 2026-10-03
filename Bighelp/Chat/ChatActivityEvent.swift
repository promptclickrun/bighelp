import Foundation

enum ChatActivityKind: String, Codable, Equatable, Sendable {
    case reasoning
    case tool
    case subagent
    case botHandoff = "bot_handoff"
}

enum ChatActivityLifecycle: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case recorded

    var isTerminal: Bool {
        self != .running && self != .recorded
    }
}

struct ChatActivityEvent: Identifiable, Codable, Equatable, Sendable {
    let eventID: String
    private(set) var sessionID: String
    let turnID: String
    let kind: ChatActivityKind
    private(set) var lifecycle: ChatActivityLifecycle
    let title: String
    private(set) var summary: String?
    private(set) var detail: String?
    private(set) var occurredAt: Int
    private(set) var durationMilliseconds: Int?
    let toolCallID: String?
    /// Canonical Hermes tool name from the authenticated tool-call coordinate.
    /// Unlike `title`, this field is never free-form presentation prose.
    let toolName: String?
    /// Authenticated Hermes tool-call arguments retained for on-demand detail.
    private(set) var arguments: String?
    /// Authenticated Hermes tool result retained for on-demand detail.
    private(set) var result: String?
    /// Locally cached bytes resolved from the exact stored tool result. This is
    /// never populated from a provider URL or a client-supplied path.
    private(set) var generatedMedia: GeneratedMediaResolution?
    let subagentID: String?
    let botRunID: String?
    let memberID: String?
    let fromMemberID: String?
    /// The first authenticated arrival position for live activity, or the
    /// canonical Hermes history row when restored.
    private(set) var sourceOrder: Int?
    /// The result/source row is a preview until explicitly read and verified.
    private(set) var contentReference: CanonicalContentReference?

    var id: String {
        let activityID = switch kind {
        case .tool:
            toolCallID.map { "tool:\($0)" } ?? "event:\(eventID)"
        case .subagent:
            subagentID.map { "subagent:\($0)" } ?? "event:\(eventID)"
        case .botHandoff:
            if let botRunID, let memberID {
                "handoff:\(botRunID):\(memberID)"
            } else {
                "event:\(eventID)"
            }
        case .reasoning:
            "event:\(eventID)"
        }
        return "\(sessionID):\(turnID):\(activityID)"
    }

    var isPresentable: Bool {
        kind != .reasoning || reasoningText != nil
    }

    var reasoningText: String? {
        guard kind == .reasoning else { return nil }
        let emptyLifecycleLabels = [
            "",
            "preparing a response",
            "response ready",
            "response stopped",
            "reasoning completed",
        ]
        for value in [detail, summary] {
            guard let value,
                  !emptyLifecycleLabels.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else { continue }
            return value
        }
        return nil
    }

    /// Plain words for the work, from the shared tool catalog: "Running a
    /// command…" while it runs, "Ran a command" once it ends. A tool the
    /// catalog doesn't know says "Using tools…" / "Used tools".
    var presentationTitle: String {
        switch kind {
        case .reasoning: return "Thinking"
        case .tool, .subagent:
            let activity = presentationActivity
            return lifecycle == .running ? activity.label : activity.doneLabel
        case .botHandoff: return title
        }
    }

    /// The catalog entry for this work. A subagent is another agent asked to help.
    var presentationActivity: BighelpToolActivity {
        switch kind {
        case .reasoning: BighelpToolActivityCatalog.thinking
        case .subagent: BighelpToolActivityCatalog.activity(forTool: "delegate_task")
        case .tool, .botHandoff: BighelpToolActivityCatalog.activity(forTool: canonicalToolName)
        }
    }

    /// The Hermes tool this call ran. `tool_call` only wraps another tool, so
    /// its nested name wins. Older events carry just Hermes' own title for a
    /// few tools; any other free-form title is never taken for a name.
    var canonicalToolName: String? {
        guard kind == .tool else { return nil }
        let name = toolName.flatMap(safeCollapsedIdentifier)?.lowercased() ?? Self.toolNamesByTitle[
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        guard name == "tool_call" else { return name }
        return nonemptyArgument("name", in: argumentObject ?? [:]).flatMap(safeCollapsedIdentifier)
    }

    private static let toolNamesByTitle = [
        "using skill view": "skill_view",
        "running a command": "terminal",
        "using execute code": "execute_code",
        "using tool call": "tool_call",
    ]

    /// What the collapsed line may name besides the tool, all from
    /// authenticated coordinates: the command's executable, the skill or the
    /// program, a subagent's goal, or the name of a tool the catalog doesn't
    /// know. Never the arguments, the summary or a free-form server title.
    var presentationDetail: String? {
        switch kind {
        case .subagent:
            let goal = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return goal.isEmpty ? nil : String(goal.prefix(120))
        case .tool:
            // Arguments are parsed only for the tools that name something in them.
            switch canonicalToolName {
            case "skill_view":
                return nonemptyArgument("name", in: argumentObject ?? [:]).flatMap(safeCollapsedIdentifier)
            case "terminal":
                guard let command = nonemptyArgument("command", in: argumentObject ?? [:]),
                      let executable = commandExecutableName(command) else { return nil }
                // `cd app && npm test` names npm, the program that does the work.
                return ChatCommandPhrase.isSetup(executable) ? ChatCommandPhrase.program(for: command) : executable
            case "execute_code":
                let arguments = argumentObject ?? [:]
                return (nonemptyArgument("executable", in: arguments) ?? nonemptyArgument("name", in: arguments))
                    .flatMap(executableBasename).flatMap(safeCollapsedIdentifier)
            case let name?:
                return presentationActivity == BighelpToolActivityCatalog.fallback ? name : nil
            case nil:
                return nil
            }
        case .reasoning, .botHandoff:
            return nil
        }
    }

    var collapsedPresentationSummary: String? {
        kind == .tool ? nil : summary
    }

    /// The collapsed row as VoiceOver reads it: the words, what they name, and
    /// an outcome worth hearing ("Failed").
    func collapsedAccessibilityLabel(status: String?) -> String {
        // The same words the step line shows ("Reading notes.md…").
        let words = switch kind {
        case .tool, .subagent: lifecycle == .running ? toolPhrase.live : toolPhrase.past
        case .reasoning, .botHandoff: presentationTitle
        }
        let detail = presentationDetail.flatMap { words.contains($0) ? nil : $0 }
        return [words, detail, collapsedPresentationSummary, status]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: ", ")
    }

    private var argumentObject: [String: Any]? {
        guard
            let arguments,
            let data = arguments.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func nonemptyArgument(_ key: String, in object: [String: Any]) -> String? {
        guard let value = object[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func safeCollapsedIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy(isSafeIdentifierScalar) else {
            return nil
        }
        return String(trimmed.prefix(80))
    }

    private func isSafeIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            true
        default:
            "_-.@:/+".unicodeScalars.contains(scalar)
        }
    }

    private func commandExecutableName(_ command: String) -> String? {
        guard let firstLine = command.split(whereSeparator: { $0.isNewline }).first else {
            return nil
        }
        let tokens = firstLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        var index = 0
        if executableBasename(tokens[0]) == "env" {
            index += 1
            while index < tokens.count, tokens[index].hasPrefix("-") {
                index += 1
            }
        }

        while index < tokens.count, isEnvironmentAssignment(tokens[index]) {
            guard hasBalancedQuotes(tokens[index]) else { return nil }
            index += 1
        }
        guard index < tokens.count, hasBalancedQuotes(tokens[index]) else { return nil }
        guard let basename = executableBasename(tokens[index]) else { return nil }
        return safeCollapsedIdentifier(basename)
    }

    private func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "=") else { return false }
        let name = token[..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private func hasBalancedQuotes(_ token: String) -> Bool {
        token.filter { $0 == "'" }.count.isMultiple(of: 2)
            && token.filter { $0 == "\"" }.count.isMultiple(of: 2)
    }

    private func executableBasename(_ token: String) -> String? {
        let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard !stripped.isEmpty else { return nil }
        return stripped.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
    }

    func isVisible(using visibility: ChatActivityVisibility) -> Bool {
        guard isPresentable else { return false }
        return switch kind {
        case .reasoning: visibility.showReasoning
        case .tool: visibility.showToolCalls
        case .subagent, .botHandoff: true
        }
    }

    init(
        eventID: String,
        sessionID: String,
        turnID: String,
        kind: ChatActivityKind,
        lifecycle: ChatActivityLifecycle,
        title: String,
        summary: String?,
        detail: String?,
        occurredAt: Int,
        durationMilliseconds: Int? = nil,
        toolCallID: String? = nil,
        toolName: String? = nil,
        arguments: String? = nil,
        result: String? = nil,
        generatedMedia: GeneratedMediaResolution? = nil,
        subagentID: String? = nil,
        botRunID: String? = nil,
        memberID: String? = nil,
        fromMemberID: String? = nil,
        sourceOrder: Int? = nil,
        contentReference: CanonicalContentReference? = nil
    ) {
        self.contentReference = contentReference
        self.eventID = eventID
        self.sessionID = sessionID
        self.turnID = turnID
        self.kind = kind
        self.lifecycle = lifecycle
        self.title = title
        self.summary = summary
        self.detail = detail
        self.occurredAt = occurredAt
        self.durationMilliseconds = durationMilliseconds
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.generatedMedia = generatedMedia
        self.subagentID = subagentID
        self.botRunID = botRunID
        self.memberID = memberID
        self.fromMemberID = fromMemberID
        self.sourceOrder = sourceOrder
    }

    func updating(
        lifecycle: ChatActivityLifecycle,
        summary: String?,
        detail: String?,
        occurredAt: Int,
        durationMilliseconds: Int? = nil,
        arguments: String? = nil,
        result: String? = nil
    ) -> ChatActivityEvent {
        var event = self
        event.lifecycle = lifecycle
        event.summary = summary
        event.detail = detail
        event.occurredAt = occurredAt
        event.durationMilliseconds = durationMilliseconds
        event.arguments = arguments ?? self.arguments
        event.result = result ?? self.result
        return event
    }

    func ordered(_ sourceOrder: Int) -> ChatActivityEvent {
        var event = self
        event.sourceOrder = sourceOrder
        return event
    }

    func routed(to sessionID: String) -> ChatActivityEvent {
        var event = self
        event.sessionID = sessionID
        event.contentReference = contentReference?.routed(to: sessionID)
        return event
    }

    func resolvingGeneratedMedia(_ resolution: GeneratedMediaResolution) -> ChatActivityEvent {
        var event = self
        event.generatedMedia = resolution
        return event
    }

    var semanticIdentity: String? {
        switch kind {
        case .tool:
            guard let toolCallID else { return nil }
            return "\(turnID):tool:\(toolCallID)"
        case .subagent:
            guard let subagentID else { return nil }
            return "\(turnID):subagent:\(subagentID)"
        case .botHandoff:
            guard let botRunID, let memberID else { return nil }
            return "\(turnID):handoff:\(botRunID):\(memberID)"
        case .reasoning:
            return nil
        }
    }
}

struct ChatActivityVisibility: Codable, Equatable, Sendable {
    var showReasoning: Bool
    var showToolCalls: Bool

    static let `default` = ChatActivityVisibility(
        showReasoning: false,
        showToolCalls: true
    )
}

enum ChatActivityReconciliation: Equatable, Sendable {
    case inserted
    case recovered
    case updated
    case duplicate
    case stale
    case ignoredWrongSession
    case ignoredTerminalWithoutStart
    case ignoredIdentityConflict
}

enum ChatActivityVisualTone: Equatable, Sendable {
    case neutral
    case success
    case failure
    case secondary
}

struct ChatActivityVisualState: Equatable, Sendable {
    let tone: ChatActivityVisualTone
    let shimmers: Bool

    init(lifecycle: ChatActivityLifecycle) {
        switch lifecycle {
        case .running:
            tone = .neutral
            shimmers = true
        case .succeeded:
            tone = .success
            shimmers = false
        case .failed:
            tone = .failure
            shimmers = false
        case .cancelled:
            tone = .secondary
            shimmers = false
        case .recorded:
            tone = .secondary
            shimmers = false
        }
    }
}
