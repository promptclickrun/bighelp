@preconcurrency import AVFoundation
import CoreLocation
import Foundation
import ImageIO
@preconcurrency import Photos
import UIKit
import UniformTypeIdentifiers

/// What iOS says about library access. `limited` is the person's chosen subset (iOS 14 and later).
enum DevicePhotosAuthorization: Equatable, Sendable {
    case notDetermined, restricted, denied, authorized, limited
}

enum DevicePhotoMediaFilter: Equatable, Sendable {
    case image, video, any
}

/// One photo or video, projected to plain values. Nothing here keeps a `PHAsset` alive.
struct DevicePhotoAsset: Equatable, Sendable {
    let id: String
    /// The asset's modification date; the tool turns it into the `revision` the agent hands back.
    let modified: Date
    let created: Date?
    let isVideo: Bool
    let width: Int
    let height: Int
    let favorite: Bool
    let duration: Double?
    let latitude: Double?
    let longitude: Double?
}

struct DevicePhotoAlbum: Equatable, Sendable {
    let id: String
    let title: String
    let count: Int
    let isSmart: Bool
}

struct DevicePhotoQuery: Equatable, Sendable {
    /// Creation date: `start` is included, `end` is not.
    var start: Date?
    var end: Date?
    var albumID: String?
    var media: DevicePhotoMediaFilter = .any
    /// nil asks for both; true only favorites; false only the rest.
    var favorite: Bool?
    /// The library returns up to this many, newest first.
    var limit: Int
}

struct DevicePhotoJPEG: Equatable, Sendable {
    let data: Data
    let width: Int
    let height: Int
}

/// What the library can say went wrong. The tool turns each into the agent's error code.
enum DevicePhotosLibraryError: Error, Equatable, Sendable {
    case notFound
    /// The person tapped Don't Allow on iOS's own confirmation.
    case userCancelled
    case unsupportedMedia
    case accessDenied
    case failed
}

/// PhotoKit behind a seam, so the tool's choices can be tested without a device. A mutating method
/// calls `beforeCommit` right before it hands the change to iOS, the last place to re-check that the
/// switch is on and the chat is still current.
@MainActor
protocol DevicePhotosLibrary: AnyObject {
    var authorization: DevicePhotosAuthorization { get }
    /// iOS's question, from the person's tap on the Settings switch.
    func requestAuthorization() async -> DevicePhotosAuthorization
    /// Newest first, as many as `query.limit`.
    func assets(matching query: DevicePhotoQuery) async throws -> [DevicePhotoAsset]
    /// The person's albums and the main smart albums; `truncated` when the user albums were cut short.
    func albums() async throws -> (albums: [DevicePhotoAlbum], truncated: Bool)
    /// The assets that exist and that this app may see (a limited library hides the rest).
    func assets(withIDs ids: [String]) async throws -> [DevicePhotoAsset]
    /// Of `ids`, the user albums that accept new content.
    func editableAlbumIDs(among ids: [String]) async -> Set<String>
    /// The picture (a video's first frame) as a JPEG of at most `DevicePhotosJPEG.maximumBytes`.
    func jpeg(forAssetID id: String, maxPixels: Int) async throws -> DevicePhotoJPEG
    func update(assetID: String, favorite: Bool?, addToAlbumIDs: [String], removeFromAlbumIDs: [String],
                beforeCommit: @MainActor () throws -> Void) async throws
    func createAlbum(title: String, beforeCommit: @MainActor () throws -> Void) async throws -> String
    /// iOS asks the person to confirm. Don't Allow throws `userCancelled`.
    func deleteAssets(withIDs ids: [String], beforeCommit: @MainActor () throws -> Void) async throws
    /// Adds the file as a new photo or video (and to `albumID`), returning the new asset's ID.
    func importMedia(fileURL: URL, isVideo: Bool, albumID: String?,
                     beforeCommit: @MainActor () throws -> Void) async throws -> String
}

// MARK: - Picture encoding

enum DevicePhotosJPEG {
    /// The plugin's result limit is 128 KB of JSON; base64 makes 90 KB of JPEG about 120 KB.
    static let maximumBytes = 90_000
    static let qualities: [CGFloat] = [0.8, 0.7, 0.6, 0.5, 0.4, 0.3]
    static let smallestLongEdge: CGFloat = 64

