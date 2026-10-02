import Foundation

struct DirectHermesHistoryToolCall: Equatable, Sendable {
    let id: String?
    let name: String?
    let arguments: String?
}

struct DirectHermesHistoryRow: Equatable, Sendable {
    let id: Int
    let sessionID: String
    let role: String
    let content: BighelpJSONValue
    let displayContent: BighelpJSONValue?
    let text: String
    let hasUnsupportedContent: Bool
    let toolCalls: [DirectHermesHistoryToolCall]
    let toolCallID: String?
    let toolName: String?
    let reasoning: String?
    let timestamp: Date?
    let turnDurationMilliseconds: Int?
    let platformMessageID: String?
    let displayKind: String?
    let raw: [String: BighelpJSONValue]

    var isVisible: Bool {
        displayKind != "hidden" && displayKind != "internal_notification"
    }

    /// `display_metadata.reply_expected`: false when the message wasn't addressed to the agent.
    var replyExpected: Bool? {
        raw["display_metadata"]?.object?["reply_expected"]?.boolean
    }

    /// The agent reacted to this message (`display_metadata.reactions`, author "agent").
    var hasAgentReaction: Bool {
        raw["display_metadata"]?.object?["reactions"]?.array?.contains {
            $0.object?["author"]?.string == "agent"
        } ?? false
    }

    init(_ value: BighelpJSONValue, sessionID: String) throws {
        guard let row = value.object, let id = row["id"]?.integer,
              id > 0, id <= 9_007_199_254_740_991 else { throw WorkspaceClientError.invalidResponse }
        self.id = id
        self.sessionID = try DirectHermesSessionValidation.string(row["session_id"])
        guard DirectHermesSessionValidation.same(self.sessionID, sessionID) else {
            throw WorkspaceClientError.invalidResponse
        }
        role = try DirectHermesSessionValidation.string(row["role"], maximum: 64)
        content = row["content"] ?? .null
        displayContent = row["display_content"]
        let displayed = try Self.displayText(displayContent ?? content)
        text = displayed.text
        hasUnsupportedContent = displayed.unsupported
        timestamp = try DirectHermesSessionValidation.date(row["timestamp"])
        turnDurationMilliseconds = Self.optionalDuration(row["turn_duration_ms"])
        platformMessageID = try Self.optionalCoordinate(row["platform_message_id"])
        toolCallID = try Self.optionalCoordinate(row["tool_call_id"])
        toolName = try Self.optionalCoordinate(row["tool_name"], maximum: 128)
        displayKind = try Self.optionalCoordinate(row["display_kind"], maximum: 128)
        let reasoningValue = [row["reasoning_content"], row["reasoning"]]
            .compactMap { value -> BighelpJSONValue? in
                guard let value, value != .null else { return nil }
                return value
            }
            .first
        if let value = reasoningValue {
            guard let string = value.string else { throw WorkspaceClientError.invalidResponse }
            reasoning = try Self.historyText(string)
        } else {
            reasoning = nil
        }
        switch row["tool_calls"] {
        case nil, .null, .string(""):
            toolCalls = []
        case .array(let values):
            guard values.count <= 128 else { throw WorkspaceClientError.capacityExceeded }
            toolCalls = try values.map { value in
                guard let call = value.object else { throw WorkspaceClientError.invalidResponse }
                let function = call["function"]?.object
                let arguments = function?["arguments"]
                return DirectHermesHistoryToolCall(
                    id: try Self.optionalCoordinate(call["id"]),
                    name: try Self.optionalCoordinate(function?["name"], maximum: 128),
                    arguments: try arguments.map(Self.literalText)
                )
            }
        default:
            throw WorkspaceClientError.invalidResponse
        }
        raw = row
    }

