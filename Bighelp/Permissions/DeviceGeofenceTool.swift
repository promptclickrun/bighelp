@preconcurrency import CoreLocation
import Foundation
import SwiftUI
import UIKit

/// `geofences.list`, `geofences.create` and `geofences.delete`: the agent's `iphone_geofences` tool, places the phone watches so it can tell the chat that set them when the person arrives or leaves.
///
/// Watching a place needs location access that outlives the screen: with Always, iOS wakes bighelp
/// for an arrival even when it's closed; with While Using the places are watched only while bighelp
/// is open. Region monitoring is also off when the person keeps location approximate, so a place can
/// be made only with Precise Location on.
@MainActor
final class DeviceGeofenceTool: DeviceCapabilityTool {
    let capability = DeviceToolCapability.geofences

    /// The most `create` may ask of the phone, and what `list` reports.
    static let placeLimit = DeviceGeofenceMonitor.placeLimit
    static let defaultRadius: Double = 150
    static let radiusRange: ClosedRange<Double> = 100...5000
    static let maximumNameLength = 100
    static let maximumNoteLength = 1000
    /// Where the phone remembers it already asked for Always: iOS asks once, so the switch must not wait on it again.
    /// How long creating a place waits for a fix to learn whether the person is already inside it.
    static let startingFixSeconds: Double = 8
    static let askedAlwaysKey = "bighelp.device-tools.geofences.asked-always"

    private let engine: DeviceGeofenceMonitor
    private let location: any DeviceLocationProviding
    private let alwaysRequester: any DeviceGeofenceAlwaysRequesting
    private let defaults: UserDefaults
    /// Demo mode: nothing is asked of iOS and nothing is watched.
    private let usesFixtures: Bool
    /// The app's ID for the chat a call came from, found through the catalog. Nil keeps the call's own ID.
    private let resolveSession: @MainActor (String) async -> String?
    private var protectedDataObserver: (any NSObjectProtocol)?
    private var grantObserver: (any NSObjectProtocol)?

    init(
        engine: DeviceGeofenceMonitor,
        location: any DeviceLocationProviding,
        alwaysRequester: any DeviceGeofenceAlwaysRequesting,
        defaults: UserDefaults,
        usesFixtures: Bool = false,
        resolveSession: @escaping @MainActor (String) async -> String? = { _ in nil }
    ) {
        self.engine = engine; self.location = location; self.alwaysRequester = alwaysRequester
        self.defaults = defaults; self.usesFixtures = usesFixtures; self.resolveSession = resolveSession
    }

