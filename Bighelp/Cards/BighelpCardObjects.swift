import CryptoKit
import Foundation

/// The object components (plugin feature `native-card-objects-v1`): one real
/// person, place or piece of music the person can act on. Their props are
/// plain values, never bindings, and every button is a fixed native action
/// the app picks from them (docs/BIGHELP_CARDS.md › Object components).
///
/// The validator and the renderer read props through these same initializers,
/// so a card that validates always draws.
enum BighelpCardObjects {
    static let types: Set<String> = ["contact", "place", "music"]
    /// What the speaker note says this app draws when the plugin knows about them.
    static let feature = "native-card-objects-v1"
    static let renders = ["contact", "place", "music"]

    static func validate(type: String, props: [String: BighelpJSONValue]) throws {
        switch type {
        case "contact": _ = try BighelpCardContact(props: props)
        case "place": _ = try BighelpCardPlace(props: props)
        case "music": _ = try BighelpCardMusic(props: props)
        default: throw BighelpCardValidationError.invalid
        }
    }

    // MARK: Reading props

    static func requireKeys(_ props: [String: BighelpJSONValue], allowed: Set<String>, required: Set<String>) throws {
        guard required.isSubset(of: props.keys), Set(props.keys).isSubset(of: allowed) else {
            throw BighelpCardValidationError.invalid
        }
    }

    /// A string of at most `maximum` characters. Required ones need something
    /// besides spaces; an empty optional one reads as missing.
    static func text(_ value: BighelpJSONValue?, maximum: Int, required: Bool = false) throws -> String? {
        guard let value else {
            if required { throw BighelpCardValidationError.invalid }
            return nil
        }
        guard case .string(let raw) = value, raw.count <= maximum else { throw BighelpCardValidationError.invalid }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if required { throw BighelpCardValidationError.invalid }
            return nil
        }
        return trimmed
    }

    static func number(_ value: BighelpJSONValue?) throws -> Double? {
        switch value {
        case nil: return nil
        case .integer(let number)?: return Double(number)
        case .number(let number)? where number.isFinite: return number
        default: throw BighelpCardValidationError.invalid
        }
    }

    /// Scalars a phone number may hold: ASCII digits, space and `+ ( ) - .`.
    /// Byte checks, not `CharacterSet`, so every device reads them the same.
    static func isPhoneNumber(_ text: String) -> Bool {
        var digits = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39: digits += 1
            case 0x20, 0x2B, 0x28, 0x29, 0x2D, 0x2E: continue
            default: return false
            }
        }
        return digits > 0
    }

    /// One `@`, something before it, and a dotted domain after it, with no
    /// spaces, control characters or the few marks that break a `mailto:`.
    static func isEmailAddress(_ text: String) -> Bool {
        let forbidden: Set<UInt32> = [0x22, 0x28, 0x29, 0x2C, 0x3A, 0x3B, 0x3C, 0x3E, 0x5B, 0x5C, 0x5D, 0x3F, 0x26, 0x23, 0x25]
        guard !text.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F || forbidden.contains($0.value) })
        else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64 else { return false }
        let domain = parts[1]
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }
    }

    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }
}

// MARK: - Contact

struct BighelpCardLabeledValue: Equatable, Sendable {
    let label: String?
    let value: String
}

struct BighelpCardPostalAddress: Equatable, Sendable {
    var street: String?
    var city: String?
    var region: String?
    var postalCode: String?
    var country: String?

    /// "12 Sample Street", "Testville, CA 90000", "United States".
    var lines: [String] {
        let locality = [city, [region, postalCode].compactMap { $0 }.joined(separator: " ")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return [street, locality, country].compactMap { $0 }.filter { !$0.isEmpty }
    }

    var singleLine: String { lines.joined(separator: ", ") }
}

struct BighelpCardContact: Equatable, Sendable {
    static let maximumEntries = 5

    let name: String
    let subtitle: String?
    let phones: [BighelpCardLabeledValue]
    let emails: [BighelpCardLabeledValue]
    let address: BighelpCardPostalAddress?
    /// The id from `iphone_contacts`, for opening the person in Contacts.
    let contactID: String?

