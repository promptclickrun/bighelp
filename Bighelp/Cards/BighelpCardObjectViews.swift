import MapKit
import SwiftUI
import UIKit
@preconcurrency import Contacts
#if canImport(ContactsUI)
@preconcurrency import ContactsUI
#endif
#if canImport(MusicKit)
import MusicKit
#endif

/// What object cards may use on this device. Chat rows can't reach the
/// launch's stores through the environment (the timeline copies only some
/// values into each row), so launch wires these once.
@MainActor
enum BighelpCardObjectAccess {
    /// Settings › Device access › Music for the computer in use. Off until launch says otherwise.
    static var musicEnabled: () -> Bool = { false }
}

/// One fixed native action of an object card: a round button, and on the Mac
/// the same action in the right-click menu.
struct BighelpCardObjectAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let run: @MainActor () -> Void
}

// MARK: - Shared layout

/// Bots mode's row: a round or square picture, a title and one quiet line,
/// and round buttons at the end. When they don't fit on one line (a long
/// name, five buttons, large text) the buttons go under the picture.
private struct BighelpCardObjectRow<Picture: View>: View {
    let title: String
    let lines: [String]
    let actions: [BighelpCardObjectAction]
    let elementID: String
    @ViewBuilder var picture: Picture
    @BighelpThemeReader private var theme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BighelpTokens.space12) {
                picture
                info
                Spacer(minLength: BighelpTokens.space8)
                buttons
            }
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                HStack(spacing: BighelpTokens.space12) {
                    picture
                    info
                    Spacer(minLength: 0)
                }
                buttons
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(BighelpCardObjectMacMenu(actions: actions))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card.object.\(elementID)")
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.bighelp(.headline))
                .foregroundStyle(theme.primaryText)
                .lineLimit(2)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
        HStack(spacing: BighelpTokens.space8) {
            ForEach(actions) { action in
                BighelpCardObjectButton(action: action)
            }
        }
    }
}

/// A round glass button with one symbol, like Bots mode's header buttons.
private struct BighelpCardObjectButton: View {
    let action: BighelpCardObjectAction
    @BighelpThemeReader private var theme

    var body: some View {
        Button(action: action.run) {
            Image(systemName: action.systemImage)
                .font(.bighelp(.body, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.circle)
                .bighelpNavigationGlass(in: Circle(), isInteractive: true)
        }
        .bighelpPlainButtonStyle()
        .bighelpIconLabel(action.title)
        .accessibilityIdentifier(action.id)
    }
}

/// The Mac has no long press to find these by, so a right-click lists them too.
private struct BighelpCardObjectMacMenu: ViewModifier {
    let actions: [BighelpCardObjectAction]

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.contextMenu {
            ForEach(actions) { action in
                Button(action: action.run) { Label(action.title, systemImage: action.systemImage) }
            }
        }
        #else
        content
        #endif
    }
}

// MARK: - Contact

struct BighelpCardContactView: View {
    let contact: BighelpCardContact
    let elementID: String

    @Environment(\.openURL) private var openURL
    @State private var sheet: BighelpContactSheetRequest?
    /// Whether Contacts already lets bighelp show this person; read once, never asked for.
    @State private var opensSaved = false
    /// The saved person's own photo, when Contacts already lets bighelp read it.
    @State private var photo: UIImage?

    private static let pictureSize: CGFloat = 48

