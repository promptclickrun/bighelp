import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A file the phone downloaded from the host, kept in a folder of its own that the caller removes.
struct DeviceHostFile: Equatable, Sendable {
    let url: URL
    let directory: URL
    let fileName: String
    let mimeType: String
    let byteCount: Int

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// How a phone tool gets a file from the host for the chat that asked.
@MainActor
protocol DeviceHostFileDownloading: AnyObject {
    /// Downloads one file by its host path. `checkpoint` runs between pieces, so a switch turned off
    /// or a chat that closed stops the download. Throws `DevicePhotosTool.Failure` for a missing,
    /// oversized or unsupported file.
    func download(path: String, agentID: String, sessionID: String, maximumBytes: Int,
                  checkpoint: @MainActor () throws -> Void) async throws -> DeviceHostFile
}

extension DeviceToolServices {
    /// The host download for the connection in use, or nil without one. The app sets it where it sets
    /// `workspace`, from the same connection store.
    static var hostFileDownloader: (@MainActor () -> (any DeviceHostFileDownloading)?)?
}

/// `photos.list`, `photos.albums`, `photos.get`, `photos.save`, `photos.update`, `photos.createAlbum` and `photos.delete`: the agent's `iphone_photos` tool.
@MainActor
final class DevicePhotosTool: DeviceCapabilityTool {
    enum Failure: String, DeviceToolFailure, Equatable {
        case notFound = "not_found"
        /// The person tapped Don't Allow on iOS's delete confirmation.
        case cancelled
        case unsupportedMedia = "unsupported_media"
        case fileTooLarge = "file_too_large"

        var code: String { rawValue }
    }

    let capability = DeviceToolCapability.photos

    static let defaultListLimit = 30
    static let maximumListLimit = 100
    static let defaultMaxPixels = 768
    static let maxPixelsRange = 256...1_024
    static let maximumListLength = 20
    static let maximumDeleteCount = 50
    static let maximumIdentifierLength = 512
    static let maximumTitleLength = 200
    static let maximumPathLength = 4_096
    static let maximumSaveBytes = 50 * 1_024 * 1_024

    private let library: any DevicePhotosLibrary
    private let hostFiles: @MainActor () -> (any DeviceHostFileDownloading)?

    init(library: any DevicePhotosLibrary,
         hostFiles: @escaping @MainActor () -> (any DeviceHostFileDownloading)? = { DeviceToolServices.hostFileDownloader?() }) {
        self.library = library
        self.hostFiles = hostFiles
    }

    static func live(_ environment: DeviceToolEnvironment) -> DevicePhotosTool {
        // Demo mode never asks iOS or touches the person's photos.
        DevicePhotosTool(library: environment.usesFixtures ? DemoDevicePhotosLibrary() : LiveDevicePhotosLibrary())
    }

    // MARK: Access

    /// iOS's current answer. Never asks.
    func status() async -> DeviceToolSystemAccess {
        Self.access(library.authorization)
    }

    /// The Settings switch: the first time, iOS asks for read and write access.
    func request() async -> DeviceToolSystemAccess {
        guard library.authorization == .notDetermined else { return Self.access(library.authorization) }
        return Self.access(await library.requestAuthorization())
    }

    private static func access(_ authorization: DevicePhotosAuthorization) -> DeviceToolSystemAccess {
        switch authorization {
        case .notDetermined: .notRequested
        case .authorized, .limited: .available
        case .denied: .denied
        case .restricted: .unavailable
        }
    }

    /// Run after every wait and right before each change: the switch and chat are still current, and
    /// iOS still allows the access (the person can pull it in Settings at any moment).
    private func checkpoint(_ authorize: @MainActor () throws -> Void) throws {
        try authorize()
        switch Self.access(library.authorization) {
        case .available: break
        case .unavailable: throw AppleDeviceToolError.unavailable
        case .notRequested, .denied: throw AppleDeviceToolError.authorizationRequired
        }
    }

