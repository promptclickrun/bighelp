import SwiftUI

/// A job staged in Bighelp IDE's message box, waiting for Send all. It keeps the
/// chips it was staged with (where it runs, branch, model, mode).
struct CodeStagedJob: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let message: String
    let agentID: String
    let projectID: String
    let placement: CodePlacement
    /// As `CodeLaunchRequest.branch`: the base for a new worktree, the branch for Local.
    let branch: String?
    let newBranch: String?
    let runtime: CodeRuntimeChoice
    let mode: CodeSessionMode

    var title: String { CodeSessionTitle.from(message) }
}

/// Jobs sent together with Send all (Orchestration mode): one card on the IDE home and
/// one chat for all of them. The app combines the sessions; each stays an ordinary
/// Hermes session underneath.
struct CodeBatch: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let projectID: String
    /// The first job's name until the person renames it.
    var title: String
    let createdAt: Date
    let jobCount: Int
    /// Session IDs in send order, added as each session starts.
    var sessionIDs: [String]
    /// What was sent from the batch chat, oldest first.
    var messages: [CodeBatchMessage]

    static let maximumMessages = 100

    /// The first job names the batch; its card says how many sessions it has.
    static func title(for jobs: [CodeStagedJob]) -> String {
        jobs.first?.title ?? "Batch"
    }
}

/// One message sent from a batch chat, and the sessions it went to.
struct CodeBatchMessage: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// As typed, mentions and all.
    let text: String
    let sessionIDs: [String]
    let sentAt: Date
}

/// A batch session as the batch chat names and colors it.
struct CodeBatchMember: Identifiable, Equatable {
    let id: String
    /// What `#` inserts and the pills show: two words of the session's name.
    let name: String
    let index: Int
    let branch: String?
    let title: String

    var color: Color { CodeSessionColor.color(at: index) }

    /// Members in batch order, with names that never repeat.
    static func members(of batch: CodeBatch, sessions: [CodeSessionRecord]) -> [CodeBatchMember] {
        var taken = Set<String>()
        return batch.sessionIDs.enumerated().compactMap { index, id in
            guard let session = sessions.first(where: { $0.id == id }) else { return nil }
            var name = shortName(session.title)
            if taken.contains(name.lowercased()) { name += " \(index + 1)" }
            taken.insert(name.lowercased())
            return CodeBatchMember(id: id, name: name, index: index, branch: session.branch, title: session.title)
        }
    }

    /// "Fix the widget tap when the host is asleep" is "Widget tap".
    static func shortName(_ title: String) -> String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let kept = words.filter { !skipped.contains($0.lowercased()) }
        let chosen = (kept.isEmpty ? words : kept).prefix(2).joined(separator: " ")
        guard let first = chosen.first else { return "Session" }
        return first.uppercased() + chosen.dropFirst()
    }

    private static let skipped: Set<String> = [
        "a", "an", "the", "to", "for", "of", "on", "in", "at", "by", "with", "and", "or", "when", "is", "are", "be",
        "it", "its", "this", "that", "from", "into", "add", "fix", "make", "write", "update", "change", "tighten",
        "please", "can", "you", "new", "use",
    ]
}

/// One color per session in a batch, the same on the home card, the pills and the replies.
enum CodeSessionColor {
    static func color(at index: Int) -> Color {
        palette[index % palette.count]
    }

    private static let palette: [Color] = [
        Color(hex: "9B7BFF"), Color(hex: "F2766A"), Color(hex: "2FB5A6"),
        Color(hex: "E0A33A"), Color(hex: "4E9BF0"), Color(hex: "D9669E"),
    ]
}

/// Where a batch chat message goes, and what each session reads. Session mentions (`#Widget
/// tap`) pick the sessions and drop out of the text; a pull request mention (`#142`) stays,
/// spelled out with its branch, and goes to the session working on that branch. With no
/// mention, the message goes to `fallback` (the target chip: every session, or one).
enum CodeBatchRouting {
    struct Outgoing: Equatable {
        let sessionIDs: [String]
        let text: String
        /// Why a pull request picked its session, for the line over the message box.
        let pullRequestOwners: [Int: String]
    }

    static func route(_ typed: String, members: [CodeBatchMember], pullRequests: [StockGitPullRequest],
                      fallback: [String]) -> Outgoing {
        var text = typed
        var targets: [String] = []
        // Longest names first, so "#Widget tap 2" isn't read as "#Widget tap".
        for member in members.sorted(by: { $0.name.count > $1.name.count }) {
            let token = "#" + member.name
            guard text.range(of: token, options: .caseInsensitive) != nil else { continue }
            text = text.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
            targets.append(member.id)
        }
        var owners: [Int: String] = [:]
        for number in pullRequestNumbers(in: text) {
            guard let pullRequest = pullRequests.first(where: { $0.number == number }) else { continue }
            text = text.replacingOccurrences(of: "#\(number)", with: "pull request #\(number) (branch \(pullRequest.branch))")
            if let owner = members.first(where: { $0.branch == pullRequest.branch }) {
                owners[number] = owner.id
                targets.append(owner.id)
            }
        }
        let cleaned = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var unique: [String] = []
        for id in targets where !unique.contains(id) { unique.append(id) }
        // Batch order, whatever order the mentions came in.
        let ordered = members.map(\.id).filter(unique.contains)
        return Outgoing(sessionIDs: ordered.isEmpty ? fallback : ordered, text: cleaned, pullRequestOwners: owners)
    }

    /// `#142` anywhere, not part of a word.
    static func pullRequestNumbers(in text: String) -> [Int] {
        guard let expression = try? NSRegularExpression(pattern: #"(?<![\w#])#(\d{1,7})\b"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
    }

    /// The `#query` being typed at the end of the text, if any (no space after it yet).
    static func mentionQuery(in text: String) -> String? {
        guard let hash = text.lastIndex(of: "#") else { return nil }
        if hash > text.startIndex {
            let before = text[text.index(before: hash)]
            guard before.isWhitespace else { return nil }
        }
        let query = text[text.index(after: hash)...]
        // Any space closes it: "# " is a heading, a picked mention ends with one, and
        // a two-word name filters fine on its first word.
        guard query.count <= 40, !query.contains(where: \.isWhitespace) else { return nil }
        return String(query)
    }
}
