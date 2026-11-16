import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Bighelp

@MainActor
struct PetdexTests {
    @Test func manifestKeepsOnlyPetdexHostedPetsOnce() throws {
        let manifest = Data("""
        {"generatedAt": "2026-01-01T00:00:00Z", "total": 6, "pets": [
          {"slug": "boba", "displayName": "Boba", "kind": "creature",
           "spritesheetUrl": "https://assets.petdex.dev/curated/boba/sprite-v2.webp"},
          {"slug": "nameless", "spritesheetUrl": "https://assets.petdex.dev/pets/nameless-1/sprite.webp"},
          {"slug": "plain-http", "displayName": "Plain", "spritesheetUrl": "http://assets.petdex.dev/pets/a/sprite.webp"},
          {"slug": "lookalike", "displayName": "Lookalike", "spritesheetUrl": "https://petdex.dev.example.com/sprite.webp"},
          {"slug": "boba", "displayName": "Again", "spritesheetUrl": "https://assets.petdex.dev/pets/boba-2/sprite.webp"},
          {"displayName": "No slug", "spritesheetUrl": "https://assets.petdex.dev/pets/x/sprite.webp"}
        ]}
        """.utf8)
        let pets = try PetdexPolicy.pets(fromManifest: manifest)
        #expect(pets.map(\.slug) == ["boba", "nameless"])
        #expect(pets[0].curated)
        #expect(!pets[1].curated)
        #expect(pets[1].displayName == "nameless")
    }

    @Test func onlyPetdexAddressesOverHTTPSAreFetched() {
        #expect(PetdexPolicy.isPetdexURL(URL(string: "https://petdex.dev/api/manifest")))
        #expect(PetdexPolicy.isPetdexURL(URL(string: "https://assets.petdex.dev/pets/a/preview.webp")))
        #expect(!PetdexPolicy.isPetdexURL(URL(string: "http://assets.petdex.dev/pets/a/preview.webp")))
        #expect(!PetdexPolicy.isPetdexURL(URL(string: "https://petdex.dev.example.com/a.webp")))
        #expect(!PetdexPolicy.isPetdexURL(URL(string: "https://notpetdex.dev/a.webp")))
        #expect(!PetdexPolicy.isPetdexURL(nil))
    }