    // MARK: Operations

    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        context: DeviceToolCallContext,
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        do {
            switch operation {
            case "photos.list": return try await list(arguments, authorize)
            case "photos.albums": return try await albums(arguments, authorize)
            case "photos.get": return try await get(arguments, authorize)
            case "photos.save": return try await save(arguments, context, authorize)
            case "photos.update": return try await update(arguments, authorize)
            case "photos.createAlbum": return try await createAlbum(arguments, authorize)
            case "photos.delete": return try await delete(arguments, authorize)
            default: throw AppleDeviceToolError.unsupportedOperation
            }
        } catch let error as DevicePhotosLibraryError {
            throw Self.failure(error)
        }
    }

    private func list(_ arguments: [String: BighelpJSONValue],
                      _ authorize: @MainActor () throws -> Void) async throws -> [String: BighelpJSONValue] {
        let filter = try ListFilter(arguments)
        try checkpoint(authorize)
        // One more than asked, to say whether there are more.
        var query = filter.query
        query.limit += 1
        let found = try await library.assets(matching: query)
        try checkpoint(authorize)
        return [
            "photos": .array(found.prefix(filter.query.limit).map { .object(Self.item($0)) }),
            "truncated": .boolean(found.count > filter.query.limit),
            "access": .string(Self.accessName(library.authorization)),
        ]
    }

    private func albums(_ arguments: [String: BighelpJSONValue],
                        _ authorize: @MainActor () throws -> Void) async throws -> [String: BighelpJSONValue] {
        try Self.requireKeys(arguments, allowed: [])
        try checkpoint(authorize)
        let found = try await library.albums()
        try checkpoint(authorize)
        var result: [String: BighelpJSONValue] = [
            "albums": .array(found.albums.map { album in
                .object([
                    "id": .string(album.id),
                    "title": .string(Self.clean(album.title, limit: Self.maximumTitleLength)),
                    "count": .integer(album.count),
                    "kind": .string(album.isSmart ? "smart" : "album"),
                ])
            }),
            "access": .string(Self.accessName(library.authorization)),
        ]
        if found.truncated { result["truncated"] = .boolean(true) }
        return result
    }

    private func get(_ arguments: [String: BighelpJSONValue],
                     _ authorize: @MainActor () throws -> Void) async throws -> [String: BighelpJSONValue] {
        try Self.requireKeys(arguments, allowed: ["id", "maxPixels"])
        let id = try Self.identifier(arguments["id"])
        var maxPixels = Self.defaultMaxPixels
        if let value = arguments["maxPixels"] {
            guard let pixels = value.integer, Self.maxPixelsRange.contains(pixels) else {
                throw AppleDeviceToolError.invalidArguments
            }
            maxPixels = pixels
        }
        try checkpoint(authorize)
        guard let asset = try await library.assets(withIDs: [id]).first else { throw Failure.notFound }
        try checkpoint(authorize)
        let jpeg = try await library.jpeg(forAssetID: id, maxPixels: maxPixels)
        try checkpoint(authorize)
        guard jpeg.data.count <= DevicePhotosJPEG.maximumBytes else { throw AppleDeviceToolError.resultLimitExceeded }
        var result = Self.item(asset)
        result["image"] = .object([
            "format": .string("jpeg"),
            "width": .integer(jpeg.width),
            "height": .integer(jpeg.height),
            "data": .string(jpeg.data.base64EncodedString()),
        ])
        return result
    }

    private func save(_ arguments: [String: BighelpJSONValue], _ context: DeviceToolCallContext,
                      _ authorize: @MainActor () throws -> Void) async throws -> [String: BighelpJSONValue] {
        try Self.requireKeys(arguments, allowed: ["path", "albumID"])
        let path = try Self.hostPath(arguments["path"])
        let albumID = try arguments["albumID"].map(Self.identifier)
        try checkpoint(authorize)
        if let albumID {
            guard await library.editableAlbumIDs(among: [albumID]).contains(albumID) else { throw Failure.notFound }
            try checkpoint(authorize)
        }
        guard let downloader = hostFiles() else { throw AppleDeviceToolError.unavailable }
        // Nothing has touched Photos yet, so no failure here may look like "might have happened":
        // the coordinator turns an unclassified error into `outcome_unknown` and the request ID
        // could never run again.
        let file = try await Self.beforeAnyChange {
            try await downloader.download(
                path: path, agentID: context.agentID, sessionID: context.sessionID,
                maximumBytes: Self.maximumSaveBytes, checkpoint: { try self.checkpoint(authorize) })
        }
        // The copy on the phone goes whether or not the photo was added.
        defer { file.remove() }
        try checkpoint(authorize)
        guard file.byteCount <= Self.maximumSaveBytes else { throw Failure.fileTooLarge }
        let isVideo = try Self.isVideo(mimeType: file.mimeType)
        let id = try await library.importMedia(
            fileURL: file.url, isVideo: isVideo, albumID: albumID, beforeCommit: { try self.checkpoint(authorize) })
        try checkpoint(authorize)
        return ["id": .string(id)]
    }

