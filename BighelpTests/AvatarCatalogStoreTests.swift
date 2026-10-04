import Foundation
import Testing
@testable import Bighelp

/// The avatar catalog: lenient reading, on-device start and expiry, ETags, a good copy that a
/// failure never replaces, checked packs, and saved picks that outlive the catalog.
@MainActor
@Suite(.serialized)
struct AvatarCatalogStoreTests {
    private actor FakeTransport: AvatarCatalogFetching {
        var replies: [URL: [Result<AvatarCatalogFetchResult, URLError>]] = [:]
        var sentETags: [String?] = []
        var requests: [URL] = []

        func reply(_ url: URL, _ result: Result<AvatarCatalogFetchResult, URLError>) {
            replies[url, default: []].append(result)
        }

        func fetch(_ url: URL, etag: String?) async throws -> AvatarCatalogFetchResult {
            requests.append(url)
            if url == AvatarCatalogPolicy.discoveryURL { sentETags.append(etag) }
            guard var queue = replies[url], !queue.isEmpty else { throw URLError(.notConnectedToInternet) }
            let next = queue.removeFirst()
            replies[url] = queue
            return try next.get()
        }
    }

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private static let packURL = URL(string: "https://avatars.bighelp.app/assets/pack.json")!

    private static func discovery(expiresAt: String? = "2026-11-03T00:00:00-06:00", sha: String, extra: String = "") -> Data {
        let expiry = expiresAt.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"schemaVersion":1,"revision":"r1","categories":[],
         "sets":[{"id":"bighelp","name":"bighelp","category":"bighelp","startsAt":null,"expiresAt":null},
                 {"id":"halloween","name":"Halloween","category":"seasonal","startsAt":null,"expiresAt":\(expiry)},
                 {"id":"community","name":"Community","category":"community","startsAt":null,"expiresAt":null}],
         "avatars":[
          {"id":"bighelp-biggie","name":"Biggie","setId":"bighelp","category":"bighelp","startsAt":null,"expiresAt":null,
           "kit":{"url":"\(packURL.absoluteString)","sha256":"\(sha)","bytes":10}},
          {"id":"halloween-ghost","name":"Ghost","setId":"halloween","category":"seasonal","startsAt":null,"expiresAt":\(expiry),
           "kit":{"url":"https://avatars.bighelp.app/assets/ghost.json","sha256":"\(String(repeating: "a", count: 64))","bytes":10}},
          {"id":"evil","name":"Evil","setId":"bighelp","category":"bighelp",
           "kit":{"url":"https://example.com/evil.json","sha256":"\(String(repeating: "b", count: 64))","bytes":10}},
          {"id":"BAD ID","name":"Bad","setId":"bighelp","category":"bighelp",
           "kit":{"url":"\(packURL.absoluteString)","sha256":"\(sha)","bytes":10}}\(extra)
         ],"nextChangeAt":null}
        """.utf8)
    }

    /// One character from the shipped pack, as a single-character pack.
    private static func pack(id: String = "bighelp-biggie") throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "AvatarCatalogKit", withExtension: "json"))
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let characters = try #require(object["characters"] as? [[String: Any]])
        object["characters"] = characters.filter { $0["id"] as? String == id }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "avatar-catalog-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func readsLenientlyAndOnlyFromTheAvatarHost() throws {
        let catalog = try #require(AvatarCatalog(discovery: Self.discovery(sha: String(repeating: "c", count: 64))))
        #expect(catalog.avatars.map(\.id) == ["bighelp-biggie", "halloween-ghost"], "Other hosts and bad IDs are dropped")
        let date = try #require(AvatarCatalog.date("2026-10-04T12:00:00Z"))
        #expect(catalog.sets(in: .bighelp, at: date).map(\.id) == ["bighelp", "halloween"])
        #expect(catalog.sets(in: .other, at: date).isEmpty, "A set with no characters doesn't show")
        #expect(AvatarCatalog(discovery: Data("{\"schemaVersion\":2}".utf8)) == nil)
        #expect(AvatarCatalog.date("2026-11-03") == nil, "Dates need a time and offset")
    }

    @Test func seasonalSetsExpireOnThePhoneAtTheExactMoment() throws {
        let catalog = try #require(AvatarCatalog(discovery: Self.discovery(sha: String(repeating: "c", count: 64))))
        let cutoff = try #require(AvatarCatalog.date("2026-11-03T06:00:00Z"))
        #expect(catalog.avatars(in: .bighelp, at: cutoff.addingTimeInterval(-1)).map(\.id).contains("halloween-ghost"))
        #expect(!catalog.avatars(in: .bighelp, at: cutoff).map(\.id).contains("halloween-ghost"))
        #expect(catalog.nextChange(after: cutoff.addingTimeInterval(-60)) == cutoff)
        #expect(catalog.nextChange(after: cutoff) == nil)
    }

    @Test func etagsGoBackUnchangedAndFailuresKeepTheGoodCopy() async throws {
        let transport = FakeTransport()
        let clock = Clock(try #require(AvatarCatalog.date("2026-10-04T12:00:00Z")))
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sha = AvatarKitPackValidator.sha256(try Self.pack())
        await transport.reply(AvatarCatalogPolicy.discoveryURL, .success(.fetched(Self.discovery(sha: sha), etag: "W/\"v1\"", maxAge: 300)))
        let store = AvatarCatalogStore(transport: transport, directory: folder, clock: { clock.now })
        await store.refreshIfNeeded()
        #expect(store.catalog.avatars.count == 2)

        await store.refreshIfNeeded()
        #expect(await transport.sentETags == [nil], "Not again within five minutes")

        clock.now.addTimeInterval(301)
        await transport.reply(AvatarCatalogPolicy.discoveryURL, .success(.notModified(maxAge: 300)))
        await store.refreshIfNeeded()
        #expect(await transport.sentETags == [nil, "W/\"v1\""], "The weak ETag goes back as it came")

        clock.now.addTimeInterval(301)
        await transport.reply(AvatarCatalogPolicy.discoveryURL, .success(.fetched(Data("not json".utf8), etag: "x", maxAge: nil)))
        await store.refreshIfNeeded()
        #expect(store.catalog.avatars.count == 2, "A bad download doesn't replace the good copy")

        clock.now.addTimeInterval(301)
        await store.refreshIfNeeded()
        #expect(store.catalog.avatars.count == 2, "Offline keeps it too")

        let cold = AvatarCatalogStore(transport: FakeTransport(), directory: folder, clock: { clock.now })
        #expect(cold.catalog.avatars.count == 2, "A cold start reads the saved copy")
    }

    @Test func packsAreHashCheckedAndKeptForPicksThatExpire() async throws {
        let transport = FakeTransport()
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try Self.pack()
        let sha = AvatarKitPackValidator.sha256(data)
        let store = AvatarCatalogStore(transport: transport, directory: folder)
        let reference = AvatarCatalogReference(id: "bighelp-biggie", name: "Biggie", kitSHA256: sha, kitURL: Self.packURL)

        await transport.reply(Self.packURL, .success(.fetched(Data(data.dropLast()), etag: nil, maxAge: nil)))
        #expect(await store.pack(for: reference) == nil, "Bytes that don't match the hash are refused")

        await transport.reply(Self.packURL, .success(.fetched(data, etag: nil, maxAge: nil)))
        #expect(await store.pack(for: reference)?.character("bighelp-biggie") != nil)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "packs/\(sha).json").path))

        // The catalog drops it; the pick still draws from the kept pack, offline.
        let library = AvatarKitLibrary.shared
        library.directory = folder.appending(path: "packs", directoryHint: .isDirectory)
        var appearance = CompanionAppearance(usesCharacterColors: true)
        appearance.catalogAvatar = reference
        #expect(appearance.kitArt?.art.id == "bighelp-biggie")
        #expect(appearance.displayName == "Biggie")
    }

    @Test func unknownCatalogIDsNeverBecomeALobster() throws {
        var appearance = CompanionAppearance(character: .dog)
        appearance.catalogAvatar = AvatarCatalogReference(
            id: "brand-new-one", name: "Brand New", kitSHA256: String(repeating: "d", count: 64),
            kitURL: URL(string: "https://avatars.bighelp.app/assets/new.json")!)
        let data = try JSONEncoder().encode(appearance)
        let decoded = try JSONDecoder().decode(CompanionAppearance.self, from: data)
        #expect(decoded.catalogAvatar?.id == "brand-new-one")
        #expect(decoded.character == .dog)
        #expect(decoded.kitArt == nil, "Nothing to draw until its pack arrives; not a stand-in")

        // A reference pointing anywhere but the avatar host is dropped, the rest of the look kept.
        let tampered = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "avatars.bighelp.app", with: "example.com")
        let safe = try JSONDecoder().decode(CompanionAppearance.self, from: Data(tampered.utf8))
        #expect(safe.catalogAvatar == nil && safe.character == .dog)
    }

    @Test func picksAndColorsSurviveTheStore() throws {
        let suite = "avatar-catalog-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let entry = try #require(AvatarCatalog.bundled.avatars(in: .bighelp, at: .now).first)
        let store = CompanionStore(defaults: defaults)
        #expect(store.defaultAppearance.catalogAvatar != nil, "A new phone's pet is a bighelp character")
        var look = CompanionAppearance(usesCharacterColors: false)
        look.catalogAvatar = AvatarCatalogReference(entry)
        look.colorHex = "#3F6FD8"
        look.matchesTheme = false
        store.setOverride(look, for: "host:agent")
        let reopened = CompanionStore(defaults: defaults)
        #expect(reopened.override(for: "host:agent")?.catalogAvatar?.id == entry.id)
        #expect(reopened.override(for: "host:agent")?.avatarKitColors(themeHex: "#000000")?.primary == "#3F6FD8")
    }

    @Test func packsWithUnsupportedDrawingAreRefused() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Self.pack()) as? [String: Any])
        var characters = try #require(object["characters"] as? [[String: Any]])
        characters[0]["tree"] = ["t": "image", "st": ["idle": [:]]]
        object["characters"] = characters
        #expect(AvatarKitPackValidator.decode(try JSONSerialization.data(withJSONObject: object)) == nil)
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        #expect(AvatarKitPackValidator.nesting(of: Data(deep.utf8)) == 200)
        #expect(AvatarKitPackValidator.decode(Data(deep.utf8)) == nil)
    }
}
