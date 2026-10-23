import Foundation
import Testing
@testable import Bighelp

/// The agent's `iphone_music` tool on the phone: iOS permission, the subscription rules, what it
/// accepts, and the bounded results. Every song, artist and playlist here is made up.
@MainActor
struct DeviceMusicToolTests {
    // MARK: Catalog

    @Test func playingAndControlActOnWhatPlaysNowSoOnlyLibraryEditsAreJournaled() {
        for operation in ["nowPlaying", "search", "library", "play", "control"] {
            #expect(DeviceToolCatalog.operations["music.\(operation)"]?.journaled == false, "\(operation)")
        }
        for operation in ["createPlaylist", "addToPlaylist", "addToLibrary"] {
            #expect(DeviceToolCatalog.operations["music.\(operation)"]?.journaled == true, "\(operation)")
        }
        #expect(DeviceToolCapability.music.pluginFeature == "native-device-music-v1")
    }

    @Test func libraryEditsAnswerWithOnlyAnID() async throws {
        let fixture = MusicFixture()
        let created = try await fixture.run("music.createPlaylist", ["name": .string("Road trip"), "itemIDs": .array([.string("lib-song-1")])])
        let added = try await fixture.run("music.addToPlaylist", ["playlistID": .string("lib-playlist-1"), "itemIDs": .array([.string("lib-song-2")])])
        fixture.provider.hasSubscription = true
        let imported = try await fixture.run("music.addToLibrary", ["id": .string("cat-song-1"), "type": .string("song")])
        for result in [created, added, imported] {
            #expect(Set(result.keys) == ["id"], "A journal entry would lose \(result.keys)")
        }
    }

    // MARK: Access

    @Test func statusMapsIOSAuthorizationWithoutAsking() async {
        let cases: [(DeviceMusicAuthorization, DeviceToolSystemAccess)] = [
            (.notDetermined, .notRequested), (.denied, .denied), (.restricted, .unavailable), (.authorized, .available),
        ]
        for (authorization, expected) in cases {
            let fixture = MusicFixture(authorization: authorization)
            #expect(await fixture.tool.status() == expected)
            #expect(fixture.provider.authorizationRequests == 0)
        }
    }

    @Test func turningTheSwitchOnAsksIOSOnlyTheFirstTime() async {
        let fixture = MusicFixture(authorization: .notDetermined)
        fixture.provider.answerToRequest = .authorized
        #expect(await fixture.tool.request() == .available)
        #expect(await fixture.tool.request() == .available)
        #expect(fixture.provider.authorizationRequests == 1)

        let refused = MusicFixture(authorization: .notDetermined)
        refused.provider.answerToRequest = .denied
        #expect(await refused.tool.request() == .denied)
        let restricted = MusicFixture(authorization: .restricted)
        #expect(await restricted.tool.request() == .unavailable)
        #expect(restricted.provider.authorizationRequests == 0)
    }