    private func update(_ arguments: [String: BighelpJSONValue],
                        _ authorize: @MainActor () throws -> Void) async throws -> [String: BighelpJSONValue] {
        try Self.requireKeys(arguments, allowed: ["id", "expectedRevision", "favorite", "addToAlbumIDs", "removeFromAlbumIDs"])
        let id = try Self.identifier(arguments["id"])
        let expected = try Self.identifier(arguments["expectedRevision"])
        var favorite: Bool?
        if let value = arguments["favorite"] {
            guard let flag = value.boolean else { throw AppleDeviceToolError.invalidArguments }
            favorite = flag
        }
        let add = try arguments["addToAlbumIDs"].map { try Self.identifiers($0, limit: Self.maximumListLength) } ?? []
        let remove = try arguments["removeFromAlbumIDs"].map { try Self.identifiers($0, limit: Self.maximumListLength) } ?? []
        // Nothing to change, or an album both added to and removed from, is a request that makes no sense.
        guard favorite != nil || !add.isEmpty || !remove.isEmpty, Set(add).isDisjoint(with: remove) else {
            throw AppleDeviceToolError.invalidArguments
        }
        try checkpoint(authorize)
        guard let asset = try await library.assets(withIDs: [id]).first else { throw Failure.notFound }
        try checkpoint(authorize)
        guard Self.revision(asset) == expected else { throw AppleDeviceToolError.staleRevision }
        let wanted = Set(add + remove)
        if !wanted.isEmpty {
            guard await library.editableAlbumIDs(among: Array(wanted)) == wanted else { throw Failure.notFound }
            try checkpoint(authorize)
        }
        try await library.update(assetID: id, favorite: favorite, addToAlbumIDs: add, removeFromAlbumIDs: remove,
                                 beforeCommit: { try self.checkpoint(authorize) })
        try checkpoint(authorize)
        guard let updated = try await library.assets(withIDs: [id]).first else { throw AppleDeviceToolError.nativeFailure }
        return ["id": .string(id), "revision": .string(Self.revision(updated))]
    }

