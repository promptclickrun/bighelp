import Foundation
import Testing
@testable import Bighelp

/// Object components (`contact`, `place`, `music`): exactly the props, values
/// and limits in docs/BIGHELP_CARDS.md › Object components, and nothing else.
@MainActor
struct BighelpCardObjectsTests {
    // MARK: Contact

    private static let contact: [String: BighelpJSONValue] = [
        "name": .string("Jordan Sample"),
        "subtitle": .string("Designer at Example Studio"),
        "phones": .array([.object(["label": .string("mobile"), "value": .string("+1 (555) 010-0142")])]),
        "emails": .array([.object(["label": .string("work"), "value": .string("jordan@example.com")])]),
        "address": .object(["street": .string("12 Sample Street"), "city": .string("Testville"),
                            "region": .string("CA"), "postal_code": .string("90000"),
                            "country": .string("United States")]),
        "contact_id": .string("ABCD-1234:ABPerson"),
    ]

    @Test func aFullContactValidatesAndReadsBack() throws {
        try accepts("contact", Self.contact)
        let contact = try BighelpCardContact(props: Self.contact)
        #expect(contact.name == "Jordan Sample")
        #expect(contact.phones.first?.value == "+1 (555) 010-0142")
        #expect(contact.emails.first?.label == "work")
        #expect(contact.address?.singleLine == "12 Sample Street, Testville, CA 90000, United States")
        #expect(contact.contactID == "ABCD-1234:ABPerson")
        try accepts("contact", ["name": .string("Jordan")])
        // A phone or email may leave out its label.
        try accepts("contact", ["name": .string("Jordan"), "phones": .array([.object(["value": .string("555 0100")])])])
    }

    @Test func contactRefusesWhatTheContractDoesNotAllow() throws {
        try refuses("contact", [:])
        try refuses("contact", ["name": .string("   ")])
        try refuses("contact", ["name": .string(String(repeating: "a", count: 201))])
        try refuses("contact", ["name": .integer(4)])
        try refuses("contact", merged(Self.contact, ["nickname": .string("Jo")]))
        try refuses("contact", merged(Self.contact, ["subtitle": .string(String(repeating: "a", count: 201))]))
        try refuses("contact", merged(Self.contact, ["contact_id": .string(String(repeating: "a", count: 513))]))
        // Phones: digits, spaces and + ( ) - . only, at least one digit, at most five.
        try refuses("contact", phones("555-0100 ext 4"))
        try refuses("contact", phones("tel:5550100"))
        try refuses("contact", phones("+()- ."))
        try refuses("contact", phones("５５５０１００")) // full-width digits
        try accepts("contact", phones("+44 20.7946.0000"))
        try refuses("contact", merged(Self.contact, ["phones": .array(Array(repeating: .object(["value": .string("5550100")]), count: 6))]))
        try refuses("contact", merged(Self.contact, ["phones": .array([.object(["value": .string("5550100"), "kind": .string("x")])])]))
        try refuses("contact", merged(Self.contact, ["phones": .array([.object(["label": .string(String(repeating: "a", count: 41)), "value": .string("5550100")])])]))
        try refuses("contact", merged(Self.contact, ["phones": .array([.string("5550100")])]))
        try refuses("contact", merged(Self.contact, ["phones": .string("5550100")]))
        // Emails must look like one.
        for bad in ["jordan", "jordan@", "@example.com", "jordan@example", "jordan@@example.com",
                    "jordan smith@example.com", "jordan@example..com", "jordan@example.com?subject=hi",
                    "<jordan@example.com>"] {
            try refuses("contact", emails(bad))
        }
        try accepts("contact", emails("jordan.sample+cards@mail.example.co"))
        // Address: the five parts only, each at most 100.
        try refuses("contact", merged(Self.contact, ["address": .object(["planet": .string("Earth")])]))
        try refuses("contact", merged(Self.contact, ["address": .object(["city": .string(String(repeating: "a", count: 101))])]))
        try refuses("contact", merged(Self.contact, ["address": .string("12 Sample Street")]))
        try refuses("contact", merged(Self.contact, ["address": .object(["city": .integer(5)])]))
    }