    var body: some View {
        BighelpCardObjectRow(title: contact.name, lines: contact.subtitle.map { [$0] } ?? [],
                             actions: actions, elementID: elementID) {
            Group {
                if let photo = photo ?? contact.contactID.flatMap(BighelpCardContacts.keptPhoto) {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Self.pictureSize, height: Self.pictureSize)
                        .clipShape(.circle)
                } else {
                    // The person's initials on their own color.
                    AvatarView(stableID: "card.contact.\(contact.name)", displayName: contact.name,
                               size: Self.pictureSize, kind: .person)
                }
            }
            .accessibilityHidden(true)
        }
        .task(id: contact.contactID) {
            opensSaved = contact.contactID != nil && BighelpCardContacts.canReadSaved
            if opensSaved, let id = contact.contactID { photo = await BighelpCardContacts.photo(id) }
        }
        #if canImport(ContactsUI)
        .bighelpSheet(item: $sheet) { request in
            BighelpContactSheet(request: request)
                .ignoresSafeArea()
                .bighelpSheetSize(.standard)
        }
        #endif
    }

    private var actions: [BighelpCardObjectAction] {
        var actions: [BighelpCardObjectAction] = []
        if let phone = contact.phones.first.map(\.value), let dial = BighelpCardContacts.dialable(phone) {
            if let url = URL(string: "tel:\(dial)") {
                actions.append(.init(id: "card.contact.call", title: String(localized: "Call"),
                                     systemImage: "phone.fill") { openURL(url) })
            }
            if let url = URL(string: "sms:\(dial)") {
                actions.append(.init(id: "card.contact.message", title: String(localized: "Message"),
                                     systemImage: "message.fill") { openURL(url) })
            }
        }
        if let email = contact.emails.first?.value, let url = BighelpCardContacts.mail(email) {
            actions.append(.init(id: "card.contact.email", title: String(localized: "Email"),
                                 systemImage: "envelope.fill") { openURL(url) })
        }
        if let address = contact.address, let url = BighelpCardContacts.directions(to: address.singleLine) {
            actions.append(.init(id: "card.contact.directions", title: String(localized: "Directions"),
                                 systemImage: "arrow.triangle.turn.up.right.diamond.fill") { openURL(url) })
        }
        #if canImport(ContactsUI)
        actions.append(.init(id: "card.contact.contacts",
                             title: opensSaved ? String(localized: "Open in Contacts") : String(localized: "Add to Contacts"),
                             systemImage: opensSaved ? "person.crop.circle" : "person.crop.circle.badge.plus") {
            sheet = BighelpCardContacts.sheet(for: contact)
        })
        #endif
        return actions
    }
}

@MainActor
enum BighelpCardContacts {
    /// Contacts access bighelp already has. A card never asks for it.
    static var canReadSaved: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return true }
        if #available(iOS 18.0, *), status == .limited { return true }
        return false
    }

    /// Saved people's photos by contact id, the newest 50, for the launch.
    private static var photos: [String: UIImage] = [:]
    private static var photoOrder: [String] = []
    /// Ids already read that have no photo, so a scrolled-back row doesn't read again.
    private static var noPhoto: Set<String> = []

    static func keptPhoto(_ id: String) -> UIImage? { photos[id] }

    /// The saved person's thumbnail, read once off the main thread. Only
    /// called when Contacts access was already given; never asks for it.
    static func photo(_ id: String) async -> UIImage? {
        if let photo = photos[id] { return photo }
        guard !noPhoto.contains(id), canReadSaved else { return nil }
        guard let data = await thumbnailData(id), let image = UIImage(data: data) else {
            noPhoto.insert(id)
            return nil
        }
        photos[id] = image
        photoOrder.append(id)
        if photoOrder.count > 50 { photos[photoOrder.removeFirst()] = nil }
        return image
    }

    private nonisolated static func thumbnailData(_ id: String) async -> Data? {
        let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        guard let person = try? CNContactStore().unifiedContact(withIdentifier: id, keysToFetch: keys),
              let data = person.thumbnailImageData, data.count <= 1_024 * 1_024 else { return nil }
        return data
    }

    /// Digits and a leading `+`, for `tel:` and `sms:`.
    nonisolated static func dialable(_ phone: String) -> String? {
        var result = ""
        for scalar in phone.unicodeScalars {
            if (0x30...0x39).contains(scalar.value) {
                result.unicodeScalars.append(scalar)
            } else if scalar.value == 0x2B, result.isEmpty {
                result = "+"
            }
        }
        return result.contains(where: \.isNumber) ? result : nil
    }

    /// `mailto:` for an address the validator already checked.
    nonisolated static func mail(_ address: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        return components.url
    }

    /// Maps' driving directions to a written address.
    nonisolated static func directions(to address: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "daddr", value: address), URLQueryItem(name: "dirflg", value: "d")]
        return components?.url
    }

    /// The saved person when this phone has them and Contacts lets bighelp
    /// read them, else a new contact filled in from the card.
    static func sheet(for contact: BighelpCardContact) -> BighelpContactSheetRequest {
        if let id = contact.contactID, canReadSaved, let saved = savedContact(id) {
            return BighelpContactSheetRequest(kind: .saved(saved))
        }
        return BighelpContactSheetRequest(kind: .new(newContact(contact)))
    }

    private static func savedContact(_ id: String) -> CNContact? {
        #if canImport(ContactsUI)
        // One lookup by id, on a tap.
        return try? CNContactStore().unifiedContact(
            withIdentifier: id, keysToFetch: [CNContactViewController.descriptorForRequiredKeys()])
        #else
        return nil
        #endif
    }

    static func newContact(_ contact: BighelpCardContact) -> CNMutableContact {
        let person = CNMutableContact()
        let words = contact.name.split(separator: " ", maxSplits: 1).map(String.init)
        person.givenName = words.first ?? contact.name
        if words.count > 1 { person.familyName = words[1] }
        if let subtitle = contact.subtitle { person.jobTitle = subtitle }
        person.phoneNumbers = contact.phones.map {
            CNLabeledValue(label: $0.label ?? CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0.value))
        }
        person.emailAddresses = contact.emails.map {
            CNLabeledValue(label: $0.label ?? CNLabelHome, value: $0.value as NSString)
        }
        if let address = contact.address {
            let postal = CNMutablePostalAddress()
            postal.street = address.street ?? ""
            postal.city = address.city ?? ""
            postal.state = address.region ?? ""
            postal.postalCode = address.postalCode ?? ""
            postal.country = address.country ?? ""
            person.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: postal)]
        }
        return person
    }
}

