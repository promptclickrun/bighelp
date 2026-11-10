import Foundation
import UIKit

/// One name in a folder on the Hermes computer.
struct HostFolderEntry: Identifiable, Hashable, Sendable {
    /// The full path Hermes gave it.
    let path: String
    let name: String
    let isDirectory: Bool

    var id: String { path }

    /// How a chat's Files shows a file: read as text, drawn as a picture, or rendered as Markdown.
    enum Preview: Equatable, Sendable { case markdown, picture, text }

    var preview: Preview {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown": .markdown
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif": .picture
        default: .text
        }
    }
}

/// A picture on the Hermes computer, read whole to show in a chat's Files.
enum HostPictureFile {
    /// Hermes sends a picture as a base64 data URL, a third bigger than the picture. This allows
    /// a picture of about 8 MB; a bigger one says it can't show here.
    static let maximumResponseBytes = 12 * 1_024 * 1_024

    /// The bytes inside a `data:<type>;base64,<bytes>` URL.
    static func data(fromDataURL text: String) -> Data? {
        guard text.hasPrefix("data:"), let comma = text.firstIndex(of: ","),
              text[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(text[text.index(after: comma)...]))
    }
}

/// Folders on the Hermes computer for a chat's Files (#944): Hermes' own `/api/fs/*`
/// routes as the chat's agent sees the computer, or the demo's folders.
@MainActor
protocol HostFolderAccess: AnyObject {
    /// The folder this chat works in: its session's own, else the agent's.
    func workingFolder() async -> String
    /// What `path` holds, folders first. Hermes expands "~" and leaves out what it keeps private.
    func list(_ path: String) async throws -> [HostFolderEntry]
    func picture(_ path: String) async throws -> Data
}

/// What a chat's Files needs: the folders, and the text files in them.
struct ChatFolderContext {
    let folders: any HostFolderAccess
    let files: any HostTextFileAccess
}

@MainActor
final class LiveHostFolders: HostFolderAccess {
    private let client: DirectHermesWorkspaceClient
    private let owner: WorkspaceOwner
    private let profileID: String
    /// The folder Hermes says the chat's session runs in, when the app knows it.
    private let sessionFolder: String?

    init(client: DirectHermesWorkspaceClient, owner: WorkspaceOwner, profileID: String, sessionFolder: String?) {
        self.client = client
        self.owner = owner
        self.profileID = profileID
        self.sessionFolder = sessionFolder
    }

    func workingFolder() async -> String {
        if let sessionFolder, HermesFolderPath.isAccepted(sessionFolder) { return sessionFolder }
        // An older Hermes has no default-cwd route: home is always there.
        let answer = try? await client.defaultFolder(profileID: profileID, owner: owner)
        guard let folder = answer?.object?["cwd"]?.string, HermesFolderPath.isAccepted(folder) else { return "~" }
        return folder
    }

    func list(_ path: String) async throws -> [HostFolderEntry] {
        try Self.entries(try await client.listFolder(path: path, profileID: profileID, owner: owner))
    }

    func picture(_ path: String) async throws -> Data {
        let answer = try await client.readFileDataURL(path: path, profileID: profileID, owner: owner)
        guard let text = answer.object?["dataUrl"]?.string, let data = HostPictureFile.data(fromDataURL: text) else {
            throw WorkspaceClientError.invalidResponse
        }
        return data
    }

    /// Hermes' listing, read leniently: a row the app can't read hides only itself.
    static func entries(_ response: BighelpJSONValue) throws -> [HostFolderEntry] {
        guard let object = response.object else { throw WorkspaceClientError.invalidResponse }
        if let code = object["error"]?.string, !code.isEmpty { throw WorkspaceClientError.rejected(code: code) }
        guard let rows = object["entries"]?.array else { throw WorkspaceClientError.invalidResponse }
        let entries = rows.prefix(maximumEntries).compactMap { row -> HostFolderEntry? in
            guard let entry = row.object, let name = entry["name"]?.string, let path = entry["path"]?.string,
                  !name.isEmpty, !path.isEmpty, path.utf8.count <= 4_096 else { return nil }
            return HostFolderEntry(path: path, name: name, isDirectory: entry["isDirectory"]?.boolean == true)
        }
        return sorted(entries)
    }

    /// One folder's rows; a bigger folder shows its first names.
    static let maximumEntries = 5_000

    static func sorted(_ entries: [HostFolderEntry]) -> [HostFolderEntry] {
        entries.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}

/// A chat's Files (#944): the chat's working folder on the computer as a tree that opens a
/// folder at a time, a path field that shows any other folder, and a search of the names loaded.
@MainActor
@Observable
final class ChatFolderBrowserModel {
    struct Row: Identifiable, Equatable {
        let entry: HostFolderEntry
        /// How far inside the folder on show: 0 for its own names.
        let depth: Int
        /// Where a search result is, inside the folder on show ("src/api"); nil in the tree.
        var place: String?

