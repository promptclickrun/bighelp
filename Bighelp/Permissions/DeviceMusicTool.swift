import Foundation
#if canImport(MusicKit)
import MusicKit
#endif

/// What iOS says about access to the person's music.
enum DeviceMusicAuthorization: Equatable, Sendable {
    case notDetermined, denied, restricted, authorized
}

/// The kinds of thing the agent can find. Results name them singular; `types` takes them plural.
enum DeviceMusicKind: String, CaseIterable, Equatable, Sendable {
    case song, album, playlist, artist

    init?(plural name: String) {
        guard let kind = Self.allCases.first(where: { $0.plural == name }) else { return nil }
        self = kind
    }

    /// What `play` and `addToLibrary` accept for a result's `type`: the singular, or the plural the agent
    /// used when it searched.
    init?(resultType name: String) {
        guard let kind = Self(rawValue: name) ?? Self(plural: name) else { return nil }
        self = kind
    }

    var plural: String { rawValue + "s" }
}

enum DeviceMusicSource: String, Equatable, Sendable {
    case catalog, library
}

struct DeviceMusicItem: Equatable, Sendable {
    let id: String
    let kind: DeviceMusicKind
    let title: String
    var artist: String? = nil
    var album: String? = nil
    let source: DeviceMusicSource
}

enum DeviceMusicLibraryListing: String, Equatable, Sendable {
    case playlists, recent
}

enum DeviceMusicPlaybackState: String, Equatable, Sendable {
    case playing, paused, stopped
}

struct DeviceMusicPlayingItem: Equatable, Sendable {
    let id: String
    let title: String
    var artist: String? = nil
    var album: String? = nil
    var durationSeconds: Int? = nil
}

struct DeviceMusicNowPlaying: Equatable, Sendable {
    let state: DeviceMusicPlaybackState
    var item: DeviceMusicPlayingItem? = nil
    var positionSeconds: Double = 0
}

enum DeviceMusicControl: String, CaseIterable, Equatable, Sendable {
    case pause, resume, next, previous, stop
}

enum DeviceMusicProviderError: Error, Equatable, Sendable {
    /// No such item, or nothing playing to act on.
    case notFound
    /// The request needs the person's Apple Music subscription.
    case subscriptionRequired
    /// Apple's catalog service refused or couldn't be reached: no MusicKit app service on the App ID,
    /// a developer token that didn't come, or no network.
    case serviceUnavailable
    /// This platform can't do it (the Mac has no Music app player or library edits).
    case unavailable
    case notAuthorized
    case failed
}

/// MusicKit behind a seam, so the choices below can be tested without a device or a subscription.
@MainActor
protocol DeviceMusicProviding: AnyObject {
    var authorization: DeviceMusicAuthorization { get }
    func requestAuthorization() async -> DeviceMusicAuthorization
    /// Whether the person's subscription plays the Apple Music catalog. False when it can't be read.
    func canPlayCatalog() async -> Bool
    /// Up to `limitPerKind` of each kind. Library search is local; catalog search needs the MusicKit
    /// app service and throws `serviceUnavailable` without it.
    func search(query: String, kinds: [DeviceMusicKind], source: DeviceMusicSource, limitPerKind: Int) async throws -> [DeviceMusicItem]
    func library(_ listing: DeviceMusicLibraryListing, limit: Int) async throws -> [DeviceMusicItem]
    /// Starts it in the Music app's player, which keeps playing with bighelp in the background.
    /// Looking the item up takes seconds, so `beforeCommit` runs after the last wait, right before the
    /// queue is set: a switch turned off during the lookup plays nothing.
    func play(id: String, kind: DeviceMusicKind, source: DeviceMusicSource, shuffle: Bool?,
              beforeCommit: @MainActor () throws -> Void) async throws
    /// Throws `unavailable` where the Music app's player can't be read.
    func nowPlaying() throws -> DeviceMusicNowPlaying
    func control(_ action: DeviceMusicControl) async throws
    /// Returns the new playlist's ID. Songs may be library or catalog IDs. `beforeCommit` runs after the
    /// songs are found and right before the playlist is made.
    func createPlaylist(name: String, description: String?, songIDs: [String],
                        beforeCommit: @MainActor () throws -> Void) async throws -> String
    /// `beforeEach` runs before every song is added, so a revoked switch stops the rest.
    func addToPlaylist(playlistID: String, songIDs: [String], beforeEach: @MainActor () throws -> Void) async throws
    /// `beforeCommit` runs after the lookups and right before the item is added.
    func addToLibrary(id: String, kind: DeviceMusicKind, beforeCommit: @MainActor () throws -> Void) async throws
}

/// `music.nowPlaying`, `music.search`, `music.library`, `music.play`, `music.control`, `music.createPlaylist`, `music.addToPlaylist` and `music.addToLibrary`: the agent's `iphone_music` tool.
/// Playback goes through the Music app's player, so it keeps going when bighelp closes.
@MainActor
final class DeviceMusicTool: DeviceCapabilityTool {
    enum Failure: String, DeviceToolFailure, Equatable {
        case notFound = "not_found"
        case subscriptionRequired = "subscription_required"
        case serviceUnavailable = "music_service_unavailable"

        var code: String { rawValue }
    }