struct BighelpContactSheetRequest: Identifiable {
    enum Kind {
        case saved(CNContact)
        case new(CNMutableContact)
    }

    let id = UUID()
    let kind: Kind
}

#if canImport(ContactsUI)
/// Contacts' own screen for the person. A new contact's screen runs outside
/// bighelp, so showing it and saving from it never needs Contacts access.
private struct BighelpContactSheet: UIViewControllerRepresentable {
    let request: BighelpContactSheetRequest
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller: CNContactViewController
        switch request.kind {
        case .saved(let contact):
            controller = CNContactViewController(for: contact)
            let coordinator = context.coordinator
            controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .done, primaryAction: UIAction { _ in coordinator.dismiss() })
        case .new(let contact):
            controller = CNContactViewController(forNewContact: contact)
            controller.contactStore = CNContactStore()
        }
        controller.delegate = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.dismiss = dismiss
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency CNContactViewControllerDelegate {
        var dismiss: DismissAction

        init(dismiss: DismissAction) { self.dismiss = dismiss }

        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            dismiss()
        }
    }
}
#endif

// MARK: - Place

struct BighelpCardPlaceView: View {
    let place: BighelpCardPlace
    let elementID: String

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Button { BighelpCardPlaces.open(place) } label: {
                BighelpCardMapPicture(place: place)
                    .contentShape(.rect(cornerRadius: BighelpTokens.radius16))
            }
            .bighelpPlainButtonStyle()
            .accessibilityLabel(Text("Map of \(place.name)"))
            .accessibilityHint(Text("Opens in Maps"))
            .accessibilityIdentifier("card.place.map")
            BighelpCardObjectRow(title: place.name, lines: [place.subtitle, place.address].compactMap { $0 },
                                 actions: actions, elementID: elementID) { EmptyView() }
        }
    }

    private var actions: [BighelpCardObjectAction] {
        [
            .init(id: "card.place.directions", title: String(localized: "Directions"),
                  systemImage: "arrow.triangle.turn.up.right.diamond.fill") { BighelpCardPlaces.directions(to: place) },
            .init(id: "card.place.maps", title: String(localized: "Open in Maps"),
                  systemImage: "map.fill") { BighelpCardPlaces.open(place) },
        ]
    }
}

@MainActor
enum BighelpCardPlaces {
    static func directions(to place: BighelpCardPlace) {
        _ = mapItem(place).openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    static func open(_ place: BighelpCardPlace) {
        let region = MKCoordinateRegion(center: coordinate(place), latitudinalMeters: place.spanMeters,
                                        longitudinalMeters: place.spanMeters)
        _ = mapItem(place).openInMaps(launchOptions: [MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: region.span)])
    }

    private static func coordinate(_ place: BighelpCardPlace) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }

    private static func mapItem(_ place: BighelpCardPlace) -> MKMapItem {
        let item: MKMapItem
        if #available(iOS 26.0, *) {
            item = MKMapItem(location: CLLocation(latitude: place.latitude, longitude: place.longitude), address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate(place)))
        }
        item.name = place.name
        return item
    }
}

