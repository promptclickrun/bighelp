import Foundation
import Testing
import UIKit
@testable import Bighelp

/// The agent's `iphone_photos` tool on the phone. The library is `DemoDevicePhotosLibrary`, an
/// in-memory stand-in that follows PhotoKit where the tool depends on it: a limited library hides
/// what the person didn't pick, every change moves the modification date, and iOS's delete
/// confirmation can be declined. Every photo, album and path here is made up.
@MainActor
struct DevicePhotosToolTests {
    private static let epoch = DemoDevicePhotosLibrary.epoch

    // MARK: Fixtures

    @MainActor
    private final class Fixture {
        let library: DemoDevicePhotosLibrary
        let files: FakeHostFiles
        let tool: DevicePhotosTool
        var authorizeCalls = 0
        var failAuthorizeAt: Int?

        static let context = DeviceToolCallContext(
            requestID: "request-1", hostID: "host-1", agentID: "agent-1", sessionID: "session-1", turnID: "turn-1")

        init(authorization: DevicePhotosAuthorization = .authorized) {
            let library = DemoDevicePhotosLibrary(authorization: authorization)
            let files = FakeHostFiles()
            self.library = library
            self.files = files
            tool = DevicePhotosTool(library: library, hostFiles: { files })
        }

        func listIDs(_ arguments: [String: BighelpJSONValue] = [:]) async throws -> [String] {
            ids(try await run("list", arguments))
        }

        func run(_ operation: String, _ arguments: [String: BighelpJSONValue] = [:]) async throws -> [String: BighelpJSONValue] {
            try await tool.execute(operation: "photos." + operation, arguments: arguments, context: Self.context) { [self] in
                authorizeCalls += 1
                if authorizeCalls == failAuthorizeAt { throw AppleDeviceToolError.authorizationRequired }
            }
        }

        func revision(_ id: String) -> BighelpJSONValue {
            .string(DevicePhotosTool.revision(library.asset(id)!))
        }

        static func objects(_ value: BighelpJSONValue?) -> [[String: BighelpJSONValue]] {
            (value?.array ?? []).compactMap { $0.object }
        }

        func ids(_ result: [String: BighelpJSONValue]) -> [String] {
            (result["photos"]?.array ?? []).compactMap { $0.object?["id"]?.string }
        }

        func cleanUp() { files.directories.forEach { try? FileManager.default.removeItem(at: $0) } }
    }

    @MainActor
    private final class FakeHostFiles: DeviceHostFileDownloading {
        struct Call: Equatable { let path: String, agentID: String, sessionID: String, maximumBytes: Int }
        var calls: [Call] = []
        var data = DevicePhotosToolTests.pngData()
        var mimeType = "image/png"
        var failure: (any Error)?
        var directories: [URL] = []

        func download(path: String, agentID: String, sessionID: String, maximumBytes: Int,
                      checkpoint: @MainActor () throws -> Void) async throws -> DeviceHostFile {
            calls.append(Call(path: path, agentID: agentID, sessionID: sessionID, maximumBytes: maximumBytes))
            if let failure { throw failure }
            try checkpoint()
            let directory = FileManager.default.temporaryDirectory.appending(path: "photos-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            directories.append(directory)
            let file = directory.appending(path: "photo.png")
            try data.write(to: file)
            return DeviceHostFile(url: file, directory: directory, fileName: "made-up.png", mimeType: mimeType,
                                  byteCount: data.count)
        }
    }

    static func pngData() -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// Pseudo-random pixels: hard to compress, so the encoder has to work to fit.
    private static func noisyImage(width: Int, height: Int) -> UIImage {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bytes[index + channel] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }

    private static func iso(_ offsetFromEpoch: TimeInterval) -> BighelpJSONValue {
        .string(DevicePhotosTool.timestamp(epoch.addingTimeInterval(offsetFromEpoch)))
    }

    // MARK: Access

    @Test func statusMapsIOSAuthorizationWithoutAsking() async {
        let cases: [(DevicePhotosAuthorization, DeviceToolSystemAccess)] = [
            (.notDetermined, .notRequested), (.authorized, .available), (.limited, .available),
            (.denied, .denied), (.restricted, .unavailable),
        ]
        for (authorization, expected) in cases {
            let fixture = Fixture(authorization: authorization)
            #expect(await fixture.tool.status() == expected)
            #expect(fixture.library.requestedAuthorization == 0)
        }
    }

    @Test func turningPhotosOnAsksIOSOnlyTheFirstTime() async {
        let fresh = Fixture(authorization: .notDetermined)
        fresh.library.answerToRequest = .limited
        #expect(await fresh.tool.request() == .available)
        #expect(fresh.library.requestedAuthorization == 1)

        let refused = Fixture(authorization: .notDetermined)
        refused.library.answerToRequest = .denied
        #expect(await refused.tool.request() == .denied)

        for authorization in [DevicePhotosAuthorization.denied, .authorized, .restricted] {
            let fixture = Fixture(authorization: authorization)
            _ = await fixture.tool.request()
            #expect(fixture.library.requestedAuthorization == 0, "iOS asks once; later the person uses Settings")
        }
    }

