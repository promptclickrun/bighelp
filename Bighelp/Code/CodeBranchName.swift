import Foundation

/// Bighelp IDE names a new worktree's branch from the message that starts it:
/// "Make the Kanban lanes scroll on iPad" → `code/make-kanban-lanes-scroll-ipad`.
/// The worktree's folder takes the part after `code/`.
enum CodeBranchName {
    static let prefix = "code/"

    /// The suggested branch, never one of `taken` (the repository's local branches).
    static func suggested(for message: String, taken: Set<String> = []) -> String {
        let slug = slug(for: message)
        var branch = prefix + slug
        var suffix = 2
        while taken.contains(branch) {
            branch = "\(prefix)\(slug)-\(suffix)"
            suffix += 1
        }
        return branch
    }

    /// The worktree folder for `branch`: its last part, in the characters Hermes accepts.
    static func worktreeName(for branch: String) -> String {
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        var name = Substring(String(last.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "-" }))
        // Never starting or ending with "-" or ".": git would read the folder as an option or a hidden file.
        // (Plain character checks: Foundation's CharacterSet misjudged simple ASCII on one iPhone.)
        while let first = name.first, first == "-" || first == "." { name = name.dropFirst() }
        while let end = name.last, end == "-" || end == "." { name = name.dropLast() }
        return name.isEmpty ? "session" : String(name.prefix(80))
    }

    /// Up to five words that say what the change is, lowercase ASCII joined by "-".
    private static func slug(for text: String) -> String {
        let words = text.lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .map(String.init)
            .filter { !fillerWords.contains($0) }
        var slug = ""
        for word in words.prefix(5) {
            let next = slug.isEmpty ? word : slug + "-" + word
            guard next.count <= maximumSlugLength else { break }
            slug = next
        }
        if slug.isEmpty, let first = words.first { slug = String(first.prefix(maximumSlugLength)) }
        return slug.isEmpty ? "session" : slug
    }

    private static let maximumSlugLength = 40

    private static let fillerWords: Set<String> = [
        "a", "an", "the", "to", "of", "and", "or", "for", "in", "on", "at", "with", "when", "is", "are", "be",
        "it", "its", "this", "that", "my", "our", "please", "can", "could", "would", "you", "we", "i", "so",
    ]
}