    static func literalText(_ value: BighelpJSONValue) throws -> String {
        if let string = value.string {
            return try historyText(string)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 1_048_576, let result = String(data: data, encoding: .utf8) else {
            throw WorkspaceClientError.capacityExceeded
        }
        return result
    }

    private static func displayText(_ value: BighelpJSONValue) throws -> (text: String, unsupported: Bool) {
        switch value {
        case .null: return ("", false)
        case .string(let string):
            return (try historyText(string), false)
        case .array(let parts):
            guard parts.count <= 512 else { throw WorkspaceClientError.capacityExceeded }
            var text: [String] = []
            var unsupported = false
            for part in parts {
                guard let object = part.object, let type = object["type"]?.string,
                      ["text", "input_text", "output_text"].contains(type),
                      let value = object["text"]?.string else {
                    unsupported = true
                    continue
                }
                text.append(try historyText(value))
            }
            let combined = text.joined(separator: "\n")
            _ = try historyText(combined)
            return (combined, unsupported)
        default:
            return ("", true)
        }
    }

    // Transcript bodies can contain invisible Unicode formatting and terminal
    // output. They are inert display text, not protocol identifiers. Retain
    // them verbatim within the same byte bound instead of rejecting a chat.
    private static func historyText(_ value: String) throws -> String {
        guard value.utf8.count <= 1_048_576 else { throw WorkspaceClientError.capacityExceeded }
        return value
    }

    private static func optionalCoordinate(_ value: BighelpJSONValue?, maximum: Int = 512) throws -> String? {
        guard let value, value != .null, value != .string("") else { return nil }
        return try DirectHermesSessionValidation.string(value, maximum: maximum)
    }

    private static func optionalDuration(_ value: BighelpJSONValue?) -> Int? {
        guard let value, value != .null,
              let duration = value.integer,
              (0...86_400_000).contains(duration) else { return nil }
        return duration
    }
}

struct DirectHermesHistoryToolRecord: Identifiable, Equatable, Sendable {
    let id: String
    let requestRowID: Int?
    let resultRowID: Int?
    let toolCallID: String?
    let name: String?
    let arguments: String?
    let result: String?
    let timestamp: Date?
    let sourceOrder: Int
}

struct DirectHermesHistoryProjection: Equatable, Sendable {
    let rows: [DirectHermesHistoryRow]
    let messages: [TimelineItem]
    let tools: [DirectHermesHistoryToolRecord]
    let unsupportedContentRowIDs: [Int]
    let sourceOrderBase: Int

    func activityEvents(sessionID: String) -> [ChatActivityEvent] {
        let counts = Dictionary(grouping: tools.compactMap(\.toolCallID), by: DirectHermesSessionIdentity.key).mapValues(\.count)
        // History stores a tool request and its result as separate rows. The
        // request/result pair remains two source rows, but one logical turn
        // owns both. Bind each row to the nearest preceding visible user row
        // so reopening a chat preserves the live turn grouping.
        var turnByRowID: [Int: String] = [:]
        var currentTurnID: String?
        for row in rows where row.isVisible {
            if row.role == "user", row.displayKind != "model_switch" {
                currentTurnID = "\(sessionID):history-row:\(row.id)"
            }
            if let currentTurnID { turnByRowID[row.id] = currentTurnID }
        }
        func turnID(requestRowID: Int?, resultRowID: Int?) -> String {
            if let requestRowID, let turnID = turnByRowID[requestRowID] { return turnID }
            if let resultRowID, let turnID = turnByRowID[resultRowID] { return turnID }
            return "\(sessionID):history-row:\(requestRowID ?? resultRowID ?? 0)"
        }
        var events = tools.map { tool in
            let uniqueCallID = tool.toolCallID.flatMap {
                counts[DirectHermesSessionIdentity.key($0)] == 1 ? $0 : nil
            }
            return ChatActivityEvent(
                eventID: tool.id, sessionID: sessionID,
                turnID: turnID(requestRowID: tool.requestRowID, resultRowID: tool.resultRowID),
                kind: .tool, lifecycle: .recorded, title: tool.name ?? "Recorded tool",
                summary: "Recorded history; execution outcome not classified.", detail: nil,
                occurredAt: tool.timestamp.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0,
                toolCallID: uniqueCallID, toolName: tool.name, arguments: tool.arguments,
                result: tool.result, sourceOrder: tool.sourceOrder
            )
        }
        for (index, row) in rows.enumerated() where row.isVisible {
            guard let reasoning = row.reasoning, !reasoning.isEmpty else { continue }
            events.append(ChatActivityEvent(
                eventID: "\(sessionID):reasoning-row:\(row.id)", sessionID: sessionID,
                turnID: turnID(requestRowID: row.id, resultRowID: nil), kind: .reasoning, lifecycle: .recorded,
                title: "Recorded reasoning", summary: reasoning, detail: nil,
                occurredAt: row.timestamp.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0,
                sourceOrder: sourceOrderBase + index
            ))
        }
        return events.sorted { ($0.sourceOrder ?? 0) < ($1.sourceOrder ?? 0) }
    }

