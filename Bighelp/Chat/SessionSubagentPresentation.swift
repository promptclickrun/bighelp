import Foundation

enum SessionSubagentRosterPresentation {
    struct Card: Equatable, Sendable {
        let name: String
        let summary: String
    }

    static let maximumNameLength = 52
    static let maximumSummaryLength = 96

    static func card(for subagent: SessionSubagentSnapshot) -> Card {
        let sentence = firstTaskSentence(in: subagent.goal)
        let action = taskAction(in: sentence)
        let topic = action.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameTopic = droppingLeadingArticle(topic)
        let nameSource = nameTopic.isEmpty ? friendlyFallback(role: subagent.role) : nameTopic
        let name = bounded(
            nameSource.localizedCapitalized,
            maximum: maximumNameLength
        )
        let summarySource = topic.isEmpty
            ? sentence
            : "\(action.verb) \(topic.lowercased())."
        return Card(
            name: name,
            summary: bounded(summarySource, maximum: maximumSummaryLength)
        )
    }

    private static func firstTaskSentence(in goal: String) -> String {
        var normalized = goal
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if normalized.lowercased().hasPrefix("in /"),
           let comma = normalized.firstIndex(of: ",") {
            normalized = String(normalized[normalized.index(after: comma)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return normalized
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func taskAction(in sentence: String) -> (verb: String, topic: String) {
        let lowercased = sentence.lowercased()
        for (marker, verb) in [
            (" correction for ", "Improving"),
            (" fix for ", "Fixing"),
        ] {
            if let range = lowercased.range(of: marker) {
                let topicStart = range.upperBound
                return (
                    verb,
                    String(sentence[topicStart...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        for (prefix, verb) in [
            ("review ", "Reviewing"),
            ("audit ", "Auditing"),
            ("test ", "Testing"),
            ("verify ", "Verifying"),
            ("implement ", "Implementing"),
        ] where lowercased.hasPrefix(prefix) {
            let start = sentence.index(sentence.startIndex, offsetBy: prefix.count)
            return (
                verb,
                String(sentence[start...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return ("Working on", sentence)
    }

    private static func droppingLeadingArticle(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("the ") {
            return String(trimmed.dropFirst(4))
        }
        return trimmed
    }

    private static func friendlyFallback(role: String) -> String {
        let normalized = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let genericRoles = ["agent", "child", "leaf", "subagent", "worker"]
        return genericRoles.contains(normalized.lowercased()) ? "Subagent Task" : normalized
    }

    private static func bounded(_ text: String, maximum: Int) -> String {
        guard text.count > maximum else { return text }
        let prefix = String(text.prefix(maximum - 1))
        let breakIndex = prefix.lastIndex(where: { $0.isWhitespace })
        let bounded = breakIndex.map { String(prefix[..<$0]) } ?? prefix
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

enum SessionSubagentDetailPresentation: Equatable {
    case waiting
    case live
    case completed
    case failed
    case cancelled
    case recorded

    static func state(for record: SessionRecord) -> Self {
        if record.hasActiveWork { return .live }
        guard let latest = record.activityEvents.last else {
            return .completed
        }
        switch latest.lifecycle {
        case .running: return .live
        case .succeeded: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .recorded: return .recorded
        }
    }

    static func shouldShowWaiting(for record: SessionRecord?) -> Bool {
        record == nil
    }

    static func statusTitle(for record: SessionRecord) -> String {
        switch state(for: record) {
        case .waiting: return "Waiting for child session"
        case .live: return "Active subagent"
        case .completed: return "Completed child session"
        case .failed: return "Failed child session"
        case .cancelled: return "Cancelled child session"
        case .recorded: return "Saved child session; outcome unavailable"
        }
    }
}
