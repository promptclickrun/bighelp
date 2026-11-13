import Foundation

/// Hermes' run errors in plain words. The raw text (a worker's exit code and
/// its last output) stays available under Show details.
enum KanbanFailure {
    static func explain(_ error: String) -> String {
        let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("timed out") || lower.contains("max_runtime") || lower.contains("exceeded max runtime") {
            return "It ran longer than it's allowed to and was stopped."
        }
        if lower.hasPrefix("workspace:") {
            return "Its folder isn't set up: " + clipped(String(text.dropFirst("workspace:".count)))
        }
        if let problem = lastError(in: text) {
            if let module = missingModule(in: problem) {
                return "The bot couldn't start on your computer: Python can't find \"\(module)\". Hermes may need to be reinstalled or updated there."
            }
            return "The bot stopped with an error: " + clipped(problem)
        }
        if let code = exitCode(in: text) {
            return "The bot stopped unexpectedly (exit code \(code))."
        }
        return clipped(text)
    }

    /// "ModuleNotFoundError: No module named 'x'" and the like: the last line
    /// in the worker's output that names an error.
    static func lastError(in text: String) -> String? {
        let pattern = #"([A-Z][A-Za-z]*(?:Error|Exception)): ([^\n"()]+(?:\([^)]*\))?[^\n"()]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = matches.last, let range = Range(last.range, in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func missingModule(in problem: String) -> String? {
        guard problem.hasPrefix("ModuleNotFoundError"),
              let start = problem.range(of: "No module named '")?.upperBound,
              let end = problem[start...].firstIndex(of: "'") else { return nil }
        return String(problem[start..<end])
    }

    private static func exitCode(in text: String) -> Int? {
        guard let range = text.range(of: "exited with code ") else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber || $0 == "-" })
    }

    private static func clipped(_ text: String, limit: Int = 220) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