    private func createAlbum(_ arguments: [String: BighelpJSONValue],
                             _ authorize: @MainActor () throws -> Void) async throws -> [String: BighelpJSONValue] {
        try Self.requireKeys(arguments, allowed: ["title"])
        guard let raw = arguments["title"]?.string, raw.count <= Self.maximumTitleLength,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AppleDeviceToolError.invalidArguments }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AppleDeviceToolError.invalidArguments }
        try checkpoint(authorize)
        let id = try await library.createAlbum(title: title, beforeCommit: { try self.checkpoint(authorize) })
        try checkpoint(authorize)
        return ["id": .string(id)]
    }

    private func delete(_ arguments: [String: BighelpJSONValue],
                        _ authorize: @MainActor () throws -> Void) async throws -> [String: BighelpJSONValue] {
        try Self.requireKeys(arguments, allowed: ["ids"])
        guard let value = arguments["ids"] else { throw AppleDeviceToolError.invalidArguments }
        let ids = try Self.identifiers(value, limit: Self.maximumDeleteCount)
        guard !ids.isEmpty else { throw AppleDeviceToolError.invalidArguments }
        try checkpoint(authorize)
        // One missing photo stops the whole call before iOS asks the person anything.
        let found = try await library.assets(withIDs: ids)
        guard Set(found.map(\.id)) == Set(ids) else { throw Failure.notFound }
        try checkpoint(authorize)
        try await library.deleteAssets(withIDs: ids, beforeCommit: { try self.checkpoint(authorize) })
        try checkpoint(authorize)
        return ["deleted": .boolean(true), "count": .integer(ids.count)]
    }

    // MARK: Results

    /// Hands the agent only what the library says, in the contract's fields.
    static func item(_ asset: DevicePhotoAsset) -> [String: BighelpJSONValue] {
        var item: [String: BighelpJSONValue] = [
            "id": .string(asset.id),
            "revision": .string(revision(asset)),
            "mediaType": .string(asset.isVideo ? "video" : "image"),
            "width": .integer(asset.width),
            "height": .integer(asset.height),
            "favorite": .boolean(asset.favorite),
        ]
        if let created = asset.created { item["created"] = .string(timestamp(created)) }
        if asset.isVideo, let duration = asset.duration, duration.isFinite, duration >= 0 {
            item["durationSeconds"] = .number((duration * 100).rounded() / 100)
        }
        if let latitude = asset.latitude, let longitude = asset.longitude,
           (-90...90).contains(latitude), (-180...180).contains(longitude) {
            item["latitude"] = .number(rounded(latitude))
            item["longitude"] = .number(rounded(longitude))
        }
        return item
    }

    /// The modification date in UTC with milliseconds. The agent hands it back to change the photo;
    /// a different value means the photo changed since the agent looked.
    static func revision(_ asset: DevicePhotoAsset) -> String { timestamp(asset.modified) }

    static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    static func accessName(_ authorization: DevicePhotosAuthorization) -> String {
        authorization == .limited ? "limited" : "full"
    }

    /// Four decimals is about eleven meters.
    private static func rounded(_ degrees: Double) -> Double { (degrees * 10_000).rounded() / 10_000 }

    private static func clean(_ value: String, limit: Int) -> String {
        let visible = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        return String(visible.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    /// Runs a step that cannot have changed the library. A failure the agent can read by code
    /// passes through; a dropped connection, a changed owner, a full disk or a cancel is `unavailable`.
    static func beforeAnyChange<Value>(_ step: () async throws -> Value) async throws -> Value {
        do {
            return try await step()
        } catch let error as any DeviceToolFailure {
            throw error
        } catch let error as DevicePhotosLibraryError {
            throw failure(error)
        } catch {
            throw AppleDeviceToolError.unavailable
        }
    }

    static func failure(_ error: DevicePhotosLibraryError) -> any DeviceToolFailure {
        switch error {
        case .notFound: return Failure.notFound
        case .userCancelled: return Failure.cancelled
        case .unsupportedMedia: return Failure.unsupportedMedia
        case .accessDenied: return AppleDeviceToolError.authorizationRequired
        case .failed: return AppleDeviceToolError.nativeFailure
        }
    }

    /// An image or a video, by the type the host reports. Photos adds nothing else.
    static func isVideo(mimeType: String) throws -> Bool {
        let mime = mimeType.lowercased()
        guard mime != "image/svg+xml", let type = UTType(mimeType: mime) else { throw Failure.unsupportedMedia }
        if type.conforms(to: .image) { return false }
        if type.conforms(to: .movie) { return true }
        throw Failure.unsupportedMedia
    }

    // MARK: Arguments

    @MainActor private struct ListFilter {
        var query: DevicePhotoQuery

        init(_ arguments: [String: BighelpJSONValue]) throws {
            try DevicePhotosTool.requireKeys(arguments, allowed: ["start", "end", "albumID", "mediaType", "favorites", "limit"])
            var query = DevicePhotoQuery(limit: DevicePhotosTool.defaultListLimit)
            guard (arguments["start"] == nil) == (arguments["end"] == nil) else { throw AppleDeviceToolError.invalidArguments }
            if let start = arguments["start"], let end = arguments["end"] {
                guard let start = start.string.flatMap(DevicePhotosTool.parseDate),
                      let end = end.string.flatMap(DevicePhotosTool.parseDate), end > start else {
                    throw AppleDeviceToolError.invalidArguments
                }
                query.start = start
                query.end = end
            }
            query.albumID = try arguments["albumID"].map(DevicePhotosTool.identifier)
            if let value = arguments["mediaType"] {
                switch value.string {
                case "image": query.media = .image
                case "video": query.media = .video
                case "any": query.media = .any
                default: throw AppleDeviceToolError.invalidArguments
                }
            }
            if let value = arguments["favorites"] {
                guard let flag = value.boolean else { throw AppleDeviceToolError.invalidArguments }
                query.favorite = flag
            }
            if let value = arguments["limit"] {
                guard let limit = value.integer, (1...DevicePhotosTool.maximumListLimit).contains(limit) else {
                    throw AppleDeviceToolError.invalidArguments
                }
                query.limit = limit
            }
            self.query = query
        }
    }

    static func requireKeys(_ arguments: [String: BighelpJSONValue], allowed: Set<String>) throws {
        guard Set(arguments.keys).isSubset(of: allowed) else { throw AppleDeviceToolError.invalidArguments }
    }

    static func identifier(_ value: BighelpJSONValue?) throws -> String {
        guard let id = value?.string, !id.isEmpty, id.count <= maximumIdentifierLength,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AppleDeviceToolError.invalidArguments }
        return id
    }

    /// A list of IDs without repeats, in the order given.
    static func identifiers(_ value: BighelpJSONValue, limit: Int) throws -> [String] {
        guard let values = value.array, values.count <= limit else { throw AppleDeviceToolError.invalidArguments }
        var seen = Set<String>()
        return try values.map { try identifier($0) }.filter { seen.insert($0).inserted }
    }

    /// A path on the host. The host decides whether it may be sent; the phone only keeps it sane.
    static func hostPath(_ value: BighelpJSONValue?) throws -> String {
        guard let path = value?.string, !path.isEmpty, path.utf8.count <= maximumPathLength,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AppleDeviceToolError.invalidArguments }
        return path
    }

    static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