    @Test func aPlatformWithoutMusicKitIsUnavailable() async {
        let tool = DeviceMusicTool(provider: nil)
        #expect(await tool.status() == .unavailable)
        #expect(await tool.request() == .unavailable)
        await #expect(throws: AppleDeviceToolError.unavailable) {
            try await tool.execute(operation: "music.nowPlaying", arguments: [:], context: MusicFixture.context, authorize: {})
        }
    }

    @Test func nothingRunsWithoutIOSAccess() async {
        for (authorization, expected) in [
            (DeviceMusicAuthorization.notDetermined, AppleDeviceToolError.authorizationRequired),
            (.denied, .authorizationRequired),
            (.restricted, .unavailable),
        ] {
            let fixture = MusicFixture(authorization: authorization)
            for (operation, arguments) in [
                ("music.nowPlaying", [:]),
                ("music.search", ["query": .string("morning")]),
                ("music.play", ["query": .string("morning")]),
                ("music.control", ["action": .string("pause")]),
                ("music.createPlaylist", ["name": .string("Mix")]),
            ] as [(String, [String: BighelpJSONValue])] {
                await #expect(throws: expected) { try await fixture.run(operation, arguments) }
            }
            #expect(fixture.provider.calls.isEmpty, "\(authorization) must not reach the music library: \(fixture.provider.calls)")
        }
    }

    @Test func aCallThatLostItsChatPlaysNothing() async {
        let fixture = MusicFixture()
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await fixture.run("music.play", ["query": .string("morning")], authorize: { throw AppleDeviceToolError.authorizationRequired })
        }
        #expect(fixture.provider.played.isEmpty && fixture.provider.calls.isEmpty)
    }

    @Test func accessEndingDuringASearchHidesItsResults() async {
        let fixture = MusicFixture()
        var allowed = true
        fixture.provider.onSearch = { allowed = false }
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await fixture.run("music.search", ["query": .string("morning")], authorize: {
                guard allowed else { throw AppleDeviceToolError.authorizationRequired }
            })
        }
    }

    // MARK: Now playing

    @Test func nowPlayingTakesNoArgumentsAndSaysNothingIsPlaying() async throws {
        let fixture = MusicFixture()
        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await fixture.run("music.nowPlaying", ["verbose": .boolean(true)])
        }
        let idle = try await fixture.run("music.nowPlaying", [:])
        #expect(idle["state"] == .string("stopped"))
        #expect(idle["item"] == nil, "No song is not an empty song")
        #expect(idle["positionSeconds"] == .number(0))
    }

    @Test func nowPlayingReportsTheItemAndPositionInTenths() async throws {
        let fixture = MusicFixture()
        fixture.provider.current = DeviceMusicNowPlaying(
            state: .playing,
            item: DeviceMusicPlayingItem(id: "lib-song-1", title: "Example Morning", artist: "Sample Band",
                                         album: "Demo Days", durationSeconds: 215),
            positionSeconds: 61.2345)
        let result = try await fixture.run("music.nowPlaying", [:])
        #expect(result["state"] == .string("playing"))
        #expect(result["positionSeconds"] == .number(61.2))
        #expect(result["item"] == .object([
            "id": .string("lib-song-1"), "title": .string("Example Morning"), "artist": .string("Sample Band"),
            "album": .string("Demo Days"), "durationSeconds": .integer(215),
        ]))
    }

    @Test func textFromTheLibraryIsCleanedAndBounded() throws {
        let messy = DeviceMusicItem(id: "x", kind: .song, title: String(repeating: "t", count: 500),
                                    artist: "  Band\u{0007}\nName ", album: "   ", source: .library)
        let item = try #require(DeviceMusicTool.json(messy).object)
        #expect(item["title"]?.string?.count == DeviceMusicTool.maximumTextLength)
        #expect(item["artist"] == .string("BandName"))
        #expect(item["album"] == nil, "A blank album is left out, not sent empty")

        let strange = DeviceMusicNowPlaying(state: .paused, item: DeviceMusicPlayingItem(id: "y", title: "A", durationSeconds: -4),
                                            positionSeconds: .nan)
        let result = DeviceMusicTool.json(strange)
        #expect(result["positionSeconds"] == .number(0))
        #expect(result["item"]?.object?["durationSeconds"] == nil)
    }

    // MARK: Search

    @Test func searchUsesTheCatalogWhenTheSubscriptionPlaysIt() async throws {
        let fixture = MusicFixture()
        fixture.provider.hasSubscription = true
        let result = try await fixture.run("music.search", ["query": .string("  morning ")])
        let call = try #require(fixture.provider.searches.first)
        #expect(call.query == "morning")
        #expect(call.source == .catalog)
        #expect(call.kinds == [.song, .album, .playlist], "Artists are only searched when asked for")
        #expect(call.limitPerKind == 10)
        #expect(result["subscription"] == .object(["canPlayCatalog": .boolean(true)]))
        let first = try #require(result["results"]?.array?.first?.object)
        #expect(first["source"] == .string("catalog"))
        #expect(first["type"] == .string("song"))
    }

    @Test func withoutASubscriptionSearchUsesTheLibraryAndSaysWhy() async throws {
        let fixture = MusicFixture()
        let result = try await fixture.run("music.search", ["query": .string("morning")])
        #expect(fixture.provider.searches.first?.source == .library)
        #expect(result["subscription"] == .object(["canPlayCatalog": .boolean(false)]))
        let sources = result["results"]?.array?.compactMap { $0.object?["source"]?.string }
        #expect(Set(sources ?? []) == ["library"])
    }

    @Test func askingForTheCatalogWithoutASubscriptionIsRefusedBeforeSearching() async {
        let fixture = MusicFixture()
        await #expect(throws: DeviceMusicTool.Failure.subscriptionRequired) {
            try await fixture.run("music.search", ["query": .string("morning"), "source": .string("catalog")])
        }
        #expect(DeviceMusicTool.Failure.subscriptionRequired.code == "subscription_required")
        #expect(fixture.provider.searches.isEmpty)
    }

    @Test func theLibraryCanBeSearchedEvenWithASubscription() async throws {
        let fixture = MusicFixture()
        fixture.provider.hasSubscription = true
        let result = try await fixture.run("music.search", ["query": .string("morning"), "source": .string("library")])
        #expect(fixture.provider.searches.first?.source == .library)
        #expect(result["subscription"] == .object(["canPlayCatalog": .boolean(true)]))
    }

    @Test func aCatalogWithoutTheMusicKitServiceFailsAsUnavailableButTheLibraryStillWorks() async throws {
        let fixture = MusicFixture()
        fixture.provider.hasSubscription = true
        fixture.provider.catalogServiceWorks = false
        await #expect(throws: DeviceMusicTool.Failure.serviceUnavailable) {
            try await fixture.run("music.search", ["query": .string("morning")])
        }
        #expect(DeviceMusicTool.Failure.serviceUnavailable.code == "music_service_unavailable")
        let library = try await fixture.run("music.search", ["query": .string("morning"), "source": .string("library")])
        #expect(library["results"]?.array?.isEmpty == false)
    }

    @Test func searchPassesTheKindsAndLimitAndMixesThemFairly() async throws {
        let fixture = MusicFixture()
        fixture.provider.hasSubscription = true
        let result = try await fixture.run("music.search", [
            "query": .string("morning"), "types": .array([.string("artists"), .string("songs"), .string("artists")]), "limit": .integer(3),
        ])
        let call = try #require(fixture.provider.searches.first)
        #expect(call.kinds == [.artist, .song], "Repeated kinds fold into one")
        #expect(call.limitPerKind == 3)
        let types = result["results"]?.array?.compactMap { $0.object?["type"]?.string }
        #expect(types == ["artist", "song"], "Each kind gets a turn")
    }

    @Test func interleavingTakesTurnsAndStopsAtTheLimit() {
        func item(_ kind: DeviceMusicKind, _ number: Int) -> DeviceMusicItem {
            DeviceMusicItem(id: "\(kind.rawValue)-\(number)", kind: kind, title: "t", source: .library)
        }
        let items = [item(.song, 1), item(.song, 2), item(.song, 3), item(.album, 1), item(.playlist, 1), item(.playlist, 2)]
        let merged = DeviceMusicTool.interleaved(items, kinds: [.song, .album, .playlist], limit: 5)
        #expect(merged.map(\.id) == ["song-1", "album-1", "playlist-1", "song-2", "playlist-2"])
        #expect(DeviceMusicTool.interleaved(items, kinds: [.song], limit: 2).map(\.id) == ["song-1", "song-2"])
        #expect(DeviceMusicTool.interleaved([], kinds: [.song], limit: 5).isEmpty)
    }

    @Test func searchBoundsAreEnforced() async throws {
        let fixture = MusicFixture()
        fixture.provider.hasSubscription = true
        for arguments: [String: BighelpJSONValue] in [
            ["query": .string(String(repeating: "q", count: 200)), "limit": .integer(25)],
            ["query": .string("a"), "limit": .integer(1)],
            ["query": .string("a"), "types": .array(DeviceMusicKind.allCases.map { .string($0.plural) })],
        ] {
            _ = try await fixture.run("music.search", arguments)
        }
        let bad: [(String, [String: BighelpJSONValue])] = [
            ("no query", [:]),
            ("empty query", ["query": .string("  ")]),
            ("query too long", ["query": .string(String(repeating: "q", count: 201))]),
            ("query with a control character", ["query": .string("a\u{0001}b")]),
            ("query as a number", ["query": .integer(5)]),
            ("limit 0", ["query": .string("a"), "limit": .integer(0)]),
            ("limit 26", ["query": .string("a"), "limit": .integer(26)]),
            ("limit as text", ["query": .string("a"), "limit": .string("5")]),
            ("no types", ["query": .string("a"), "types": .array([])]),
            ("unknown type", ["query": .string("a"), "types": .array([.string("podcasts")])]),
            ("singular type", ["query": .string("a"), "types": .array([.string("song")])]),
            ("types as text", ["query": .string("a"), "types": .string("songs")]),
            ("unknown source", ["query": .string("a"), "source": .string("cloud")]),
            ("unknown key", ["query": .string("a"), "genre": .string("pop")]),
        ]
        let searches = fixture.provider.searches.count
        for (name, arguments) in bad {
            await #expect(throws: AppleDeviceToolError.invalidArguments, "\(name)") { try await fixture.run("music.search", arguments) }
        }
        #expect(fixture.provider.searches.count == searches, "A refused request must not reach Music")
    }

    // MARK: Library

    @Test func libraryListsPlaylistsByDefaultAndRecentOnRequest() async throws {
        let fixture = MusicFixture()
        let playlists = try await fixture.run("music.library", [:])
        #expect(fixture.provider.listings.last?.0 == .playlists)
        #expect(fixture.provider.listings.last?.1 == 25)
        let types = playlists["items"]?.array?.compactMap { $0.object?["type"]?.string }
        #expect(Set(types ?? []) == ["playlist"])
        let recent = try await fixture.run("music.library", ["type": .string("recent"), "limit": .integer(2)])
        #expect(fixture.provider.listings.last?.0 == .recent)
        #expect((recent["items"]?.array?.count ?? 9) <= 2)
        #expect(recent["items"]?.array?.first?.object?["type"] == .string("song"))
    }

    @Test func libraryBoundsAreEnforced() async throws {
        let fixture = MusicFixture()
        _ = try await fixture.run("music.library", ["limit": .integer(50)])
        _ = try await fixture.run("music.library", ["limit": .integer(1)])
        for arguments: [String: BighelpJSONValue] in [
            ["limit": .integer(0)], ["limit": .integer(51)], ["type": .string("albums")], ["type": .integer(1)], ["source": .string("library")],
        ] {
            await #expect(throws: AppleDeviceToolError.invalidArguments) { try await fixture.run("music.library", arguments) }
        }
    }

    // MARK: Play

    @Test func playStartsExactlyTheItemFromAResult() async throws {
        let fixture = MusicFixture()
        fixture.provider.hasSubscription = true
        let result = try await fixture.run("music.play", [
            "id": .string("cat-album-1"), "type": .string("album"), "source": .string("catalog"), "shuffle": .boolean(true),
        ])
        #expect(fixture.provider.played == [PlayCall(id: "cat-album-1", kind: .album, source: .catalog, shuffle: true)])
        #expect(result["state"] == .string("playing"))
        #expect(result["item"]?.object?["id"] == .string("cat-album-1"))
    }

    @Test func playAcceptsTheTypeAsTheAgentSearchedForIt() async throws {
        let fixture = MusicFixture()
        _ = try await fixture.run("music.play", ["id": .string("lib-playlist-1"), "type": .string("playlists"), "source": .string("library")])
        #expect(fixture.provider.played.first?.kind == .playlist)
        #expect(fixture.provider.played.first?.shuffle == nil, "Shuffle stays as the person had it unless asked")
    }

    @Test func playingTheCatalogNeedsTheSubscription() async {
        let fixture = MusicFixture()
        await #expect(throws: DeviceMusicTool.Failure.subscriptionRequired) {
            try await fixture.run("music.play", ["id": .string("cat-song-1"), "type": .string("song"), "source": .string("catalog")])
        }
        #expect(fixture.provider.played.isEmpty)
    }

    @Test func aQueryPlaysTheBestSongFromTheLibraryWithoutASubscription() async throws {
        let fixture = MusicFixture()
        let result = try await fixture.run("music.play", ["query": .string("morning")])
        let search = try #require(fixture.provider.searches.first)
        #expect(search.kinds == [.song] && search.limitPerKind == 1 && search.source == .library)
        #expect(fixture.provider.played == [PlayCall(id: "lib-song-1", kind: .song, source: .library, shuffle: nil)])
        #expect(result["state"] == .string("playing"))
    }

    @Test func aQueryPlaysFromTheCatalogWithASubscription() async throws {
        let fixture = MusicFixture()
        fixture.provider.hasSubscription = true
        _ = try await fixture.run("music.play", ["query": .string("morning"), "shuffle": .boolean(false)])
        #expect(fixture.provider.searches.first?.source == .catalog)
        #expect(fixture.provider.played == [PlayCall(id: "cat-song-1", kind: .song, source: .catalog, shuffle: false)])
    }

    @Test func aQueryWithNoMatchIsNotFoundAndPlaysNothing() async {
        let fixture = MusicFixture()
        await #expect(throws: DeviceMusicTool.Failure.notFound) { try await fixture.run("music.play", ["query": .string("zzzz")]) }
        #expect(DeviceMusicTool.Failure.notFound.code == "not_found")
        #expect(fixture.provider.played.isEmpty)
    }

    @Test func anItemThatIsGoneIsNotFound() async {
        let fixture = MusicFixture()
        await #expect(throws: DeviceMusicTool.Failure.notFound) {
            try await fixture.run("music.play", ["id": .string("lib-song-404"), "type": .string("song"), "source": .string("library")])
        }
    }

    @Test func playRefusesWhatItCannotMean() async {
        let fixture = MusicFixture()
        let bad: [(String, [String: BighelpJSONValue])] = [
            ("nothing to play", [:]),
            ("id without a type", ["id": .string("lib-song-1")]),
            ("type without an id", ["type": .string("song")]),
            ("unknown type", ["id": .string("a"), "type": .string("podcast")]),
            ("id too long", ["id": .string(String(repeating: "a", count: 513)), "type": .string("song")]),
            ("empty id", ["id": .string(""), "type": .string("song")]),
            ("query and id", ["query": .string("a"), "id": .string("a"), "type": .string("song")]),
            ("query and source", ["query": .string("a"), "source": .string("library")]),
            ("empty query", ["query": .string("")]),
            ("shuffle as text", ["query": .string("a"), "shuffle": .string("yes")]),
            ("unknown source", ["id": .string("a"), "type": .string("song"), "source": .string("radio")]),
            ("unknown key", ["query": .string("a"), "volume": .integer(5)]),
        ]
        for (name, arguments) in bad {
            await #expect(throws: AppleDeviceToolError.invalidArguments, "\(name)") { try await fixture.run("music.play", arguments) }
        }
        #expect(fixture.provider.played.isEmpty)
    }

    // MARK: Control

    @Test func controlDoesWhatWasAskedAndSaysWhatThePlayerDid() async throws {
        let fixture = MusicFixture()
        _ = try await fixture.run("music.play", ["query": .string("morning")])
        var states: [String] = []
        for action in ["pause", "resume", "next", "previous", "stop"] {
            let result = try await fixture.run("music.control", ["action": .string(action)])
            states.append(result["state"]?.string ?? "?")
        }
        #expect(fixture.provider.controls == [.pause, .resume, .next, .previous, .stop])
        #expect(states == ["paused", "playing", "playing", "playing", "stopped"])
    }

    @Test func controllingNothingThatPlaysIsNotFoundButPausingIsHarmless() async throws {
        let fixture = MusicFixture()
        for action in ["resume", "next", "previous"] {
            await #expect(throws: DeviceMusicTool.Failure.notFound) { try await fixture.run("music.control", ["action": .string(action)]) }
        }
        let paused = try await fixture.run("music.control", ["action": .string("pause")])
        #expect(paused["state"] == .string("stopped"))
    }

    @Test func controlRefusesUnknownActions() async {
        let fixture = MusicFixture()
        for arguments: [String: BighelpJSONValue] in [
            [:], ["action": .string("rewind")], ["action": .string("Pause")], ["action": .integer(1)],
            ["action": .string("pause"), "seconds": .integer(5)],
        ] {
            await #expect(throws: AppleDeviceToolError.invalidArguments) { try await fixture.run("music.control", arguments) }
        }
        #expect(fixture.provider.controls.isEmpty)
    }

    @Test func aPlayerThatCannotBeReachedIsUnavailable() async {
        let fixture = MusicFixture()
        fixture.provider.playerUnavailable = true
        for (operation, arguments) in [
            ("music.nowPlaying", [:]),
            ("music.control", ["action": .string("pause")]),
            ("music.play", ["id": .string("lib-song-1"), "type": .string("song"), "source": .string("library")]),
        ] as [(String, [String: BighelpJSONValue])] {
            await #expect(throws: AppleDeviceToolError.unavailable) { try await fixture.run(operation, arguments) }
        }
    }

    // MARK: Library edits

    @Test func createPlaylistMakesItWithTheSongsInOrder() async throws {
        let fixture = MusicFixture()
        let result = try await fixture.run("music.createPlaylist", [
            "name": .string("  Road trip "), "description": .string("Made-up songs for a made-up drive"),
            "itemIDs": .array([.string("lib-song-2"), .string("lib-song-1")]),
        ])
        #expect(result == ["id": .string("lib-playlist-new")])
        #expect(fixture.provider.created == [CreateCall(name: "Road trip", description: "Made-up songs for a made-up drive",
                                                        songIDs: ["lib-song-2", "lib-song-1"])])
    }

    @Test func aPlaylistCanStartEmpty() async throws {
        let fixture = MusicFixture()
        _ = try await fixture.run("music.createPlaylist", ["name": .string("Later")])
        #expect(fixture.provider.created.first?.songIDs == [])
        #expect(fixture.provider.created.first?.description == nil)
    }

    @Test func createPlaylistChecksEverySongBeforeMakingAnything() async {
        let fixture = MusicFixture()
        await #expect(throws: DeviceMusicTool.Failure.notFound) {
            try await fixture.run("music.createPlaylist", ["name": .string("Mix"), "itemIDs": .array([.string("lib-song-1"), .string("lib-song-404")])])
        }
        #expect(fixture.provider.created.isEmpty, "A playlist missing a song would be a half-made change")
        await #expect(throws: DeviceMusicTool.Failure.subscriptionRequired) {
            try await fixture.run("music.createPlaylist", ["name": .string("Mix"), "itemIDs": .array([.string("cat-song-1")])])
        }
        #expect(fixture.provider.created.isEmpty)
    }

    @Test func playlistBoundsAreEnforced() async throws {
        let fixture = MusicFixture()
        fixture.provider.knownSongs = Set((0..<100).map { "lib-bulk-\($0)" })
        _ = try await fixture.run("music.createPlaylist", [
            "name": .string(String(repeating: "n", count: 100)), "description": .string(String(repeating: "d", count: 300)),
            "itemIDs": .array((0..<100).map { .string("lib-bulk-\($0)") }),
        ])
        let created = fixture.provider.created.count
        let bad: [(String, [String: BighelpJSONValue])] = [
            ("no name", [:]),
            ("empty name", ["name": .string(" ")]),
            ("name too long", ["name": .string(String(repeating: "n", count: 101))]),
            ("name with a control character", ["name": .string("a\u{0000}b")]),
            ("description too long", ["name": .string("a"), "description": .string(String(repeating: "d", count: 301))]),
            ("description as a number", ["name": .string("a"), "description": .integer(1)]),
            ("101 songs", ["name": .string("a"), "itemIDs": .array((0..<101).map { .string("s\($0)") })]),
            ("a song id that is a number", ["name": .string("a"), "itemIDs": .array([.integer(1)])]),
            ("a song id too long", ["name": .string("a"), "itemIDs": .array([.string(String(repeating: "i", count: 513))])]),
            ("songs as text", ["name": .string("a"), "itemIDs": .string("lib-song-1")]),
            ("unknown key", ["name": .string("a"), "public": .boolean(true)]),
        ]
        for (name, arguments) in bad {
            await #expect(throws: AppleDeviceToolError.invalidArguments, "\(name)") { try await fixture.run("music.createPlaylist", arguments) }
        }
        #expect(fixture.provider.created.count == created)
    }

    @Test func addToPlaylistAddsEverySongToThatPlaylist() async throws {
        let fixture = MusicFixture()
        let result = try await fixture.run("music.addToPlaylist", [
            "playlistID": .string("lib-playlist-1"), "itemIDs": .array([.string("lib-song-1"), .string("lib-song-2")]),
        ])
        #expect(result == ["id": .string("lib-playlist-1")])
        #expect(fixture.provider.added == [AddCall(playlistID: "lib-playlist-1", songID: "lib-song-1"),
                                           AddCall(playlistID: "lib-playlist-1", songID: "lib-song-2")])
    }

    @Test func addToPlaylistStopsWhenAccessEndsBetweenSongs() async {
        let fixture = MusicFixture()
        var checks = 0
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await fixture.run("music.addToPlaylist", [
                "playlistID": .string("lib-playlist-1"), "itemIDs": .array([.string("lib-song-1"), .string("lib-song-2")]),
            ], authorize: {
                checks += 1
                // Passes for the call itself and the first song; refuses right before the second.
                if checks > 2 { throw AppleDeviceToolError.authorizationRequired }
            })
        }
        #expect(fixture.provider.added.map(\.songID) == ["lib-song-1"], "The second song must not be added once the switch is off")
    }

    @Test func addToPlaylistRefusesAMissingPlaylistAndBadLists() async {
        let fixture = MusicFixture()
        await #expect(throws: DeviceMusicTool.Failure.notFound) {
            try await fixture.run("music.addToPlaylist", ["playlistID": .string("lib-playlist-404"), "itemIDs": .array([.string("lib-song-1")])])
        }
        for arguments: [String: BighelpJSONValue] in [
            ["playlistID": .string("lib-playlist-1")],
            ["itemIDs": .array([.string("lib-song-1")])],
            ["playlistID": .string("lib-playlist-1"), "itemIDs": .array([])],
            ["playlistID": .string("lib-playlist-1"), "itemIDs": .array((0..<101).map { .string("s\($0)") })],
            ["playlistID": .string("lib-playlist-1"), "itemIDs": .array([.string("lib-song-1")]), "position": .integer(0)],
        ] {
            await #expect(throws: AppleDeviceToolError.invalidArguments) { try await fixture.run("music.addToPlaylist", arguments) }
        }
        #expect(fixture.provider.added.isEmpty)
    }

    @Test func addToLibraryNeedsTheSubscriptionForCatalogItemsOnly() async throws {
        let fixture = MusicFixture()
        await #expect(throws: DeviceMusicTool.Failure.subscriptionRequired) {
            try await fixture.run("music.addToLibrary", ["id": .string("cat-song-1"), "type": .string("song")])
        }
        let already = try await fixture.run("music.addToLibrary", ["id": .string("lib-song-1"), "type": .string("songs")])
        #expect(already == ["id": .string("lib-song-1")], "Already in the library is done, not an error")
        fixture.provider.hasSubscription = true
        _ = try await fixture.run("music.addToLibrary", ["id": .string("cat-album-1"), "type": .string("album")])
        #expect(fixture.provider.libraryAdds == [LibraryAddCall(id: "cat-album-1", kind: .album)])
        await #expect(throws: DeviceMusicTool.Failure.notFound) {
            try await fixture.run("music.addToLibrary", ["id": .string("cat-song-404"), "type": .string("song")])
        }
    }

    @Test func addToLibraryRefusesArtistsAndBadArguments() async {
        let fixture = MusicFixture()
        fixture.provider.hasSubscription = true
        for arguments: [String: BighelpJSONValue] in [
            ["id": .string("cat-artist-1"), "type": .string("artist")],
            ["id": .string("cat-song-1")],
            ["type": .string("song")],
            ["id": .string("cat-song-1"), "type": .string("video")],
            ["id": .string("cat-song-1"), "type": .string("song"), "source": .string("catalog")],
        ] {
            await #expect(throws: AppleDeviceToolError.invalidArguments) { try await fixture.run("music.addToLibrary", arguments) }
        }
        #expect(fixture.provider.libraryAdds.isEmpty)
    }

    @Test func aMacWithoutLibraryEditsSaysSo() async {
        let fixture = MusicFixture()
        fixture.provider.editsUnavailable = true
        await #expect(throws: AppleDeviceToolError.unavailable) {
            try await fixture.run("music.createPlaylist", ["name": .string("Mix")])
        }
        await #expect(throws: AppleDeviceToolError.unavailable) {
            try await fixture.run("music.addToLibrary", ["id": .string("lib-song-1"), "type": .string("song")])
        }
    }

    // MARK: Access ending during a lookup

    /// A lookup takes seconds. The switch can go off in them, and then nothing may start or change.
    @Test func turningMusicOffDuringALookupPlaysNothing() async throws {
        for arguments: [String: BighelpJSONValue] in [
            ["id": .string("lib-song-1"), "type": .string("song"), "source": .string("library")],
            ["query": .string("morning")],
        ] {
            let fixture = MusicFixture()
            var allowed = true
            fixture.provider.onLookup = { allowed = false }
            await #expect(throws: AppleDeviceToolError.authorizationRequired) {
                try await fixture.run("music.play", arguments, authorize: {
                    guard allowed else { throw AppleDeviceToolError.authorizationRequired }
                })
            }
            #expect(fixture.provider.played.isEmpty, "Music must not start after the switch went off")
            #expect(fixture.provider.current.state == .stopped)
        }
    }

    @Test func turningMusicOffDuringALookupMakesNoPlaylist() async {
        let fixture = MusicFixture()
        var allowed = true
        fixture.provider.onLookup = { allowed = false }
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await fixture.run("music.createPlaylist", ["name": .string("Mix"), "itemIDs": .array([.string("lib-song-1")])], authorize: {
                guard allowed else { throw AppleDeviceToolError.authorizationRequired }
            })
        }
        #expect(fixture.provider.created.isEmpty, "A playlist must not be made after the switch went off")
    }

    @Test func turningMusicOffDuringALookupAddsNothingToTheLibrary() async {
        let fixture = MusicFixture()
        fixture.provider.hasSubscription = true
        var allowed = true
        fixture.provider.onLookup = { allowed = false }
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await fixture.run("music.addToLibrary", ["id": .string("cat-song-1"), "type": .string("song")], authorize: {
                guard allowed else { throw AppleDeviceToolError.authorizationRequired }
            })
        }
        #expect(fixture.provider.libraryAdds.isEmpty)
    }

    @Test func iOSRevokingAccessDuringALookupStopsTheChangeToo() async {
        let fixture = MusicFixture()
        fixture.provider.onLookup = { fixture.provider.authorization = .denied }
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await fixture.run("music.createPlaylist", ["name": .string("Mix"), "itemIDs": .array([.string("lib-song-1")])])
        }
        #expect(fixture.provider.created.isEmpty)
    }

    // MARK: Errors

    @Test func appleFailuresReachTheAgentAsTheirOwnCodes() async {
        let fixture = MusicFixture()
        fixture.provider.hasSubscription = true
        let cases: [(DeviceMusicProviderError, String)] = [
            (.notFound, "not_found"), (.subscriptionRequired, "subscription_required"),
            (.serviceUnavailable, "music_service_unavailable"), (.unavailable, "unavailable"),
            (.notAuthorized, "authorization_required"), (.failed, "native_failure"),
        ]
        for (failure, code) in cases {
            fixture.provider.searchFailure = failure
            do {
                _ = try await fixture.run("music.search", ["query": .string("morning")])
                Issue.record("A \(failure) search unexpectedly worked")
            } catch let error as any DeviceToolFailure {
                #expect(error.code == code)
            } catch {
                Issue.record("\(failure) escaped as \(error)")
            }
        }
    }

    @Test func kindsReadTheWordsAnAgentUses() {
        #expect(DeviceMusicKind(resultType: "song") == .song)
        #expect(DeviceMusicKind(resultType: "playlists") == .playlist)
        #expect(DeviceMusicKind(resultType: "Song") == nil)
        #expect(DeviceMusicKind(plural: "artists") == .artist)
        #expect(DeviceMusicKind(plural: "artist") == nil)
    }

    @Test func unknownOperationsAreRefused() async {
        let fixture = MusicFixture()
        await #expect(throws: AppleDeviceToolError.unsupportedOperation) { try await fixture.run("music.volume", [:]) }
    }

    // MARK: Demo

    @Test func demoMusicIsMadeUpAndNeverTouchesIOS() async throws {
        let tool = DeviceMusicTool(provider: DemoDeviceMusicProvider())
        #expect(await tool.status() == .notRequested)
        #expect(await tool.request() == .available)
        let found = try await tool.execute(operation: "music.search", arguments: ["query": .string("morning")],
                                           context: MusicFixture.context, authorize: {})
        let id = try #require(found["results"]?.array?.first?.object?["id"]?.string)
        let playing = try await tool.execute(
            operation: "music.play", arguments: ["id": .string(id), "type": .string("song"), "source": .string("library")],
            context: MusicFixture.context, authorize: {})
        #expect(playing["state"] == .string("playing"))
        #expect(found["subscription"] == .object(["canPlayCatalog": .boolean(false)]))
    }
}

