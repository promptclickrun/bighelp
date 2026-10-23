import Foundation

// MARK: Places

enum DeviceGeofenceTrigger: String, Codable, CaseIterable, Sendable {
    case arrive, leave, both
}

/// One place an agent asked the phone to watch. It belongs to the host, agent and chat that made
/// it: an arrival or departure is told to that chat and no other.
struct DeviceGeofencePlace: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let hostID: String
    let agentID: String
    let sessionID: String
    let name: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let on: DeviceGeofenceTrigger
    let note: String
    let repeats: Bool
    let created: Date
    /// Where the phone last was, as far as this place knows. A "left" or "arrived" is a change
    /// from this, so the state iOS reports when a place is first added tells nobody anything.
    var isInside: Bool
    /// When this place last told its chat. One event per place per five minutes.
    var lastEventAt: Date?
    /// A place made from coordinates, with no clear fix to say where the person is, may start
    /// inside without the phone knowing. iOS then reports "inside" at once; a change reported
    /// before this time only confirms the starting state and tells nobody.
    var ignoresChangesUntil: Date?
}

/// What an agent asked for, before the phone gives it an ID.
struct DeviceGeofenceDraft: Sendable {
    let hostID: String
    let agentID: String
    let sessionID: String
    let name: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let on: DeviceGeofenceTrigger
    let note: String
    let repeats: Bool
    /// The place was made where the phone is now (`here: true`), or a clear fix says so.
    let startsInside: Bool
    /// Nothing sure is known about where the phone is, so iOS' first report may only confirm it.
    var startingStateIsUncertain = false
}

enum DeviceGeofenceError: DeviceToolFailure, Equatable, LocalizedError, Sendable {
    case limitReached
    case notFound
    case preciseLocationRequired
    case storageUnavailable

    var code: String {
        switch self {
        case .limitReached: "limit_reached"
        case .notFound: "not_found"
        case .preciseLocationRequired: "precise_location_required"
        case .storageUnavailable: "storage_unavailable"
        }
    }

    var errorDescription: String? {
        switch self {
        case .limitReached: "The phone already watches as many places as iOS allows."
        case .notFound: "The phone doesn't watch a place with that ID."
        case .preciseLocationRequired: "Precise Location is off for bighelp, and iOS can't watch places without it."
        case .storageUnavailable: "The phone couldn't save the place."
        }
    }
}

// MARK: Seams

/// iOS' answer for a place: inside it or outside it.
enum DeviceGeofenceState: Equatable, Sendable {
    case inside, outside, unknown
}

struct DeviceGeofenceEvent: Equatable, Sendable {
    let identifier: String
    let state: DeviceGeofenceState
    let date: Date
}

struct DeviceGeofenceRegion: Equatable, Sendable {
    let identifier: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
}

/// `CLMonitor` behind a seam. It keeps its places across launches under its name, and after the
/// app was gone it holds an event until a monitor of that name is open and being listened to, so
/// `events()` must be called early and once.
protocol DeviceGeofenceMonitoring: AnyObject, Sendable {
    /// The places iOS holds for this app now.
    func identifiers() async -> [String]
    func add(_ region: DeviceGeofenceRegion, assuming state: DeviceGeofenceState) async
    func remove(identifier: String) async
    func events() -> AsyncStream<DeviceGeofenceEvent>
}

/// Tells a place's chat what happened, through the Shortcuts host path.
@MainActor
protocol DeviceGeofenceMessageSending: AnyObject {
    func send(_ message: String, to place: DeviceGeofencePlace) async throws
}

/// What the person sees when the chat couldn't be told.
@MainActor
protocol DeviceGeofenceNotifying: AnyObject {
    func notifyDeliveryFailed(place: DeviceGeofencePlace, arrived: Bool) async
}

/// Asks iOS for background time while an event is told to the chat. Returns the way to give it back.
typealias DeviceGeofenceBackgroundTask = @MainActor (_ name: String) -> (@MainActor () -> Void)

@MainActor
protocol DeviceGeofenceStoring: AnyObject {
    /// Whether places were ever saved. A phone that never used the tool has nothing to tidy in iOS.
    var exists: Bool { get }
    func load() throws -> [DeviceGeofencePlace]
    func save(_ places: [DeviceGeofencePlace]) throws
}

enum DeviceGeofenceStoreError: Error, Equatable {
    /// iOS keeps the file shut until the first unlock after a restart.
    case unreadable
    case corrupt
    case unwritable
}

// MARK: Engine

/// Owns the places and what happens when iOS reports one: the debounce, the message to the chat,
/// the notification when that fails, and removing a place that doesn't repeat.
@MainActor
final class DeviceGeofenceMonitor {
    /// iOS watches at most 20 places for one app.
    static let placeLimit = 20
    static let debounceSeconds: TimeInterval = 300
    /// How long after a place is made an unexpected first report only confirms where the person already was.
    static let startingStateSeconds: TimeInterval = 120

