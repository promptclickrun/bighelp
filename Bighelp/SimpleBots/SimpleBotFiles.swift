import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Where a bot's Files tab reads: the folder its computer shares with bighelp (what Files
/// shows in the full app, through `DirectHermesManagedFilesClient`), or the demo's folders.
@MainActor
protocol SimpleBotFilesSource: AnyObject {
    /// The largest file that opens in the preview.
    var downloadLimit: Int { get }
    func list(agentID: String, path: String?) async throws -> HermesManagedFileDirectory
    func download(agentID: String, file: HermesManagedFile) async throws -> HermesManagedFileContents
    /// Videos and songs the computer can stream (Files' Preview Video), at any size.
    func canStream(agentID: String, file: HermesManagedFile) -> Bool
    func playback(agentID: String, file: HermesManagedFile) -> DirectHermesManagedMediaPlayback?
}

enum SimpleBotFilesError: Error, Equatable {
    /// The computer shares the folder of the agent its bighelp plugin runs as; this is another one.
    case sharedByAnotherBot(String)
}

/// A bot's files on its computer. The bighelp plugin shares one folder: that of the agent it
/// runs as (`servingProfileID`), so another bot's tab never shows it as its own. Each call
/// uses the connection of the moment, so a reconnect needs nothing from the screen.
@MainActor
final class SimpleBotHostFiles: SimpleBotFilesSource {
    /// The computer in use; nil while it's disconnected.
    struct Connection {
        let owner: WorkspaceOwner
        let http: any DirectHermesAuthenticatedHTTP
        let servingProfileID: String?
    }

    private let connection: @MainActor () -> Connection?
    private var client: DirectHermesManagedFilesClient?

    init(connection: @escaping @MainActor () -> Connection?) {
        self.connection = connection
    }

    var downloadLimit: Int {
        currentClient()?.supportsBinaryTransfers == true ? DirectHermesManagedFilesClient.maximumNativeTransferBytes
            : DirectHermesManagedFilesClient.maximumJSONDownloadBytes
    }

    func list(agentID: String, path: String?) async throws -> HermesManagedFileDirectory {
        try await sharedClient(for: agentID).list(path: path)
    }

    func download(agentID: String, file: HermesManagedFile) async throws -> HermesManagedFileContents {
        try await sharedClient(for: agentID).download(file)
    }

    func canStream(agentID: String, file: HermesManagedFile) -> Bool {
        guard connection()?.servingProfileID == agentID, let client = currentClient() else { return false }
        return client.supportsBinaryTransfers && DirectHermesManagedMediaPlayback.supports(file)
    }

    func playback(agentID: String, file: HermesManagedFile) -> DirectHermesManagedMediaPlayback? {
        guard canStream(agentID: agentID, file: file), let client = currentClient() else { return nil }
        return DirectHermesManagedMediaPlayback(file: file, reader: client)
    }

    /// One client per connection: every reconnect is a new owner, which the old client refuses.
    private func currentClient() -> DirectHermesManagedFilesClient? {
        guard let current = connection() else { return nil }
        if let client, client.ownsScope { return client }
        let connection = connection
        let made = DirectHermesManagedFilesClient(
            http: current.http, binaryHTTP: current.http as? any DirectHermesManagedFileBinaryHTTP,
            owner: current.owner, currentOwner: { connection()?.owner })
        client = made
        return made
    }

    private func sharedClient(for agentID: String) async throws -> DirectHermesManagedFilesClient {
        guard let client = currentClient() else { throw WorkspaceClientError.transportUnavailable }
        // A plugin that can't share files says so first, whichever bot asks.
        _ = try await client.workspaceScope()
        try Self.requireShared(agentID: agentID, servingProfileID: connection()?.servingProfileID)
        return client
    }

    static func requireShared(agentID: String, servingProfileID: String?) throws {
        guard let servingProfileID, !servingProfileID.isEmpty else { throw DirectHermesManagedFilesError.scopeUnavailable }
        guard servingProfileID == agentID else { throw SimpleBotFilesError.sharedByAnotherBot(servingProfileID) }
    }
}

