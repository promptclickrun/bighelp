import CoreLocation
import Foundation

/// What a voice call tells the voice model about who is talking and where, for its brief (plugin
/// `native-voice-context-v1`): the agent's name as the app shows it, the name the person saved, a coarse
/// place while they share their location, and the phone's time zone. The plugin cleans each one again.
struct LiveVoiceCallContext: Equatable, Sendable {
    static let maximumAgentNameLength = 80
    static let maximumPlaceLength = 80

    var agentName: String?
    var personName: String?
    var place: String?
    var timeZone: String?

    /// The offer's fields: only the parts that are there, each one line and bounded. Never "You", the name
    /// the app shows before one is saved.
    var fields: [String: BighelpJSONValue] {
        var fields: [String: BighelpJSONValue] = [:]
        let person = Self.line(personName, UserIdentity.maximumNameLength)
        for (key, value) in [("agentName", Self.line(agentName, Self.maximumAgentNameLength)),
                             ("personName", person == UserIdentity.placeholderName ? "" : person),
                             ("place", Self.line(place, Self.maximumPlaceLength)),
                             ("timeZone", Self.line(timeZone, 64))] where !value.isEmpty {
            fields[key] = .string(value)
        }
        return fields
    }

    /// Cut by Unicode scalars, as the plugin counts: by characters, 30 family emoji were 210 code points
    /// and the plugin refused the whole offer.
    private static func line(_ value: String?, _ limit: Int) -> String {
        let text = (value ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Roughly where the person is (city, region, country), for a voice call's weather and local questions.
/// Only while Device access › Location is on and iOS allows it; never coordinates or a street. It comes
/// from the last known fix under an hour old, else a fresh city-level one. A call waits for it at most
/// `within`, and a slower search still finishes and is kept for the next call.
@MainActor
final class LiveVoicePlace {
    /// Set at launch (`BighelpAppComposition`).
    static let shared = LiveVoicePlace()
    static let reuseFor: TimeInterval = 30 * 60
    /// A city needs no better than this, and a coarse fix comes quickly.
    static let cityAccuracy: CLLocationAccuracy = kCLLocationAccuracyKilometer

    var isAllowed: @MainActor () -> Bool
    var provider: (any DeviceLocationProviding)?
    /// The phone's last known fix: a city doesn't need a new one, which can take seconds.
    var lastKnown: @MainActor () -> DeviceLocationFix? = { nil }
    private var cached: (text: String, at: Date)?
    private var finding: Task<String?, Never>?

    init(isAllowed: @escaping @MainActor () -> Bool = { false }, provider: (any DeviceLocationProviding)? = nil) {
        self.isAllowed = isAllowed
        self.provider = provider
    }

    /// Starts finding the place ahead of the call's offer, so the offer seldom has to wait.
    func prepare() {
        guard isAllowed(), fresh == nil else { return }
        _ = find()
    }

    func coarse(within seconds: Double = 1) async -> String? {
        guard isAllowed() else { return nil }
        if let fresh { return fresh }
        let search = find()
        // A race, not a task group: a group waits for every child, so the offer waited out the whole
        // search (up to 20 s) and then had nothing. The deadline gives up on waiting, not on the search.
        return (try? await DeviceLocationDeadline.run(seconds: seconds) { await search.value }) ?? nil
    }

    private var fresh: String? {
        guard let cached, Date().timeIntervalSince(cached.at) < Self.reuseFor else { return nil }
        return cached.text
    }

    /// One search at a time. It finishes after the call stops waiting and fills the cache for the next one.
    private func find() -> Task<String?, Never> {
        if let finding { return finding }
        let task = Task { [weak self] () -> String? in
            guard let provider = self?.provider else {
                self?.finding = nil
                return nil
            }
            let known = self?.lastKnown().flatMap { Date().timeIntervalSince($0.timestamp) < 3_600 ? $0 : nil }
            let fix: DeviceLocationFix? = if let known { known } else { try? await provider.currentFix() }
            guard let fix, let place = await provider.place(for: fix) else {
                self?.finding = nil
                return nil
            }
            let text = Self.text(place)
            self?.finding = nil
            if let text { self?.cached = (text, Date()) }
            return text
        }
        finding = task
        return task
    }

    /// Core Location's last fix, if it has one.
    static func systemLastKnown() -> DeviceLocationFix? {
        CLLocationManager().location.map {
            DeviceLocationFix(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                              horizontalAccuracy: $0.horizontalAccuracy, timestamp: $0.timestamp)
        }
    }

    static func text(_ place: DeviceLocationPlace) -> String? {
        let parts = [place.city, place.region, place.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : String(parts.joined(separator: ", ").prefix(LiveVoiceCallContext.maximumPlaceLength))
    }
}

extension LiveVoiceCallContext {
    static let feature = "native-voice-context-v1"

    /// The voice session's context for a computer whose plugin takes it, nil for one that doesn't (it would
    /// refuse the fields). Asking starts the place search, so the offer seldom waits for it.
    @MainActor static func offerContext(features: Set<String>, agentName: String?,
                                        personName: @escaping @MainActor () -> String?,
                                        place: LiveVoicePlace) -> NativeLiveVoiceSession.Context? {
        guard features.contains(feature) else { return nil }
        place.prepare()
        return { () async -> [String: BighelpJSONValue] in
            let found = await place.coarse()
            return LiveVoiceCallContext(agentName: agentName, personName: personName(), place: found,
                                        timeZone: TimeZone.current.identifier).fields
        }
    }
}