        var id: String { entry.path }
    }

    /// The folder on show, as Hermes spells it once it has listed it.
    private(set) var root: String?
    private(set) var workingFolder: String?
    /// The path field's text.
    var pathText = ""
    var search = ""
    /// Names that start with a dot (".git", ".env") stay out of the way until asked for.
    var showsHidden = false
    private(set) var isLoading = false
    /// Why the folder on show didn't open, in plain words.
    private(set) var rootMessage: String?
    private(set) var expanded: Set<String> = []
    private(set) var loading: Set<String> = []
    private(set) var folderMessages: [String: String] = [:]

    @ObservationIgnored private var children: [String: [HostFolderEntry]] = [:]
    /// Bumped with `children`, which the rows are made from.
    private var revision = 0
    @ObservationIgnored private let access: any HostFolderAccess
    /// Only the newest request for the folder on show may land.
    @ObservationIgnored private var request = 0

    init(access: any HostFolderAccess) {
        self.access = access
    }

    var isAtWorkingFolder: Bool { root != nil && root == workingFolder }
    var canGoUp: Bool { root.flatMap(HermesFolderPath.parent(of:)) != nil }

    /// How many names in the folder on show start with a dot.
    var hiddenCount: Int {
        _ = revision
        return root.flatMap { children[$0] }?.count { $0.name.hasPrefix(".") } ?? 0
    }

    /// The tree as rows; while searching, every loaded name that matches, with where it is.
    var rows: [Row] {
        _ = revision
        guard let root, let top = children[root] else { return [] }
        let match = search.trimmingCharacters(in: .whitespaces).lowercased()
        // A search that starts with a dot is a search for hidden names.
        let showsHidden = showsHidden || match.hasPrefix(".")
        var rows: [Row] = []
        func add(_ entries: [HostFolderEntry], depth: Int, place: String?) {
            for entry in entries where showsHidden || !entry.name.hasPrefix(".") {
                if match.isEmpty {
                    rows.append(Row(entry: entry, depth: depth))
                } else if entry.name.lowercased().contains(match) {
                    rows.append(Row(entry: entry, depth: 0, place: place))
                }
                // A search looks through every folder that was opened; the tree, only the open ones.
                if entry.isDirectory, let inside = children[entry.path], !match.isEmpty || expanded.contains(entry.path) {
                    add(inside, depth: depth + 1, place: place.map { "\($0)/\(entry.name)" } ?? entry.name)
                }
            }
        }
        add(top, depth: 0, place: nil)
        return rows
    }

    /// Opens the chat's working folder, once.
    func start() async {
        guard root == nil, !isLoading else { return }
        isLoading = true
        let folder = await access.workingFolder()
        workingFolder = folder
        await open(folder)
        // The session's folder can be gone (a removed worktree): home is always there.
        if root == nil, rootMessage != nil, folder != "~" {
            workingFolder = "~"
            await open("~")
        }
    }

    func openWorkingFolder() async {
        guard let workingFolder else { return await start() }
        await open(workingFolder)
    }

    func goUp() async {
        guard let parent = root.flatMap(HermesFolderPath.parent(of:)) else { return }
        await open(parent)
    }

    /// The path field's folder: a full or "~" path, or one inside the folder on show.
    func submitPath() async {
        let typed = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            pathText = root ?? ""
            return
        }
        guard !typed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              typed.utf8.count <= 4_096 else {
            rootMessage = "That isn't a folder path."
            return
        }
        await open(HermesFolderPath.isAccepted(typed) ? typed : HostFileLink.resolve(typed, in: root))
    }

    /// Shows `path` in place of the folder on show. Its old tree stays until the new one lands.
    func open(_ path: String) async {
        request += 1
        let current = request
        isLoading = true
        rootMessage = nil
        defer { if current == request { isLoading = false } }
        do {
            let entries = try await access.list(path)
            guard current == request else { return }
            // Hermes answers with full paths, which is how a "~" path gets its real name.
            let resolved = entries.first.flatMap { HermesFolderPath.parent(of: $0.path) } ?? path
            if workingFolder == path { workingFolder = resolved }
            children = [resolved: entries]
            expanded = []
            loading = []
            folderMessages = [:]
            root = resolved
            pathText = resolved
            search = ""
            revision += 1
        } catch is CancellationError {
        } catch {
            guard current == request else { return }
            rootMessage = Self.message(for: error)
        }
    }

