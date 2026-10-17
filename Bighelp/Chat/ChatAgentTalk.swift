import Foundation

/// One agent messaging another, read from the tool call Hermes recorded:
/// a `hermes -p <agent> chat -q …` command, `hermes peer dm <computer>`, or
/// Hermes' `message_agent` tool. Never guessed from the agent's prose.
struct AgentTalkCall: Equatable, Sendable {
    enum Route: Equatable, Sendable {
        /// `hermes -p <agent> chat`: the reply is the command's output.
        case chat
        /// `hermes peer dm|run`: an agent on another computer; the reply is the output.
        case peer
        /// `message_agent`: queued, and the reply comes back later as its own message.
        case message
    }

    /// The agent written to: a profile ID on this computer, or a peer's
    /// `<computer>/<agent>` label.
    let targetID: String
    /// The words sent. Nil when they came from a file or standard input.
    let message: String?
    let route: Route

    /// The other agent's display name when Hermes' roster doesn't know it:
    /// "Researcher" for `spark/researcher`.
    var fallbackTargetName: String {
        let last = targetID.split(separator: "/").last.map(String.init) ?? targetID
        let handle = last.split(separator: "@").first.map(String.init) ?? last
        return handle.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }

    /// Reads a recorded tool call. Only the shapes Hermes documents count.
    static func parse(toolName: String?, arguments: String?) -> AgentTalkCall? {
        guard let toolName = toolName?.lowercased(), let arguments, !arguments.isEmpty else { return nil }
        switch toolName {
        case "message_agent":
            guard let object = jsonObject(arguments),
                  let target = (object["target"] as? String).flatMap(AgentTalkIdentity.agentID(fromHandle:))
            else { return nil }
            return AgentTalkCall(targetID: target, message: nonempty(object["message"] as? String), route: .message)
        case "terminal":
            // Cheap first: most commands never mention Hermes.
            guard arguments.contains("hermes"), let object = jsonObject(arguments),
                  let command = object["command"] as? String,
                  let commands = AgentTalkShellWords.commands(in: command) else { return nil }
            for words in commands {
                if let call = hermesCall(words) { return call }
            }
            return nil
        default:
            return nil
        }
    }

    /// `hermes [-p X] chat … -q TEXT`, `hermes peer dm TARGET [TEXT]`, after
    /// any `cd`, `timeout`, `env` or variable set up front.
    private static func hermesCall(_ raw: [String]) -> AgentTalkCall? {
        var words = raw[...]
        while let first = words.first {
            let name = basename(first)
            if isAssignment(first) {
                words = words.dropFirst()
            } else if runners.contains(name) {
                words = words.dropFirst()
                while let next = words.first, next.hasPrefix("-") || isAssignment(next)
                        || next.allSatisfy({ $0.isNumber || $0 == "." || $0 == "s" || $0 == "m" }) {
                    words = words.dropFirst()
                }
            } else {
                break
            }
        }
        guard let program = words.first, basename(program) == "hermes" else { return nil }
        words = words.dropFirst()

        var profile: String?
        var subcommand: [String] = []
        var query: String?
        var queryFromFile = false
        var index = words.startIndex
        while index < words.endIndex {
            let word = words[index]
            let next = words.index(after: index) < words.endIndex ? words[words.index(after: index)] : nil
            switch word {
            case "-p", "--profile":
                profile = next
                index = words.index(index, offsetBy: 2, limitedBy: words.endIndex) ?? words.endIndex
                continue
            case "-q", "--query":
                query = next
                index = words.index(index, offsetBy: 2, limitedBy: words.endIndex) ?? words.endIndex
                continue
            case "--query-file":
                queryFromFile = true
                index = words.index(index, offsetBy: 2, limitedBy: words.endIndex) ?? words.endIndex
                continue
            default:
                if word.hasPrefix("--profile=") {
                    profile = String(word.dropFirst("--profile=".count))
                } else if word.hasPrefix("--query=") {
                    query = String(word.dropFirst("--query=".count))
                } else if word.hasPrefix("--query-file=") {
                    queryFromFile = true
                } else if valueOptions.contains(word) {
                    // Skip the value so it is never read as a subcommand.
                    if let next, !next.hasPrefix("-") || word != "-c" && word != "--continue" {
                        index = words.index(after: index)
                    }
                } else if !word.hasPrefix("-") {
                    subcommand.append(word)
                }
            }
            index = words.index(after: index)
        }

        switch subcommand.first {
        case "chat":
            // Without -p the target is whichever agent the shell points at: unknown.
            guard let profile = profile.flatMap(AgentTalkIdentity.agentID(fromHandle:)),
                  query != nil || queryFromFile else { return nil }
            return AgentTalkCall(targetID: profile, message: query.flatMap(nonempty), route: .chat)
        case "peer":
            guard subcommand.count >= 3, ["dm", "run"].contains(subcommand[1]),
                  let target = AgentTalkIdentity.peerTarget(subcommand[2]) else { return nil }
            return AgentTalkCall(targetID: target, message: subcommand.dropFirst(3).first.flatMap(nonempty),
                                 route: .peer)
        default:
            return nil
        }
    }