// MARK: - Music

/// Apple Music's own cell: the artwork large and rounded at the front (round
/// for an artist), the kind, title and artist beside it, and Play and Open in
/// Music under them. The object sits on a wash of the artwork's own color.
/// At accessibility text sizes the artwork goes on top.
struct BighelpCardMusicView: View {
    let music: BighelpCardMusic
    let elementID: String
    /// Worked out once per card, not on every redraw of the chat.
    private let artworkKey: String

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @BighelpThemeReader private var theme
    /// Music is on in Device access and iOS lets bighelp play it.
    @State private var playsHere = false
    @State private var isStarting = false
    @State private var loaded: BighelpCardMusicArtworkStore.Found?

    private static let artworkSize: CGFloat = 96
    private static let stackedArtworkSize: CGFloat = 168

    init(music: BighelpCardMusic, elementID: String) {
        self.music = music
        self.elementID = elementID
        artworkKey = BighelpCardMusicLookup.cacheKey(for: music)
    }

    /// A row scrolled back into view draws the kept picture in its first frame.
    private var artwork: BighelpCardMusicArtworkStore.Found? {
        loaded ?? BighelpCardMusicArtworkStore.shared.cached(artworkKey)
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    picture(size: Self.stackedArtworkSize)
                    info
                    buttons
                }
            } else {
                HStack(alignment: .top, spacing: BighelpTokens.space12) {
                    picture(size: Self.artworkSize)
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        info
                        Spacer(minLength: 0)
                        buttons
                    }
                    .frame(maxWidth: .infinity, minHeight: Self.artworkSize, alignment: .topLeading)
                }
            }
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { wash }
        .modifier(BighelpCardObjectMacMenu(actions: actions))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card.object.\(elementID)")
        .task(id: music) { await load() }
    }

    private var wash: some View {
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
        return shape.fill(theme.incomingMessageBackground.opacity(0.55))
            .overlay {
                if let tint = artwork?.tint {
                    shape.fill(tint.opacity(colorScheme == .dark ? 0.26 : 0.16))
                }
            }
            .animation(.easeOut(duration: 0.25), value: artwork?.tint)
    }

    private func picture(size: CGFloat) -> some View {
        let shape: AnyShape = music.kind == .artist
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: size >= Self.stackedArtworkSize ? BighelpTokens.radius16
                                            : BighelpTokens.radius12, style: .continuous))
        let found = artwork
        return ZStack {
            placeholder(size: size)
            if let found {
                artworkImage(found, size: size)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay { shape.stroke(theme.separator, lineWidth: BighelpTokens.hairline) }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 8, y: 3)
        .accessibilityElement()
        .accessibilityLabel(Text(music.artworkLabel))
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("card.music.artwork")
        .accessibilityHidden(found == nil)
    }

    @ViewBuilder
    private func artworkImage(_ found: BighelpCardMusicArtworkStore.Found, size: CGFloat) -> some View {
        switch found {
        case .picture(let picture):
            Image(uiImage: picture.image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
        #if canImport(MusicKit)
        case .musicKit(let artwork):
            ArtworkImage(artwork, width: size, height: size)
        #endif
        }
    }

    /// While the artwork loads, and when there is none: the kind's symbol on
    /// the card's own colors.
    private func placeholder(size: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [theme.incomingMessageBackground, theme.surface],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(theme.tertiaryText)
        }
    }

    private var symbol: String {
        switch music.kind {
        case .song: "music.note"
        case .album: "square.stack.fill"
        case .playlist: "music.note.list"
        case .artist: "music.mic"
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(music.kindName)
                .font(.bighelp(.caption2, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(theme.secondaryText)
            Text(music.title)
                .font(.bighelp(.headline))
                .foregroundStyle(theme.primaryText)
                .lineLimit(2)
            if let artist = music.artist {
                Text(artist)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
        HStack(spacing: BighelpTokens.space8) {
            ForEach(actions) { action in
                BighelpCardObjectButton(action: action)
            }
        }
    }

    private var actions: [BighelpCardObjectAction] {
        var actions = [BighelpCardObjectAction(
            id: "card.music.play", title: String(localized: "Play"),
            systemImage: isStarting ? "ellipsis" : "play.fill") { play() }]
        if music.openURL != nil {
            actions.append(.init(id: "card.music.open", title: String(localized: "Open in Music"),
                                 systemImage: "arrow.up.forward.app") { openInMusic() })
        }
        return actions
    }

    private func load() async {
        #if canImport(MusicKit)
        // Only what Music already allows; showing a card never asks.
        let usesMusicKit = BighelpCardObjectAccess.musicEnabled() && MusicAuthorization.currentStatus == .authorized
        #if targetEnvironment(macCatalyst)
        // The Mac has no Music app player to start; Play opens Music.
        playsHere = false
        #else
        playsHere = usesMusicKit && music.musicID != nil
        #endif
        #else
        let usesMusicKit = false
        #endif
        guard loaded == nil else { return }
        if let found = await BighelpCardMusicArtworkStore.shared.artwork(
            for: music, key: artworkKey, usesMusicKit: usesMusicKit) {
            withAnimation(.easeOut(duration: 0.25)) { loaded = found }
        }
    }

    private func play() {
        #if canImport(MusicKit) && !targetEnvironment(macCatalyst)
        if playsHere, !isStarting, let id = music.musicID,
           let kind = DeviceMusicKind(rawValue: music.kind.rawValue),
           let source = DeviceMusicSource(rawValue: (music.source ?? .catalog).rawValue) {
            isStarting = true
            Task {
                defer { isStarting = false }
                do {
                    try await LiveDeviceMusicProvider().play(id: id, kind: kind, source: source, shuffle: nil) {
                        // Music turned off while the item was looked up: play nothing.
                        guard BighelpCardObjectAccess.musicEnabled() else { throw DeviceMusicProviderError.notAuthorized }
                    }
                } catch {
                    openInMusic()
                }
            }
            return
        }
        #endif
        openInMusic()
    }

    private func openInMusic() {
        if let url = music.openURL { openURL(url) }
    }
}

/// A finished artwork picture and its average color. Never changed after it's made.
struct BighelpCardArtworkPicture: @unchecked Sendable {
    let image: UIImage
    let red: Double
    let green: Double
    let blue: Double

    var tint: Color { Color(red: red, green: green, blue: blue) }
}

/// Music card artwork, found once per item and kept: in memory for the
/// launch (the newest 60) and as files in Caches (`BighelpCardArtworkFiles`),
/// so a chat full of cards neither asks again nor stutters while scrolling.
///
/// Where it comes from, in order: the kept file; MusicKit, when Music is on in
/// Device access and the person has allowed Apple Music (the catalog item, or
/// the library item for library ids); else Apple's public lookup by the
/// link's or `music_id`'s store number, else its search by title and artist.
/// Nothing found shows the card's placeholder; it's asked again after five minutes.
@MainActor
final class BighelpCardMusicArtworkStore {
    enum Found: @unchecked Sendable {
        case picture(BighelpCardArtworkPicture)
        #if canImport(MusicKit)
        /// Library artwork has no web address; only `ArtworkImage` draws it.
        case musicKit(Artwork)
        #endif

        var tint: Color? {
            switch self {
            case .picture(let picture): picture.tint
            #if canImport(MusicKit)
            case .musicKit(let artwork): artwork.backgroundColor.map { Color(cgColor: $0) }
            #endif
            }
        }
    }

    static let shared = BighelpCardMusicArtworkStore()
    private static let limit = 60
    private static let retryAfter: TimeInterval = 300
    /// Demo mode draws a made-up cover and never goes online.
    private static let isDemo = ProcessInfo.processInfo.arguments.contains("-use-demo-fixtures")

    private var kept: [String: Found] = [:]
    private var order: [String] = []
    private var missing: [String: Date] = [:]
    private var inFlight: [String: Task<Found?, Never>] = [:]

    func cached(_ key: String) -> Found? { kept[key] }

    /// The artwork for `music`, found once; cards waiting on the same item share it.
    func artwork(for music: BighelpCardMusic, key: String, usesMusicKit: Bool) async -> Found? {
        if let found = kept[key] { return found }
        if let missed = missing[key], Date().timeIntervalSince(missed) < Self.retryAfter { return nil }
        if let running = inFlight[key] { return await running.value }
        // Not tied to the row: a card scrolled away still finishes and keeps it.
        let task = Task { @MainActor in await Self.find(music, key: key, usesMusicKit: usesMusicKit) }
        inFlight[key] = task
        let found = await task.value
        inFlight[key] = nil
        if let found {
            keep(found, key)
            missing[key] = nil
        } else {
            missing[key] = Date()
        }
        return found
    }

    private func keep(_ found: Found, _ key: String) {
        if kept[key] == nil { order.append(key) }
        kept[key] = found
        while order.count > Self.limit { kept[order.removeFirst()] = nil }
    }

    private static func find(_ music: BighelpCardMusic, key: String, usesMusicKit: Bool) async -> Found? {
        if isDemo { return await BighelpCardArtworkFiles.demoCover(for: music).map(Found.picture) }
        if let file = await BighelpCardArtworkFiles.read(key) { return .picture(file) }
        #if canImport(MusicKit)
        if usesMusicKit, let artwork = await musicKitArtwork(music) {
            let pixels = BighelpCardMusicLookup.artworkPixels
            if let url = artwork.url(width: pixels, height: pixels), url.scheme == "https",
               let picture = await BighelpCardArtworkFiles.download(url, key: key) {
                return .picture(picture)
            }
            return .musicKit(artwork)
        }
        #endif
        guard let address = await BighelpCardArtworkFiles.publicArtworkURL(for: music),
              let picture = await BighelpCardArtworkFiles.download(address, key: key) else { return nil }
        return .picture(picture)
    }

    #if canImport(MusicKit)
    /// A card without `source` reads library ids (`i.…`) from the library and
    /// anything else from the catalog, including the store number in its link.
    private static func musicKitArtwork(_ music: BighelpCardMusic) async -> Artwork? {
        guard let id = music.musicID ?? BighelpCardMusicLookup.storeID(for: music)?.id else { return nil }
        let source = music.source ?? (BighelpCardMusicLookup.isLibraryID(id) ? .library : .catalog)
        return try? await fetch(MusicItemID(id), kind: music.kind, source: source)
    }

    private static func fetch(_ id: MusicItemID, kind: BighelpCardMusic.Kind,
                              source: BighelpCardMusic.Source) async throws -> Artwork? {
        switch (source, kind) {
        case (.catalog, .song):
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id)
            request.limit = 1
            return try await request.response().items.first?.artwork
        case (.catalog, .album):
            var request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: id)
            request.limit = 1
            return try await request.response().items.first?.artwork
        case (.catalog, .playlist):
            var request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: id)
            request.limit = 1
            return try await request.response().items.first?.artwork
        case (.catalog, .artist):
            var request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: id)
            request.limit = 1
            return try await request.response().items.first?.artwork
        case (.library, .song):
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: id)
            request.limit = 1
            return try await request.response().items.first?.artwork
        case (.library, .album):
            var request = MusicLibraryRequest<Album>()
            request.filter(matching: \.id, equalTo: id)
            request.limit = 1
            return try await request.response().items.first?.artwork
        case (.library, .playlist):
            var request = MusicLibraryRequest<Playlist>()
            request.filter(matching: \.id, equalTo: id)
            request.limit = 1
            return try await request.response().items.first?.artwork
        case (.library, .artist):
            var request = MusicLibraryRequest<Artist>()
            request.filter(matching: \.id, equalTo: id)
            request.limit = 1
            return try await request.response().items.first?.artwork
        }
    }
    #endif
}