    @Test func contactButtonsDialOnlyDigits() {
        #expect(BighelpCardContacts.dialable("+1 (555) 010-0142") == "+15550100142")
        #expect(BighelpCardContacts.dialable("555.0100") == "5550100")
        #expect(BighelpCardContacts.dialable("+ ( )") == nil)
        #expect(BighelpCardContacts.mail("jordan@example.com")?.absoluteString == "mailto:jordan@example.com")
        #expect(BighelpCardContacts.directions(to: "12 Sample Street, Testville")?.host == "maps.apple.com")
    }

    /// One picture per spot, span, size and light or dark: the chat never makes a map per redraw.
    @Test func mapPicturesAreKeptBySpotSizeAndStyle() throws {
        let place = try BighelpCardPlace(props: Self.place)
        let size = CGSize(width: 320.2, height: 132)
        let light = BighelpCardMapSnapshots.Key(place: place, size: size, scale: 3, isDark: false)
        #expect(light == BighelpCardMapSnapshots.Key(place: place, size: CGSize(width: 320, height: 132), scale: 3, isDark: false))
        #expect(light != BighelpCardMapSnapshots.Key(place: place, size: size, scale: 3, isDark: true))
        #expect(light != BighelpCardMapSnapshots.Key(place: place, size: CGSize(width: 400, height: 132), scale: 3, isDark: false))
        #expect(!BighelpCardMapSnapshots.Key(place: place, size: .zero, scale: 3, isDark: false).isDrawable)
    }

    // MARK: Place

    private static let place: [String: BighelpJSONValue] = [
        "name": .string("Fixture Coffee"), "subtitle": .string("Coffee · Open until 6 PM"),
        "address": .string("1 Placeholder Way, Testville"),
        "latitude": .number(37.7694), "longitude": .number(-122.4862), "span_meters": .integer(1_200),
    ]

    @Test func aPlaceValidatesWithItsDefaultSpan() throws {
        try accepts("place", Self.place)
        let minimal = try BighelpCardPlace(props: ["name": .string("Spot"), "latitude": .integer(0), "longitude": .integer(0)])
        #expect(minimal.spanMeters == 1_000)
        try accepts("place", merged(Self.place, ["latitude": .integer(-90), "longitude": .integer(180)]))
        try accepts("place", merged(Self.place, ["span_meters": .integer(200)]))
        try accepts("place", merged(Self.place, ["span_meters": .number(50_000)]))
    }

    @Test func placeRefusesWhatTheContractDoesNotAllow() throws {
        try refuses("place", ["name": .string("Spot"), "latitude": .integer(0)])
        try refuses("place", ["latitude": .integer(0), "longitude": .integer(0)])
        try refuses("place", merged(Self.place, ["latitude": .number(90.0001)]))
        try refuses("place", merged(Self.place, ["longitude": .number(-180.5)]))
        try refuses("place", merged(Self.place, ["latitude": .string("37.7")]))
        try refuses("place", merged(Self.place, ["span_meters": .integer(199)]))
        try refuses("place", merged(Self.place, ["span_meters": .integer(50_001)]))
        try refuses("place", merged(Self.place, ["address": .string(String(repeating: "a", count: 301))]))
        try refuses("place", merged(Self.place, ["zoom": .integer(12)]))
        try refuses("place", merged(Self.place, ["subtitle": .object(["literal": .string("Bound")])]))
    }

    // MARK: Music

    private static let music: [String: BighelpJSONValue] = [
        "kind": .string("album"), "title": .string("Sample Album"), "artist": .string("The Placeholders"),
        "music_id": .string("1234567890"), "source": .string("catalog"),
        "url": .string("https://music.apple.com/us/album/sample-album/1234567890"),
    ]

    @Test func musicValidatesEveryKindAndSource() throws {
        try accepts("music", Self.music)
        for kind in ["song", "album", "playlist", "artist"] {
            try accepts("music", ["kind": .string(kind), "title": .string("Sample")])
        }
        try accepts("music", merged(Self.music, ["source": .string("library"), "music_id": .string("i.AbC123")]))
    }