    init(rows: [DirectHermesHistoryRow], appID: String, profileID: String,
         source: String?, sourceOrderBase: Int) throws {
        guard rows.count <= DirectHermesSessionValidation.maximumHistoryRows,
              Set(rows.map(\.id)).count == rows.count else { throw WorkspaceClientError.invalidResponse }
        self.rows = rows
        self.sourceOrderBase = sourceOrderBase
        var messages: [TimelineItem] = []
        var tools: [DirectHermesHistoryToolRecord] = []
        var unsupported: [Int] = []
        var requestCounts: [String: Int] = [:]
        var resultRows: [String: [DirectHermesHistoryRow]] = [:]
        for row in rows where row.isVisible {
            for call in row.toolCalls {
                if let id = call.id { requestCounts[DirectHermesSessionIdentity.key(id), default: 0] += 1 }
            }
            if row.role == "tool", let id = row.toolCallID {
                resultRows[DirectHermesSessionIdentity.key(id), default: []].append(row)
            }
        }
        var joinedResultIDs = Set<Int>()
        let isScheduled = ["cron", "webhook"].contains { source?.caseInsensitiveCompare($0) == .orderedSame }
        var turnPrompt: DirectHermesHistoryRow?
        for (index, row) in rows.enumerated() {
            // Hidden rows still own their turn: an off-screen note may be answered with silence.
            if row.role == "user" { turnPrompt = row }
            guard row.isVisible else { continue }
            let order = sourceOrderBase.addingReportingOverflow(index)
            guard !order.overflow else { throw WorkspaceClientError.capacityExceeded }
            if row.hasUnsupportedContent { unsupported.append(row.id) }
            let isModelSwitch = row.displayKind == "model_switch"
            var text = row.role == "user" && !isModelSwitch ? HermesUserMessageDisplay.text(row.text) : row.text
            // Hermes' rule with the turn's real kind (ChatSilentReply): quiet unless a person's
            // message got only a marker, which shows Hermes' notice. An unknown turn stays quiet,
            // and so does one the agent answered with a reaction.
            var isSilent = false
            if row.role == "assistant", ChatSilentReply.isMarker(text) {
                if !isScheduled, let prompt = turnPrompt, !prompt.hasAgentReaction, !ChatSilentReply.silenceAllowed(
                    displayKind: prompt.displayKind, replyExpected: prompt.replyExpected) {
                    text = ChatSilentReply.notice
                } else {
                    isSilent = true
                }
            }
            if (isModelSwitch || row.role == "user" || row.role == "assistant"), !isSilent,
               !text.isEmpty || row.hasUnsupportedContent {
                messages.append(TimelineItem(
                    id: "\(appID):row:\(row.id)",
                    role: isModelSwitch || row.role == "assistant" ? .assistant : .human,
                    sender: isModelSwitch
                        ? .system(snapshot: .init(name: "System"))
                        : row.role == "user"
                            ? .user(snapshot: .init(name: "You"))
                            : .agent(id: profileID, snapshot: .init(name: profileID)),
                    content: .message(text),
                    metadata: .init(
                        source: source.map { "Hermes · \($0)" } ?? "Hermes",
                        freshness: row.hasUnsupportedContent ? "Contains native non-text content" : nil,
                        delivery: "Saved", timestamp: row.timestamp, sourceOrder: order.partialValue,
                        platformMessageID: row.platformMessageID,
                        turnDurationMilliseconds: row.turnDurationMilliseconds
                    )
                ))
            }
            for (callIndex, call) in row.toolCalls.enumerated() {
                let key = call.id.map(DirectHermesSessionIdentity.key)
                let uniqueRequest = key.map { requestCounts[$0] == 1 } ?? false
                let candidates = key.flatMap { resultRows[$0] } ?? []
                let result = uniqueRequest && candidates.count == 1 ? candidates.first : nil
                if let result { joinedResultIDs.insert(result.id) }
                tools.append(.init(
                    id: "\(appID):tool-row:\(row.id):\(callIndex)", requestRowID: row.id,
                    resultRowID: result?.id, toolCallID: call.id, name: call.name ?? result?.toolName,
                    arguments: call.arguments,
                    result: try result.map { try DirectHermesHistoryRow.literalText($0.content) },
                    timestamp: result?.timestamp ?? row.timestamp, sourceOrder: order.partialValue
                ))
            }
        }
        for (index, row) in rows.enumerated() where row.role == "tool" && row.isVisible && !joinedResultIDs.contains(row.id) {
            tools.append(.init(
                id: "\(appID):tool-result-row:\(row.id)", requestRowID: nil, resultRowID: row.id,
                toolCallID: row.toolCallID, name: row.toolName, arguments: nil,
                result: try DirectHermesHistoryRow.literalText(row.content),
                timestamp: row.timestamp, sourceOrder: sourceOrderBase + index
            ))
        }
        self.messages = messages
        self.tools = tools.sorted { $0.sourceOrder < $1.sourceOrder }
        unsupportedContentRowIDs = unsupported
    }
}