/// A bot's photos and videos (the plugin's `attachments/recent`, as the full app's Files › Media
/// reads them), through the connection of the moment, so a reconnect needs nothing from the screen.
@MainActor
final class SimpleBotHostMedia: AgentMediaClient {
    private let connection: @MainActor () -> (workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner)?

    init(connection: @escaping @MainActor () -> (workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner)?) {
        self.connection = connection
    }

    func recent(agentID: String) async throws -> [AgentMediaItem] {
        try await client().recent(agentID: agentID)
    }

    func data(agentID: String, item: AgentMediaItem) async throws -> Data {
        try await client().data(agentID: agentID, item: item)
    }

    private func client() throws -> DirectHermesAgentMediaClient {
        guard let current = connection() else { throw WorkspaceClientError.transportUnavailable }
        return DirectHermesAgentMediaClient(workspace: current.workspace, owner: current.owner)
    }
}

/// What tapping a row does.
enum SimpleBotFileOpening: Equatable {
    case folder, stream, preview, empty, tooBig

    static func decide(_ file: HermesManagedFile, downloadLimit: Int, canStream: Bool) -> Self {
        if file.isDirectory { return .folder }
        if canStream { return .stream }
        guard let size = file.byteCount, size > 0 else { return .empty }
        return size <= min(downloadLimit, ChatAttachment.maximumAgentBytes) ? .preview : .tooBig
    }
}

/// A bot's Files tab: one folder at a time, in its folder on the computer. Files open in the
/// preview chats use (Markdown, pictures, PDFs, Quick Look); videos and songs stream.
@MainActor
@Observable
final class SimpleBotFilesModel {
    enum Phase: Equatable {
        case loading, loaded, needsPluginUpdate, failed(String)
        /// The computer shares this other bot's folder, not this one's.
        case sharedByAnotherBot(String)
    }

    let agentID: String
    private(set) var phase: Phase = .loading
    private(set) var directory: HermesManagedFileDirectory?
    /// The folder's files as shown: folders first, then by name.
    private(set) var entries: [HermesManagedFile] = []
    private(set) var openingPath: String?
    /// A folder or file that didn't open, said under the list that's still shown.
    private(set) var notice: String?
    var preview: ChatAttachment?
    var playback: DirectHermesManagedMediaPlayback?

    @ObservationIgnored private let source: any SimpleBotFilesSource
    @ObservationIgnored private let showsHidden: Bool
    @ObservationIgnored private var generation = 0

    init(agentID: String, source: any SimpleBotFilesSource, showsHidden: Bool = false) {
        self.agentID = agentID
        self.source = source
        self.showsHidden = showsHidden
    }

    /// The bot's top folder, once it has loaded.
    private(set) var rootPath: String?

    var isAtTop: Bool { directory?.parent == nil }
    /// Where the list is, from the top folder: "Reports › 2026".
    var locationTitle: String {
        guard let directory, !isAtTop else { return "All files" }
        return Self.location(of: directory.path, root: rootPath).joined(separator: " › ")
    }
    /// Where Back goes.
    var parentTitle: String {
        guard let parent = directory?.parent else { return "All files" }
        return Self.location(of: parent, root: rootPath).last ?? "All files"
    }

    /// Reloads the folder on screen (the top one the first time), keeping it shown meanwhile.
    func refresh() async {
        await load(path: directory?.path)
    }

    func goUp() async {
        guard let parent = directory?.parent else { return }
        await load(path: parent)
    }

    func open(_ file: HermesManagedFile) async {
        let opening = SimpleBotFileOpening.decide(file, downloadLimit: source.downloadLimit,
                                                  canStream: source.canStream(agentID: agentID, file: file))
        switch opening {
        case .folder:
            await load(path: file.path)
        case .stream:
            notice = nil
            playback = source.playback(agentID: agentID, file: file)
        case .empty:
            notice = "\(file.name) is empty."
        case .tooBig:
            notice = "\(file.name) is too big to open here."
        case .preview:
            await download(file)
        }
    }