    /// Scales to at most `maxPixels` on the long edge (never up), then steps the quality down and,
    /// when that isn't enough, the size, until the JPEG fits. nil only when nothing fits.
    static func encode(_ image: UIImage, maxPixels: Int, maxBytes: Int = maximumBytes) -> DevicePhotoJPEG? {
        let source = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(source.width, source.height)
        guard source.width >= 1, source.height >= 1, maxPixels >= 1 else { return nil }
        var edge = min(longest, CGFloat(maxPixels))
        repeat {
            let ratio = edge / longest
            let size = CGSize(width: max(1, (source.width * ratio).rounded()),
                              height: max(1, (source.height * ratio).rounded()))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            for quality in qualities {
                if let data = rendered.jpegData(compressionQuality: quality), data.count <= maxBytes {
                    return DevicePhotoJPEG(data: data, width: Int(size.width), height: Int(size.height))
                }
            }
            edge = (edge * 0.8).rounded(.down)
        } while edge >= smallestLongEdge
        return nil
    }
}

// MARK: - Checking a file before it goes in

enum DevicePhotosMediaCheck {
    /// A photo ImageIO can open, or a video AVFoundation can play. PhotoKit would refuse anything else
    /// only after it was asked to add it.
    static func validate(fileURL: URL, isVideo: Bool) async throws {
        if isVideo {
            let playable = (try? await AVURLAsset(url: fileURL).load(.isPlayable)) ?? false
            guard playable else { throw DevicePhotosLibraryError.unsupportedMedia }
        } else {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetCount(source) > 0 else { throw DevicePhotosLibraryError.unsupportedMedia }
        }
    }
}

// MARK: - PhotoKit

/// A value a PhotoKit change block hands back from its background queue.
private final class DevicePhotosResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func set(_ value: String?) { lock.lock(); stored = value; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// One `PHImageManager` request, finished exactly once from whichever side gets there first: the
/// image manager's queue, a cancel, or the deadline. Its callbacks run off the main actor.
private final class DevicePhotosImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHImageRequestID?
    private var finished = false
    private var continuation: CheckedContinuation<DevicePhotoJPEG, any Error>?

    func attach(_ continuation: CheckedContinuation<DevicePhotoJPEG, any Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func started(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let alreadyDone = finished
        lock.unlock()
        if alreadyDone { PHImageManager.default().cancelImageRequest(id) }
    }

    func finish(_ result: Result<DevicePhotoJPEG, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        finish(.failure(CancellationError()))
        lock.lock()
        let id = requestID
        lock.unlock()
        if let id { PHImageManager.default().cancelImageRequest(id) }
    }
}

@MainActor
final class LiveDevicePhotosLibrary: DevicePhotosLibrary {
    /// iOS can hold a picture back while it downloads from iCloud; a tool call can't wait forever.
    static let imageTimeoutSeconds = 25.0
    static let maximumAlbums = 300

    var authorization: DevicePhotosAuthorization {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .restricted
        }
    }

    func requestAuthorization() async -> DevicePhotosAuthorization {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return authorization
    }