    init(props: [String: BighelpJSONValue]) throws {
        try BighelpCardObjects.requireKeys(
            props, allowed: ["name", "subtitle", "phones", "emails", "address", "contact_id"], required: ["name"])
        name = try BighelpCardObjects.text(props["name"], maximum: 200, required: true)!
        subtitle = try BighelpCardObjects.text(props["subtitle"], maximum: 200)
        phones = try Self.entries(props["phones"]) { BighelpCardObjects.isPhoneNumber($0) }
        emails = try Self.entries(props["emails"]) { BighelpCardObjects.isEmailAddress($0) }
        address = try Self.address(props["address"])
        if let id = try BighelpCardObjects.text(props["contact_id"], maximum: 512) {
            guard !BighelpCardObjects.hasControlCharacters(id) else { throw BighelpCardValidationError.invalid }
            contactID = id
        } else {
            contactID = nil
        }
    }

    private static func entries(_ value: BighelpJSONValue?, check: (String) -> Bool) throws -> [BighelpCardLabeledValue] {
        guard let value else { return [] }
        guard case .array(let list) = value, list.count <= maximumEntries else { throw BighelpCardValidationError.invalid }
        return try list.map { item -> BighelpCardLabeledValue in
            guard case .object(let entry) = item else { throw BighelpCardValidationError.invalid }
            try BighelpCardObjects.requireKeys(entry, allowed: ["label", "value"], required: ["value"])
            guard let text = try BighelpCardObjects.text(entry["value"], maximum: 200, required: true), check(text) else {
                throw BighelpCardValidationError.invalid
            }
            return BighelpCardLabeledValue(label: try BighelpCardObjects.text(entry["label"], maximum: 40), value: text)
        }
    }

    private static func address(_ value: BighelpJSONValue?) throws -> BighelpCardPostalAddress? {
        guard let value else { return nil }
        guard case .object(let parts) = value else { throw BighelpCardValidationError.invalid }
        try BighelpCardObjects.requireKeys(
            parts, allowed: ["street", "city", "region", "postal_code", "country"], required: [])
        let address = BighelpCardPostalAddress(
            street: try BighelpCardObjects.text(parts["street"], maximum: 100),
            city: try BighelpCardObjects.text(parts["city"], maximum: 100),
            region: try BighelpCardObjects.text(parts["region"], maximum: 100),
            postalCode: try BighelpCardObjects.text(parts["postal_code"], maximum: 100),
            country: try BighelpCardObjects.text(parts["country"], maximum: 100))
        return address.lines.isEmpty ? nil : address
    }
}

// MARK: - Place

struct BighelpCardPlace: Equatable, Sendable {
    static let spanRange: ClosedRange<Double> = 200...50_000
    static let defaultSpan: Double = 1_000

    let name: String
    let subtitle: String?
    let address: String?
    let latitude: Double
    let longitude: Double
    let spanMeters: Double

    init(props: [String: BighelpJSONValue]) throws {
        try BighelpCardObjects.requireKeys(
            props, allowed: ["name", "subtitle", "address", "latitude", "longitude", "span_meters"],
            required: ["name", "latitude", "longitude"])
        name = try BighelpCardObjects.text(props["name"], maximum: 200, required: true)!
        subtitle = try BighelpCardObjects.text(props["subtitle"], maximum: 200)
        address = try BighelpCardObjects.text(props["address"], maximum: 300)
        guard let latitude = try BighelpCardObjects.number(props["latitude"]), (-90...90).contains(latitude),
              let longitude = try BighelpCardObjects.number(props["longitude"]), (-180...180).contains(longitude)
        else { throw BighelpCardValidationError.invalid }
        self.latitude = latitude
        self.longitude = longitude
        let span = try BighelpCardObjects.number(props["span_meters"]) ?? Self.defaultSpan
        guard Self.spanRange.contains(span) else { throw BighelpCardValidationError.invalid }
        spanMeters = span
    }
}

// MARK: - Music

struct BighelpCardMusic: Equatable, Sendable {
    enum Kind: String, Sendable { case song, album, playlist, artist }
    enum Source: String, Sendable { case catalog, library }

    let kind: Kind
    let title: String
    let artist: String?
    /// The id from `iphone_music`.
    let musicID: String?
    let source: Source?
    /// Only `https://music.apple.com/…`.
    let url: URL?