    /// Runs at every launch, the ones a place's event causes in the background too: it opens the
    /// monitor and listens, which is what makes iOS hand over the event that woke the app.
    static func live(_ environment: DeviceToolEnvironment) -> DeviceGeofenceTool {
        let defaults = environment.defaults
        if environment.usesFixtures {
            let engine = DeviceGeofenceMonitor(
                store: DemoGeofenceStore(), monitor: UnavailableDeviceGeofenceMonitor(),
                sender: DemoGeofenceSender(), notifier: DemoGeofenceNotifier())
            return DeviceGeofenceTool(engine: engine, location: DemoGeofenceLocation(),
                                      alwaysRequester: DemoGeofenceAlwaysRequester(),
                                      defaults: defaults, usesFixtures: true)
        }
        #if os(visionOS)
        let monitor: any DeviceGeofenceMonitoring = UnavailableDeviceGeofenceMonitor()
        #else
        let monitor: any DeviceGeofenceMonitoring = LiveDeviceGeofenceMonitor()
        #endif
        let engine = DeviceGeofenceMonitor(
            store: DeviceGeofenceFileStore(url: environment.dataDirectory.appending(path: "device-geofences-v1.json")),
            monitor: monitor, sender: LiveDeviceGeofenceSender(), notifier: LiveDeviceGeofenceNotifier(),
            backgroundTask: { DeviceGeofenceBackgroundTasks.begin($0) },
            grantAllows: { Self.grantAllows($0, defaults: defaults) })
        let tool = DeviceGeofenceTool(engine: engine, location: LiveDeviceLocationProvider(),
                                      alwaysRequester: LiveDeviceGeofenceAlwaysRequester(), defaults: defaults,
                                      resolveSession: { await DeviceGeofenceChats.resolveInWorkspace($0) })
        tool.observeGrants()
        Task { @MainActor in await engine.start() }
        // The saved places can't be read until the first unlock after a restart.
        tool.protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await engine.start() }
        }
        return tool
    }

    /// Turning the switch off saves the grant to `UserDefaults` (`DeviceToolPermissions`), which posts
    /// this notification: the places of a host that no longer allows them are forgotten at once.
    func observeGrants() {
        grantObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [engine = self.engine] _ in
            Task { @MainActor in await engine.pruneDisallowed() }
        }
    }

    /// For a caller that knows a switch just changed.
    func grantsChanged() async { await engine.pruneDisallowed() }

    /// Whether Arriving and leaving is still on for the place's computer. The switch is saved
    /// per computer (`DeviceToolPermissions`); a place whose switch went off stops being watched.
    /// With no phone ID yet (the app is still starting) nothing is taken away.
    static func grantAllows(_ place: DeviceGeofencePlace, defaults: UserDefaults) -> Bool {
        guard let deviceID = defaults.string(forKey: "loopdy.native-device-tools.device-id") else { return true }
        let scope = DeviceToolScope(deviceID: deviceID, authorizationEpoch: 1, hostID: place.hostID)
        return (defaults.stringArray(forKey: scope.storageKey) ?? [])
            .contains(DeviceToolCapability.geofences.rawValue)
    }

    // MARK: Permission

    func status() async -> DeviceToolSystemAccess {
        #if os(visionOS)
        return .unavailable
        #else
        guard !usesFixtures else { return .unavailable }
        guard await location.servicesEnabled() else { return .denied }
        return Self.access(location.authorization)
        #endif
    }

    /// The Settings switch: While Using first, then, once, Always. The switch turns on with
    /// While Using; Always only decides whether places are watched with bighelp closed.
    func request() async -> DeviceToolSystemAccess {
        #if os(visionOS)
        return .unavailable
        #else
        guard !usesFixtures else { return .unavailable }
        guard await location.servicesEnabled() else { return .denied }
        var authorization = location.authorization
        if authorization == .notDetermined { authorization = await location.requestWhenInUse() }
        if authorization == .whenInUse, !defaults.bool(forKey: Self.askedAlwaysKey) {
            defaults.set(true, forKey: Self.askedAlwaysKey)
            alwaysRequester.requestAlways()
        }
        return Self.access(authorization)
        #endif
    }

    static func access(_ authorization: DeviceLocationAuthorization) -> DeviceToolSystemAccess {
        switch authorization {
        case .notDetermined: .notRequested
        case .whenInUse, .always: .available
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
        case "geofences.list": try list(arguments, context: context)
        case "geofences.create": try await create(arguments, context: context, authorize: authorize)
        case "geofences.delete": try await delete(arguments, context: context, authorize: authorize)
        default: throw AppleDeviceToolError.unsupportedOperation
        }
    }

    private func list(
        _ arguments: [String: BighelpJSONValue], context: DeviceToolCallContext
    ) throws -> [String: BighelpJSONValue] {
        guard arguments.isEmpty else { throw AppleDeviceToolError.invalidArguments }
        // Only this computer's places: another computer's agents never see them.
        let places = engine.places(for: context.hostID).sorted { $0.created < $1.created }
        return [
            "geofences": .array(places.map { .object(Self.item($0)) }),
            "background": .boolean(location.authorization == .always),
            "limit": .integer(Self.placeLimit),
        ]
    }

    private func create(
        _ arguments: [String: BighelpJSONValue], context: DeviceToolCallContext,
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        let request = try Request(arguments)
        try authorize()
        // iOS can't watch a place when location is approximate.
        guard location.accuracy == .full else { throw DeviceGeofenceError.preciseLocationRequired }
        guard engine.places.count < Self.placeLimit else { throw DeviceGeofenceError.limitReached }
        var latitude = request.latitude, longitude = request.longitude
        var startsInside = request.here
        var uncertain = false
        if request.here {
            let fix: DeviceLocationFix
            do { fix = try await location.currentFix() } catch { throw AppleDeviceToolError.unavailable }
            try authorize()
            guard fix.latitude.isFinite, fix.longitude.isFinite, fix.horizontalAccuracy >= 0,
                  (-90...90).contains(fix.latitude), (-180...180).contains(fix.longitude) else {
                throw AppleDeviceToolError.unavailable
            }
            latitude = fix.latitude; longitude = fix.longitude
        } else if let latitude, let longitude {
            // Where the person is decides what iOS' first report means. Without a clear fix the
            // place starts as "outside" and the engine ignores a first report that only confirms otherwise.
            let fix = try? await DeviceLocationDeadline.run(seconds: Self.startingFixSeconds) { [location] in
                try await location.currentFix()
            }
            try authorize()
            if let inside = Self.startsInside(fix: fix, latitude: latitude, longitude: longitude,
                                              radiusMeters: request.radiusMeters) {
                startsInside = inside
            } else {
                uncertain = true
            }
        }
        guard let latitude, let longitude else { throw AppleDeviceToolError.invalidArguments }
        // The chat's ID as the app knows it, so an arrival finds it again whichever ID the call carried.
        let sessionID = await resolveSession(context.sessionID) ?? context.sessionID
        try authorize()
        let place = try await engine.add(DeviceGeofenceDraft(
            hostID: context.hostID, agentID: context.agentID, sessionID: sessionID,
            name: request.name, latitude: latitude, longitude: longitude, radiusMeters: request.radiusMeters,
            on: request.on, note: request.note, repeats: request.repeats, startsInside: startsInside,
            startingStateIsUncertain: uncertain))
        do { try authorize() }
        catch {
            // The person turned the switch off while it was being added.
            try? await engine.remove(id: place.id, hostID: context.hostID)
            throw error
        }
        return ["id": .string(place.id)]
    }

    private func delete(
        _ arguments: [String: BighelpJSONValue], context: DeviceToolCallContext,
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        guard Set(arguments.keys) == ["id"], let id = arguments["id"]?.string, !id.isEmpty, id.count <= 512 else {
            throw AppleDeviceToolError.invalidArguments
        }
        try authorize()
        try await engine.remove(id: id, hostID: context.hostID)
        return ["id": .string(id), "deleted": .boolean(true)]
    }

    /// Whether the phone is inside a place right now, or nil when the fix can't tell: none, or one
    /// less precise than the place is wide.
    static func startsInside(fix: DeviceLocationFix?, latitude: Double, longitude: Double, radiusMeters: Double) -> Bool? {
        guard let fix, fix.latitude.isFinite, fix.longitude.isFinite, fix.horizontalAccuracy >= 0,
              fix.horizontalAccuracy <= radiusMeters else { return nil }
        let distance = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
            .distance(from: CLLocation(latitude: latitude, longitude: longitude))
        return distance <= radiusMeters
    }

    // MARK: Arguments

    /// `create`'s arguments, all checked before anything is asked of iOS.
    @MainActor private struct Request {
        let name: String
        let latitude: Double?
        let longitude: Double?
        let here: Bool
        let radiusMeters: Double
        let on: DeviceGeofenceTrigger
        let note: String
        let repeats: Bool

        init(_ arguments: [String: BighelpJSONValue]) throws {
            let allowed: Set<String> = ["name", "latitude", "longitude", "here", "radiusMeters", "on", "note", "repeats"]
            guard Set(arguments.keys).isSubset(of: allowed),
                  let rawName = arguments["name"]?.string else { throw AppleDeviceToolError.invalidArguments }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= DeviceGeofenceTool.maximumNameLength,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw AppleDeviceToolError.invalidArguments
            }
            self.name = name

            var here = false
            if let value = arguments["here"] {
                guard let flag = value.boolean else { throw AppleDeviceToolError.invalidArguments }
                here = flag
            }
            self.here = here
            let hasLatitude = arguments["latitude"] != nil, hasLongitude = arguments["longitude"] != nil
            if here {
                guard !hasLatitude, !hasLongitude else { throw AppleDeviceToolError.invalidArguments }
                latitude = nil; longitude = nil
            } else {
                guard let latitude = arguments["latitude"]?.number, let longitude = arguments["longitude"]?.number,
                      latitude.isFinite, longitude.isFinite,
                      (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                    throw AppleDeviceToolError.invalidArguments
                }
                self.latitude = latitude; self.longitude = longitude
            }

            var radius = DeviceGeofenceTool.defaultRadius
            if let value = arguments["radiusMeters"] {
                guard let number = value.number, number.isFinite, DeviceGeofenceTool.radiusRange.contains(number) else {
                    throw AppleDeviceToolError.invalidArguments
                }
                radius = number
            }
            radiusMeters = radius

            var on = DeviceGeofenceTrigger.arrive
            if let value = arguments["on"] {
                guard let raw = value.string, let parsed = DeviceGeofenceTrigger(rawValue: raw) else {
                    throw AppleDeviceToolError.invalidArguments
                }
                on = parsed
            }
            self.on = on

            var note = ""
            if let value = arguments["note"] {
                guard let text = value.string, text.count <= DeviceGeofenceTool.maximumNoteLength else {
                    throw AppleDeviceToolError.invalidArguments
                }
                note = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            self.note = note

            var repeats = false
            if let value = arguments["repeats"] {
                guard let flag = value.boolean else { throw AppleDeviceToolError.invalidArguments }
                repeats = flag
            }
            self.repeats = repeats
        }
    }

    // MARK: Result

    private static func item(_ place: DeviceGeofencePlace) -> [String: BighelpJSONValue] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return [
            "id": .string(place.id),
            "name": .string(place.name),
            "latitude": .number(place.latitude),
            "longitude": .number(place.longitude),
            "radiusMeters": number(place.radiusMeters),
            "on": .string(place.on.rawValue),
            "note": .string(place.note),
            "repeats": .boolean(place.repeats),
            "created": .string(formatter.string(from: place.created)),
            "agentId": .string(place.agentID),
        ]
    }

    private static func number(_ value: Double) -> BighelpJSONValue {
        value.rounded() == value && abs(value) < 1_000_000 ? .integer(Int(value)) : .number(value)
    }
}