    static let maximumQueryLength = 200
    static let maximumNameLength = 100
    static let maximumDescriptionLength = 300
    static let maximumItems = 100
    static let maximumIDLength = 512
    static let maximumTextLength = 200
    static let searchLimits = 1...25
    static let libraryLimits = 1...50
    static let defaultSearchLimit = 10
    static let defaultLibraryLimit = 25
    static let defaultKinds: [DeviceMusicKind] = [.song, .album, .playlist]

    let capability = DeviceToolCapability.music
    private let provider: (any DeviceMusicProviding)?

    /// With no provider (a platform without MusicKit) the tool says it's unavailable.
    init(provider: (any DeviceMusicProviding)?) {
        self.provider = provider
    }

    static func live(_ environment: DeviceToolEnvironment) -> DeviceMusicTool {
        if environment.usesFixtures { return DeviceMusicTool(provider: DemoDeviceMusicProvider()) }
        #if canImport(MusicKit)
        return DeviceMusicTool(provider: LiveDeviceMusicProvider())
        #else
        return DeviceMusicTool(provider: nil)
        #endif
    }

    // MARK: Access

    func status() async -> DeviceToolSystemAccess {
        guard let provider else { return .unavailable }
        return Self.access(provider.authorization)
    }

    func request() async -> DeviceToolSystemAccess {
        guard let provider else { return .unavailable }
        if provider.authorization == .notDetermined { _ = await provider.requestAuthorization() }
        return Self.access(provider.authorization)
    }

    private static func access(_ authorization: DeviceMusicAuthorization) -> DeviceToolSystemAccess {
        switch authorization {
        case .notDetermined: .notRequested
        case .authorized: .available
        case .denied: .denied
        case .restricted: .unavailable
        }
    }