    init(props: [String: BighelpJSONValue]) throws {
        try BighelpCardObjects.requireKeys(
            props, allowed: ["kind", "title", "artist", "music_id", "source", "url"], required: ["kind", "title"])
        guard case .string(let kindName)? = props["kind"], let kind = Kind(rawValue: kindName) else {
            throw BighelpCardValidationError.invalid
        }
        self.kind = kind
        title = try BighelpCardObjects.text(props["title"], maximum: 200, required: true)!
        artist = try BighelpCardObjects.text(props["artist"], maximum: 200)
        if let id = try BighelpCardObjects.text(props["music_id"], maximum: 512) {
            guard !BighelpCardObjects.hasControlCharacters(id) else { throw BighelpCardValidationError.invalid }
            musicID = id
        } else {
            musicID = nil
        }
        if let value = props["source"] {
            guard case .string(let name) = value, let source = Source(rawValue: name) else {
                throw BighelpCardValidationError.invalid
            }
            self.source = source
        } else {
            source = nil
        }
        if let link = try BighelpCardObjects.text(props["url"], maximum: 500) {
            guard let url = Self.musicURL(link) else { throw BighelpCardValidationError.invalid }
            self.url = url
        } else {
            url = nil
        }
    }

    /// An `https://music.apple.com/…` link with nothing else in its address
    /// part: no other host, port, user or password.
    static func musicURL(_ text: String) -> URL? {
        guard text.hasPrefix("https://music.apple.com/"), !BighelpCardObjects.hasControlCharacters(text),
              !text.unicodeScalars.contains(where: { $0.value == 0x20 }),
              let components = URLComponents(string: text),
              components.scheme == "https", components.host == "music.apple.com",
              components.port == nil, components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    /// Where Open in Music goes: the card's link, else the catalog item's
    /// page, else a search in Music for the title and artist. Library ids have
    /// no public page.
    var openURL: URL? {
        if let url { return url }
        if let musicID, source != .library,
           let id = musicID.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let page = URL(string: "https://music.apple.com/\(kind.rawValue)/\(id)") {
            return page
        }
        var search = URLComponents(string: "https://music.apple.com/search")
        search?.queryItems = [URLQueryItem(name: "term", value: [title, artist].compactMap { $0 }.joined(separator: " "))]
        return search?.url
    }

    /// "Song", "Album", "Playlist" or "Artist".
    var kindName: String {
        switch kind {
        case .song: String(localized: "Song")
        case .album: String(localized: "Album")
        case .playlist: String(localized: "Playlist")
        case .artist: String(localized: "Artist")
        }
    }

    /// "Song · Sample Artist".
    var detail: String {
        [kindName, artist].compactMap { $0 }.joined(separator: " · ")
    }

    /// What VoiceOver calls the card's picture.
    var artworkLabel: String {
        switch kind {
        case .song, .album: String(localized: "Album artwork for \(title)")
        case .playlist: String(localized: "Playlist artwork for \(title)")
        case .artist: String(localized: "Picture of \(title)")
        }
    }
}

// MARK: - Music artwork lookup

/// Where a music card's picture comes from without signing in: Apple's public
/// lookup by store id, else its search by title and artist. Only the picture
/// Apple lists for that item is ever shown; a search answer that names another
/// song or artist is no answer.
enum BighelpCardMusicLookup {
    static let timeout: TimeInterval = 6
    static let maximumResponseBytes = 256 * 1024
    static let maximumImageBytes = 4 * 1024 * 1024
    /// Sharp at 3x for the card's largest picture.
    static let artworkPixels = 600

    struct StoreID: Equatable, Sendable {
        let id: String
        /// The two-letter store in the link (`us`), so the lookup asks the right country.
        let storefront: String?
    }

    /// Library ids (`i.…`, `l.…`, `p.…`) live only on the person's devices.
    static func isLibraryID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", maxSplits: 1)
        return parts.count == 2 && parts[0].count == 1 && parts[0].allSatisfy { $0.isASCII && $0.isLetter }
    }