    func assets(matching query: DevicePhotoQuery) async throws -> [DevicePhotoAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = query.limit
        var predicates: [NSPredicate] = []
        switch query.media {
        case .image: predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        case .video: predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        case .any:
            predicates.append(NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                          PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue))
        }
        if let favorite = query.favorite { predicates.append(NSPredicate(format: "favorite == %@", NSNumber(value: favorite))) }
        if let start = query.start { predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate)) }
        if let end = query.end { predicates.append(NSPredicate(format: "creationDate < %@", end as NSDate)) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        let result: PHFetchResult<PHAsset>
        if let albumID = query.albumID {
            guard let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumID], options: nil).firstObject else { throw DevicePhotosLibraryError.notFound }
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        return Self.projected(result)
    }

    func albums() async throws -> (albums: [DevicePhotoAlbum], truncated: Bool) {
        var albums: [DevicePhotoAlbum] = []
        let smart: [PHAssetCollectionSubtype] = [
            .smartAlbumFavorites, .smartAlbumUserLibrary, .smartAlbumScreenshots,
            .smartAlbumSelfPortraits, .smartAlbumVideos,
        ]
        for subtype in smart {
            guard let collection = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: subtype, options: nil).firstObject else { continue }
            albums.append(Self.album(collection, isSmart: true))
        }
        let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        for index in 0..<min(user.count, Self.maximumAlbums) {
            albums.append(Self.album(user.object(at: index), isSmart: false))
        }
        return (albums, user.count > Self.maximumAlbums)
    }

    func assets(withIDs ids: [String]) async throws -> [DevicePhotoAsset] {
        guard !ids.isEmpty else { return [] }
        return Self.projected(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
    }

    func editableAlbumIDs(among ids: [String]) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let result = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil)
        var editable = Set<String>()
        for index in 0..<result.count {
            let collection = result.object(at: index)
            if collection.assetCollectionType == .album, collection.assetCollectionSubtype == .albumRegular,
               collection.canPerform(.addContent) {
                editable.insert(collection.localIdentifier)
            }
        }
        return editable
    }

    func jpeg(forAssetID id: String, maxPixels: Int) async throws -> DevicePhotoJPEG {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw DevicePhotosLibraryError.notFound
        }
        let request = DevicePhotosImageRequest()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.version = .current
        let target = CGSize(width: maxPixels, height: maxPixels)
        // A video's request gives its poster frame, so one path serves both.
        return try await DeviceLocationDeadline.run(seconds: Self.imageTimeoutSeconds) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DevicePhotoJPEG, any Error>) in
                    request.attach(continuation)
                    let requestID = PHImageManager.default().requestImage(
                        for: asset, targetSize: target, contentMode: .aspectFit, options: options,
                        resultHandler: Self.imageHandler(maxPixels: maxPixels, request: request))
                    request.started(requestID)
                }
            } onCancel: {
                request.cancel()
            }
        }
    }

    func update(assetID: String, favorite: Bool?, addToAlbumIDs: [String], removeFromAlbumIDs: [String],
                beforeCommit: @MainActor () throws -> Void) async throws {
        try beforeCommit()
        do {
            try await PHPhotoLibrary.shared().performChanges(
                Self.updateBlock(assetID: assetID, favorite: favorite, add: addToAlbumIDs, remove: removeFromAlbumIDs))
        } catch { throw Self.mapped(error) }
    }

    func createAlbum(title: String, beforeCommit: @MainActor () throws -> Void) async throws -> String {
        try beforeCommit()
        let created = DevicePhotosResultBox()
        do {
            try await PHPhotoLibrary.shared().performChanges(Self.createAlbumBlock(title: title, created: created))
        } catch { throw Self.mapped(error) }
        guard let id = created.value else { throw DevicePhotosLibraryError.failed }
        return id
    }

    func deleteAssets(withIDs ids: [String], beforeCommit: @MainActor () throws -> Void) async throws {
        try beforeCommit()
        do {
            try await PHPhotoLibrary.shared().performChanges(Self.deleteBlock(ids: ids))
        } catch { throw Self.mapped(error) }
    }

    func importMedia(fileURL: URL, isVideo: Bool, albumID: String?,
                     beforeCommit: @MainActor () throws -> Void) async throws -> String {
        try await DevicePhotosMediaCheck.validate(fileURL: fileURL, isVideo: isVideo)
        try beforeCommit()
        let created = DevicePhotosResultBox()
        do {
            try await PHPhotoLibrary.shared().performChanges(
                Self.importBlock(fileURL: fileURL, isVideo: isVideo, albumID: albumID, created: created))
        } catch { throw Self.mapped(error) }
        guard let id = created.value else { throw DevicePhotosLibraryError.failed }
        return id
    }

    // MARK: Off the main actor
    //
    // PhotoKit runs change blocks and image callbacks on its own queues. Every closure below is made
    // in a nonisolated function and is @Sendable: one made inside a main-actor method would inherit
    // the main actor and trap when PhotoKit calls it from another queue (the EventKit crash).

    nonisolated private static func updateBlock(
        assetID: String, favorite: Bool?, add: [String], remove: [String]
    ) -> @Sendable () -> Void {
        {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
            if let favorite { PHAssetChangeRequest(for: asset).isFavorite = favorite }
            for (ids, adding) in [(add, true), (remove, false)] where !ids.isEmpty {
                let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil)
                for index in 0..<collections.count {
                    guard let change = PHAssetCollectionChangeRequest(for: collections.object(at: index)) else { continue }
                    if adding { change.addAssets([asset] as NSArray) } else { change.removeAssets([asset] as NSArray) }
                }
            }
        }
    }

    nonisolated private static func createAlbumBlock(title: String, created: DevicePhotosResultBox) -> @Sendable () -> Void {
        {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            created.set(request.placeholderForCreatedAssetCollection.localIdentifier)
        }
    }

    nonisolated private static func deleteBlock(ids: [String]) -> @Sendable () -> Void {
        {
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
        }
    }

    nonisolated private static func importBlock(
        fileURL: URL, isVideo: Bool, albumID: String?, created: DevicePhotosResultBox
    ) -> @Sendable () -> Void {
        {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            // The tool deletes its own temporary copy afterwards.
            options.shouldMoveFile = false
            request.addResource(with: isVideo ? .video : .photo, fileURL: fileURL, options: options)
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            created.set(placeholder.localIdentifier)
            if let albumID,
               let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
               let change = PHAssetCollectionChangeRequest(for: album) {
                change.addAssets([placeholder] as NSArray)
            }
        }
    }

    nonisolated private static func imageHandler(
        maxPixels: Int, request: DevicePhotosImageRequest
    ) -> @Sendable (UIImage?, [AnyHashable: Any]?) -> Void {
        { image, info in
            // A degraded picture is only a stand-in; the final one follows.
            if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
            guard (info?[PHImageCancelledKey] as? Bool) != true, info?[PHImageErrorKey] == nil,
                  let image, let jpeg = DevicePhotosJPEG.encode(image, maxPixels: maxPixels) else {
                request.finish(.failure(DevicePhotosLibraryError.failed))
                return
            }
            request.finish(.success(jpeg))
        }
    }

    nonisolated private static func mapped(_ error: any Error) -> DevicePhotosLibraryError {
        if let photos = error as? PHPhotosError {
            switch photos.code {
            case .userCancelled: return .userCancelled
            case .accessUserDenied, .accessRestricted: return .accessDenied
            case .invalidResource: return .unsupportedMedia
            case .identifierNotFound: return .notFound
            default: return .failed
            }
        }
        return .failed
    }

    // MARK: Projection

    private static func projected(_ result: PHFetchResult<PHAsset>) -> [DevicePhotoAsset] {
        (0..<result.count).compactMap { index in
            let asset = result.object(at: index)
            guard asset.mediaType == .image || asset.mediaType == .video else { return nil }
            let coordinate = asset.location?.coordinate
            return DevicePhotoAsset(
                id: asset.localIdentifier,
                modified: asset.modificationDate ?? asset.creationDate ?? Date(timeIntervalSince1970: 0),
                created: asset.creationDate, isVideo: asset.mediaType == .video,
                width: asset.pixelWidth, height: asset.pixelHeight, favorite: asset.isFavorite,
                duration: asset.mediaType == .video ? asset.duration : nil,
                latitude: coordinate?.latitude, longitude: coordinate?.longitude)
        }
    }

    private static func album(_ collection: PHAssetCollection, isSmart: Bool) -> DevicePhotoAlbum {
        DevicePhotoAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "",
                         count: PHAsset.fetchAssets(in: collection, options: nil).count, isSmart: isSmart)
    }
}