// MARK: Device access

/// What the Arriving and leaving switch says about when places are watched.
enum DeviceGeofenceAccessNote: Equatable {
    /// Always: places are watched with bighelp closed.
    case watchedWhenClosed
    /// While Using: places are watched only while bighelp is open.
    case watchedWhenOpen
    /// Location is approximate, which iOS can't watch places with.
    case needsPreciseLocation

    static func make(authorization: DeviceLocationAuthorization, accuracy: DeviceLocationAccuracy) -> DeviceGeofenceAccessNote? {
        switch authorization {
        case .notDetermined, .denied, .restricted: nil
        case .always: accuracy == .reduced ? .needsPreciseLocation : .watchedWhenClosed
        case .whenInUse: accuracy == .reduced ? .needsPreciseLocation : .watchedWhenOpen
        }
    }

    /// Whether a button to iOS Settings helps: for Always, or for Precise Location.
    var offersSettings: Bool { self != .watchedWhenClosed }

    static func current() -> DeviceGeofenceAccessNote? {
        #if os(visionOS)
        return nil
        #else
        let manager = CLLocationManager()
        let authorization: DeviceLocationAuthorization
        switch manager.authorizationStatus {
        case .authorizedAlways: authorization = .always
        case .authorizedWhenInUse: authorization = .whenInUse
        case .denied: authorization = .denied
        case .restricted: authorization = .restricted
        default: authorization = .notDetermined
        }
        return make(authorization: authorization,
                    accuracy: manager.accuracyAuthorization == .fullAccuracy ? .full : .reduced)
        #endif
    }
}