// MARK: - Fakes

private struct PlayCall: Equatable {
    let id: String
    let kind: DeviceMusicKind
    let source: DeviceMusicSource
    let shuffle: Bool?
}

private struct CreateCall: Equatable {
    let name: String
    let description: String?
    let songIDs: [String]
}

private struct AddCall: Equatable {
    let playlistID: String
    let songID: String
}

private struct LibraryAddCall: Equatable {
    let id: String
    let kind: DeviceMusicKind
}

@MainActor
private final class MusicFixture {
    static let context = DeviceToolCallContext(requestID: "request", hostID: "host", agentID: "agent",
                                               sessionID: "session", turnID: "turn")

    let provider = FakeMusicProvider()
    let tool: DeviceMusicTool

    init(authorization: DeviceMusicAuthorization = .authorized) {
        provider.authorization = authorization
        tool = DeviceMusicTool(provider: provider)
    }

    @discardableResult
    func run(
        _ operation: String, _ arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void = {}
    ) async throws -> [String: BighelpJSONValue] {
        try await tool.execute(operation: operation, arguments: arguments, context: Self.context, authorize: authorize)
    }
}

/// MusicKit as far as the tool can tell. The person's library holds `lib-…` items and the Apple Music
/// catalog `cat-…` ones; the catalog answers only with the MusicKit app service on the App ID, plays and
/// is added to the library only with a subscription, and the Music app's player keeps what it was told.
@MainActor
private final class FakeMusicProvider: DeviceMusicProviding {
    struct Search: Equatable {
        let query: String
        let kinds: [DeviceMusicKind]
        let source: DeviceMusicSource
        let limitPerKind: Int
    }