    private let store: any DeviceGeofenceStoring
    private let monitor: any DeviceGeofenceMonitoring
    private let sender: any DeviceGeofenceMessageSending
    private let notifier: any DeviceGeofenceNotifying
    private let backgroundTask: DeviceGeofenceBackgroundTask
    private let grantAllows: @MainActor (DeviceGeofencePlace) -> Bool
    private let timeZone: TimeZone
    private let locale: Locale
    private let clock: () -> Date
    private(set) var places: [DeviceGeofencePlace] = []
    private(set) var isStarted = false
    private var listener: Task<Void, Never>?
    private var deliveries: [UUID: Task<Void, Never>] = [:]

    /// - Parameter grantAllows: whether the person still allows this place's host to use Arriving
    ///   and leaving. A place whose switch is off is removed instead of telling its chat.
    init(
        store: any DeviceGeofenceStoring,
        monitor: any DeviceGeofenceMonitoring,
        sender: any DeviceGeofenceMessageSending,
        notifier: any DeviceGeofenceNotifying,
        backgroundTask: @escaping DeviceGeofenceBackgroundTask = { _ in {} },
        grantAllows: @escaping @MainActor (DeviceGeofencePlace) -> Bool = { _ in true },
        timeZone: TimeZone = .current,
        locale: Locale = .current,
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store; self.monitor = monitor; self.sender = sender; self.notifier = notifier
        self.backgroundTask = backgroundTask; self.grantAllows = grantAllows
        self.timeZone = timeZone; self.locale = locale; self.clock = clock
    }

    /// Restores the places from disk and puts iOS in step with them. Safe to call again: it runs
    /// at every launch (also the ones a place's event causes in the background), and again when
    /// the phone's files open after a restart. Returns false while the saved places can't be read yet.
    @discardableResult
    func start() async -> Bool {
        guard !isStarted else { return true }
        do { places = try store.load() }
        catch DeviceGeofenceStoreError.unreadable { return false }
        catch { places = [] }
        isStarted = true
        // A phone that never watched a place has nothing in iOS to tidy, so `CLMonitor` stays closed.
        // Once places were saved (even if none are left, or the file is damaged), iOS is always
        // put in step with them: a place the phone forgot must not stay watched.
        guard !places.isEmpty || store.exists else { return true }
        // Listen first: an event iOS held while the app was gone arrives as soon as someone does.
        if !places.isEmpty { beginListening() }
        let allowed = places.filter { grantAllows($0) }
        if allowed.count != places.count {
            places = allowed
            try? store.save(places)
        }
        let held = Set(await monitor.identifiers())
        let wanted = Set(places.map(\.id))
        for place in places where !held.contains(place.id) {
            await monitor.add(Self.region(place), assuming: place.isInside ? .inside : .outside)
        }
        for stale in held.subtracting(wanted) { await monitor.remove(identifier: stale) }
        return true
    }

    /// Stops watching every place whose Arriving and leaving switch is off, and forgets it: its
    /// name, coordinates and note leave the disk and iOS at once. Called when the switch changes.
    func pruneDisallowed() async {
        guard isStarted else { return }
        let kept = places.filter { grantAllows($0) }
        guard kept.count != places.count else { return }
        let dropped = places.filter { place in !kept.contains { $0.id == place.id } }
        places = kept
        try? store.save(places)
        for place in dropped { await monitor.remove(identifier: place.id) }
    }

    func places(for hostID: String) -> [DeviceGeofencePlace] {
        places.filter { $0.hostID == hostID }
    }

    func add(_ draft: DeviceGeofenceDraft) async throws -> DeviceGeofencePlace {
        guard await start() else { throw DeviceGeofenceError.storageUnavailable }
        guard places.count < Self.placeLimit else { throw DeviceGeofenceError.limitReached }
        let created = clock()
        let place = DeviceGeofencePlace(
            id: UUID().uuidString.lowercased(), hostID: draft.hostID, agentID: draft.agentID,
            sessionID: draft.sessionID, name: draft.name, latitude: draft.latitude,
            longitude: draft.longitude, radiusMeters: draft.radiusMeters, on: draft.on, note: draft.note,
            repeats: draft.repeats, created: created, isInside: draft.startsInside, lastEventAt: nil,
            ignoresChangesUntil: draft.startingStateIsUncertain
                ? created.addingTimeInterval(Self.startingStateSeconds) : nil)
        // Saved before iOS hears of it: a crash in between leaves a place the next launch adds.
        do { try store.save(places + [place]) } catch { throw DeviceGeofenceError.storageUnavailable }
        places.append(place)
        beginListening()
        await monitor.add(Self.region(place), assuming: place.isInside ? .inside : .outside)
        return place
    }

    func remove(id: String, hostID: String) async throws {
        guard await start() else { throw DeviceGeofenceError.storageUnavailable }
        guard let index = places.firstIndex(where: { $0.id == id && $0.hostID == hostID }) else {
            throw DeviceGeofenceError.notFound
        }
        var remaining = places
        remaining.remove(at: index)
        do { try store.save(remaining) } catch { throw DeviceGeofenceError.storageUnavailable }
        places = remaining
        await monitor.remove(identifier: id)
    }