/// What Device access shows under the geofences switch.
@MainActor
struct GeofencePermissionExtras: View {
    let permissions: DeviceToolPermissions
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var note: DeviceGeofenceAccessNote?

    var body: some View {
        Group {
            if permissions.isEnabled(.geofences), permissions.status(for: .geofences) == .available, let note {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    Text(Self.text(for: note))
                        .bighelpFont(.metadata).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if note.offersSettings {
                        Button(BighelpPlatform.isMac ? "Open System Settings" : "Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .accessibilityIdentifier("permissions.device-tools.geofences.settings")
                    }
                }
            }
        }
        .task(id: permissions.revision) { note = DeviceGeofenceAccessNote.current() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { note = DeviceGeofenceAccessNote.current() }
        }
    }

    private static func text(for note: DeviceGeofenceAccessNote) -> LocalizedStringKey {
        switch note {
        case .watchedWhenClosed:
            "Always allowed: places are watched even when bighelp is closed."
        case .watchedWhenOpen:
            "Only while bighelp is open. To watch places when it is closed, allow location Always in Settings."
        case .needsPreciseLocation:
            "iOS can't watch places while your location is approximate. Turn on Precise Location for bighelp in Settings."
        }
    }
}

// MARK: Demo mode

/// Demo mode never starts `CLMonitor`, asks iOS or touches a real place.
@MainActor
private final class DemoGeofenceStore: DeviceGeofenceStoring {
    private var places: [DeviceGeofencePlace] = []
    var exists: Bool { false }
    func load() throws -> [DeviceGeofencePlace] { places }
    func save(_ places: [DeviceGeofencePlace]) throws { self.places = places }
}

@MainActor
private final class DemoGeofenceSender: DeviceGeofenceMessageSending {
    func send(_ message: String, to place: DeviceGeofencePlace) async throws {}
}

@MainActor
private final class DemoGeofenceNotifier: DeviceGeofenceNotifying {
    func notifyDeliveryFailed(place: DeviceGeofencePlace, arrived: Bool) async {}
}

@MainActor
private final class DemoGeofenceAlwaysRequester: DeviceGeofenceAlwaysRequesting {
    func requestAlways() {}
}

@MainActor
private final class DemoGeofenceLocation: DeviceLocationProviding {
    var authorization: DeviceLocationAuthorization { .notDetermined }
    var accuracy: DeviceLocationAccuracy { .full }
    func servicesEnabled() async -> Bool { false }
    func requestWhenInUse() async -> DeviceLocationAuthorization { .notDetermined }
    func requestPrecise(purposeKey: String) async -> DeviceLocationAccuracy { .full }
    func currentFix() async throws -> DeviceLocationFix { throw AppleDeviceToolError.unavailable }
    func place(for fix: DeviceLocationFix) async -> DeviceLocationPlace? { nil }
}