    // MARK: Operations

    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        context: DeviceToolCallContext,
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        switch operation {
        case "music.nowPlaying": return try nowPlaying(arguments, authorize: authorize)
        case "music.search": return try await search(arguments, authorize: authorize)
        case "music.library": return try await library(arguments, authorize: authorize)
        case "music.play": return try await play(arguments, authorize: authorize)
        case "music.control": return try await control(arguments, authorize: authorize)
        case "music.createPlaylist": return try await createPlaylist(arguments, authorize: authorize)
        case "music.addToPlaylist": return try await addToPlaylist(arguments, authorize: authorize)
        case "music.addToLibrary": return try await addToLibrary(arguments, authorize: authorize)
        default: throw AppleDeviceToolError.unsupportedOperation
        }
    }

    private func nowPlaying(
        _ arguments: [String: BighelpJSONValue], authorize: @MainActor () throws -> Void
    ) throws -> [String: BighelpJSONValue] {
        guard arguments.isEmpty else { throw AppleDeviceToolError.invalidArguments }
        let provider = try ready(authorize)
        return try Self.playing(provider)
    }

    private func search(
        _ arguments: [String: BighelpJSONValue], authorize: @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        try Self.requireKeys(arguments, allowed: ["query", "types", "source", "limit"])
        let query = try Self.query(arguments["query"])
        let kinds = try Self.kinds(arguments["types"])
        let requested = try Self.source(arguments["source"])
        let limit = try Self.limit(arguments["limit"], in: Self.searchLimits, default: Self.defaultSearchLimit)
        let provider = try ready(authorize)
        let canPlay = await provider.canPlayCatalog()
        try recheck(provider, authorize)
        // The catalog plays only with a subscription; without one the library is all there is to search.
        let source = requested ?? (canPlay ? .catalog : .library)
        if source == .catalog, !canPlay { throw Failure.subscriptionRequired }
        let found: [DeviceMusicItem]
        do {
            found = try await provider.search(query: query, kinds: kinds, source: source, limitPerKind: limit)
        } catch { throw Self.mapped(error) }
        try recheck(provider, authorize)
        return [
            "results": .array(Self.interleaved(found, kinds: kinds, limit: limit).map(Self.json)),
            "subscription": .object(["canPlayCatalog": .boolean(canPlay)]),
        ]
    }

    private func library(
        _ arguments: [String: BighelpJSONValue], authorize: @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        try Self.requireKeys(arguments, allowed: ["type", "limit"])
        var listing = DeviceMusicLibraryListing.playlists
        if let value = arguments["type"] {
            guard let name = value.string, let parsed = DeviceMusicLibraryListing(rawValue: name) else {
                throw AppleDeviceToolError.invalidArguments
            }
            listing = parsed
        }
        let limit = try Self.limit(arguments["limit"], in: Self.libraryLimits, default: Self.defaultLibraryLimit)
        let provider = try ready(authorize)
        let items: [DeviceMusicItem]
        do { items = try await provider.library(listing, limit: limit) } catch { throw Self.mapped(error) }
        try recheck(provider, authorize)
        return ["items": .array(items.prefix(limit).map(Self.json))]
    }

    private func play(
        _ arguments: [String: BighelpJSONValue], authorize: @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        try Self.requireKeys(arguments, allowed: ["id", "type", "source", "query", "shuffle"])
        var shuffle: Bool?
        if let value = arguments["shuffle"] {
            guard let flag = value.boolean else { throw AppleDeviceToolError.invalidArguments }
            shuffle = flag
        }
        let target: Target
        if arguments["query"] != nil {
            // A query is its own way to pick; it can't be mixed with a result's coordinates.
            guard arguments["id"] == nil, arguments["type"] == nil, arguments["source"] == nil else {
                throw AppleDeviceToolError.invalidArguments
            }
            target = .query(try Self.query(arguments["query"]))
        } else {
            let id = try Self.identifier(arguments["id"])
            guard let name = arguments["type"]?.string, let kind = DeviceMusicKind(resultType: name) else {
                throw AppleDeviceToolError.invalidArguments
            }
            target = .item(id: id, kind: kind, source: try Self.source(arguments["source"]))
        }
        let provider = try ready(authorize)
        let canPlay = await provider.canPlayCatalog()
        try recheck(provider, authorize)
        let id: String, kind: DeviceMusicKind, source: DeviceMusicSource
        switch target {
        case .item(let itemID, let itemKind, let itemSource):
            (id, kind, source) = (itemID, itemKind, itemSource ?? (canPlay ? .catalog : .library))
        case .query(let query):
            // The best song match, from the catalog when the subscription plays it, else the library.
            let searched: DeviceMusicSource = canPlay ? .catalog : .library
            let best: DeviceMusicItem?
            do {
                best = try await provider.search(query: query, kinds: [.song], source: searched, limitPerKind: 1)
                    .first(where: { $0.kind == .song })
            } catch { throw Self.mapped(error) }
            try recheck(provider, authorize)
            guard let best else { throw Failure.notFound }
            (id, kind, source) = (best.id, .song, best.source)
        }
        if source == .catalog, !canPlay { throw Failure.subscriptionRequired }
        do {
            try await provider.play(id: id, kind: kind, source: source, shuffle: shuffle, beforeCommit: { [self] in
                try recheck(provider, authorize)
            })
        } catch { throw Self.mapped(error) }
        return try Self.playing(provider)
    }

    private func control(
        _ arguments: [String: BighelpJSONValue], authorize: @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        guard Set(arguments.keys) == ["action"],
              let name = arguments["action"]?.string, let action = DeviceMusicControl(rawValue: name) else {
            throw AppleDeviceToolError.invalidArguments
        }
        let provider = try ready(authorize)
        do { try await provider.control(action) } catch { throw Self.mapped(error) }
        return try Self.playing(provider)
    }

    private func createPlaylist(
        _ arguments: [String: BighelpJSONValue], authorize: @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        try Self.requireKeys(arguments, allowed: ["name", "description", "itemIDs"])
        guard let name = arguments["name"]?.string.map(Self.trimmed),
              (1...Self.maximumNameLength).contains(name.count), !Self.hasControlCharacters(name) else {
            throw AppleDeviceToolError.invalidArguments
        }
        var description: String?
        if let value = arguments["description"] {
            guard let text = value.string, text.count <= Self.maximumDescriptionLength else {
                throw AppleDeviceToolError.invalidArguments
            }
            description = text.isEmpty ? nil : text
        }
        let songIDs = try Self.identifiers(arguments["itemIDs"], minimum: 0)
        let provider = try ready(authorize)
        let id: String
        do {
            id = try await provider.createPlaylist(name: name, description: description, songIDs: songIDs, beforeCommit: { [self] in
                try recheck(provider, authorize)
            })
        } catch { throw Self.mapped(error) }
        // The playlist exists now; the answer says so even if access ended while it was made.
        return ["id": .string(id)]
    }

    private func addToPlaylist(
        _ arguments: [String: BighelpJSONValue], authorize: @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        guard Set(arguments.keys) == ["playlistID", "itemIDs"] else { throw AppleDeviceToolError.invalidArguments }
        let playlistID = try Self.identifier(arguments["playlistID"])
        let songIDs = try Self.identifiers(arguments["itemIDs"], minimum: 1)
        let provider = try ready(authorize)
        do {
            try await provider.addToPlaylist(playlistID: playlistID, songIDs: songIDs, beforeEach: { [self] in
                try recheck(provider, authorize)
            })
        } catch { throw Self.mapped(error) }
        return ["id": .string(playlistID)]
    }

    private func addToLibrary(
        _ arguments: [String: BighelpJSONValue], authorize: @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        guard Set(arguments.keys) == ["id", "type"] else { throw AppleDeviceToolError.invalidArguments }
        let id = try Self.identifier(arguments["id"])
        // Artists can be followed in Music but not added by an app.
        guard let name = arguments["type"]?.string, let kind = DeviceMusicKind(resultType: name), kind != .artist else {
            throw AppleDeviceToolError.invalidArguments
        }
        let provider = try ready(authorize)
        do {
            try await provider.addToLibrary(id: id, kind: kind, beforeCommit: { [self] in
                try recheck(provider, authorize)
            })
        } catch { throw Self.mapped(error) }
        return ["id": .string(id)]
    }

    // MARK: Checks

    private enum Target {
        case item(id: String, kind: DeviceMusicKind, source: DeviceMusicSource?)
        case query(String)
    }

    /// The call still belongs to the chat that made it, and iOS still allows music.
    private func ready(_ authorize: @MainActor () throws -> Void) throws -> any DeviceMusicProviding {
        guard let provider else { throw AppleDeviceToolError.unavailable }
        try recheck(provider, authorize)
        return provider
    }

    private func recheck(_ provider: any DeviceMusicProviding, _ authorize: @MainActor () throws -> Void) throws {
        try authorize()
        switch provider.authorization {
        case .authorized: break
        case .notDetermined, .denied: throw AppleDeviceToolError.authorizationRequired
        case .restricted: throw AppleDeviceToolError.unavailable
        }
    }

    private static func playing(_ provider: any DeviceMusicProviding) throws -> [String: BighelpJSONValue] {
        do { return json(try provider.nowPlaying()) } catch { throw mapped(error) }
    }

    private static func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let failure = error as? any DeviceToolFailure { return failure }
        switch error as? DeviceMusicProviderError {
        case .notFound: return Failure.notFound
        case .subscriptionRequired: return Failure.subscriptionRequired
        case .serviceUnavailable: return Failure.serviceUnavailable
        case .unavailable: return AppleDeviceToolError.unavailable
        case .notAuthorized: return AppleDeviceToolError.authorizationRequired
        case .failed, nil: return AppleDeviceToolError.nativeFailure
        }
    }

    // MARK: Arguments

    private static func requireKeys(_ arguments: [String: BighelpJSONValue], allowed: Set<String>) throws {
        guard Set(arguments.keys).isSubset(of: allowed) else { throw AppleDeviceToolError.invalidArguments }
    }

    private static func query(_ value: BighelpJSONValue?) throws -> String {
        guard let text = value?.string.map(trimmed), (1...maximumQueryLength).contains(text.count),
              !hasControlCharacters(text) else { throw AppleDeviceToolError.invalidArguments }
        return text
    }

    private static func kinds(_ value: BighelpJSONValue?) throws -> [DeviceMusicKind] {
        guard let value else { return defaultKinds }
        guard let list = value.array, (1...DeviceMusicKind.allCases.count).contains(list.count) else {
            throw AppleDeviceToolError.invalidArguments
        }
        var kinds: [DeviceMusicKind] = []
        for item in list {
            guard let name = item.string, let kind = DeviceMusicKind(plural: name) else {
                throw AppleDeviceToolError.invalidArguments
            }
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        return kinds
    }

    private static func source(_ value: BighelpJSONValue?) throws -> DeviceMusicSource? {
        guard let value else { return nil }
        guard let name = value.string, let source = DeviceMusicSource(rawValue: name) else {
            throw AppleDeviceToolError.invalidArguments
        }
        return source
    }

    private static func limit(_ value: BighelpJSONValue?, in range: ClosedRange<Int>, default fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard let limit = whole(value), range.contains(limit) else { throw AppleDeviceToolError.invalidArguments }
        return limit
    }

    private static func identifier(_ value: BighelpJSONValue?) throws -> String {
        guard let id = value?.string, (1...maximumIDLength).contains(id.count), !hasControlCharacters(id) else {
            throw AppleDeviceToolError.invalidArguments
        }
        return id
    }

    private static func identifiers(_ value: BighelpJSONValue?, minimum: Int) throws -> [String] {
        guard let value else {
            guard minimum == 0 else { throw AppleDeviceToolError.invalidArguments }
            return []
        }
        guard let list = value.array, (minimum...maximumItems).contains(list.count) else {
            throw AppleDeviceToolError.invalidArguments
        }
        return try list.map { try identifier($0) }
    }

    private static func whole(_ value: BighelpJSONValue) -> Int? {
        switch value {
        case .integer(let number): return number
        case .number(let number):
            guard number.isFinite, number == number.rounded(), abs(number) < 1_000_000_000 else { return nil }
            return Int(number)
        default: return nil
        }
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    // MARK: Results

    /// Takes the kinds in turn, so a search for songs, albums and playlists shows some of each instead
    /// of ten songs and nothing else.
    static func interleaved(_ items: [DeviceMusicItem], kinds: [DeviceMusicKind], limit: Int) -> [DeviceMusicItem] {
        var queues = kinds.map { kind in items.filter { $0.kind == kind } }
        var merged: [DeviceMusicItem] = []
        while merged.count < limit, queues.contains(where: { !$0.isEmpty }) {
            for index in queues.indices where !queues[index].isEmpty && merged.count < limit {
                merged.append(queues[index].removeFirst())
            }
        }
        return merged
    }

    static func json(_ item: DeviceMusicItem) -> BighelpJSONValue {
        var fields: [String: BighelpJSONValue] = [
            "id": .string(item.id),
            "type": .string(item.kind.rawValue),
            "title": .string(text(item.title) ?? ""),
            "source": .string(item.source.rawValue),
        ]
        if let artist = text(item.artist) { fields["artist"] = .string(artist) }
        if let album = text(item.album) { fields["album"] = .string(album) }
        return .object(fields)
    }

    static func json(_ nowPlaying: DeviceMusicNowPlaying) -> [String: BighelpJSONValue] {
        var fields: [String: BighelpJSONValue] = [
            "state": .string(nowPlaying.state.rawValue),
            "positionSeconds": .number(seconds(nowPlaying.positionSeconds)),
        ]
        if let item = nowPlaying.item {
            var described: [String: BighelpJSONValue] = [
                "id": .string(item.id),
                "title": .string(text(item.title) ?? ""),
            ]
            if let artist = text(item.artist) { described["artist"] = .string(artist) }
            if let album = text(item.album) { described["album"] = .string(album) }
            if let duration = item.durationSeconds, duration >= 0 { described["durationSeconds"] = .integer(duration) }
            fields["item"] = .object(described)
        }
        return fields
    }

    /// Tenths of a second, never a negative or a huge number from a bad clock.
    private static func seconds(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return (min(value, 1_000_000) * 10).rounded() / 10
    }

    /// Titles come from a library the agent doesn't control; keep them printable and short.
    private static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        let printable = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        let cleaned = trimmed(printable)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(maximumTextLength))
    }
}