// MARK: - Demo

/// A library in memory, for demo mode and for tests. It behaves the way PhotoKit does where the tool
/// depends on it: a limited library hides what the person didn't pick, a change moves the asset's
/// modification date, a missing ID is nothing rather than an error, and iOS's delete confirmation
/// can be declined. Every picture and place is made up.
@MainActor
final class DemoDevicePhotosLibrary: DevicePhotosLibrary {
    private struct Entry {
        var asset: DevicePhotoAsset
        var albumIDs: Set<String>
    }

    private struct DemoAlbum {
        let id: String
        var title: String
        let isSmart: Bool
    }

    static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    var authorization: DevicePhotosAuthorization
    /// What iOS answers when the Settings switch asks.
    var answerToRequest: DevicePhotosAuthorization = .authorized
    /// Under limited access, the only assets the app can see; nil means the person picked none yet.
    var limitedSelection: Set<String> = []
    /// The person's answer to iOS's delete confirmation.
    var allowsDelete = true
    /// Every change handed to "iOS" so far, so a test can tell a refused call changed nothing.
    private(set) var commitCount = 0
    private(set) var requestedAuthorization = 0
    private(set) var importedFiles: [URL] = []
    private(set) var imageRequests: [(id: String, maxPixels: Int)] = []
    var clock: () -> Date = { DemoDevicePhotosLibrary.epoch }

    private var entries: [String: Entry] = [:]
    private var albumList: [DemoAlbum] = []
    private var nextNumber = 1