    /// Options of `hermes` and `hermes chat` that take a value. `-c` takes one
    /// only when a name follows.
    private static let valueOptions: Set<String> = [
        "-m", "--model", "-t", "--toolsets", "--reasoning", "-s", "--skills", "--provider", "--resume", "-r",
        "--in", "--max-turns", "--run-budget", "--source", "--image", "--format", "-c", "--continue",
    ]

    private static let runners: Set<String> = ["timeout", "gtimeout", "env", "nohup", "exec", "command", "time", "nice"]

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber } && !word.hasPrefix("-")
    }

    private static func basename(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        guard text.utf8.count <= 262_144, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// What came back from an agent-to-agent call, read from its recorded result.
struct AgentTalkReply: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The other agent answered with `text`.
        case answered
        /// `message_agent` queued the message; the answer arrives as its own message.
        case queued
        case failed
    }

    let outcome: Outcome
    /// The other agent's words, without Hermes' "Message from …:" signature.
    let text: String?
    /// The other agent's own chat for this exchange, from `hermes chat -Q`'s
    /// `session_id:` line.
    let sessionID: String?
    /// `message_agent`'s background delivery, whose notice carries the answer.
    var processID: String?

    static func parse(_ call: AgentTalkCall, result: String?, lifecycle: ChatActivityLifecycle) -> AgentTalkReply? {
        guard let result, !result.isEmpty else {
            return lifecycle == .failed ? AgentTalkReply(outcome: .failed, text: nil, sessionID: nil) : nil
        }
        let object = AgentTalkCall.jsonObject(result)
        switch call.route {
        case .message:
            let status = (object?["status"] as? String)?.lowercased()
            if lifecycle == .failed || status == "error" || status == "failed" || object?["error"] is String {
                return AgentTalkReply(outcome: .failed, text: nil, sessionID: nil)
            }
            let process = (object?["process_id"] as? String).flatMap { AgentTalkIdentity.isSessionID($0) ? $0 : nil }
            return AgentTalkReply(outcome: .queued, text: nil, sessionID: nil, processID: process)
        case .chat, .peer:
            let output = object.map { ($0["output"] as? String) ?? "" } ?? result
            let exitCode = (object?["exit_code"] as? NSNumber)?.intValue ?? 0
            var sessionID: String?
            // `hermes chat -Q` prints `session_id: <id>` on stderr, which the terminal
            // tool merges with the reply, so the line can land anywhere in it.
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("session_id:") else { return true }
                let value = trimmed.dropFirst("session_id:".count).trimmingCharacters(in: .whitespaces)
                guard AgentTalkIdentity.isSessionID(value), !value.contains(" ") else { return true }
                sessionID = value
                return false
            }
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = AgentTalkIncomingMessage.parse(joined)?.body ?? joined
            guard lifecycle != .failed, exitCode == 0, !text.isEmpty else {
                return AgentTalkReply(outcome: .failed, text: nil, sessionID: sessionID)
            }
            return AgentTalkReply(outcome: .answered, text: text, sessionID: sessionID)
        }
    }
}