    @Test func musicRefusesWhatTheContractDoesNotAllow() throws {
        try refuses("music", ["title": .string("Sample")])
        try refuses("music", ["kind": .string("podcast"), "title": .string("Sample")])
        try refuses("music", ["kind": .string("song")])
        try refuses("music", merged(Self.music, ["source": .string("radio")]))
        try refuses("music", merged(Self.music, ["artist": .string(String(repeating: "a", count: 201))]))
        try refuses("music", merged(Self.music, ["music_id": .string(String(repeating: "1", count: 513))]))
        try refuses("music", merged(Self.music, ["artwork_url": .string("https://example.com/a.png")]))
        for bad in ["http://music.apple.com/us/album/1", "https://music.apple.com.example.com/a",
                    "https://example.com/music.apple.com/", "https://user@music.apple.com/a",
                    "https://music.apple.com:8443/a", "music://music.apple.com/a",
                    "https://music.apple.com/" + String(repeating: "a", count: 480)] {
            try refuses("music", merged(Self.music, ["url": .string(bad)]))
        }
    }

    @Test func openInMusicUsesTheLinkThenTheCatalogPageThenASearch() throws {
        let linked = try BighelpCardMusic(props: Self.music)
        #expect(linked.openURL?.absoluteString == "https://music.apple.com/us/album/sample-album/1234567890")
        let catalog = try BighelpCardMusic(props: ["kind": .string("song"), "title": .string("Sample"),
                                                   "music_id": .string("987")])
        #expect(catalog.openURL?.absoluteString == "https://music.apple.com/song/987")
        let library = try BighelpCardMusic(props: ["kind": .string("song"), "title": .string("Sample Song"),
                                                   "artist": .string("The Placeholders"),
                                                   "music_id": .string("i.abc"), "source": .string("library")])
        let search = try #require(library.openURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(search.host == "music.apple.com" && search.path == "/search")
        #expect(search.queryItems == [URLQueryItem(name: "term", value: "Sample Song The Placeholders")])
    }

    // MARK: Music artwork

    private func music(_ props: [String: BighelpJSONValue]) throws -> BighelpCardMusic {
        try BighelpCardMusic(props: merged(["kind": .string("song"), "title": .string("Sample Song"),
                                            "artist": .string("The Placeholders")], props))
    }

