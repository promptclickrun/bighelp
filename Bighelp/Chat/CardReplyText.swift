import Foundation

/// The message a card sends for the person when they answer it: plain words
/// both they and the agent can read, so it needs no special handling on the host.
enum CardReplyText {
    struct Answer: Equatable {
        let label: String
        let text: String
    }

    /// "My answers to “Trip”:" then one line per answered field.
    static func form(title: String, answers: [Answer]) -> String {
        let lines = answers.compactMap { answer -> String? in
            let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Keep a long answer's own lines readable under its label.
            return "- \(answer.label): " + text.replacingOccurrences(of: "\n", with: "\n  ")
        }
        let heading = "My answers to “\(title)”:"
        return ([heading] + (lines.isEmpty ? ["- (I left everything blank.)"] : lines)).joined(separator: "\n")
    }

    /// The chosen options' replies, as the agent wrote them, one per line.
    static func selection(_ replies: [String]) -> String {
        replies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// One form value in plain words: option labels instead of IDs, Yes or No,
    /// a written-out date.
    static func value(
        _ value: BighelpJSONValue?,
        kind: String,
        options: [(id: String, label: String)]
    ) -> String {
        guard let value else { return "" }
        func label(_ id: String) -> String { options.first { $0.id == id }?.label ?? id }
        switch (kind, value) {
        case ("toggle", .boolean(let on)):
            return on ? "Yes" : "No"
        case ("select", .string(let id)):
            return label(id)
        case ("multi_select", .array(let ids)):
            let labels = ids.compactMap(\.string).map(label)
            return labels.isEmpty ? "None" : labels.joined(separator: ", ")
        case ("date", .string(let day)):
            return GenerativeUIFormDate().date(from: day).map { $0.formatted(date: .long, time: .omitted) } ?? day
        case (_, .integer(let number)):
            return String(number)
        case (_, .number(let number)):
            return number.formatted(.number.grouping(.never))
        case (_, .string(let text)):
            return text
        default:
            return value.displayText ?? ""
        }
    }
}