// MARK: - Host download

/// Downloads a host file through the plugin's `attachments/resolve` and `attachments/fetch`, the
/// same two routes the chat uses for an agent's `MEDIA:` files, for the chat that made the call.
/// It writes each piece to disk as it arrives (a video can be 50 MB) and leaves the file for the
/// caller to remove. The chat's own loader caps a file at 25 MB and holds it in memory, so this one
/// has its own loop over the same routes.
@MainActor
final class DirectHermesDeviceHostFiles: DeviceHostFileDownloading {
    typealias Perform = @MainActor (WorkspaceOperation, [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]

    static let chunkRetryDelays: [Duration] = [.seconds(1), .seconds(3)]

    private let perform: Perform
    private let isCurrent: @MainActor () -> Bool
    private let retryDelays: [Duration]
    private let parent: URL

    init(perform: @escaping Perform, isCurrent: @escaping @MainActor () -> Bool,
         retryDelays: [Duration] = DirectHermesDeviceHostFiles.chunkRetryDelays,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.perform = perform
        self.isCurrent = isCurrent
        self.retryDelays = retryDelays
        parent = temporaryDirectory
    }

    convenience init(workspace: DirectHermesWorkspaceClient, owner: WorkspaceOwner) {
        self.init(
            perform: { operation, payload in try await workspace.perform(operation, payload: payload, owner: owner) },
            isCurrent: { workspace.owner == owner })
    }

    func download(path: String, agentID: String, sessionID: String, maximumBytes: Int,
                  checkpoint: @MainActor () throws -> Void) async throws -> DeviceHostFile {
        guard !agentID.isEmpty, !sessionID.isEmpty else { throw AppleDeviceToolError.invalidArguments }
        let itemID = "photo"
        let response: [String: BighelpJSONValue]
        do {
            response = try await perform(.attachmentsResolve, [
                "agentId": .string(agentID), "storedId": .string(sessionID),
                "items": .array([.object(["itemId": .string(itemID), "text": .string("MEDIA:" + path)])]),
            ])
        } catch WorkspaceClientError.unavailable {
            // The plugin has no such route: it needs an update.
            throw AppleDeviceToolError.unavailable
        } catch WorkspaceClientError.rejected(let code, _) {
            throw Self.failure(forHostCode: code)
        }
        try verify(checkpoint)
        guard let rows = response["items"]?.array, rows.count == 1, let row = rows[0].object,
              row["itemId"]?.string == itemID, let listed = row["attachments"]?.array else {
            throw WorkspaceClientError.invalidResponse
        }
        // The host gave nothing for that path: it isn't a file the agent may send.
        guard let meta = listed.first?.object else { throw DevicePhotosTool.Failure.notFound }
        guard let id = meta["id"]?.string, let fileName = meta["fileName"]?.string,
              let mimeType = meta["mimeType"]?.string, let size = meta["byteCount"]?.integer, size >= 1 else {
            throw WorkspaceClientError.invalidResponse
        }
        guard size <= maximumBytes else { throw DevicePhotosTool.Failure.fileTooLarge }
        _ = try DevicePhotosTool.isVideo(mimeType: mimeType)
        guard let ext = Self.fileExtension(fileName: fileName, mimeType: mimeType) else {
            throw DevicePhotosTool.Failure.unsupportedMedia
        }

        let directory = parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appending(path: "photo." + ext)
        do {
            try Data().write(to: file, options: [.completeFileProtectionUnlessOpen])
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var offset = 0
            while true {
                try checkpoint()
                let chunk = try await fetchChunk(id: id, agentID: agentID, size: size, offset: offset)
                try verify(checkpoint)
                try handle.write(contentsOf: chunk.bytes)
                offset += chunk.bytes.count
                guard let next = chunk.nextOffset else { break }
                offset = next
            }
            guard offset == size else { throw WorkspaceClientError.invalidResponse }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return DeviceHostFile(url: file, directory: directory, fileName: fileName,
                              mimeType: mimeType.lowercased(), byteCount: size)
    }

    private func verify(_ checkpoint: @MainActor () throws -> Void) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw WorkspaceClientError.ownerChanged }
        try checkpoint()
    }