    @Test func accessPulledInSettingsStopsTheCallEvenWithTheSwitchOn() async {
        let fixture = Fixture()
        fixture.library.authorization = .denied
        await #expect(throws: AppleDeviceToolError.authorizationRequired) { try await fixture.run("list") }
        fixture.library.authorization = .restricted
        await #expect(throws: AppleDeviceToolError.unavailable) { try await fixture.run("list") }
    }

    @Test func aLimitedLibraryShowsOnlyWhatThePersonPicked() async throws {
        let fixture = Fixture(authorization: .limited)
        fixture.library.limitedSelection = ["demo-photo-2", "demo-photo-4"]
        let listed = try await fixture.run("list")
        #expect(fixture.ids(listed) == ["demo-photo-2", "demo-photo-4"])
        #expect(listed["access"] == .string("limited"))
        // What isn't shared is nothing at all, not a refusal that proves it exists.
        await #expect(throws: DevicePhotosTool.Failure.notFound) {
            try await fixture.run("get", ["id": .string("demo-photo-1")])
        }
        await #expect(throws: DevicePhotosTool.Failure.notFound) {
            try await fixture.run("delete", ["ids": .array([.string("demo-photo-1")])])
        }
        let albums = try await fixture.run("albums")
        let trip = try #require(Fixture.objects(albums["albums"]).first { $0["id"] == .string("album-trip") })
        #expect(trip["count"] == .integer(1), "the album counts only the shared photos")
        #expect(try await Fixture(authorization: .authorized).run("list")["access"] == .string("full"))
    }

    // MARK: Validation happens before anything is touched

    @Test func badArgumentsAreRefusedBeforeThePhoneTouchesAnything() async {
        let tooLong = String(repeating: "x", count: DevicePhotosTool.maximumIdentifierLength + 1)
        let cases: [(String, [String: BighelpJSONValue])] = [
            ("list", ["surprise": .boolean(true)]),
            ("list", ["start": Self.iso(0)]),
            ("list", ["end": Self.iso(0)]),
            ("list", ["start": Self.iso(10), "end": Self.iso(0)]),
            ("list", ["start": .string("yesterday"), "end": Self.iso(0)]),
            ("list", ["limit": .integer(0)]),
            ("list", ["limit": .integer(101)]),
            ("list", ["limit": .string("5")]),
            ("list", ["mediaType": .string("audio")]),
            ("list", ["favorites": .string("yes")]),
            ("list", ["albumID": .string("")]),
            ("albums", ["limit": .integer(1)]),
            ("get", [:]),
            ("get", ["id": .string("demo-photo-1"), "maxPixels": .integer(255)]),
            ("get", ["id": .string("demo-photo-1"), "maxPixels": .integer(1_025)]),
            ("get", ["id": .string(tooLong)]),
            ("save", [:]),
            ("save", ["path": .string("")]),
            ("save", ["path": .string("/host/made-up.png"), "albumID": .integer(3)]),
            ("update", ["id": .string("demo-photo-1"), "expectedRevision": .string("r")]),
            ("update", ["id": .string("demo-photo-1"), "favorite": .boolean(true)]),
            ("update", ["id": .string("demo-photo-1"), "expectedRevision": .string("r"), "favorite": .string("yes")]),
            ("update", ["id": .string("demo-photo-1"), "expectedRevision": .string("r"),
                        "addToAlbumIDs": .array([.string("album-trip")]), "removeFromAlbumIDs": .array([.string("album-trip")])]),
            ("update", ["id": .string("demo-photo-1"), "expectedRevision": .string("r"),
                        "addToAlbumIDs": .array((0..<21).map { .string("album-\($0)") })]),
            ("createAlbum", [:]),
            ("createAlbum", ["title": .string("   ")]),
            ("createAlbum", ["title": .string(String(repeating: "a", count: 201))]),
            ("createAlbum", ["title": .string("Line\nbreak")]),
            ("delete", [:]),
            ("delete", ["ids": .array([])]),
            ("delete", ["ids": .array((0..<51).map { .string("demo-photo-\($0)") })]),
            ("delete", ["ids": .string("demo-photo-1")]),
            ("delete", ["ids": .array([.integer(1)])]),
        ]
        for (operation, arguments) in cases {
            let fixture = Fixture()
            await #expect(throws: AppleDeviceToolError.invalidArguments, "photos.\(operation) \(arguments)") {
                try await fixture.run(operation, arguments)
            }
            #expect(fixture.authorizeCalls == 0, "photos.\(operation) checked its arguments before anything else")
            #expect(fixture.library.commitCount == 0)
            #expect(fixture.files.calls.isEmpty)
        }
    }

    @Test func anUnknownOperationIsRefused() async {
        let fixture = Fixture()
        await #expect(throws: AppleDeviceToolError.unsupportedOperation) { try await fixture.run("rename") }
    }

    // MARK: Reading

    @Test func listIsNewestFirstAndSaysWhenThereIsMore() async throws {
        let fixture = Fixture()
        let all = try await fixture.run("list")
        #expect(fixture.ids(all) == (1...5).map { "demo-photo-\($0)" })
        #expect(all["truncated"] == .boolean(false))
        let two = try await fixture.run("list", ["limit": .integer(2)])
        #expect(fixture.ids(two) == ["demo-photo-1", "demo-photo-2"])
        #expect(two["truncated"] == .boolean(true))
        let exact = try await fixture.run("list", ["limit": .integer(5)])
        #expect(exact["truncated"] == .boolean(false), "exactly the limit is not 'more'")
    }

    @Test func listFiltersByKindFavoriteAlbumAndCreationDate() async throws {
        let fixture = Fixture()
        #expect(try await fixture.listIDs(["mediaType": .string("video")]) == ["demo-photo-3"])
        #expect(try await fixture.listIDs(["mediaType": .string("image")]).count == 4)
        #expect(try await fixture.listIDs(["favorites": .boolean(true)]) == ["demo-photo-1"])
        #expect(try await fixture.listIDs(["favorites": .boolean(false)]).count == 4)
        #expect(try await fixture.listIDs(["albumID": .string("album-trip")]) == ["demo-photo-1", "demo-photo-2"])
        await #expect(throws: DevicePhotosTool.Failure.notFound) { try await fixture.run("list", ["albumID": .string("album-gone")]) }
        // Start is included, end is not: day 0 is the newest photo, day -2 the third.
        #expect(try await fixture.listIDs(["start": Self.iso(-2 * 86_400), "end": Self.iso(0)])
                == ["demo-photo-2", "demo-photo-3"])
        // An offset instead of Z names the same instants (the epoch is 2026-09-21T14:13:20Z).
        #expect(try await fixture.listIDs([
            "start": .string("2026-09-19T16:13:20+02:00"), "end": .string("2026-09-21T09:13:20-05:00")])
                == ["demo-photo-2", "demo-photo-3"])
    }

    @Test func listItemsCarryOnlyTheContractsFields() async throws {
        let fixture = Fixture()
        let listed = try await fixture.run("list")
        let items = Fixture.objects(listed["photos"])
        let first = try #require(items.first)
        #expect(Set(first.keys) == ["id", "revision", "mediaType", "created", "width", "height", "favorite"])
        #expect(first["mediaType"] == .string("image"))
        #expect(first["favorite"] == .boolean(true))
        #expect(first["created"] == .string("2026-09-21T14:13:20.000Z"))
        #expect(first["revision"] == .string("2026-09-21T14:14:20.000Z"))
        let video = try #require(items.first { $0["id"] == .string("demo-photo-3") })
        #expect(video["mediaType"] == .string("video"))
        #expect(video["durationSeconds"] == .number(12.5))
        #expect(first["durationSeconds"] == nil, "only videos have a length")
        let placed = try #require(items.first { $0["id"] == .string("demo-photo-2") })
        #expect(placed["latitude"] == .number(12.3456) && placed["longitude"] == .number(-65.4321))
        #expect(first["latitude"] == nil && first["longitude"] == nil, "no place means no coordinates")
        for item in items {
            let revision = try #require(item["revision"]?.string)
            #expect(revision.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil)
        }
    }

    @Test func aFullPageOfPhotosStaysUnderTheResultLimit() async throws {
        let fixture = Fixture()
        let png = try Self.tempPNG()
        defer { try? FileManager.default.removeItem(at: png) }
        for _ in 0..<110 { _ = try await fixture.library.importMedia(fileURL: png, isVideo: false, albumID: nil, beforeCommit: {}) }
        let listed = try await fixture.run("list", ["limit": .integer(100)])
        #expect(fixture.ids(listed).count == 100)
        #expect(listed["truncated"] == .boolean(true))
        let encoded = try JSONEncoder().encode(listed)
        #expect(encoded.count < 128_000)
    }

    @Test func albumsListThePersonsAlbumsAndTheMainSmartOnes() async throws {
        let fixture = Fixture()
        let result = try await fixture.run("albums")
        let albums = Fixture.objects(result["albums"])
        func album(_ id: String) -> [String: BighelpJSONValue]? { albums.first { $0["id"] == .string(id) } }
        #expect(album("album-trip")?["title"] == .string("Sample Trip"))
        #expect(album("album-trip")?["count"] == .integer(2))
        #expect(album("album-trip")?["kind"] == .string("album"))
        #expect(album("smart-favorites")?["kind"] == .string("smart"))
        #expect(album("smart-favorites")?["count"] == .integer(1))
        #expect(album("smart-videos")?["count"] == .integer(1))
        for entry in albums { #expect(Set(entry.keys) == ["id", "title", "count", "kind"]) }
    }

    @Test func getGivesAPictureThatFitsTheResultAndKeepsTheShape() async throws {
        let fixture = Fixture()
        let result = try await fixture.run("get", ["id": .string("demo-photo-1")])
        #expect(result["id"] == .string("demo-photo-1"))
        #expect(result["revision"] == fixture.revision("demo-photo-1"))
        let image = try #require(result["image"]?.object)
        #expect(image["format"] == .string("jpeg"))
        let encoded = try #require(image["data"]?.string)
        let data = try #require(Data(base64Encoded: encoded))
        #expect(data.count <= 90_000)
        #expect(data.prefix(2) == Data([0xFF, 0xD8]), "a JPEG")
        // 4032 x 3024 fitted into the default 768 square.
        #expect(image["width"] == .integer(768) && image["height"] == .integer(576))
        let decoded = try #require(UIImage(data: data))
        #expect(Int(decoded.size.width * decoded.scale) == 768)
        #expect(fixture.library.imageRequests.map(\.maxPixels) == [768])
        #expect(try JSONEncoder().encode(result).count < 128_000)

        let small = try await fixture.run("get", ["id": .string("demo-photo-2"), "maxPixels": .integer(256)])
        #expect(small["image"]?.object?["width"] == .integer(192))
        #expect(small["image"]?.object?["height"] == .integer(256), "a tall photo is fitted by its long edge")
    }

    @Test func getGivesAVideosFirstFrameAndItsLength() async throws {
        let fixture = Fixture()
        let result = try await fixture.run("get", ["id": .string("demo-photo-3")])
        #expect(result["mediaType"] == .string("video"))
        #expect(result["durationSeconds"] == .number(12.5))
        #expect(result["image"]?.object?["width"] == .integer(768))
        #expect(result["image"]?.object?["height"] == .integer(432))
    }

    @Test func getOfAMissingPhotoIsNotFound() async {
        let fixture = Fixture()
        await #expect(throws: DevicePhotosTool.Failure.notFound) { try await fixture.run("get", ["id": .string("demo-photo-99")]) }
        #expect(fixture.library.imageRequests.isEmpty)
    }

    @Test func theEncoderStepsQualityThenSizeUntilThePictureFits() throws {
        let noisy = Self.noisyImage(width: 2_000, height: 1_500)
        let fitted = try #require(DevicePhotosJPEG.encode(noisy, maxPixels: 1_024))
        #expect(fitted.data.count <= DevicePhotosJPEG.maximumBytes)
        #expect(max(fitted.width, fitted.height) < 1_024, "noise can't fit at the full size, so it shrank")
        #expect(max(fitted.width, fitted.height) >= 64)
        #expect(abs(Double(fitted.width) / Double(fitted.height) - 4.0 / 3.0) < 0.05, "the shape is kept")
        let decoded = try #require(UIImage(data: fitted.data))
        #expect(Int(decoded.size.width * decoded.scale) == fitted.width)

        // A picture smaller than asked for is not blown up.
        let tiny = Self.noisyImage(width: 40, height: 30)
        let kept = try #require(DevicePhotosJPEG.encode(tiny, maxPixels: 1_024))
        #expect(kept.width == 40 && kept.height == 30)

        // A smooth picture fits at the size asked for.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let smooth = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 2_000), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 2_000))
        }
        let full = try #require(DevicePhotosJPEG.encode(smooth, maxPixels: 1_024))
        #expect(full.width == 1_024 && (682...683).contains(full.height))

        // Nothing fits in nothing.
        #expect(DevicePhotosJPEG.encode(noisy, maxPixels: 1_024, maxBytes: 10) == nil)
    }

    // MARK: Changing

    @Test func updateChangesAPhotoAndReturnsItsNewRevision() async throws {
        let fixture = Fixture()
        let before = fixture.revision("demo-photo-4")
        let result = try await fixture.run("update", [
            "id": .string("demo-photo-4"), "expectedRevision": before, "favorite": .boolean(true),
            "addToAlbumIDs": .array([.string("album-pets")]),
        ])
        #expect(Set(result.keys) == ["id", "revision"])
        #expect(result["revision"] != before)
        #expect(result["revision"] == fixture.revision("demo-photo-4"))
        #expect(fixture.library.asset("demo-photo-4")?.favorite == true)
        #expect(fixture.library.members(ofAlbum: "album-pets") == ["demo-photo-4"])
        // The next change needs the new revision.
        let newRevision = try #require(result["revision"])
        _ = try await fixture.run("update", [
            "id": .string("demo-photo-4"), "expectedRevision": newRevision,
            "removeFromAlbumIDs": .array([.string("album-pets")]),
        ])
        #expect(fixture.library.members(ofAlbum: "album-pets").isEmpty)
        #expect(fixture.library.asset("demo-photo-4")?.favorite == true)
    }

    @Test func aStaleRevisionChangesNothing() async throws {
        let fixture = Fixture()
        let seen = fixture.revision("demo-photo-2")
        fixture.library.touch("demo-photo-2")   // the person edits it in Photos
        await #expect(throws: AppleDeviceToolError.staleRevision) {
            try await fixture.run("update", ["id": .string("demo-photo-2"), "expectedRevision": seen, "favorite": .boolean(true)])
        }
        #expect(fixture.library.asset("demo-photo-2")?.favorite == false)
        #expect(fixture.library.commitCount == 0)
        await #expect(throws: AppleDeviceToolError.staleRevision) {
            try await fixture.run("update", ["id": .string("demo-photo-2"), "expectedRevision": .string("not a revision"),
                                             "favorite": .boolean(true)])
        }
    }

    @Test func updateOfAMissingPhotoOrAnAlbumThatCantTakePhotosIsNotFound() async {
        let fixture = Fixture()
        await #expect(throws: DevicePhotosTool.Failure.notFound) {
            try await fixture.run("update", ["id": .string("demo-photo-99"), "expectedRevision": .string("r"),
                                             "favorite": .boolean(true)])
        }
        let revision = fixture.revision("demo-photo-5")
        for album in ["smart-favorites", "album-gone"] {
            await #expect(throws: DevicePhotosTool.Failure.notFound, "\(album)") {
                try await fixture.run("update", ["id": .string("demo-photo-5"), "expectedRevision": revision,
                                                 "addToAlbumIDs": .array([.string("album-pets"), .string(album)])])
            }
        }
        #expect(fixture.library.commitCount == 0, "one bad album stops the whole update")
        #expect(fixture.library.members(ofAlbum: "album-pets").isEmpty)
    }

    @Test func createAlbumTrimsTheTitleAndReturnsItsID() async throws {
        let fixture = Fixture()
        let result = try await fixture.run("createAlbum", ["title": .string("  Made-up Garden  ")])
        #expect(Set(result.keys) == ["id"])
        let albums = try await fixture.run("albums")
        let created = try #require(Fixture.objects(albums["albums"]).first { $0["id"] == result["id"] })
        #expect(created["title"] == .string("Made-up Garden"))
        #expect(created["count"] == .integer(0))
    }

    // MARK: Delete

    @Test func deleteRemovesThePhotosOnceIOSIsConfirmed() async throws {
        let fixture = Fixture()
        let result = try await fixture.run("delete", ["ids": .array([.string("demo-photo-1"), .string("demo-photo-2"), .string("demo-photo-1")])])
        #expect(result == ["deleted": .boolean(true), "count": .integer(2)], "a repeated ID counts once")
        #expect(fixture.library.asset("demo-photo-1") == nil && fixture.library.asset("demo-photo-2") == nil)
        #expect(fixture.library.allAssetIDs.count == 3)
        #expect(fixture.library.commitCount == 1)
    }

    @Test func decliningIOSsDeleteConfirmationIsCancelledAndDeletesNothing() async {
        let fixture = Fixture()
        fixture.library.allowsDelete = false
        await #expect(throws: DevicePhotosTool.Failure.cancelled) {
            try await fixture.run("delete", ["ids": .array([.string("demo-photo-1")])])
        }
        #expect(fixture.library.allAssetIDs.count == 5)
        #expect(DevicePhotosTool.Failure.cancelled.code == "cancelled")
    }

    @Test func deleteStopsBeforeIOSAsksIfAnyPhotoIsMissing() async {
        let fixture = Fixture()
        fixture.library.allowsDelete = false   // would be a "cancelled" if iOS were ever asked
        await #expect(throws: DevicePhotosTool.Failure.notFound) {
            try await fixture.run("delete", ["ids": .array([.string("demo-photo-1"), .string("demo-photo-99")])])
        }
        #expect(fixture.library.allAssetIDs.count == 5)
    }

    // MARK: Save

    @Test func saveDownloadsTheHostFileForTheCallingChatAndAddsItToTheLibrary() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let result = try await fixture.run("save", ["path": .string("/home/made-up/pictures/cat.png"), "albumID": .string("album-pets")])
        #expect(Set(result.keys) == ["id"])
        let id = try #require(result["id"]?.string)
        #expect(fixture.files.calls == [.init(path: "/home/made-up/pictures/cat.png", agentID: "agent-1",
                                              sessionID: "session-1", maximumBytes: 50 * 1_024 * 1_024)])
        #expect(fixture.library.members(ofAlbum: "album-pets") == [id])
        #expect(fixture.library.asset(id)?.isVideo == false)
        for directory in fixture.files.directories {
            #expect(!FileManager.default.fileExists(atPath: directory.path), "the temporary copy is deleted")
        }
    }

    @Test func saveToAMissingAlbumFailsBeforeDownloadingAnything() async {
        let fixture = Fixture()
        for album in ["album-gone", "smart-videos"] {
            await #expect(throws: DevicePhotosTool.Failure.notFound) {
                try await fixture.run("save", ["path": .string("/home/made-up/cat.png"), "albumID": .string(album)])
            }
        }
        #expect(fixture.files.calls.isEmpty)
    }

    @Test func saveRefusesWhatPhotosCannotHoldAndCleansUp() async throws {
        for mime in ["application/pdf", "text/plain", "image/svg+xml", "audio/mpeg", "not a type"] {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            fixture.files.mimeType = mime
            await #expect(throws: DevicePhotosTool.Failure.unsupportedMedia, "\(mime)") {
                try await fixture.run("save", ["path": .string("/home/made-up/file")])
            }
            #expect(fixture.library.commitCount == 0)
            for directory in fixture.files.directories { #expect(!FileManager.default.fileExists(atPath: directory.path)) }
        }
        // The host called it a picture, but the bytes aren't one.
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.files.data = Data("this is not a picture".utf8)
        await #expect(throws: DevicePhotosTool.Failure.unsupportedMedia) {
            try await fixture.run("save", ["path": .string("/home/made-up/cat.png")])
        }
        #expect(fixture.library.commitCount == 0)
        for directory in fixture.files.directories { #expect(!FileManager.default.fileExists(atPath: directory.path)) }
    }

    @Test func saveTellsAnImageFromAVideoByTheHostsType() throws {
        for mime in ["image/png", "image/jpeg", "image/heic", "image/gif"] { #expect(try DevicePhotosTool.isVideo(mimeType: mime) == false, "\(mime)") }
        for mime in ["video/mp4", "video/quicktime", "video/x-m4v", "VIDEO/MP4"] { #expect(try DevicePhotosTool.isVideo(mimeType: mime) == true, "\(mime)") }
        #expect(throws: DevicePhotosTool.Failure.unsupportedMedia) { try DevicePhotosTool.isVideo(mimeType: "application/octet-stream") }
    }

    @Test func saveSurfacesTheHostsRefusalsByTheirCodes() async {
        for (failure, expected) in [
            (DevicePhotosTool.Failure.fileTooLarge, "file_too_large"),
            (.notFound, "not_found"), (.unsupportedMedia, "unsupported_media"),
        ] {
            let fixture = Fixture()
            fixture.files.failure = failure
            await #expect(throws: failure) { try await fixture.run("save", ["path": .string("/home/made-up/big.mov")]) }
            #expect(failure.code == expected)
            #expect(fixture.library.commitCount == 0)
        }
    }

    @Test func aDownloadThatFailsToConnectIsUnavailableNeverUnknown() async {
        // Errors that are not the tool's own codes: the coordinator would rewrite an unclassified one to
        // outcome_unknown, telling the agent a write may have happened when nothing touched Photos.
        let errors: [any Error] = [
            WorkspaceClientError.transportUnavailable, WorkspaceClientError.ownerChanged,
            WorkspaceClientError.invalidResponse, CancellationError(), URLError(.notConnectedToInternet),
            CocoaError(.fileWriteOutOfSpace),
        ]
        for error in errors {
            let fixture = Fixture()
            fixture.files.failure = error
            await #expect(throws: AppleDeviceToolError.unavailable, "\(error)") {
                try await fixture.run("save", ["path": .string("/home/made-up/cat.png")])
            }
            #expect(fixture.library.commitCount == 0)
        }
    }

    @Test func aRealDownloadThatDropsMidwayIsUnavailable() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = FakeHost()
        host.failOnce = [40]
        let files = DirectHermesDeviceHostFiles(perform: { try await host.perform($0, $1) }, isCurrent: { true },
                                                retryDelays: [], temporaryDirectory: scratch)
        let library = DemoDevicePhotosLibrary()
        let tool = DevicePhotosTool(library: library, hostFiles: { files })
        await #expect(throws: AppleDeviceToolError.unavailable) {
            try await tool.execute(operation: "photos.save", arguments: ["path": .string("/home/made-up/cat.png")],
                                   context: Fixture.context, authorize: {})
        }
        #expect(library.commitCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        // The connection changing mid-save is the same.
        let moved = DirectHermesDeviceHostFiles(perform: { try await FakeHost().perform($0, $1) }, isCurrent: { false },
                                                retryDelays: [], temporaryDirectory: scratch)
        await #expect(throws: AppleDeviceToolError.unavailable) {
            try await DevicePhotosTool(library: library, hostFiles: { moved }).execute(
                operation: "photos.save", arguments: ["path": .string("/home/made-up/cat.png")],
                context: Fixture.context, authorize: {})
        }
    }

    @Test func saveWithoutAHostConnectionIsUnavailable() async {
        let library = DemoDevicePhotosLibrary()
        let tool = DevicePhotosTool(library: library, hostFiles: { nil })
        await #expect(throws: AppleDeviceToolError.unavailable) {
            try await tool.execute(operation: "photos.save", arguments: ["path": .string("/home/made-up/cat.png")],
                                   context: Fixture.context, authorize: {})
        }
    }

    // MARK: Authorization is checked again after every wait

    @Test func revokingAtAnyCheckpointBeforeAChangeLeavesThePhotosAlone() async throws {
        let scenarios: [(String, @MainActor (Fixture) -> [String: BighelpJSONValue])] = [
            ("delete", { _ in ["ids": .array([.string("demo-photo-1")])] }),
            ("update", { fixture in
                ["id": .string("demo-photo-1"), "expectedRevision": fixture.revision("demo-photo-1"),
                 "favorite": .boolean(false), "addToAlbumIDs": .array([.string("album-pets")])]
            }),
            ("createAlbum", { _ in ["title": .string("Made-up")] }),
            ("save", { _ in ["path": .string("/home/made-up/cat.png"), "albumID": .string("album-pets")] }),
        ]
        for (operation, arguments) in scenarios {
            let clean = Fixture()
            defer { clean.cleanUp() }
            _ = try await clean.run(operation, arguments(clean))
            let total = clean.authorizeCalls
            #expect(total >= 3, "photos.\(operation) re-checks around each wait")
            #expect(clean.library.commitCount == 1)
            // The last check is after the change; every earlier one must stop it.
            for failing in 1..<total {
                let fixture = Fixture()
                defer { fixture.cleanUp() }
                fixture.failAuthorizeAt = failing
                await #expect(throws: AppleDeviceToolError.authorizationRequired, "photos.\(operation) check \(failing)") {
                    try await fixture.run(operation, arguments(fixture))
                }
                #expect(fixture.library.commitCount == 0, "photos.\(operation) check \(failing) came too late")
                for directory in fixture.files.directories {
                    #expect(!FileManager.default.fileExists(atPath: directory.path))
                }
            }
        }
    }

    @Test func accessPulledDuringADownloadStopsTheSaveBeforeTheLibraryChanges() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let library = fixture.library
        let revoking = RevokingHostFiles(library: library, files: fixture.files)
        let tool = DevicePhotosTool(library: library, hostFiles: { revoking })
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await tool.execute(operation: "photos.save", arguments: ["path": .string("/home/made-up/cat.png")],
                                   context: Fixture.context, authorize: {})
        }
        #expect(library.commitCount == 0)
        for directory in fixture.files.directories { #expect(!FileManager.default.fileExists(atPath: directory.path)) }
    }

    // MARK: Journaling

    @Test func changesReturnOnlyWhatTheJournalMayKeep() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let results: [(String, [String: BighelpJSONValue])] = [
            ("update", try await fixture.run("update", ["id": .string("demo-photo-5"), "expectedRevision": fixture.revision("demo-photo-5"),
                                                         "favorite": .boolean(true)])),
            ("createAlbum", try await fixture.run("createAlbum", ["title": .string("Made-up")])),
            ("save", try await fixture.run("save", ["path": .string("/home/made-up/cat.png")])),
            ("delete", try await fixture.run("delete", ["ids": .array([.string("demo-photo-1")])])),
        ]
        for (operation, result) in results {
            let entry = try #require(DeviceToolCatalog.operations["photos." + operation])
            #expect(entry.journaled)
            #expect(Set(result.keys).isSubset(of: DeviceToolCatalog.durableKeys.union(entry.liveOnlyKeys)), "photos.\(operation) \(result.keys)")
        }
        for read in ["list", "albums", "get"] { #expect(DeviceToolCatalog.operations["photos." + read]?.journaled == false) }
    }

    @MainActor
    private final class Counter { var value = 0 }

    /// A host download that finishes only after the person pulled Photos access in Settings.
    @MainActor
    private final class RevokingHostFiles: DeviceHostFileDownloading {
        let library: DemoDevicePhotosLibrary
        let files: FakeHostFiles
        init(library: DemoDevicePhotosLibrary, files: FakeHostFiles) { self.library = library; self.files = files }

        func download(path: String, agentID: String, sessionID: String, maximumBytes: Int,
                      checkpoint: @MainActor () throws -> Void) async throws -> DeviceHostFile {
            let file = try await files.download(path: path, agentID: agentID, sessionID: sessionID,
                                                maximumBytes: maximumBytes, checkpoint: checkpoint)
            library.authorization = .denied
            return file
        }
    }

    // MARK: Host download

    @MainActor
    private final class FakeHost {
        var file = Data((0..<100).map { UInt8($0) })
        var chunk = 40
        var fileName = "cat.png"
        var mimeType = "image/png"
        var resolved = true
        var resolveFailure: (any Error)?
        var failOnce: Set<Int> = []
        var badOffset: Int?
        var calls: [(WorkspaceOperation, [String: BighelpJSONValue])] = []
        var fetched: [Int] = []

        func perform(_ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
            calls.append((operation, payload))
            switch operation {
            case .attachmentsResolve:
                if let resolveFailure { throw resolveFailure }
                let item = try #require(payload["items"]?.array?.first?.object)
                let attachments: [BighelpJSONValue] = resolved ? [.object([
                    "id": .string("att-1"), "fileName": .string(fileName), "mimeType": .string(mimeType),
                    "byteCount": .integer(file.count)])] : []
                return ["items": .array([.object(["itemId": item["itemId"]!, "text": .string(""), "attachments": .array(attachments)])])]
            case .attachmentsFetch:
                let offset = try #require(payload["offset"]?.integer)
                fetched.append(offset)
                if failOnce.remove(offset) != nil { throw WorkspaceClientError.transportUnavailable }
                let end = min(file.count, offset + chunk)
                return ["attachmentId": payload["attachmentId"]!, "offset": .integer(badOffset ?? offset),
                        "byteCount": .integer(file.count), "data": .string(file[offset..<end].base64EncodedString()),
                        "nextOffset": end < file.count ? .integer(end) : .null]
            default:
                throw WorkspaceClientError.invalidRequest
            }
        }
    }

    private func downloader(_ host: FakeHost, in directory: URL, current: @escaping @MainActor () -> Bool = { true })
        -> DirectHermesDeviceHostFiles {
        DirectHermesDeviceHostFiles(perform: { try await host.perform($0, $1) }, isCurrent: current,
                                    retryDelays: [.zero], temporaryDirectory: directory)
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photos-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func theHostFileComesDownInPiecesThroughTheChatsRoutes() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = FakeHost()
        let file = try await downloader(host, in: scratch).download(
            path: "/home/made-up/cat.png", agentID: "agent-1", sessionID: "session-1", maximumBytes: 1_000, checkpoint: {})
        #expect(try Data(contentsOf: file.url) == host.file)
        #expect(file.byteCount == 100 && file.mimeType == "image/png" && file.url.pathExtension == "png")
        #expect(host.fetched == [0, 40, 80])
        let resolve = try #require(host.calls.first)
        #expect(resolve.0 == .attachmentsResolve)
        #expect(resolve.1["agentId"] == .string("agent-1") && resolve.1["storedId"] == .string("session-1"))
        let item = try #require(resolve.1["items"]?.array?.first?.object)
        #expect(item["text"] == .string("MEDIA:/home/made-up/cat.png"))
        #expect(host.calls.dropFirst().allSatisfy { $0.0 == .attachmentsFetch && $0.1["attachmentId"] == .string("att-1") })
        file.remove()
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test func aDroppedPieceIsAskedForAgain() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = FakeHost()
        host.failOnce = [40]
        let file = try await downloader(host, in: scratch).download(
            path: "/p.png", agentID: "a", sessionID: "s", maximumBytes: 1_000, checkpoint: {})
        #expect(try Data(contentsOf: file.url) == host.file)
        #expect(host.fetched == [0, 40, 40, 80])
    }

    @Test func aFileOverTheLimitIsRefusedBeforeAnyOfItDownloads() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = FakeHost()
        await #expect(throws: DevicePhotosTool.Failure.fileTooLarge) {
            try await self.downloader(host, in: scratch).download(
                path: "/p.png", agentID: "a", sessionID: "s", maximumBytes: 99, checkpoint: {})
        }
        #expect(host.fetched.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test func wrongTypesAndMissingFilesAreRefusedBeforeDownloading() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pdf = FakeHost()
        pdf.mimeType = "application/pdf"; pdf.fileName = "report.pdf"
        await #expect(throws: DevicePhotosTool.Failure.unsupportedMedia) {
            try await self.downloader(pdf, in: scratch).download(path: "/p.pdf", agentID: "a", sessionID: "s", maximumBytes: 1_000, checkpoint: {})
        }
        #expect(pdf.fetched.isEmpty)
        let missing = FakeHost()
        missing.resolved = false
        await #expect(throws: DevicePhotosTool.Failure.notFound) {
            try await self.downloader(missing, in: scratch).download(path: "/gone.png", agentID: "a", sessionID: "s", maximumBytes: 1_000, checkpoint: {})
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test func theHostsOwnRefusalCodesAndAMissingRouteMapToTheAgentsCodes() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let cases: [(any Error, String)] = [
            (WorkspaceClientError.rejected(code: "file_too_large"), "file_too_large"),
            (WorkspaceClientError.rejected(code: "unsupported_media"), "unsupported_media"),
            (WorkspaceClientError.rejected(code: "not_found"), "not_found"),
            (WorkspaceClientError.rejected(code: "something_else"), "native_failure"),
            (WorkspaceClientError.unavailable(.pluginRequired), "unavailable"),
        ]
        for (failure, expected) in cases {
            let host = FakeHost()
            host.resolveFailure = failure
            do {
                _ = try await downloader(host, in: scratch).download(path: "/p.png", agentID: "a", sessionID: "s", maximumBytes: 1_000, checkpoint: {})
                Issue.record("expected a failure for \(failure)")
            } catch {
                #expect((error as? any DeviceToolFailure)?.code == expected, "\(failure)")
            }
        }
    }

    @Test func aCalledOffDownloadLeavesNothingOnThePhone() async throws {
        struct Stop: Error {}
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = FakeHost()
        let checks = Counter()
        await #expect(throws: Stop.self) {
            try await self.downloader(host, in: scratch).download(path: "/p.png", agentID: "a", sessionID: "s", maximumBytes: 1_000) {
                checks.value += 1
                if checks.value == 3 { throw Stop() }   // the switch went off after the first piece landed
            }
        }
        #expect(host.fetched == [0])
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)

        // The connection changing under the download is the same.
        let moved = FakeHost()
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await self.downloader(moved, in: scratch, current: { false }).download(
                path: "/p.png", agentID: "a", sessionID: "s", maximumBytes: 1_000, checkpoint: {})
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)

        // A piece that isn't the one asked for is refused, not stitched in.
        let wrong = FakeHost()
        wrong.badOffset = 7
        await #expect(throws: WorkspaceClientError.invalidResponse) {
            try await self.downloader(wrong, in: scratch).download(path: "/p.png", agentID: "a", sessionID: "s", maximumBytes: 1_000, checkpoint: {})
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    // MARK: Helpers

    private static func tempPNG() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "photos-test-" + UUID().uuidString + ".png")
        try pngData().write(to: url)
        return url
    }
}