    init(authorization: DevicePhotosAuthorization = .authorized) {
        self.authorization = authorization
        albumList = [
            DemoAlbum(id: "smart-favorites", title: "Favorites", isSmart: true),
            DemoAlbum(id: "smart-videos", title: "Videos", isSmart: true),
            DemoAlbum(id: "album-trip", title: "Sample Trip", isSmart: false),
            DemoAlbum(id: "album-pets", title: "Sample Pets", isSmart: false),
        ]
        let sizes = [(4032, 3024), (3024, 4032), (1920, 1080), (4032, 3024), (1080, 1920)]
        for (index, size) in sizes.enumerated() {
            let id = "demo-photo-\(index + 1)"
            let isVideo = index == 2
            let created = Self.epoch.addingTimeInterval(-Double(index) * 86_400)
            entries[id] = Entry(
                asset: DevicePhotoAsset(
                    id: id, modified: created.addingTimeInterval(60), created: created, isVideo: isVideo,
                    width: size.0, height: size.1, favorite: index == 0,
                    duration: isVideo ? 12.5 : nil,
                    latitude: index == 1 ? 12.3456 : nil, longitude: index == 1 ? -65.4321 : nil),
                albumIDs: index < 2 ? ["album-trip"] : [])
        }
    }

    var allAssetIDs: [String] { entries.keys.sorted() }

    func asset(_ id: String) -> DevicePhotoAsset? { entries[id]?.asset }

    func members(ofAlbum id: String) -> Set<String> {
        Set(entries.values.filter { $0.albumIDs.contains(id) }.map(\.asset.id))
    }

    /// A change made outside the app, like the person editing the photo in Photos.
    func touch(_ id: String) {
        guard var entry = entries[id] else { return }
        entry.asset = Self.replacing(entry.asset, modified: nextModification(after: entry.asset.modified))
        entries[id] = entry
    }

    func requestAuthorization() async -> DevicePhotosAuthorization {
        requestedAuthorization += 1
        if authorization == .notDetermined { authorization = answerToRequest }
        return authorization
    }

    private func isVisible(_ id: String) -> Bool {
        switch authorization {
        case .authorized: entries[id] != nil
        case .limited: entries[id] != nil && limitedSelection.contains(id)
        default: false
        }
    }

    private var canSee: Bool { authorization == .authorized || authorization == .limited }

    func assets(matching query: DevicePhotoQuery) async throws -> [DevicePhotoAsset] {
        guard canSee else { throw DevicePhotosLibraryError.accessDenied }
        var pool = entries.values.map(\.asset).filter { isVisible($0.id) }
        if let albumID = query.albumID {
            guard albumList.contains(where: { $0.id == albumID }) else { throw DevicePhotosLibraryError.notFound }
            if albumID == "smart-favorites" { pool = pool.filter(\.favorite) }
            else if albumID == "smart-videos" { pool = pool.filter(\.isVideo) }
            else { pool = pool.filter { entries[$0.id]?.albumIDs.contains(albumID) == true } }
        }
        switch query.media {
        case .image: pool = pool.filter { !$0.isVideo }
        case .video: pool = pool.filter(\.isVideo)
        case .any: break
        }
        if let favorite = query.favorite { pool = pool.filter { $0.favorite == favorite } }
        if let start = query.start { pool = pool.filter { ($0.created ?? .distantPast) >= start } }
        if let end = query.end { pool = pool.filter { ($0.created ?? .distantPast) < end } }
        pool.sort { ($0.created ?? .distantPast, $0.id) > ($1.created ?? .distantPast, $1.id) }
        return Array(pool.prefix(query.limit))
    }

    func albums() async throws -> (albums: [DevicePhotoAlbum], truncated: Bool) {
        guard canSee else { throw DevicePhotosLibraryError.accessDenied }
        let visible = entries.values.filter { isVisible($0.asset.id) }
        let result = albumList.map { album -> DevicePhotoAlbum in
            let count: Int
            switch album.id {
            case "smart-favorites": count = visible.filter(\.asset.favorite).count
            case "smart-videos": count = visible.filter(\.asset.isVideo).count
            default: count = visible.filter { $0.albumIDs.contains(album.id) }.count
            }
            return DevicePhotoAlbum(id: album.id, title: album.title, count: count, isSmart: album.isSmart)
        }
        return (result, false)
    }

    func assets(withIDs ids: [String]) async throws -> [DevicePhotoAsset] {
        guard canSee else { throw DevicePhotosLibraryError.accessDenied }
        return ids.compactMap { isVisible($0) ? entries[$0]?.asset : nil }
    }

    func editableAlbumIDs(among ids: [String]) async -> Set<String> {
        Set(ids.filter { id in albumList.contains { $0.id == id && !$0.isSmart } })
    }