    var authorization = DeviceMusicAuthorization.authorized
    var answerToRequest = DeviceMusicAuthorization.authorized
    var hasSubscription = false
    var catalogServiceWorks = true
    var playerUnavailable = false
    var editsUnavailable = false
    var searchFailure: DeviceMusicProviderError?
    var onSearch: (() -> Void)?
    /// Runs while an item is being looked up, the seconds a real library or catalog request takes.
    var onLookup: (() -> Void)?
    var current = DeviceMusicNowPlaying(state: .stopped)
    var knownSongs: Set<String> = ["lib-song-1", "lib-song-2"]
    private(set) var authorizationRequests = 0
    private(set) var searches: [Search] = []
    private(set) var listings: [(DeviceMusicLibraryListing, Int)] = []
    private(set) var played: [PlayCall] = []
    private(set) var controls: [DeviceMusicControl] = []
    private(set) var created: [CreateCall] = []
    private(set) var added: [AddCall] = []
    private(set) var libraryAdds: [LibraryAddCall] = []
    /// Every call that reached the music library or player.
    private(set) var calls: [String] = []

    private let library: [DeviceMusicItem] = [
        DeviceMusicItem(id: "lib-song-1", kind: .song, title: "Example Morning", artist: "Sample Band", album: "Demo Days", source: .library),
        DeviceMusicItem(id: "lib-song-2", kind: .song, title: "Sample Evening", artist: "Sample Band", album: "Demo Days", source: .library),
        DeviceMusicItem(id: "lib-album-1", kind: .album, title: "Demo Days", artist: "Sample Band", source: .library),
        DeviceMusicItem(id: "lib-playlist-1", kind: .playlist, title: "Made-up Mix", source: .library),
        DeviceMusicItem(id: "lib-artist-1", kind: .artist, title: "Sample Band", source: .library),
    ]
    private let catalog: [DeviceMusicItem] = [
        DeviceMusicItem(id: "cat-song-1", kind: .song, title: "Example Morning", artist: "Sample Band", album: "Demo Days", source: .catalog),
        DeviceMusicItem(id: "cat-album-1", kind: .album, title: "Demo Days", artist: "Sample Band", source: .catalog),
        DeviceMusicItem(id: "cat-playlist-1", kind: .playlist, title: "Made-up Morning", source: .catalog),
        DeviceMusicItem(id: "cat-artist-1", kind: .artist, title: "Sample Band", source: .catalog),
    ]