// MARK: - Demo

/// Demo mode: a small made-up library, nothing reaches iOS and no sound plays.
@MainActor
final class DemoDeviceMusicProvider: DeviceMusicProviding {
    static let songs: [DeviceMusicItem] = [
        DeviceMusicItem(id: "demo-song-1", kind: .song, title: "Example Morning", artist: "Sample Band",
                        album: "Demo Days", source: .library),
        DeviceMusicItem(id: "demo-song-2", kind: .song, title: "Sample Evening", artist: "Sample Band",
                        album: "Demo Days", source: .library),
        DeviceMusicItem(id: "demo-album-1", kind: .album, title: "Demo Days", artist: "Sample Band", source: .library),
        DeviceMusicItem(id: "demo-playlist-1", kind: .playlist, title: "Made-up Mix", source: .library),
    ]

    private(set) var authorization = DeviceMusicAuthorization.notDetermined
    private var current: DeviceMusicPlayingItem?
    private var state = DeviceMusicPlaybackState.stopped

    func requestAuthorization() async -> DeviceMusicAuthorization {
        authorization = .authorized
        return authorization
    }

    func canPlayCatalog() async -> Bool { false }

    func search(query: String, kinds: [DeviceMusicKind], source: DeviceMusicSource, limitPerKind: Int) async throws -> [DeviceMusicItem] {
        guard source == .library else { throw DeviceMusicProviderError.serviceUnavailable }
        return Self.songs.filter { kinds.contains($0.kind) && $0.title.localizedCaseInsensitiveContains(query) }
    }