    private func fetchChunk(id: String, agentID: String, size: Int,
                            offset: Int) async throws -> (bytes: Data, nextOffset: Int?) {
        var retries = retryDelays[...]
        while true {
            do {
                let chunk = try await perform(.attachmentsFetch, [
                    "agentId": .string(agentID), "attachmentId": .string(id), "offset": .integer(offset),
                ])
                guard chunk["attachmentId"]?.string == id, chunk["offset"]?.integer == offset,
                      chunk["byteCount"]?.integer == size, let encoded = chunk["data"]?.string,
                      let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, offset + bytes.count <= size
                else { throw WorkspaceClientError.invalidResponse }
                let end = offset + bytes.count
                if chunk["nextOffset"] == nil || chunk["nextOffset"] == .null {
                    guard end == size else { throw WorkspaceClientError.invalidResponse }
                    return (bytes, nil)
                }
                guard chunk["nextOffset"]?.integer == end, end < size else { throw WorkspaceClientError.invalidResponse }
                return (bytes, end)
            } catch let error where Self.retries(after: error) && !retries.isEmpty {
                try await Task.sleep(for: retries.removeFirst())
            }
        }
    }

    /// A timeout or dropped connection is worth asking again; a refusal, a bad answer or a changed
    /// connection isn't.
    private static func retries(after error: any Error) -> Bool {
        switch error {
        case is CancellationError: false
        case WorkspaceClientError.ownerChanged, WorkspaceClientError.invalidResponse,
             WorkspaceClientError.invalidRequest, WorkspaceClientError.unavailable,
             WorkspaceClientError.rejected: false
        default: true
        }
    }

    /// The plugin may answer a refusal with its own code; the three that matter keep their meaning.
    private static func failure(forHostCode code: String?) -> any Error {
        switch code {
        case "not_found", "attachment_unavailable": return DevicePhotosTool.Failure.notFound
        case "unsupported_media": return DevicePhotosTool.Failure.unsupportedMedia
        case "file_too_large": return DevicePhotosTool.Failure.fileTooLarge
        default: return AppleDeviceToolError.nativeFailure
        }
    }

    /// Photos picks the kind of file by its extension, so the copy keeps one that matches its type.
    private static func fileExtension(fileName: String, mimeType: String) -> String? {
        let named = (fileName as NSString).pathExtension.lowercased()
        if !named.isEmpty, named.count <= 8, named.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
           let type = UTType(filenameExtension: named), type.conforms(to: .image) || type.conforms(to: .movie) {
            return named
        }
        return UTType(mimeType: mimeType.lowercased())?.preferredFilenameExtension
    }
}