    private func lookupTakesTime() async {
        await Task.yield()
        onLookup?()
    }

    func requestAuthorization() async -> DeviceMusicAuthorization {
        authorizationRequests += 1
        authorization = answerToRequest
        return authorization
    }

    func canPlayCatalog() async -> Bool {
        calls.append("subscription")
        return hasSubscription
    }

    func search(query: String, kinds: [DeviceMusicKind], source: DeviceMusicSource, limitPerKind: Int) async throws -> [DeviceMusicItem] {
        calls.append("search")
        searches.append(Search(query: query, kinds: kinds, source: source, limitPerKind: limitPerKind))
        onSearch?()
        if let searchFailure { throw searchFailure }
        if source == .catalog, !catalogServiceWorks { throw DeviceMusicProviderError.serviceUnavailable }
        let pool = source == .catalog ? catalog : library
        var found: [DeviceMusicItem] = []
        for kind in kinds {
            let matches = pool.filter { $0.kind == kind && ($0.title.localizedCaseInsensitiveContains(query) || kind == .artist) }
            found += matches.prefix(limitPerKind)
        }
        return found
    }

    func library(_ listing: DeviceMusicLibraryListing, limit: Int) async throws -> [DeviceMusicItem] {
        calls.append("library")
        listings.append((listing, limit))
        return Array(library.filter { listing == .playlists ? $0.kind == .playlist : $0.kind == .song }.prefix(limit))
    }