    /// Opens a folder in the tree, reading it the first time, or closes it.
    func toggle(_ entry: HostFolderEntry) async {
        guard entry.isDirectory else { return }
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
            return
        }
        expanded.insert(entry.path)
        guard children[entry.path] == nil, !loading.contains(entry.path) else { return }
        loading.insert(entry.path)
        folderMessages[entry.path] = nil
        let current = request
        // Another folder may go on show while this one is read: then its tree is not this one's to touch.
        defer { if current == request { loading.remove(entry.path) } }
        do {
            let entries = try await access.list(entry.path)
            guard current == request else { return }
            children[entry.path] = entries
            revision += 1
        } catch is CancellationError {
            if current == request { expanded.remove(entry.path) }
        } catch {
            guard current == request else { return }
            folderMessages[entry.path] = Self.message(for: error)
        }
    }

    func isEmptyFolder(_ entry: HostFolderEntry) -> Bool {
        _ = revision
        return children[entry.path]?.isEmpty == true
    }

    static func message(for error: any Error) -> String {
        switch error {
        case WorkspaceClientError.rejected(code: "ENOENT", _): "There's no folder at that path."
        case WorkspaceClientError.rejected(code: "ENOTDIR", _): "That path is a file, not a folder."
        case WorkspaceClientError.rejected(code: "EACCES", _): "Hermes isn't allowed to open that folder."
        case WorkspaceClientError.ownerChanged: "The connection changed. Close Files and open it again."
        default: "That folder couldn't open. Check the path and your connection, then try again."
        }
    }
}

/// The demo computer's folders: a small made-up project, kept in memory for the run. It reads
/// its own text files too, so every file in the tree opens.
@MainActor
final class DemoHostFolders: HostFolderAccess, HostTextFileAccess {
    static let shared = DemoHostFolders()

    static let home = "/Users/demo"
    static let project = "/Users/demo/Projects/weather-app"

    private var files: [String: String] = [
        "\(project)/README.md": """
        # Weather app

        A small forecast app for the demo.

        ## Setup

        1. Install Node 22.
        2. Run `npm install`.
        3. Run `npm test`.
        """,
        "\(project)/SUMMARY.md": "# Summary\n\nBuilds on Node 22. 42 tests pass.\n",
        "\(project)/notes.md": "# Notes\n\n- cache.test.ts is flaky on slow networks\n- units default to metric\n",
        "\(project)/package.json": """
        {
          "name": "weather-app",
          "version": "1.4.0",
          "scripts": { "test": "vitest run" }
        }
        """,
        "\(project)/src/forecast.ts": """
        export function forecast(city: string, days = 3): string {
          return `${city}: mild for ${days} days`
        }
        """,
        "\(project)/src/units.ts": "export const defaultUnits = \"metric\"\n",
        "\(project)/src/api/client.ts": "export const baseURL = \"https://api.example.com/weather\"\n",
        "\(project)/tests/forecast.test.ts": "import { forecast } from \"../src/forecast\"\n",
        "\(project)/assets/icon.png": "",
        "\(project)/.gitignore": "node_modules\n",
        "\(project)/.hermes/plans/2026-10-13-forecast-cache.md": "# Forecast cache\n\n1. Keep the last answer for ten minutes.\n",
        "\(home)/Projects/travel/budget.csv": "item,cost\ntrain,84\nhotel,310\n",
        "\(home)/Documents/ideas.txt": "A widget for tomorrow's rain.\n",
    ]

    func workingFolder() async -> String { Self.project }

    func list(_ path: String) async throws -> [HostFolderEntry] {
        let folder = Self.expanded(path)
        let prefix = folder == "/" ? "/" : folder + "/"
        var names: [String: Bool] = [:]
        for file in files.keys where file.hasPrefix(prefix) {
            let rest = file.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true)
            guard let first = rest.first else { continue }
            names[String(first)] = rest.count > 1 || names[String(first)] == true
        }
        guard !names.isEmpty else {
            throw WorkspaceClientError.rejected(code: files[folder] == nil ? "ENOENT" : "ENOTDIR")
        }
        return LiveHostFolders.sorted(names.map { name, isDirectory in
            HostFolderEntry(path: prefix + name, name: name, isDirectory: isDirectory)
        })
    }

    func picture(_ path: String) async throws -> Data {
        guard files[Self.expanded(path)] != nil else { throw WorkspaceClientError.invalidRequest }
        let side: CGFloat = 240
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 70, y: 70, width: 100, height: 100))
        }
    }

    func read(_ path: String) async throws -> HostTextFile {
        let full = Self.expanded(path)
        guard let text = files[full] else { throw WorkspaceClientError.invalidRequest }
        return HostTextFile(path: full, text: text, isTruncated: false, isBinary: false)
    }

    func write(_ path: String, text: String) async throws {
        files[Self.expanded(path)] = text
    }

    private static func expanded(_ path: String) -> String {
        var path = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