    static func isStoreNumber(_ text: some StringProtocol) -> Bool {
        !text.isEmpty && text.count <= 20 && text.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) }
    }

    /// The card's link first (it names the item and the store), then a numeric catalog `music_id`.
    static func storeID(for music: BighelpCardMusic) -> StoreID? {
        if let url = music.url, let id = storeID(from: url, kind: music.kind) { return id }
        if let id = music.musicID, music.source != .library, !isLibraryID(id), isStoreNumber(id) {
            return StoreID(id: id, storefront: nil)
        }
        return nil
    }

    /// `…/us/album/name/123?i=456` is song 456 on album 123: a song card takes
    /// 456, anything else 123. Old links spell the id `id123`.
    static func storeID(from url: URL, kind: BighelpCardMusic.Kind) -> StoreID? {
        guard url.host == "music.apple.com",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        let storefront = path.first.flatMap { first -> String? in
            first.count == 2 && first.allSatisfy({ $0.isASCII && $0.isLowercase }) ? first : nil
        }
        if kind == .song, let song = components.queryItems?.first(where: { $0.name == "i" })?.value,
           isStoreNumber(song) {
            return StoreID(id: song, storefront: storefront)
        }
        for part in path.reversed() {
            let digits = part.hasPrefix("id") ? String(part.dropFirst(2)) : part
            if isStoreNumber(digits) { return StoreID(id: digits, storefront: storefront) }
        }
        return nil
    }

    static func lookupURL(_ id: StoreID) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        var items = [URLQueryItem(name: "id", value: id.id)]
        if let storefront = id.storefront { items.append(URLQueryItem(name: "country", value: storefront)) }
        components?.queryItems = items
        return components?.url
    }

    /// Apple's search lists no pictures for artists or playlists, so those never search.
    static func searchURL(for music: BighelpCardMusic) -> URL? {
        let entity: String
        switch music.kind {
        case .song: entity = "song"
        case .album: entity = "album"
        case .playlist, .artist: return nil
        }
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: [music.title, music.artist].compactMap { $0 }.joined(separator: " ")),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: "5"),
        ]
        return components?.url
    }

    /// `…/100x100bb.jpg` → `…/600x600bb.jpg`, on Apple's picture servers only.
    static func largeArtworkURL(_ text: String) -> URL? {
        let large = text.replacingOccurrences(of: "100x100", with: "\(artworkPixels)x\(artworkPixels)")
        guard let url = URL(string: large), let host = url.host?.lowercased(),
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com"),
              (try? BighelpCardNetworkPolicy.validate(url)) != nil else { return nil }
        return url
    }

    private struct Response: Decodable {
        let results: [Item]
    }

    private struct Item: Decodable {
        let artworkUrl100: String?
        let trackName: String?
        let collectionName: String?
        let artistName: String?
    }

    /// The picture's address in a lookup or search answer. A lookup asked for
    /// one id, so its first picture is that item's; a search answer must name
    /// the card's title (and artist, when the card has one).
    static func artworkURL(in data: Data, for music: BighelpCardMusic, matchingNames: Bool) -> URL? {
        guard data.count <= maximumResponseBytes,
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        for item in response.results {
            guard let artwork = item.artworkUrl100, let url = largeArtworkURL(artwork) else { continue }
            if !matchingNames { return url }
            let name = music.kind == .album ? item.collectionName : item.trackName
            guard let name, sameName(name, music.title) else { continue }
            if let artist = music.artist {
                guard let found = item.artistName, sameName(found, artist) else { continue }
            }
            return url
        }
        return nil
    }

    /// Letters and digits only, case and accents folded; one may run on past
    /// the other ("Sample Song (Remastered)", "The Placeholders & Friends").
    static func sameName(_ found: String, _ wanted: String) -> Bool {
        let a = folded(found), b = folded(wanted)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    private static func folded(_ text: String) -> String {
        let plain = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = String.UnicodeScalarView()
        for scalar in plain.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }

    /// One name per card's item, the same on every launch: what the cache files are called.
    static func cacheKey(for music: BighelpCardMusic) -> String {
        let parts = ["v1", music.kind.rawValue, music.source?.rawValue ?? "", music.musicID ?? "",
                     music.url?.absoluteString ?? "", music.title, music.artist ?? ""]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