    func play(id: String, kind: DeviceMusicKind, source: DeviceMusicSource, shuffle: Bool?,
              beforeCommit: @MainActor () throws -> Void) async throws {
        calls.append("play")
        if playerUnavailable { throw DeviceMusicProviderError.unavailable }
        let pool = source == .catalog ? catalog : library
        guard let item = pool.first(where: { $0.id == id && $0.kind == kind }) else { throw DeviceMusicProviderError.notFound }
        await lookupTakesTime()
        try beforeCommit()
        played.append(PlayCall(id: id, kind: kind, source: source, shuffle: shuffle))
        current = DeviceMusicNowPlaying(
            state: .playing,
            item: DeviceMusicPlayingItem(id: item.id, title: item.title, artist: item.artist, album: item.album, durationSeconds: 200),
            positionSeconds: 0)
    }

    func nowPlaying() throws -> DeviceMusicNowPlaying {
        calls.append("nowPlaying")
        if playerUnavailable { throw DeviceMusicProviderError.unavailable }
        return current
    }

    func control(_ action: DeviceMusicControl) async throws {
        calls.append("control")
        if playerUnavailable { throw DeviceMusicProviderError.unavailable }
        controls.append(action)
        switch action {
        case .pause: if current.item != nil { current = DeviceMusicNowPlaying(state: .paused, item: current.item, positionSeconds: 5) }
        case .resume, .next, .previous:
            guard current.item != nil else { throw DeviceMusicProviderError.notFound }
            current = DeviceMusicNowPlaying(state: .playing, item: current.item, positionSeconds: 0)
        case .stop: current = DeviceMusicNowPlaying(state: .stopped)
        }
    }