    func library(_ listing: DeviceMusicLibraryListing, limit: Int) async throws -> [DeviceMusicItem] {
        Self.songs.filter { listing == .playlists ? $0.kind == .playlist : $0.kind == .song }
    }

    func play(id: String, kind: DeviceMusicKind, source: DeviceMusicSource, shuffle: Bool?,
              beforeCommit: @MainActor () throws -> Void) async throws {
        guard let item = Self.songs.first(where: { $0.id == id && $0.kind == kind }) else {
            throw DeviceMusicProviderError.notFound
        }
        try beforeCommit()
        current = DeviceMusicPlayingItem(id: item.id, title: item.title, artist: item.artist, album: item.album,
                                         durationSeconds: 180)
        state = .playing
    }

    func nowPlaying() throws -> DeviceMusicNowPlaying {
        DeviceMusicNowPlaying(state: state, item: current, positionSeconds: 0)
    }

    func control(_ action: DeviceMusicControl) async throws {
        switch action {
        case .pause: if current != nil { state = .paused }
        case .resume: if current != nil { state = .playing }
        case .next, .previous: if current == nil { throw DeviceMusicProviderError.notFound }
        case .stop: state = .stopped; current = nil
        }
    }

    func createPlaylist(name: String, description: String?, songIDs: [String],
                        beforeCommit: @MainActor () throws -> Void) async throws -> String {
        try beforeCommit()
        return "demo-playlist-new"
    }

    func addToPlaylist(playlistID: String, songIDs: [String], beforeEach: @MainActor () throws -> Void) async throws {}
    func addToLibrary(id: String, kind: DeviceMusicKind, beforeCommit: @MainActor () throws -> Void) async throws {
        try beforeCommit()
    }
}

// MARK: - MusicKit