/// A message an agent sent into this chat. Hermes signs them
/// "Message from 🤖 Name (@handle): …" (`message_agent`), and agents
/// asked to message each other use the same signature.
struct AgentTalkIncomingMessage: Equatable, Sendable {
    let senderName: String
    let senderID: String
    /// The words after the signature. With a comma ("…(@nova), on behalf
    /// of…") the whole message stays, because the signature runs into it.
    let body: String

    static func parse(_ text: String) -> AgentTalkIncomingMessage? {
        let range = NSRange(text.startIndex..., in: text)
        guard text.hasPrefix("Message from") || text.drop(while: \.isWhitespace).hasPrefix("Message from"),
              let match = expression.firstMatch(in: text, range: range),
              let nameRange = Range(match.range(at: 1), in: text),
              let handleRange = Range(match.range(at: 2), in: text),
              let separatorRange = Range(match.range(at: 3), in: text),
              let senderID = AgentTalkIdentity.agentID(fromHandle: String(text[handleRange])) else { return nil }
        let name = text[nameRange].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let rest = text[match.range.upperBound(in: text)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text[separatorRange] == ":" ? rest : text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return AgentTalkIncomingMessage(senderName: name, senderID: senderID, body: body)
    }

    // swiftlint:disable:next force_try
    private static let expression = try! NSRegularExpression(
        pattern: #"^\s*Message from (?:\x{1F916}\x{FE0F}?\s*)?([^\n()@]{1,64}?)\s*\(@([A-Za-z0-9][A-Za-z0-9_./@-]{0,127})\)\s*([:,])"#)
}

/// The answer to a `message_agent` message. Hermes runs the delivery as a
/// background process and, when it ends, adds its notice to the chat:
/// "[IMPORTANT: Background process proc_… exited (exit code 0).\nCommand: …
/// bot_mode_dm.py --run-delivery … hermes -p havok chat …\nOutput:\n<reply>]".
struct AgentTalkDelivery: Equatable, Sendable {
    /// Matches the `process_id` the `message_agent` call returned.
    let processID: String
    /// The agent that answered, when the delivery command names it.
    let targetID: String?
    let succeeded: Bool
    /// The other agent's words.
    let reply: String?

    static func parse(_ text: String) -> AgentTalkDelivery? {
        guard text.hasPrefix("[IMPORTANT: Background process "), text.contains("--run-delivery"),
              text.contains("bot_mode_dm"),
              let header = text.firstMatch(of: /^\[IMPORTANT: Background process ([A-Za-z0-9_.-]{1,128}) [^\n]*\(exit code (-?\d+|\?)/),
              let commandLine = text.firstMatch(of: /\nCommand: ([^\n]*)\n/),
              let outputStart = text.range(of: "\nOutput:\n") else { return nil }
        let command = String(commandLine.1)
        guard command.contains("bot_mode_dm"), command.contains("--run-delivery") else { return nil }
        var output = String(text[outputStart.upperBound...])
        if output.hasSuffix("]") { output.removeLast() }
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // A relayed answer says who it is from first: "Reply from @x on studio:".
        if let relayed = output.firstMatch(of: /^Reply from @[A-Za-z0-9_.\/@-]{1,128}(?: on [^\n:]{1,64})?:\s*/) {
            output = String(output[relayed.range.upperBound...])
        }
        output = AgentTalkIncomingMessage.parse(output)?.body ?? output
        let target = AgentTalkShellWords.commands(in: command)?.lazy.compactMap { words -> String? in
            guard let start = words.firstIndex(where: { $0.split(separator: "/").last == "hermes" }) else { return nil }
            return AgentTalkCall.parse(toolName: "terminal", arguments: Self.terminalArguments(
                Array(words[start...])))?.targetID
        }.first
        let succeeded = header.2 == "0"
        return AgentTalkDelivery(processID: String(header.1), targetID: target, succeeded: succeeded,
                                 reply: succeeded && !output.isEmpty ? output : nil)
    }

    private static func terminalArguments(_ words: [String]) -> String? {
        // Quote each word again so the shell reading gives back the same words.
        let command = words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        guard let data = try? JSONSerialization.data(withJSONObject: ["command": command]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Agent IDs as Hermes routes them.
enum AgentTalkIdentity {
    /// `@nova` and `nova` are the nova profile; `hermes` is Hermes' alias
    /// for the default agent. Peers keep their `<computer>/<agent>` label.
    static func agentID(fromHandle raw: String) -> String? {
        let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "@" }
        guard !handle.isEmpty, handle.count <= 128,
              handle.unicodeScalars.allSatisfy(isHandleScalar),
              let first = handle.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return nil }
        let lowered = handle.lowercased()
        return lowered == "hermes" ? "default" : lowered
    }

    /// A Hermes profile on this computer, as the plugin accepts it (`^[a-z0-9][a-z0-9_-]{0,63}$`).
    static func isProfileID(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, value.unicodeScalars.count <= 64 else { return false }
        func isLowerAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
        }
        return isLowerAlphanumeric(first) && value.unicodeScalars.allSatisfy { isLowerAlphanumeric($0) || $0 == "_" || $0 == "-" }
    }

    static func peerTarget(_ raw: String) -> String? {
        agentID(fromHandle: raw)
    }

    static func isSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy(isHandleScalar)
    }

    private static func isHandleScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122: true
        default: "_-./@".unicodeScalars.contains(scalar)
        }
    }
}

/// A shell command's simple commands as words, with quotes resolved, split
/// on `;`, `&&`, `||`, `|`, `&` and line breaks outside quotes. Nil when a
/// quote never closes: a command that can't be read is never guessed at.
enum AgentTalkShellWords {
    static func commands(in command: String) -> [[String]]? {
        guard command.utf8.count <= 131_072 else { return nil }
        var commands: [[String]] = [[]]
        var word = ""
        var inWord = false
        var quote: Character?
        let characters = Array(command)
        var index = 0
        func endWord() {
            if inWord { commands[commands.count - 1].append(word) }
            word = ""
            inWord = false
        }
        func endCommand() {
            endWord()
            if commands.last?.isEmpty == false { commands.append([]) }
        }
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open {
                    quote = nil
                } else if open == "\"", character == "\\", index + 1 < characters.count,
                          "\"\\$`".contains(characters[index + 1]) || characters[index + 1].isNewline {
                    index += 1
                    if !characters[index].isNewline { word.append(characters[index]) }
                } else {
                    word.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character == "\\" {
                if index + 1 < characters.count {
                    index += 1
                    if !characters[index].isNewline {
                        word.append(characters[index])
                        inWord = true
                    }
                }
            } else if character == "&", word.hasSuffix(">") || (index + 1 < characters.count && characters[index + 1] == ">") {
                // `2>&1` and `&>` redirect; they don't end the command.
                word.append(character)
                inWord = true
            } else if character == ";" || character == "&" || character == "|" || character.isNewline {
                endCommand()
            } else if character.isWhitespace {
                endWord()
            } else if character == "#", !inWord {
                while index + 1 < characters.count, !characters[index + 1].isNewline { index += 1 }
            } else {
                word.append(character)
                inWord = true
            }
            index += 1
        }
        guard quote == nil else { return nil }
        endWord()
        return commands.filter { !$0.isEmpty }
    }
}

extension ChatActivityEvent {
    /// This tool call is one agent messaging another (`AgentTalkCall`).
    var agentTalkCall: AgentTalkCall? {
        guard kind == .tool else { return nil }
        let name = toolName?.lowercased()
        guard name == "terminal" || name == "message_agent" else { return nil }
        return AgentTalkCall.parse(toolName: name, arguments: arguments)
    }

    var agentTalkReply: AgentTalkReply? {
        agentTalkCall.flatMap { AgentTalkReply.parse($0, result: result, lifecycle: lifecycle) }
    }
}

private extension NSRange {
    func upperBound(in text: String) -> String.Index {
        Range(self, in: text)?.upperBound ?? text.endIndex
    }
}
