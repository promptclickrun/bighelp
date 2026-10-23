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

    var body: some View {
        BighelpCardObjectRow(title: contact.name, lines: contact.subtitle.map { [$0] } ?? [],
                             actions: actions, elementID: elementID) {
            AvatarView(stableID: "card.contact.\(contact.name)", displayName: contact.name,
                       size: 48, kind: .person)
                .accessibilityHidden(true)
        }
        .task(id: contact.contactID) {
            opensSaved = contact.contactID != nil && BighelpCardContacts.canReadSaved
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

struct BighelpCardMusicView: View {
    let music: BighelpCardMusic
    let elementID: String

    @Environment(\.openURL) private var openURL
    @BighelpThemeReader private var theme
    /// Music is on in Device access and iOS lets bighelp play it.
    @State private var playsHere = false
    @State private var isStarting = false
    #if canImport(MusicKit)
    @State private var artwork: Artwork?
    #endif

    private static let artworkSize: CGFloat = 56

    var body: some View {
        BighelpCardObjectRow(title: music.title, lines: [music.detail], actions: actions, elementID: elementID) {
            picture
        }
        .task(id: music) { await load() }
    }

    @ViewBuilder private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
        Group {
            #if canImport(MusicKit)
            if let artwork {
                ArtworkImage(artwork, width: Self.artworkSize, height: Self.artworkSize)
            } else {
                symbolTile
            }
            #else
            symbolTile
            #endif
        }
        .frame(width: Self.artworkSize, height: Self.artworkSize)
        .clipShape(shape)
        .overlay { shape.stroke(theme.separator, lineWidth: BighelpTokens.hairline) }
        .accessibilityHidden(true)
    }

    private var symbolTile: some View {
        ZStack {
            theme.incomingMessageBackground
            Image(systemName: symbol)
                .font(.bighelp(.title2, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
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
        guard BighelpCardObjectAccess.musicEnabled(), MusicAuthorization.currentStatus == .authorized else {
            playsHere = false
            artwork = nil
            return
        }
        #if targetEnvironment(macCatalyst)
        // The Mac has no Music app player to start; Play opens Music.
        playsHere = false
        #else
        playsHere = music.musicID != nil
        #endif
        artwork = await BighelpCardMusicArtwork.artwork(for: music)
        #endif
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

#if canImport(MusicKit)
/// Artwork by id, kept for the launch so a row scrolled back into view
/// doesn't ask MusicKit again.
@MainActor
enum BighelpCardMusicArtwork {
    private static var kept: [String: Artwork] = [:]
    private static let limit = 100

    static func artwork(for music: BighelpCardMusic) async -> Artwork? {
        guard let id = music.musicID else { return nil }
        let source = music.source ?? .catalog
        let key = "\(source.rawValue):\(music.kind.rawValue):\(id)"
        if let artwork = kept[key] { return artwork }
        guard let artwork = try? await fetch(MusicItemID(id), kind: music.kind, source: source) else { return nil }
        if kept.count >= limit { kept.removeAll() }
        kept[key] = artwork
        return artwork
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
}
#endif