#if canImport(MusicKit)
@MainActor
final class LiveDeviceMusicProvider: DeviceMusicProviding {
    var authorization: DeviceMusicAuthorization {
        switch MusicAuthorization.currentStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

    func requestAuthorization() async -> DeviceMusicAuthorization {
        _ = await MusicAuthorization.request()
        return authorization
    }

    func canPlayCatalog() async -> Bool {
        (try? await MusicSubscription.current.canPlayCatalogContent) ?? false
    }

    // MARK: Find

    func search(query: String, kinds: [DeviceMusicKind], source: DeviceMusicSource, limitPerKind: Int) async throws -> [DeviceMusicItem] {
        do {
            switch source {
            case .catalog:
                let types: [any MusicCatalogSearchable.Type] = kinds.map {
                    switch $0 {
                    case .song: Song.self
                    case .album: Album.self
                    case .playlist: Playlist.self
                    case .artist: Artist.self
                    }
                }
                var request = MusicCatalogSearchRequest(term: query, types: types)
                request.limit = limitPerKind
                let response = try await request.response()
                return Self.items(songs: response.songs, albums: response.albums, playlists: response.playlists,
                                  artists: response.artists, source: .catalog)
            case .library:
                let types: [any MusicLibrarySearchable.Type] = kinds.map {
                    switch $0 {
                    case .song: Song.self
                    case .album: Album.self
                    case .playlist: Playlist.self
                    case .artist: Artist.self
                    }
                }
                var request = MusicLibrarySearchRequest(term: query, types: types)
                request.limit = limitPerKind
                let response = try await request.response()
                return Self.items(songs: response.songs, albums: response.albums, playlists: response.playlists,
                                  artists: response.artists, source: .library)
            }
        } catch { throw Self.translate(error) }
    }

    func library(_ listing: DeviceMusicLibraryListing, limit: Int) async throws -> [DeviceMusicItem] {
        do {
            switch listing {
            case .playlists:
                var request = MusicLibraryRequest<Playlist>()
                request.limit = limit
                request.sort(by: \.name, ascending: true)
                return Self.items(songs: [], albums: [], playlists: try await request.response().items, artists: [], source: .library)
            case .recent:
                // Most recently played first. Songs never played have no date and aren't "recent", so
                // ask for more than the limit and drop them.
                var request = MusicLibraryRequest<Song>()
                request.limit = min(limit * 4, 200)
                request.sort(by: \.lastPlayedDate, ascending: false)
                let played = try await request.response().items.filter { $0.lastPlayedDate != nil }
                return Self.items(songs: Array(played.prefix(limit)), albums: [], playlists: [], artists: [], source: .library)
            }
        } catch { throw Self.translate(error) }
    }

    private static func items(
        songs: some Collection<Song>, albums: some Collection<Album>, playlists: some Collection<Playlist>,
        artists: some Collection<Artist>, source: DeviceMusicSource
    ) -> [DeviceMusicItem] {
        songs.map { DeviceMusicItem(id: $0.id.rawValue, kind: .song, title: $0.title, artist: $0.artistName,
                                    album: $0.albumTitle, source: source) }
        + albums.map { DeviceMusicItem(id: $0.id.rawValue, kind: .album, title: $0.title, artist: $0.artistName,
                                       source: source) }
        + playlists.map { DeviceMusicItem(id: $0.id.rawValue, kind: .playlist, title: $0.name, artist: $0.curatorName,
                                          source: source) }
        + artists.map { DeviceMusicItem(id: $0.id.rawValue, kind: .artist, title: $0.name, source: source) }
    }

    // MARK: Play

    #if !targetEnvironment(macCatalyst)
    func play(id: String, kind: DeviceMusicKind, source: DeviceMusicSource, shuffle: Bool?,
              beforeCommit: @MainActor () throws -> Void) async throws {
        do {
            let player = SystemMusicPlayer.shared
            let itemID = MusicItemID(id)
            // Every lookup is done before the check, and nothing awaits between the check and the queue.
            let queue: MusicPlayer.Queue
            switch kind {
            case .song:
                queue = SystemMusicPlayer.Queue(for: [try await song(itemID, source: source)])
            case .album:
                queue = SystemMusicPlayer.Queue(for: [try await album(itemID, source: source)])
            case .playlist:
                queue = SystemMusicPlayer.Queue(for: [try await playlist(itemID, source: source)])
            case .artist:
                let songs = try await songs(by: itemID, source: source)
                guard !songs.isEmpty else { throw DeviceMusicProviderError.notFound }
                queue = SystemMusicPlayer.Queue(for: songs)
            }
            try beforeCommit()
            player.queue = queue
            if let shuffle { player.state.shuffleMode = shuffle ? .songs : .off }
            try await player.play()
        } catch { throw Self.translate(error) }
    }

    func nowPlaying() throws -> DeviceMusicNowPlaying {
        let player = SystemMusicPlayer.shared
        let state: DeviceMusicPlaybackState
        switch player.state.playbackStatus {
        case .playing, .seekingForward, .seekingBackward: state = .playing
        case .paused, .interrupted: state = .paused
        case .stopped: state = .stopped
        @unknown default: state = .stopped
        }
        guard let entry = player.queue.currentEntry else { return DeviceMusicNowPlaying(state: .stopped) }
        var item = DeviceMusicPlayingItem(id: entry.id, title: entry.title, artist: entry.subtitle)
        switch entry.item {
        case .song(let song)?:
            item = DeviceMusicPlayingItem(id: song.id.rawValue, title: song.title, artist: song.artistName,
                                          album: song.albumTitle, durationSeconds: song.duration.map { Int($0.rounded()) })
        case .musicVideo(let video)?:
            item = DeviceMusicPlayingItem(id: video.id.rawValue, title: video.title, artist: video.artistName,
                                          album: video.albumTitle, durationSeconds: video.duration.map { Int($0.rounded()) })
        case nil, .some: break
        }
        return DeviceMusicNowPlaying(state: state, item: item, positionSeconds: player.playbackTime)
    }

    func control(_ action: DeviceMusicControl) async throws {
        let player = SystemMusicPlayer.shared
        do {
            switch action {
            case .pause:
                player.pause()
                await settle(player, until: [.paused, .stopped])
            case .stop:
                player.stop()
                await settle(player, until: [.stopped])
            case .resume:
                guard player.queue.currentEntry != nil else { throw DeviceMusicProviderError.notFound }
                try await player.play()
                await settle(player, until: [.playing])
            case .next:
                guard player.queue.currentEntry != nil else { throw DeviceMusicProviderError.notFound }
                try await player.skipToNextEntry()
            case .previous:
                guard player.queue.currentEntry != nil else { throw DeviceMusicProviderError.notFound }
                try await player.skipToPreviousEntry()
            }
        } catch { throw Self.translate(error) }
    }

    /// The player reports a pause a moment late. Wait briefly for the state the action asked for, so the
    /// answer to the agent is what the player did, not what it did before.
    private func settle(_ player: SystemMusicPlayer, until wanted: Set<MusicPlayer.PlaybackStatus>) async {
        for _ in 0..<10 {
            if wanted.contains(player.state.playbackStatus) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    #else
    func play(id: String, kind: DeviceMusicKind, source: DeviceMusicSource, shuffle: Bool?,
              beforeCommit: @MainActor () throws -> Void) async throws {
        throw DeviceMusicProviderError.unavailable
    }

    func nowPlaying() throws -> DeviceMusicNowPlaying { throw DeviceMusicProviderError.unavailable }

    func control(_ action: DeviceMusicControl) async throws {
        throw DeviceMusicProviderError.unavailable
    }
    #endif

    // MARK: Library edits

    #if !targetEnvironment(macCatalyst)
    func createPlaylist(name: String, description: String?, songIDs: [String],
                        beforeCommit: @MainActor () throws -> Void) async throws -> String {
        do {
            let songs = try await resolveSongs(songIDs)
            try beforeCommit()
            let playlist = try await MusicLibrary.shared.createPlaylist(name: name, description: description, items: songs)
            return playlist.id.rawValue
        } catch { throw Self.translate(error) }
    }

    func addToPlaylist(playlistID: String, songIDs: [String], beforeEach: @MainActor () throws -> Void) async throws {
        do {
            var request = MusicLibraryRequest<Playlist>()
            request.filter(matching: \.id, equalTo: MusicItemID(playlistID))
            request.limit = 1
            guard var playlist = try await request.response().items.first else { throw DeviceMusicProviderError.notFound }
            let songs = try await resolveSongs(songIDs)
            for song in songs {
                try beforeEach()
                playlist = try await MusicLibrary.shared.add(song, to: playlist)
            }
        } catch { throw Self.translate(error) }
    }

    func addToLibrary(id: String, kind: DeviceMusicKind, beforeCommit: @MainActor () throws -> Void) async throws {
        do {
            let itemID = MusicItemID(id)
            // Already in the library: nothing to do, and no subscription needed to say so.
            if try await libraryHas(itemID, kind: kind) { return }
            guard await canPlayCatalog() else { throw DeviceMusicProviderError.subscriptionRequired }
            // Find the item first, check, then add with nothing awaited in between.
            switch kind {
            case .song:
                let song = try await catalogSong(itemID)
                try beforeCommit()
                try await MusicLibrary.shared.add(song)
            case .album:
                let album = try await catalogAlbum(itemID)
                try beforeCommit()
                try await MusicLibrary.shared.add(album)
            case .playlist:
                let playlist = try await catalogPlaylist(itemID)
                try beforeCommit()
                try await MusicLibrary.shared.add(playlist)
            case .artist: throw DeviceMusicProviderError.unavailable
            }
        } catch MusicLibrary.Error.itemAlreadyAdded {
            return
        } catch { throw Self.translate(error) }
    }

    /// Library songs first, then the catalog for what's left. Catalog songs need the subscription to add.
    private func resolveSongs(_ ids: [String]) async throws -> [Song] {
        guard !ids.isEmpty else { return [] }
        let unique = Array(Set(ids))
        var found: [String: Song] = [:]
        var library = MusicLibraryRequest<Song>()
        library.filter(matching: \.id, memberOf: unique.map { MusicItemID($0) })
        library.limit = unique.count
        for song in try await library.response().items { found[song.id.rawValue] = song }
        let missing = unique.filter { found[$0] == nil }
        if !missing.isEmpty {
            guard await canPlayCatalog() else { throw DeviceMusicProviderError.subscriptionRequired }
            var catalog = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: missing.map { MusicItemID($0) })
            catalog.limit = missing.count
            for song in try await catalog.response().items { found[song.id.rawValue] = song }
        }
        let songs = ids.compactMap { found[$0] }
        guard songs.count == ids.count else { throw DeviceMusicProviderError.notFound }
        return songs
    }

    private func libraryHas(_ id: MusicItemID, kind: DeviceMusicKind) async throws -> Bool {
        switch kind {
        case .song:
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: id)
            request.limit = 1
            return !(try await request.response().items.isEmpty)
        case .album:
            var request = MusicLibraryRequest<Album>()
            request.filter(matching: \.id, equalTo: id)
            request.limit = 1
            return !(try await request.response().items.isEmpty)
        case .playlist:
            var request = MusicLibraryRequest<Playlist>()
            request.filter(matching: \.id, equalTo: id)
            request.limit = 1
            return !(try await request.response().items.isEmpty)
        case .artist:
            return false
        }
    }
    #else
    func createPlaylist(name: String, description: String?, songIDs: [String],
                        beforeCommit: @MainActor () throws -> Void) async throws -> String {
        throw DeviceMusicProviderError.unavailable
    }

    func addToPlaylist(playlistID: String, songIDs: [String], beforeEach: @MainActor () throws -> Void) async throws {
        throw DeviceMusicProviderError.unavailable
    }

    func addToLibrary(id: String, kind: DeviceMusicKind, beforeCommit: @MainActor () throws -> Void) async throws {
        throw DeviceMusicProviderError.unavailable
    }
    #endif

    // MARK: Lookup

    private func song(_ id: MusicItemID, source: DeviceMusicSource) async throws -> Song {
        switch source {
        case .catalog:
            return try await catalogSong(id)
        case .library:
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: id)
            request.limit = 1
            guard let song = try await request.response().items.first else { throw DeviceMusicProviderError.notFound }
            return song
        }
    }

