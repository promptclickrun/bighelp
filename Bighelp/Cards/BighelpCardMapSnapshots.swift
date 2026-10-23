import MapKit
import SwiftUI
import UIKit

/// Still map pictures for place cards. The chat redraws its rows for the
/// keyboard, the header and every streaming word, so a place never draws a
/// live map there: MapKit's snapshotter makes one picture per coordinate,
/// span, size and light or dark, and the row reads it back from here.
@MainActor
final class BighelpCardMapSnapshots {
    struct Key: Hashable, Sendable {
        /// Micro-degrees, so two cards for the same spot share a picture.
        let latitude: Int
        let longitude: Int
        let spanMeters: Int
        let width: Int
        let height: Int
        let scale: Int
        let isDark: Bool

        init(place: BighelpCardPlace, size: CGSize, scale: CGFloat, isDark: Bool) {
            latitude = Int((place.latitude * 1_000_000).rounded())
            longitude = Int((place.longitude * 1_000_000).rounded())
            spanMeters = Int(place.spanMeters.rounded())
            width = Int(size.width.rounded())
            height = Int(size.height.rounded())
            self.scale = max(1, Int(scale.rounded()))
            self.isDark = isDark
        }

        var isDrawable: Bool { width >= 20 && height >= 20 && width <= 2_000 && height <= 2_000 }
    }

    static let shared = BighelpCardMapSnapshots()

    /// About 40 pictures of a phone-wide card; the oldest go first.
    private let pictures: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        return cache
    }()
    private var inFlight: [Key: Task<SnapshotPicture, Never>] = [:]

    func cached(_ key: Key) -> UIImage? {
        pictures.object(forKey: Self.name(key))
    }

    /// The picture for `key`, made once; callers waiting on the same key share it.
    func picture(for key: Key) async -> UIImage? {
        if let image = cached(key) { return image }
        guard key.isDrawable else { return nil }
        if let running = inFlight[key] { return await running.value.image }
        let task = Task { @MainActor in await Self.snapshot(key) }
        inFlight[key] = task
        let image = await task.value.image
        inFlight[key] = nil
        if let image { pictures.setObject(image, forKey: Self.name(key)) }
        return image
    }

    private static func name(_ key: Key) -> NSString {
        "\(key.latitude),\(key.longitude),\(key.spanMeters),\(key.width)x\(key.height)@\(key.scale),\(key.isDark)" as NSString
    }

    private static func snapshot(_ key: Key) async -> SnapshotPicture {
        let options = MKMapSnapshotter.Options()
        let center = CLLocationCoordinate2D(latitude: Double(key.latitude) / 1_000_000,
                                            longitude: Double(key.longitude) / 1_000_000)
        let span = CLLocationDistance(key.spanMeters)
        options.region = MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span)
        options.size = CGSize(width: key.width, height: key.height)
        let isDark = key.isDark, scale = CGFloat(key.scale)
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = isDark ? .dark : .light
            traits.displayScale = scale
        }
        let snapshotter = MKMapSnapshotter(options: options)
        // MapKit calls back on the queue it's given; the callback is Sendable so
        // it never claims the main actor it doesn't run on.
        let picture = await withCheckedContinuation { (continuation: CheckedContinuation<SnapshotPicture, Never>) in
            snapshotter.start(with: .main) { @Sendable snapshot, _ in
                continuation.resume(returning: SnapshotPicture(image: snapshot?.image))
            }
        }
        withExtendedLifetime(snapshotter) {}
        return picture
    }
}

/// A finished snapshot's picture, handed from MapKit's callback. The image is
/// never changed after it's made.
private struct SnapshotPicture: @unchecked Sendable {
    let image: UIImage?
}

/// The map picture with a pin at its center (the snapshot is centered on the
/// place). Until the picture is made, a quiet tile with a map symbol.
struct BighelpCardMapPicture: View {
    let place: BighelpCardPlace
    var height: CGFloat = 132

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @BighelpThemeReader private var theme
    /// The last picture shown, kept while a new size or style is made.
    @State private var shown: UIImage?

    var body: some View {
        GeometryReader { geometry in
            let key = BighelpCardMapSnapshots.Key(place: place, size: geometry.size, scale: displayScale,
                                                  isDark: colorScheme == .dark)
            let image = BighelpCardMapSnapshots.shared.cached(key) ?? shown
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    theme.incomingMessageBackground
                    Image(systemName: "map")
                        .font(.bighelp(.title2))
                        .foregroundStyle(theme.tertiaryText)
                }
                BighelpCardMapPin()
            }
            .task(id: key) {
                if let picture = await BighelpCardMapSnapshots.shared.picture(for: key) { shown = picture }
            }
        }
        .frame(height: height)
        .clipShape(.rect(cornerRadius: BighelpTokens.radius16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                .stroke(theme.separator, lineWidth: BighelpTokens.hairline)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Map of \(place.name)"))
        .accessibilityAddTraits(.isImage)
    }
}

/// A round pin in the app's action color, with a white ring.
private struct BighelpCardMapPin: View {
    @BighelpThemeReader private var theme

    var body: some View {
        Image(systemName: "mappin")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(theme.outgoingMessageBackground, in: .circle)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .accessibilityHidden(true)
    }
}
