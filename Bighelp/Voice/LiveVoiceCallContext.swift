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

    private static func line(_ value: String?, _ limit: Int) -> String {
        String((value ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }
}

/// Roughly where the person is (city, region, country), for a voice call's weather and local questions.
/// Only while Device access › Location is on and iOS allows it; never coordinates or a street. A call
/// waits for it at most `within`, and the place it finds is kept for the next call.
@MainActor
final class LiveVoicePlace {
    /// Set at launch (`BighelpAppComposition`).
    static let shared = LiveVoicePlace()
    static let reuseFor: TimeInterval = 30 * 60

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

    func coarse(within limit: Duration = .seconds(1)) async -> String? {
        guard isAllowed() else { return nil }
        if let fresh { return fresh }
        let search = find()
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await search.value }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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
