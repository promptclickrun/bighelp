import UIKit

/// A text file on the Hermes computer, as the Markdown viewer reads it.
struct HostTextFile: Equatable, Sendable {
    /// The path Hermes resolved.
    let path: String
    let text: String
    /// Hermes sends the first 512 KB; a longer file opens read-only.
    let isTruncated: Bool
    let isBinary: Bool

    static let maximumSaveBytes = 524_288

    var isEditable: Bool { !isTruncated && !isBinary }
}

/// Reads and saves text files on the Hermes computer: Hermes' own `/api/fs/read-text`
/// and `/api/fs/write-text`, or the demo's files.
@MainActor
protocol HostTextFileAccess: AnyObject {
    func read(_ path: String) async throws -> HostTextFile
    func write(_ path: String, text: String) async throws
}

/// The selected computer's files, as one agent (profile) sees them.
@MainActor
final class LiveHostTextFiles: HostTextFileAccess {
    private let client: DirectHermesWorkspaceClient
    private let owner: WorkspaceOwner
    private let profileID: String

    init(client: DirectHermesWorkspaceClient, owner: WorkspaceOwner, profileID: String) {
        self.client = client
        self.owner = owner
        self.profileID = profileID
    }

    func read(_ path: String) async throws -> HostTextFile {
        let response = try await client.readTextFile(path: path, profileID: profileID, owner: owner)
        guard let object = response.object, let text = object["text"]?.string else {
            throw WorkspaceClientError.invalidResponse
        }
        return HostTextFile(path: object["path"]?.string ?? path, text: text,
                            isTruncated: object["truncated"]?.boolean == true,
                            isBinary: object["binary"]?.boolean == true)
    }

    func write(_ path: String, text: String) async throws {
        let response = try await client.writeTextFile(path: path, text: text, profileID: profileID, owner: owner)
        guard response.object?["ok"]?.boolean == true else { throw WorkspaceClientError.outcomeUnknown }
    }
}

/// The demo computer's files: a plan and a README, kept in memory for the run.
@MainActor
final class DemoHostTextFiles: HostTextFileAccess {
    static let shared = DemoHostTextFiles()

    /// The plan the demo's Plan-mode sessions "write".
    static let planPath = ".hermes/plans/2026-10-13_091500-usage-loading-state.md"

    private var files: [String: String] = [
        DemoHostTextFiles.planPath: """
        # Usage loading state

        **Goal:** show a calm placeholder while the Usage page loads, instead of an empty chart.

        ## Steps

        1. Add `UsageLoadingView` with three grey bars, the chart's height.
        2. Show it in `UsageView` while `UsageStore.isLoading` is true.
        3. Keep the last chart on screen during a refresh.

        ## Tests

        - [ ] `UsageViewTests.showsPlaceholderWhileLoading`
        - [ ] `UsageViewTests.keepsChartDuringRefresh`

        ## Risks

        - Reduce Motion: the placeholder must not shimmer.
        """,
        "README.md": """
        # bighelp

        A sample project for the demo. Open **Changes** to see what a session did.
        """,
    ]

    func read(_ path: String) async throws -> HostTextFile {
        guard let text = files[Self.key(path)] else { throw WorkspaceClientError.invalidRequest }
        return HostTextFile(path: path, text: text, isTruncated: false, isBinary: false)
    }

    func write(_ path: String, text: String) async throws {
        files[Self.key(path)] = text
    }

    /// Demo paths are matched by their end, so a worktree's copy reads the same file.
    private static func key(_ path: String) -> String {
        for known in [planPath, "README.md"] where path == known || path.hasSuffix("/" + known) { return known }
        return path
    }
}

/// Markdown file paths in chat text become links that open the viewer. The link carries
/// the path as the agent wrote it; the chat resolves it against its session's folder.
enum HostFileLink {
    static let scheme = "bighelp-file"

    static func url(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    static func path(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "open" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "path" }?.value
    }

    /// Paths ending in `.md` or `.markdown`, like `plan.md`, `~/notes/x.md` or
    /// `/Users/me/repo/.hermes/plans/y.md`. A path with spaces, or part of a web address, isn't one.
    static func markdownPathRanges(in text: String) -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![\w/.~:-])(?:~/|/|\./|\.\./)?(?:[\w.-]+/)*[\w.-]+\.(?:md|markdown)(?![\w/])"#,
            options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { Range($0.range, in: text) }
    }

    /// An absolute or `~` path stays; anything else is inside `folder`.
    static func resolve(_ path: String, in folder: String?) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~/") { return path }
        guard let folder, !folder.isEmpty else { return path }
        var relative = path
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        return (folder.hasSuffix("/") ? folder : folder + "/") + relative
    }

    /// Links each Markdown path in `text` that isn't part of a link already.
    static func addLinks(to text: NSMutableAttributedString, color: UIColor) {
        let string = text.string
        for range in markdownPathRanges(in: string) {
            let span = NSRange(range, in: string)
            guard text.attribute(.link, at: span.location, effectiveRange: nil) == nil,
                  let url = url(for: String(string[range])) else { continue }
            text.addAttributes([.link: url, .foregroundColor: color,
                                .underlineStyle: NSUnderlineStyle.single.rawValue], range: span)
        }
    }

    static func isMarkdown(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }
}