    @Test func storeNumbersComeFromTheLinkThenTheCatalogID() throws {
        typealias StoreID = BighelpCardMusicLookup.StoreID
        func storeID(_ props: [String: BighelpJSONValue]) throws -> StoreID? {
            BighelpCardMusicLookup.storeID(for: try music(props))
        }
        let link = "https://music.apple.com/us/album/sample-album/1234567890?i=1234567899"
        // A song on an album: the song's number for a song, the album's for anything else.
        #expect(try storeID(["url": .string(link)]) == StoreID(id: "1234567899", storefront: "us"))
        #expect(try storeID(["kind": .string("album"), "url": .string(link)])
                == StoreID(id: "1234567890", storefront: "us"))
        #expect(try storeID(["url": .string("https://music.apple.com/gb/song/sample-song/555")])
                == StoreID(id: "555", storefront: "gb"))
        #expect(try storeID(["kind": .string("album"), "url": .string("https://music.apple.com/album/id777")])
                == StoreID(id: "777", storefront: nil))
        // Playlists have no store number in their link.
        #expect(try storeID(["kind": .string("playlist"),
                             "url": .string("https://music.apple.com/us/playlist/sample/pl.abc123")]) == nil)
        // Without a link: a numeric catalog id, never a library one.
        #expect(try storeID(["music_id": .string("987")]) == StoreID(id: "987", storefront: nil))
        #expect(try storeID(["music_id": .string("i.AbC123")]) == nil)
        #expect(try storeID(["music_id": .string("987"), "source": .string("library")]) == nil)
        #expect(try storeID(["music_id": .string("pl.u-abc")]) == nil)
        #expect(BighelpCardMusicLookup.isLibraryID("i.AbC123") && BighelpCardMusicLookup.isLibraryID("l.xyz"))
        #expect(!BighelpCardMusicLookup.isLibraryID("pl.u-abc") && !BighelpCardMusicLookup.isLibraryID("987"))
    }

    @Test func lookupAndSearchAddresses() throws {
        let lookup = try #require(BighelpCardMusicLookup.lookupURL(.init(id: "1234567899", storefront: "us")))
        #expect(lookup.absoluteString == "https://itunes.apple.com/lookup?id=1234567899&country=us")
        #expect(BighelpCardMusicLookup.lookupURL(.init(id: "5", storefront: nil))?.absoluteString
                == "https://itunes.apple.com/lookup?id=5")
        let song = try music([:])
        let search = try #require(BighelpCardMusicLookup.searchURL(for: song)
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(search.host == "itunes.apple.com" && search.path == "/search")
        #expect(search.queryItems?.first { $0.name == "term" }?.value == "Sample Song The Placeholders")
        #expect(search.queryItems?.first { $0.name == "entity" }?.value == "song")
        let album = try music(["kind": .string("album")])
        #expect(BighelpCardMusicLookup.searchURL(for: album).map { $0.absoluteString.contains("entity=album") } == true)
        // Apple's search lists no pictures for these, so they never search.
        let artist = try music(["kind": .string("artist")])
        let playlist = try music(["kind": .string("playlist")])
        #expect(BighelpCardMusicLookup.searchURL(for: artist) == nil)
        #expect(BighelpCardMusicLookup.searchURL(for: playlist) == nil)
    }

    @Test func artworkAddressesGrowAndStayOnApplesPictureServers() {
        let small = "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/aa/bb/cc/source/100x100bb.jpg"
        #expect(BighelpCardMusicLookup.largeArtworkURL(small)?.absoluteString
                == "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/aa/bb/cc/source/600x600bb.jpg")
        #expect(BighelpCardMusicLookup.largeArtworkURL("http://is1-ssl.mzstatic.com/a/100x100bb.jpg") == nil)
        #expect(BighelpCardMusicLookup.largeArtworkURL("https://example.com/100x100bb.jpg") == nil)
        #expect(BighelpCardMusicLookup.largeArtworkURL("https://mzstatic.com.example.com/100x100bb.jpg") == nil)
    }

    /// A lookup answer as Apple sends it, with made-up names and numbers.
    private static let lookupAnswer = Data("""
    {"resultCount":1,"results":[{"wrapperType":"track","kind":"song","artistId":111,"collectionId":1234567890,
    "trackId":1234567899,"artistName":"The Placeholders","collectionName":"Sample Album",
    "trackName":"Sample Song (Remastered)",
    "artworkUrl30":"https://is1-ssl.mzstatic.com/image/thumb/Music/x/30x30bb.jpg",
    "artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music/x/100x100bb.jpg",
    "trackTimeMillis":201000,"country":"USA","primaryGenreName":"Pop","isStreamable":true}]}
    """.utf8)

    @Test func artworkAddressesComeFromTheAnswer() throws {
        let song = try music([:])
        #expect(BighelpCardMusicLookup.artworkURL(in: Self.lookupAnswer, for: song, matchingNames: false)?.absoluteString
                == "https://is1-ssl.mzstatic.com/image/thumb/Music/x/600x600bb.jpg")
        // A search answer must name the card's song and artist.
        #expect(BighelpCardMusicLookup.artworkURL(in: Self.lookupAnswer, for: song, matchingNames: true) != nil)
        let other = try music(["title": .string("Another Tune")])
        #expect(BighelpCardMusicLookup.artworkURL(in: Self.lookupAnswer, for: other, matchingNames: true) == nil)
        let otherArtist = try music(["artist": .string("Someone Else")])
        #expect(BighelpCardMusicLookup.artworkURL(in: Self.lookupAnswer, for: otherArtist, matchingNames: true) == nil)
        // Albums match by the album's name.
        let album = try music(["kind": .string("album"), "title": .string("sample  álbum")])
        #expect(BighelpCardMusicLookup.artworkURL(in: Self.lookupAnswer, for: album, matchingNames: true) != nil)
        // Nothing found, not JSON, or too big.
        let empty = Data(#"{"resultCount":0,"results":[]}"#.utf8)
        #expect(BighelpCardMusicLookup.artworkURL(in: empty, for: song, matchingNames: false) == nil)
        #expect(BighelpCardMusicLookup.artworkURL(in: Data("<html>".utf8), for: song, matchingNames: false) == nil)
        let huge = Data(count: BighelpCardMusicLookup.maximumResponseBytes + 1)
        #expect(BighelpCardMusicLookup.artworkURL(in: huge, for: song, matchingNames: false) == nil)
        let offServer = Data(#"{"results":[{"artworkUrl100":"https://example.com/100x100bb.jpg"}]}"#.utf8)
        #expect(BighelpCardMusicLookup.artworkURL(in: offServer, for: song, matchingNames: false) == nil)
    }

    /// One kept picture per item: the same card shares it, any other item doesn't.
    @Test func artworkIsKeptByTheCardsItem() throws {
        func key(_ props: [String: BighelpJSONValue]) throws -> String {
            BighelpCardMusicLookup.cacheKey(for: try music(props))
        }
        let song = try key([:])
        #expect(song.count == 64 && song.allSatisfy(\.isHexDigit))
        #expect(try song == key([:]))
        #expect(try song != key(["kind": .string("album")]))
        #expect(try song != key(["music_id": .string("987")]))
        #expect(try song != key(["artist": .string("Someone Else")]))
    }

    @Test func artworkHasAPlainVoiceOverLabel() throws {
        #expect(try music([:]).artworkLabel == "Album artwork for Sample Song")
        #expect(try music(["kind": .string("playlist")]).artworkLabel == "Playlist artwork for Sample Song")
        #expect(try music(["kind": .string("artist")]).artworkLabel == "Picture of Sample Song")
    }

    // MARK: Whole cards

    @Test func objectsTakeNoChildrenAndKeepTheOtherRules() throws {
        var elements = Self.elements(["type": .string("place"), "props": .object(Self.place),
                                      "children": .array([.string("extra")])])
        elements["extra"] = .object(["type": .string("divider"), "props": .object([:]), "children": .array([])])
        #expect(throws: BighelpCardValidationError.self) {
            try BighelpCardValidator.validateForStaticRelease(BighelpCardDocument(document: Self.document(elements)))
        }
        // A music object's `source` is a word, not a data source.
        let music = Self.elements(["type": .string("music"), "props": .object(Self.music), "children": .array([])])
        _ = try BighelpCardValidator.validateForStaticRelease(BighelpCardDocument(document: Self.document(music)))
    }

    @Test func theDemoCardHoldsAllThreeObjects() throws {
        let card = try BighelpCardValidator.validateForStaticRelease(BighelpCardDemoFixtures.objects)
        let types = Set(card.elements.values.compactMap { $0.object?["type"]?.string })
        #expect(types.isSuperset(of: ["contact", "place", "music"]))
        #expect(BighelpCardRenderer(card: card).isValid)
    }

    // MARK: Helpers

    private func accepts(_ type: String, _ props: [String: BighelpJSONValue],
                         sourceLocation: SourceLocation = #_sourceLocation) throws {
        let elements = Self.elements(["type": .string(type), "props": .object(props), "children": .array([])])
        let card = try BighelpCardDocument(document: Self.document(elements))
        #expect(throws: Never.self, sourceLocation: sourceLocation) {
            try BighelpCardValidator.validateForStaticRelease(card)
        }
    }

    private func refuses(_ type: String, _ props: [String: BighelpJSONValue],
                         sourceLocation: SourceLocation = #_sourceLocation) throws {
        let elements = Self.elements(["type": .string(type), "props": .object(props), "children": .array([])])
        let card = try BighelpCardDocument(document: Self.document(elements))
        #expect(throws: BighelpCardValidationError.self, sourceLocation: sourceLocation) {
            try BighelpCardValidator.validateForStaticRelease(card)
        }
    }

    private func merged(_ base: [String: BighelpJSONValue], _ changes: [String: BighelpJSONValue]) -> [String: BighelpJSONValue] {
        base.merging(changes) { $1 }
    }

    private func phones(_ value: String) -> [String: BighelpJSONValue] {
        merged(Self.contact, ["phones": .array([.object(["value": .string(value)])])])
    }

    private func emails(_ value: String) -> [String: BighelpJSONValue] {
        merged(Self.contact, ["emails": .array([.object(["value": .string(value)])])])
    }

    private static func elements(_ object: [String: BighelpJSONValue]) -> [String: BighelpJSONValue] {
        [
            "root": .object(["type": .string("card"), "props": .object(["title": .string("Fixture")]),
                             "children": .array([.string("object")])]),
            "object": .object(object),
        ]
    }

    private static func document(_ elements: [String: BighelpJSONValue]) -> [String: BighelpJSONValue] {
        [
            "schema": .string("loopdy.card"), "version": .integer(1), "title": .string("Fixture"),
            "spoken_summary": .string("Fixture summary"), "data_sources": .array([]), "root": .string("root"),
            "elements": .object(elements),
            "content_hash": .string(String(repeating: "a", count: 64)),
            "card_id": .string(String(repeating: "b", count: 32)),
            "origin": .string("live"), "created_at": .string("2026-09-02T12:00:00Z"),
        ]
    }
}