    @Test func previewAddressesComeOnlyFromPlainSlugs() {
        #expect(PetdexPolicy.previewURL(slug: "aurelion-sol-2")?.absoluteString
            == "https://assets.petdex.dev/pets/aurelion-sol-2/preview.webp")
        for slug in ["", "../manifest", "a/b", "Boba", "boba?x=1", "-lead", "spa ce", "émile"] {
            #expect(PetdexPolicy.previewURL(slug: slug) == nil, "\(slug)")
        }
    }

    @Test func searchMatchesNameOrSlugAndListsInstalledThenHandPickedPetsFirst() {
        let pets = [
            PetdexPet(slug: "sir-wobble", displayName: "Sir Wobble", spritesheetURL: nil),
            PetdexPet(slug: "dot", displayName: "Dot", spritesheetURL: nil, curated: true),
            PetdexPet(slug: "wobble-cat", displayName: "Cat", spritesheetURL: nil),
            PetdexPet(slug: "mine", displayName: "Little Wobble", spritesheetURL: nil, installed: true),
        ]
        #expect(PetdexPolicy.ranked(pets, query: "").map(\.slug) == ["mine", "dot", "sir-wobble", "wobble-cat"])
        #expect(PetdexPolicy.ranked(pets, query: "  WOBBLE ").map(\.slug) == ["mine", "sir-wobble", "wobble-cat"])
        #expect(PetdexPolicy.ranked(pets, query: "zebra").isEmpty)
    }

    @Test func firstFrameIsTheTopLeftCellOfTheSheet() throws {
        let sheet = try Self.png(width: 384, height: 416) { x, y in
            x < 192 && y < 208 ? (230, 40, 40) : (40, 40, 230)
        }
        let frame = try PetdexSprite.firstFrame(fromSheet: sheet)
        let image = try #require(Self.cgImage(frame))
        #expect(image.width == 192 && image.height == 208)
        let pixel = try #require(Self.pixel(image, x: 100, y: 100))
        #expect(pixel.red > 200 && pixel.blue < 80)
    }

    @Test func badSheetsAndThumbnailsAreRejected() throws {
        #expect(throws: PetdexError.invalidImage) { _ = try PetdexSprite.firstFrame(fromSheet: Data("not an image".utf8)) }
        let jpeg = try Self.encoded(Self.image(width: 8, height: 8) { _, _ in (1, 2, 3) }, as: .jpeg)
        #expect(throws: PetdexError.invalidImage) { _ = try PetdexSprite.firstFrame(fromSheet: jpeg) }
        #expect(throws: PetdexError.tooLarge) {
            _ = try PetdexSprite.firstFrame(fromSheet: Data(count: PetdexPolicy.maximumSheetBytes + 1))
        }
        let png = try #require(PetdexFixtures.thumbnail(slug: "pip"))
        #expect(try PetdexSprite.thumbnail(fromDataURI: "data:image/png;base64," + png.base64EncodedString()) == png)
        #expect(throws: PetdexError.invalidImage) {
            _ = try PetdexSprite.thumbnail(fromDataURI: "data:image/jpeg;base64," + jpeg.base64EncodedString())
        }
        #expect(throws: PetdexError.invalidImage) {
            _ = try PetdexSprite.thumbnail(fromDataURI: "data:image/png;base64," + jpeg.base64EncodedString())
        }
        #expect(throws: PetdexError.invalidImage) { _ = try PetdexSprite.thumbnail(fromDataURI: "data:image/png;base64,@@@") }
    }

    @Test func pickedPetBecomesASquarePixelSharpAvatar() throws {
        let frame = try #require(PetdexFixtures.thumbnail(slug: "pip"))
        let avatar = try #require(Self.cgImage(try PetdexSprite.avatar(fromFrame: frame)))
        #expect(avatar.width == 416 && avatar.height == 416)
        // 96×104 scales by a whole 4×, centered: the corners stay clear.
        #expect(Self.pixel(avatar, x: 2, y: 2)?.alpha == 0)
    }

    /// A sheet's rows become moves, in Hermes's current 9-row layout and the
    /// older 8-row one; each move is up to six 192×208 frames.
    @Test func aSheetIsCutIntoMovesForBothLayouts() throws {
        let demo = try PetdexSprite.strips(fromSheet: try #require(PetdexFixtures.sheet(slug: "pip")))
        #expect(Set(demo.keys) == Set(PetdexMove.allCases))
        for strip in demo.values {
            let frames = PetdexSprite.frames(fromStrip: strip)
            #expect(frames.count == PetdexSprite.framesPerMove)
            #expect(frames.allSatisfy { $0.width == 192 && $0.height == 208 })
        }
        // Each row painted with its own red, to read back which row a move came from.
        func rows(_ strips: [PetdexMove: Data]) throws -> [PetdexMove: Int] {
            try strips.mapValues { strip in
                let frame = try #require(PetdexSprite.frames(fromStrip: strip).first)
                return Int(try #require(Self.pixel(frame, x: 96, y: 104)).red) / 20
            }
        }
        let current = try PetdexSprite.strips(fromSheet: try Self.png(width: 1536, height: 1872) { _, y in
            (UInt8(y / 208 * 20), 0, 0)
        })
        #expect(try rows(current) == [.idle: 0, .wave: 3, .jump: 4, .failed: 5, .waiting: 6, .run: 7, .review: 8])
        let legacy = try PetdexSprite.strips(fromSheet: try Self.png(width: 1728, height: 1664) { _, y in
            (UInt8(y / 208 * 20), 0, 0)
        })
        #expect(try rows(legacy) == [.idle: 0, .wave: 1, .run: 2, .failed: 3, .review: 4, .jump: 5])
    }

    /// Like Hermes, a move stops at its first empty frame instead of blinking
    /// out, and a move with no frames at all is left out (idle plays instead).
    @Test func aMoveStopsAtItsFirstEmptyFrame() throws {
        let sheet = try Self.png(width: 1536, height: 1872, color: { _, _ in (200, 80, 40) }, clear: { x, y in
            (y / 208 == 3 && x / 192 >= 4) || y / 208 == 6
        })
        let strips = try PetdexSprite.strips(fromSheet: sheet)
        #expect(PetdexSprite.frames(fromStrip: try #require(strips[.wave])).count == 4)
        #expect(PetdexSprite.frames(fromStrip: try #require(strips[.idle])).count == 6)
        #expect(strips[.waiting] == nil)
    }

    @Test func movesFollowWhatTheAgentIsDoing() {
        #expect(PetdexMove(activity: .idle) == .idle)
        #expect(PetdexMove(activity: .thinking) == .review)
        #expect(PetdexMove(activity: .coding) == .run)
        #expect(PetdexMove(activity: .replying) == .run)
        #expect(PetdexMove(activity: .waiting) == .waiting)
        #expect(PetdexMove(activity: .failed) == .failed)
        #expect(PetdexMove(activity: .done) == .wave)
    }

    /// The pet goes on the agent only once its moves are saved here; they
    /// survive reopening, a failed download leaves the still picture, and
    /// removing the pet deletes its moves.
    @Test func anAgentWearsItsPetOnceItsMovesAreSaved() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = isolatedDefaults()
        let store = PetAvatarStore(defaults: defaults, directory: directory)
        let pip = PetdexFixtures.pets[0], mochi = PetdexFixtures.pets[1]
        store.assign(pip, to: "agent") {
            guard let sheet = PetdexFixtures.sheet(slug: pip.slug) else { throw PetdexError.unsupported }
            return sheet
        }
        #expect(store.frames(for: "agent", move: .idle) == nil)
        for _ in 0..<400 where store.slug(for: "agent") == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.slug(for: "agent") == pip.slug)
        #expect(store.frames(for: "agent", move: .jump)?.count == PetdexSprite.framesPerMove)
        let reopened = PetAvatarStore(defaults: defaults, directory: directory)
        #expect(reopened.frames(for: "agent", move: .review)?.count == PetdexSprite.framesPerMove)

        store.assign(mochi, to: "other") { throw PetdexError.unsupported }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.slug(for: "other") == nil)

        store.remove("agent")
        #expect(store.frames(for: "agent", move: .idle) == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))?.isEmpty ?? true)
    }

    /// A pet whose moves are saved is not fetched again, also where the folder's path has a space or
    /// a letter that a URL writes as percent codes (a Mac home folder can). The check for the saved
    /// moves used the URL's own spelling of the path, found no file there, and fetched the sheet at
    /// every pick.
    @Test func savedMovesAreFoundWhereThePathHasASpace() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Pets of José \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pip = PetdexFixtures.pets[0]
        let first = PetAvatarStore(defaults: isolatedDefaults(), directory: directory)
        first.assign(pip, to: "agent") {
            guard let sheet = PetdexFixtures.sheet(slug: pip.slug) else { throw PetdexError.unsupported }
            return sheet
        }
        for _ in 0..<400 where first.slug(for: "agent") == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(first.slug(for: "agent") == pip.slug)

        var fetches = 0
        let again = PetAvatarStore(defaults: isolatedDefaults(), directory: directory)
        again.assign(pip, to: "other") {
            fetches += 1
            throw PetdexError.unsupported
        }
        for _ in 0..<400 where again.slug(for: "other") == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(again.slug(for: "other") == pip.slug, "The saved moves go on the second agent")
        #expect(fetches == 0, "Nothing is fetched for moves that are saved")
    }

    @Test func demoPetsAreDrawnLocallyAtPetThumbSize() throws {
        #expect(PetdexFixtures.pets.count >= 24)
        #expect(Set(PetdexFixtures.pets.map(\.slug)).count == PetdexFixtures.pets.count)
        #expect(PetdexFixtures.pets.allSatisfy { $0.spritesheetURL == nil })
        let thumbnail = try #require(PetdexFixtures.thumbnail(slug: PetdexFixtures.pets[9].slug))
        let image = try #require(Self.cgImage(thumbnail))
        #expect(image.width == 96 && image.height == 104)
        #expect(PetdexFixtures.thumbnail(slug: "not-a-demo-pet") == nil)
    }

    @Test func thumbnailCacheKeepsOnlyRecentPetsAndNeverKeepsFailures() async {
        final class Counter { var loads = 0 }
        let cache = PetdexThumbnailCache()
        let counter = Counter()
        #expect(await cache.value("missing") { counter.loads += 1; return nil } == nil)
        #expect(await cache.value("missing") { counter.loads += 1; return Data([1]) } == Data([1]))
        #expect(counter.loads == 2)
        for index in 0..<PetdexThumbnailCache.capacity { _ = await cache.value("pet-\(index)") { Data([2]) } }
        #expect(cache.cached("missing") == nil, "The oldest pet makes room")
        #expect(cache.cached("pet-0") == Data([2]))
    }

    @Test func galleryUsesTheHostPagesThroughAndFallsBackWhenItCant() async {
        let hostPets = (0..<60).map { PetdexPet(slug: "pet-\($0)", displayName: "Pet \($0)", spritesheetURL: nil) }
        let model = PetdexGalleryModel(source: PetdexSource(
            hostGallery: { hostPets }, hostThumbnail: { _ in Data([7]) }, publicCatalog: nil, cacheScope: "a"
        ), cache: PetdexThumbnailCache())
        await model.loadIfNeeded()
        #expect(model.phase == .loaded)
        #expect(!model.isFromPetdex)
        #expect(model.visible.count == PetdexGalleryModel.pageSize)
        model.reached(hostPets[3])
        #expect(model.visible.count == PetdexGalleryModel.pageSize)
        model.reached(model.visible.last!)
        #expect(model.visible.count == PetdexGalleryModel.pageSize * 2)
        model.query = "pet-5"
        #expect(model.visible.map(\.slug) == ["pet-5", "pet-50", "pet-51", "pet-52", "pet-53", "pet-54", "pet-55",
                                              "pet-56", "pet-57", "pet-58", "pet-59"])
        #expect(await model.thumbnail(hostPets[5]) == Data([7]))

        let offline = PetdexGalleryModel(source: PetdexSource(
            hostGallery: { throw PetdexError.unsupported }, hostThumbnail: nil, publicCatalog: nil, cacheScope: "b"
        ), cache: PetdexThumbnailCache())
        await offline.loadIfNeeded()
        #expect(offline.phase == .failed)
    }

    // MARK: Images

    private static func image(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8),
                              clear: (Int, Int) -> Bool = { _, _ in false }) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where !clear(x, y) {
                let (r, g, b) = color(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = r; bytes[offset + 1] = g; bytes[offset + 2] = b; bytes[offset + 3] = 255
            }
        }
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private static func png(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8),
                            clear: (Int, Int) -> Bool = { _, _ in false }) throws -> Data {
        try encoded(image(width: width, height: height, color: color, clear: clear), as: .png)
    }

    private static func encoded(_ image: CGImage, as type: UTType) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func cgImage(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