/// The network and file side of music artwork, off the main thread: bounded
/// requests to Apple's lookup and picture servers, no cookies or cache, and at
/// most 200 kept pictures in Caches (the oldest go first).
enum BighelpCardArtworkFiles {
    static let maximumFiles = 200

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = BighelpCardMusicLookup.timeout
        configuration.timeoutIntervalForResource = BighelpCardMusicLookup.timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    private static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BighelpCardArtwork", isDirectory: true)
    }

    /// Keys are SHA-256 hex (`BighelpCardMusicLookup.cacheKey`), so they're safe file names.
    private static func file(_ key: String) -> URL? {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { return nil }
        return folder?.appendingPathComponent(key + ".image")
    }

    static func read(_ key: String) async -> BighelpCardArtworkPicture? {
        guard let file = file(key), let data = try? Data(contentsOf: file),
              data.count <= BighelpCardMusicLookup.maximumImageBytes,
              let image = UIImage(data: data) else { return nil }
        return picture(from: image)
    }

    /// The lookup by store number, else the search by title and artist.
    static func publicArtworkURL(for music: BighelpCardMusic) async -> URL? {
        if let id = BighelpCardMusicLookup.storeID(for: music), let lookup = BighelpCardMusicLookup.lookupURL(id),
           let data = await get(lookup, limit: BighelpCardMusicLookup.maximumResponseBytes, accepts: isJSON),
           let artwork = BighelpCardMusicLookup.artworkURL(in: data, for: music, matchingNames: false) {
            return artwork
        }
        guard let search = BighelpCardMusicLookup.searchURL(for: music),
              let data = await get(search, limit: BighelpCardMusicLookup.maximumResponseBytes, accepts: isJSON)
        else { return nil }
        return BighelpCardMusicLookup.artworkURL(in: data, for: music, matchingNames: true)
    }

    static func download(_ url: URL, key: String) async -> BighelpCardArtworkPicture? {
        guard let checked = try? BighelpCardNetworkPolicy.validate(url),
              let data = await get(checked.url, limit: BighelpCardMusicLookup.maximumImageBytes,
                                   accepts: { $0.hasPrefix("image/") }),
              let image = UIImage(data: data) else { return nil }
        write(data, key: key)
        return picture(from: image)
    }

    /// Apple's lookup answers `text/javascript`.
    private static func isJSON(_ type: String) -> Bool {
        ["application/json", "text/javascript", "application/javascript", "text/json"].contains(type)
    }

    private static func get(_ url: URL, limit: Int, accepts: (String) -> Bool) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: BighelpCardMusicLookup.timeout)
        request.httpShouldHandleCookies = false
        guard let answer = try? await session.data(for: request),
              let http = answer.1 as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= Int64(limit), answer.0.count <= limit,
              let type = http.mimeType?.lowercased(), accepts(type) else { return nil }
        return answer.0
    }

    private static func write(_ data: Data, key: String) {
        guard let folder, let file = file(key) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys),
              files.count > maximumFiles else { return }
        let oldestFirst = files.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
            return a < b
        }
        for old in oldestFirst.prefix(files.count - maximumFiles * 3 / 4) { try? manager.removeItem(at: old) }
    }

    /// Decoded once here, so the first draw on the main thread doesn't decode it.
    static func picture(from image: UIImage) -> BighelpCardArtworkPicture? {
        let ready = image.preparingForDisplay() ?? image
        let (red, green, blue) = averageColor(ready) ?? (0.5, 0.5, 0.5)
        return BighelpCardArtworkPicture(image: ready, red: red, green: green, blue: blue)
    }

    /// The mean of an 8 × 8 copy of the picture.
    static func averageColor(_ image: UIImage) -> (Double, Double, Double)? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var sums = (0.0, 0.0, 0.0)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sums.0 += Double(pixels[index])
            sums.1 += Double(pixels[index + 1])
            sums.2 += Double(pixels[index + 2])
        }
        let count = Double(side * side) * 255
        return (sums.0 / count, sums.1 / count, sums.2 / count)
    }

    /// Demo mode's made-up cover: the brand's coral to violet with a record's
    /// rings, so screenshots show where artwork sits without going online.
    static func demoCover(for music: BighelpCardMusic) async -> BighelpCardArtworkPicture? {
        let side = CGFloat(BighelpCardMusicLookup.artworkPixels)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { drawing in
            let context = drawing.cgContext
            let colors = [UIColor(red: 0xF2 / 255, green: 0x8B / 255, blue: 0x32 / 255, alpha: 1).cgColor,
                          UIColor(red: 0xD3 / 255, green: 0x3F / 255, blue: 0x42 / 255, alpha: 1).cgColor,
                          UIColor(red: 0x9A / 255, green: 0x6B / 255, blue: 0xFF / 255, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                         locations: [0, 0.5, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            }
            let center = CGPoint(x: side * 0.62, y: side * 0.62)
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
            for ring in stride(from: CGFloat(0.12), through: 0.5, by: 0.07) {
                context.setLineWidth(side * 0.012)
                context.strokeEllipse(in: CGRect(x: center.x - side * ring, y: center.y - side * ring,
                                                 width: side * ring * 2, height: side * ring * 2))
            }
            context.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - side * 0.05, y: center.y - side * 0.05,
                                           width: side * 0.1, height: side * 0.1))
        }
        return picture(from: image)
    }
}