    func createPlaylist(name: String, description: String?, songIDs: [String],
                        beforeCommit: @MainActor () throws -> Void) async throws -> String {
        calls.append("createPlaylist")
        if editsUnavailable { throw DeviceMusicProviderError.unavailable }
        for id in songIDs {
            if knownSongs.contains(id) { continue }
            guard catalog.contains(where: { $0.id == id && $0.kind == .song }) else { throw DeviceMusicProviderError.notFound }
            guard hasSubscription else { throw DeviceMusicProviderError.subscriptionRequired }
        }
        await lookupTakesTime()
        try beforeCommit()
        created.append(CreateCall(name: name, description: description, songIDs: songIDs))
        return "lib-playlist-new"
    }

    func addToPlaylist(playlistID: String, songIDs: [String], beforeEach: @MainActor () throws -> Void) async throws {
        calls.append("addToPlaylist")
        guard library.contains(where: { $0.id == playlistID && $0.kind == .playlist }) else { throw DeviceMusicProviderError.notFound }
        for id in songIDs {
            try beforeEach()
            added.append(AddCall(playlistID: playlistID, songID: id))
        }
    }

    func addToLibrary(id: String, kind: DeviceMusicKind, beforeCommit: @MainActor () throws -> Void) async throws {
        calls.append("addToLibrary")
        if editsUnavailable { throw DeviceMusicProviderError.unavailable }
        if library.contains(where: { $0.id == id && $0.kind == kind }) { return }
        guard hasSubscription else { throw DeviceMusicProviderError.subscriptionRequired }
        guard catalog.contains(where: { $0.id == id && $0.kind == kind }) else { throw DeviceMusicProviderError.notFound }
        await lookupTakesTime()
        try beforeCommit()
        libraryAdds.append(LibraryAddCall(id: id, kind: kind))
    }
}