    func jpeg(forAssetID id: String, maxPixels: Int) async throws -> DevicePhotoJPEG {
        guard canSee else { throw DevicePhotosLibraryError.accessDenied }
        guard isVisible(id), let asset = entries[id]?.asset else { throw DevicePhotosLibraryError.notFound }
        imageRequests.append((id, maxPixels))
        // PhotoKit fits the picture inside the target square.
        let scale = min(1, Double(maxPixels) / Double(max(asset.width, asset.height)))
        let size = CGSize(width: max(1, (Double(asset.width) * scale).rounded()),
                          height: max(1, (Double(asset.height) * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor.systemTeal.cgColor, UIColor.systemOrange.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero,
                                                     end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
        guard let jpeg = DevicePhotosJPEG.encode(image, maxPixels: maxPixels) else { throw DevicePhotosLibraryError.failed }
        return jpeg
    }

    func update(assetID: String, favorite: Bool?, addToAlbumIDs: [String], removeFromAlbumIDs: [String],
                beforeCommit: @MainActor () throws -> Void) async throws {
        try beforeCommit()
        guard canSee else { throw DevicePhotosLibraryError.accessDenied }
        guard isVisible(assetID), var entry = entries[assetID] else { throw DevicePhotosLibraryError.notFound }
        commitCount += 1
        if let favorite { entry.asset = Self.replacing(entry.asset, favorite: favorite) }
        entry.albumIDs.formUnion(addToAlbumIDs)
        entry.albumIDs.subtract(removeFromAlbumIDs)
        entry.asset = Self.replacing(entry.asset, modified: nextModification(after: entry.asset.modified))
        entries[assetID] = entry
    }

    func createAlbum(title: String, beforeCommit: @MainActor () throws -> Void) async throws -> String {
        try beforeCommit()
        guard canSee else { throw DevicePhotosLibraryError.accessDenied }
        commitCount += 1
        let id = "album-new-\(nextNumber)"
        nextNumber += 1
        albumList.append(DemoAlbum(id: id, title: title, isSmart: false))
        return id
    }

    func deleteAssets(withIDs ids: [String], beforeCommit: @MainActor () throws -> Void) async throws {
        try beforeCommit()
        guard canSee else { throw DevicePhotosLibraryError.accessDenied }
        guard ids.allSatisfy(isVisible) else { throw DevicePhotosLibraryError.notFound }
        // iOS shows its own confirmation; declining is a failed change with a "user cancelled" error.
        guard allowsDelete else { throw DevicePhotosLibraryError.userCancelled }
        commitCount += 1
        ids.forEach { entries[$0] = nil }
    }

    func importMedia(fileURL: URL, isVideo: Bool, albumID: String?,
                     beforeCommit: @MainActor () throws -> Void) async throws -> String {
        try await DevicePhotosMediaCheck.validate(fileURL: fileURL, isVideo: isVideo)
        try beforeCommit()
        guard canSee else { throw DevicePhotosLibraryError.accessDenied }
        if let albumID, !albumList.contains(where: { $0.id == albumID && !$0.isSmart }) {
            throw DevicePhotosLibraryError.notFound
        }
        commitCount += 1
        importedFiles.append(fileURL)
        let id = "demo-new-\(nextNumber)"
        nextNumber += 1
        let now = clock()
        entries[id] = Entry(
            asset: DevicePhotoAsset(id: id, modified: now, created: now, isVideo: isVideo, width: 1_024, height: 768,
                                    favorite: false, duration: isVideo ? 3 : nil, latitude: nil, longitude: nil),
            albumIDs: albumID.map { [$0] } ?? [])
        // A photo the app adds is one it may keep seeing under limited access.
        if authorization == .limited { limitedSelection.insert(id) }
        return id
    }

    /// Each change lands at least ten milliseconds after the one before it, as a real edit does.
    private func nextModification(after previous: Date) -> Date {
        max(clock(), previous.addingTimeInterval(0.01))
    }

    private static func replacing(_ asset: DevicePhotoAsset, modified: Date? = nil, favorite: Bool? = nil) -> DevicePhotoAsset {
        DevicePhotoAsset(
            id: asset.id, modified: modified ?? asset.modified, created: asset.created, isVideo: asset.isVideo,
            width: asset.width, height: asset.height, favorite: favorite ?? asset.favorite,
            duration: asset.duration, latitude: asset.latitude, longitude: asset.longitude)
    }
}