    private func album(_ id: MusicItemID, source: DeviceMusicSource) async throws -> Album {
        switch source {
        case .catalog:
            return try await catalogAlbum(id)
        case .library:
            var request = MusicLibraryRequest<Album>()
            request.filter(matching: \.id, equalTo: id)
            request.limit = 1
            guard let album = try await request.response().items.first else { throw DeviceMusicProviderError.notFound }
            return album
        }
    }

    private func playlist(_ id: MusicItemID, source: DeviceMusicSource) async throws -> Playlist {
        switch source {
        case .catalog:
            return try await catalogPlaylist(id)
        case .library:
            var request = MusicLibraryRequest<Playlist>()
            request.filter(matching: \.id, equalTo: id)
            request.limit = 1
            guard let playlist = try await request.response().items.first else { throw DeviceMusicProviderError.notFound }
            return playlist
        }
    }

    /// An artist plays as their songs: the catalog's top songs, or the songs of theirs in the library.
    private func songs(by id: MusicItemID, source: DeviceMusicSource) async throws -> [Song] {
        switch source {
        case .catalog:
            var request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: id)
            request.limit = 1
            guard let artist = try await request.response().items.first else { throw DeviceMusicProviderError.notFound }
            let detailed = try await artist.with([.topSongs])
            return Array(detailed.topSongs ?? [])
        case .library:
            var artists = MusicLibraryRequest<Artist>()
            artists.filter(matching: \.id, equalTo: id)
            artists.limit = 1
            guard let artist = try await artists.response().items.first else { throw DeviceMusicProviderError.notFound }
            var songs = MusicLibraryRequest<Song>()
            songs.filter(matching: \.artists, contains: artist)
            songs.limit = 100
            return Array(try await songs.response().items)
        }
    }

    private func catalogSong(_ id: MusicItemID) async throws -> Song {
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id)
        request.limit = 1
        guard let song = try await request.response().items.first else { throw DeviceMusicProviderError.notFound }
        return song
    }

    private func catalogAlbum(_ id: MusicItemID) async throws -> Album {
        var request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: id)
        request.limit = 1
        guard let album = try await request.response().items.first else { throw DeviceMusicProviderError.notFound }
        return album
    }

    private func catalogPlaylist(_ id: MusicItemID) async throws -> Playlist {
        var request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: id)
        request.limit = 1
        guard let playlist = try await request.response().items.first else { throw DeviceMusicProviderError.notFound }
        return playlist
    }

    // MARK: Errors

    /// What MusicKit throws, in the few kinds the agent can act on.
    nonisolated static func translate(_ error: any Error) -> any Error {
        // A failure the tool raised itself (access ended during a lookup) passes through untouched.
        if error is CancellationError || error is DeviceMusicProviderError || error is any DeviceToolFailure { return error }
        if let token = error as? MusicTokenRequestError {
            switch token {
            case .developerTokenRequestFailed, .userTokenRequestFailed, .unknown: return DeviceMusicProviderError.serviceUnavailable
            case .permissionDenied: return DeviceMusicProviderError.notAuthorized
            case .userNotSignedIn, .userTokenRevoked, .privacyAcknowledgementRequired:
                return DeviceMusicProviderError.subscriptionRequired
            @unknown default: return DeviceMusicProviderError.serviceUnavailable
            }
        }
        if let subscription = error as? MusicSubscription.Error {
            switch subscription {
            case .permissionDenied: return DeviceMusicProviderError.notAuthorized
            case .privacyAcknowledgementRequired: return DeviceMusicProviderError.subscriptionRequired
            case .unknown: return DeviceMusicProviderError.failed
            @unknown default: return DeviceMusicProviderError.failed
            }
        }
        if let request = error as? MusicDataRequest.Error {
            switch request.status {
            case 404: return DeviceMusicProviderError.notFound
            case 401, 403, 429, 500...599: return DeviceMusicProviderError.serviceUnavailable
            default: return DeviceMusicProviderError.failed
            }
        }
        #if !targetEnvironment(macCatalyst)
        if let library = error as? MusicLibrary.Error {
            switch library {
            case .permissionDenied: return DeviceMusicProviderError.notAuthorized
            case .playlistNotInLibrary: return DeviceMusicProviderError.notFound
            case .unknown, .unableToAddItem, .itemAlreadyAdded, .addToPlaylistFailed, .createPlaylistFailed, .editPlaylistFailed:
                return DeviceMusicProviderError.failed
            @unknown default: return DeviceMusicProviderError.failed
            }
        }
        #endif
        // No network is the catalog service being out of reach too.
        if error is URLError { return DeviceMusicProviderError.serviceUnavailable }
        return DeviceMusicProviderError.failed
    }
}
#endif