    /// Waits for every message to the chats to finish. Tests use it; the app never needs to.
    func finishDeliveries() async {
        for task in Array(deliveries.values) { await task.value }
    }

    // MARK: Events

    private func beginListening() {
        guard listener == nil else { return }
        let events = monitor.events()
        listener = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    func handle(_ event: DeviceGeofenceEvent) async {
        guard let index = places.firstIndex(where: { $0.id == event.identifier }) else {
            // iOS holds a place this phone no longer has.
            await monitor.remove(identifier: event.identifier)
            return
        }
        let inside: Bool
        switch event.state {
        case .inside: inside = true
        case .outside: inside = false
        case .unknown: return
        }
        var place = places[index]
        // Only a change counts: iOS also reports the state a place starts in.
        guard inside != place.isInside else { return }
        place.isInside = inside
        if let until = place.ignoresChangesUntil {
            // The first report soon after a place was made from coordinates is where the person
            // already was, not an arrival. It is absorbed once; a later change tells as usual.
            place.ignoresChangesUntil = nil
            if event.date < until {
                places[index] = place
                try? store.save(places)
                return
            }
        }
        let wanted = inside ? place.on != .leave : place.on != .arrive
        guard wanted else {
            places[index] = place
            try? store.save(places)
            return
        }
        guard grantAllows(place) else {
            await dropWithoutTelling(place)
            return
        }
        if let last = place.lastEventAt, event.date.timeIntervalSince(last) < Self.debounceSeconds {
            places[index] = place
            try? store.save(places)
            return
        }
        // Background time first: telling the chat takes longer than iOS leaves a woken app.
        let finishBackgroundTask = backgroundTask("bighelp place")
        place.lastEventAt = event.date
        if place.repeats {
            places[index] = place
            try? store.save(places)
        } else {
            places.remove(at: index)
            try? store.save(places)
            await monitor.remove(identifier: place.id)
        }
        let message = DeviceGeofenceMessage.text(
            placeName: place.name, arrived: inside, note: place.note, date: event.date,
            timeZone: timeZone, locale: locale)
        let key = UUID()
        deliveries[key] = Task { @MainActor [weak self] in
            guard let self else { finishBackgroundTask(); return }
            do { try await self.sender.send(message, to: place) }
            catch { await self.notifier.notifyDeliveryFailed(place: place, arrived: inside) }
            finishBackgroundTask()
            self.deliveries[key] = nil
        }
    }

    private func dropWithoutTelling(_ place: DeviceGeofencePlace) async {
        places.removeAll { $0.id == place.id }
        try? store.save(places)
        await monitor.remove(identifier: place.id)
    }

    private static func region(_ place: DeviceGeofencePlace) -> DeviceGeofenceRegion {
        DeviceGeofenceRegion(identifier: place.id, latitude: place.latitude, longitude: place.longitude,
                             radiusMeters: place.radiusMeters)
    }
}

// MARK: Message

/// The plain message an agent gets when the person arrives or leaves.
enum DeviceGeofenceMessage {
    static func text(
        placeName: String, arrived: Bool, note: String, date: Date,
        timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
        let name = oneLine(placeName).replacingOccurrences(of: "\"", with: "'")
        let verb = arrived ? "Arrived at" : "Left"
        var text = "\u{1F4CD} \(verb) \"\(name)\" at \(time)."
        let note = oneLine(note)
        if !note.isEmpty {
            text += " Your note: \(note)"
            if let last = note.last, !".!?".contains(last) { text += "." }
        }
        return text
    }

    private static func oneLine(_ value: String) -> String {
        value.components(separatedBy: .newlines.union(.controlCharacters))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: Saved places

/// The places on disk. Protected until the first unlock after a restart, not until every unlock:
/// an arrival wakes bighelp while the phone is locked, and the place has to be readable then.
@MainActor
final class DeviceGeofenceFileStore: DeviceGeofenceStoring {
    private struct File: Codable {
        var version = 1
        var places: [DeviceGeofencePlace]
    }

    private static let maximumBytes = 512_000
    private let url: URL

    init(url: URL) { self.url = url }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func load() throws -> [DeviceGeofencePlace] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw DeviceGeofenceStoreError.unreadable }
        guard data.count <= Self.maximumBytes else { throw DeviceGeofenceStoreError.corrupt }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data), file.version == 1,
              file.places.count <= DeviceGeofenceMonitor.placeLimit else {
            throw DeviceGeofenceStoreError.corrupt
        }
        return file.places
    }

    func save(_ places: [DeviceGeofencePlace]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(File(places: places))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var resource = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try resource.setResourceValues(values)
        } catch {
            throw DeviceGeofenceStoreError.unwritable
        }
    }
}

/// Demo mode and platforms without `CLMonitor`: nothing is watched and nothing asks iOS.
final class UnavailableDeviceGeofenceMonitor: DeviceGeofenceMonitoring {
    func identifiers() async -> [String] { [] }
    func add(_ region: DeviceGeofenceRegion, assuming state: DeviceGeofenceState) async {}
    func remove(identifier: String) async {}
    func events() -> AsyncStream<DeviceGeofenceEvent> { AsyncStream { $0.finish() } }
}