    private func load(path: String?) async {
        generation &+= 1
        let request = generation
        if directory == nil { phase = .loading }
        notice = nil
        do {
            let listed = try await source.list(agentID: agentID, path: path)
            guard request == generation else { return }
            directory = listed
            if listed.parent == nil { rootPath = listed.path }
            entries = Self.visible(listed.files, showsHidden: showsHidden)
            phase = .loaded
        } catch is CancellationError {
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            let failed = Self.phase(for: error)
            // A folder that didn't open leaves the one on screen; anything else replaces it.
            if directory != nil, path != nil, case .failed(let message) = failed {
                notice = message
            } else {
                directory = nil
                entries = []
                phase = failed
            }
        }
    }

    private func download(_ file: HermesManagedFile) async {
        guard openingPath == nil else { return }
        let request = generation
        openingPath = file.path
        notice = nil
        defer { if request == generation { openingPath = nil } }
        do {
            let contents = try await source.download(agentID: agentID, file: file)
            guard request == generation else { return }
            preview = try Self.attachment(contents)
        } catch is CancellationError {
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            notice = "\(file.name) didn't open. Try again."
        }
    }

    /// A folder's names below the top folder; just its own name when the top isn't known.
    static func location(of path: String, root: String?) -> [String] {
        let separator: Character = path.hasPrefix("/") ? "/" : "\\"
        if let root, DirectHermesWorkspaceFileScope.contains(root: root, path: path) {
            return path.dropFirst(root.count).split(separator: separator).map(String.init)
        }
        return path.split(separator: separator).last.map { [String($0)] } ?? []
    }

    /// Folders first, then files, each by name the way Finder sorts them. Hidden ones
    /// (a name starting with ".") show only in Nerd Mode.
    static func visible(_ files: [HermesManagedFile], showsHidden: Bool) -> [HermesManagedFile] {
        files.filter { showsHidden || !$0.name.hasPrefix(".") }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func phase(for error: any Error) -> Phase {
        switch error {
        case SimpleBotFilesError.sharedByAnotherBot(let id):
            return .sharedByAnotherBot(id)
        case WorkspaceClientError.unavailable(.unsupportedOperation), WorkspaceClientError.unavailable(.pluginRequired),
             WorkspaceClientError.rejected(code: .some(WorkspaceClientError.workspacePluginOutdated), _):
            return .needsPluginUpdate
        case WorkspaceClientError.rejected(let code, _) where WorkspaceClientError.workspaceFilesMessage(code) != nil:
            return .failed(WorkspaceClientError.workspaceFilesMessage(code) ?? "")
        case let error as DirectHermesManagedFilesError:
            return .failed(error.localizedDescription)
        default:
            return .failed("Files didn't load. Check that your computer is on, then try again.")
        }
    }

    /// The file as chats hold one, so it opens in the same preview.
    static func attachment(_ contents: HermesManagedFileContents) throws -> ChatAttachment {
        let digest = SHA256.hash(data: Data(contents.file.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return try .agentArtifact(id: "file_" + digest, fileName: contents.file.name,
                                  mimeType: mimeType(for: contents.file), data: contents.bytes)
    }

    static func mimeType(for file: HermesManagedFile) -> String {
        if let type = file.mimeType?.lowercased(), !type.isEmpty { return type }
        let type = UTType(filenameExtension: (file.name as NSString).pathExtension)
        if let mime = type?.preferredMIMEType { return mime }
        return type?.conforms(to: .text) == true ? "text/plain" : "application/octet-stream"
    }

    static func symbol(for file: HermesManagedFile) -> String {
        if file.isDirectory { return "folder" }
        let type = mimeType(for: file)
        if ChatAttachmentMarkdown.isMarkdown(fileName: file.name, mimeType: type) { return "doc.text" }
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.contains("zip") || type.contains("archive") || type.contains("compressed") { return "archivebox" }
        return type.hasPrefix("text/") ? "doc.text" : "doc"
    }
}
