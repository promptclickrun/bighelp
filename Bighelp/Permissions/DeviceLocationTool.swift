@preconcurrency import CoreLocation
import Foundation
#if os(visionOS)
import MapKit
#endif

/// What iOS says about location access. bighelp only ever asks for While Using the App.
enum DeviceLocationAuthorization: Equatable, Sendable {
    case notDetermined, denied, restricted, whenInUse, always
}

enum DeviceLocationAccuracy: Equatable, Sendable {
    case full, reduced
}

struct DeviceLocationFix: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    /// Meters. Core Location reports a negative value for a fix it couldn't place.
    let horizontalAccuracy: Double
    let timestamp: Date
}

/// Apple's name for the spot. Any part can be missing.
struct DeviceLocationPlace: Equatable, Sendable {
    var street: String?
    var neighborhood: String?
    var city: String?
    var region: String?
    var country: String?
    var postalCode: String?
}

/// Core Location behind a seam, so the choices below can be tested without a device.
@MainActor
protocol DeviceLocationProviding: AnyObject {
    var authorization: DeviceLocationAuthorization { get }
    var accuracy: DeviceLocationAccuracy { get }
    func servicesEnabled() async -> Bool
    /// Asks for While Using the App. Never Always.
    func requestWhenInUse() async -> DeviceLocationAuthorization
    /// Asks iOS to share precise location this once (`NSLocationTemporaryUsageDescriptionDictionary`).
    func requestPrecise(purposeKey: String) async -> DeviceLocationAccuracy
    func currentFix() async throws -> DeviceLocationFix
    func place(for fix: DeviceLocationFix) async -> DeviceLocationPlace?
}

/// `location.current`: where the phone is right now, for an agent the person allowed.
/// It runs only while bighelp is open; nothing tracks the phone in the background.
@MainActor
final class DeviceLocationTool {
    /// The key under Info.plist's `NSLocationTemporaryUsageDescriptionDictionary`.
    static let purposeKey = "AgentRequest"
    static let maximumFieldLength = 100
    private let provider: any DeviceLocationProviding

    init(provider: any DeviceLocationProviding) {
        self.provider = provider
    }

    /// iOS's current answer. Never asks.
    func status() async -> DeviceToolSystemAccess {
        // Location Services off is the person's choice, fixed in Settings like a denial.
        guard await provider.servicesEnabled() else { return .denied }
        return Self.access(provider.authorization)
    }

    /// The Settings switch: the first time, iOS asks for While Using the App.
    func request() async -> DeviceToolSystemAccess {
        guard await provider.servicesEnabled() else { return .denied }
        guard provider.authorization == .notDetermined else { return Self.access(provider.authorization) }
        return Self.access(await provider.requestWhenInUse())
    }

    func current(authorize: @escaping @MainActor () throws -> Void) async throws -> [String: BighelpJSONValue] {
        switch await status() {
        case .available: break
        case .unavailable: throw AppleDeviceToolError.unavailable
        case .notRequested, .denied, .managedByHealth: throw AppleDeviceToolError.authorizationRequired
        }
        // A question from iOS only while this chat still owns the call and the app is open.
        try authorize()
        var precise = provider.accuracy == .full
        if !precise {
            // bighelp shares approximate location by default; iOS asks about precise for this call.
            precise = await provider.requestPrecise(purposeKey: Self.purposeKey) == .full
            try authorize()
        }
        let fix: DeviceLocationFix
        do { fix = try await provider.currentFix() } catch { throw AppleDeviceToolError.unavailable }
        try authorize()
        precise = precise && provider.accuracy == .full
        let place = await provider.place(for: fix)
        try authorize()
        return try Self.payload(fix: fix, precise: precise, place: place)
    }

    /// The bounded result the agent gets. An approximate fix never carries a street.
    static func payload(
        fix: DeviceLocationFix, precise: Bool, place: DeviceLocationPlace?
    ) throws -> [String: BighelpJSONValue] {
        guard fix.latitude.isFinite, fix.longitude.isFinite,
              (-90...90).contains(fix.latitude), (-180...180).contains(fix.longitude),
              fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0 else {
            throw AppleDeviceToolError.unavailable
        }
        let meters = Int(min(fix.horizontalAccuracy, 1_000_000).rounded())
        var payload: [String: BighelpJSONValue] = [
            "latitude": .number(rounded(fix.latitude)),
            "longitude": .number(rounded(fix.longitude)),
            "horizontalAccuracyMeters": .integer(meters),
            "timestamp": .string(timestamp(fix.timestamp)),
            "precise": .boolean(precise),
        ]
        if !precise {
            payload["note"] = .string("The person kept approximate location, so this is only a rough area "
                + "(accurate to about \(distance(meters))). Don't name a street or an exact spot.")
        }
        var fields: [String: BighelpJSONValue] = [:]
        let named: [(String, String?)] = [
            ("street", precise ? place?.street : nil),
            ("neighborhood", precise ? place?.neighborhood : nil),
            ("city", place?.city),
            ("region", place?.region),
            ("country", place?.country),
            ("postalCode", precise ? place?.postalCode : nil),
        ]
        for (key, value) in named {
            if let value = clean(value) { fields[key] = .string(value) }
        }
        if !fields.isEmpty { payload["place"] = .object(fields) }
        return payload
    }

    private static func access(_ authorization: DeviceLocationAuthorization) -> DeviceToolSystemAccess {
        switch authorization {
        case .notDetermined: .notRequested
        case .whenInUse, .always: .available
        case .denied: .denied
        case .restricted: .unavailable
        }
    }

    /// Six decimals is about ten centimeters, more than any phone fix.
    private static func rounded(_ degrees: Double) -> Double {
        (degrees * 1_000_000).rounded() / 1_000_000
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func distance(_ meters: Int) -> String {
        meters < 1_000 ? "\(meters) m" : "\(Int((Double(meters) / 1_000).rounded())) km"
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let visible = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maximumFieldLength))
    }
}

/// One Core Location request shared by everyone waiting for it.
@MainActor
final class DeviceLocationRequestPool<Value: Sendable> {
    private var continuations: [UUID: CheckedContinuation<Value, any Error>] = [:]

    var pendingCount: Int { continuations.count }

    func value(start: @MainActor () -> Void) async throws -> Value {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let shouldStart = continuations.isEmpty
                continuations[requestID] = continuation
                if shouldStart { start() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID)
            }
        }
    }

    func finish(returning value: Value) {
        let pending = continuations.values
        continuations.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }

    func finish(throwing error: any Error) {
        let pending = continuations.values
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: error) }
    }

    private func cancel(_ requestID: UUID) {
        continuations.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
    }
}

/// A tool call has about thirty seconds; a fix or an address that takes too long is given up.
@MainActor
enum DeviceLocationDeadline {
    static func run<Value: Sendable>(
        seconds: Double, _ operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let gate = Gate()
        return try await withCheckedThrowingContinuation { continuation in
            let work = Task { @MainActor in
                do {
                    let value = try await operation()
                    if gate.claim() { continuation.resume(returning: value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            gate.timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard gate.claim() else { return }
                work.cancel()
                continuation.resume(throwing: AppleDeviceToolError.unavailable)
            }
        }
    }

    private final class Gate {
        var timer: Task<Void, Never>?
        private var finished = false

        func claim() -> Bool {
            guard !finished else { return false }
            finished = true
            timer?.cancel()
            return true
        }
    }
}

@MainActor
final class LiveDeviceLocationProvider: NSObject, DeviceLocationProviding, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let fixes = DeviceLocationRequestPool<DeviceLocationFix>()
    private var authorizationWaiters: [CheckedContinuation<DeviceLocationAuthorization, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var authorization: DeviceLocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorizedWhenInUse: .whenInUse
        case .authorizedAlways: .always
        @unknown default: .restricted
        }
    }

    var accuracy: DeviceLocationAccuracy {
        manager.accuracyAuthorization == .fullAccuracy ? .full : .reduced
    }

    func servicesEnabled() async -> Bool {
        // Apple warns against asking on the main thread.
        await Task.detached { CLLocationManager.locationServicesEnabled() }.value
    }

    func requestWhenInUse() async -> DeviceLocationAuthorization {
        guard authorization == .notDetermined else { return authorization }
        return await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            if authorizationWaiters.count == 1 { manager.requestWhenInUseAuthorization() }
        }
    }

    func requestPrecise(purposeKey: String) async -> DeviceLocationAccuracy {
        guard accuracy == .reduced else { return .full }
        let manager = manager
        // iOS answers on its own queue: a Sendable callback, or a main-actor closure traps there.
        // A question left unanswered keeps approximate rather than holding the call open.
        _ = try? await DeviceLocationDeadline.run(seconds: 20) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: purposeKey) { @Sendable _ in
                    continuation.resume()
                }
            }
        }
        return accuracy
    }

    func currentFix() async throws -> DeviceLocationFix {
        try await DeviceLocationDeadline.run(seconds: 15) { [self] in
            try await fixes.value { manager.requestLocation() }
        }
    }

    func place(for fix: DeviceLocationFix) async -> DeviceLocationPlace? {
        let location = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        return try? await DeviceLocationDeadline.run(seconds: 5) {
            try await Self.reverseGeocode(location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else {
            fixes.finish(throwing: AppleDeviceToolError.unavailable)
            return
        }
        fixes.finish(returning: DeviceLocationFix(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy, timestamp: location.timestamp))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        fixes.finish(throwing: AppleDeviceToolError.unavailable)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let current = authorization
        if current == .denied || current == .restricted {
            fixes.finish(throwing: AppleDeviceToolError.authorizationRequired)
        }
        guard current != .notDetermined, !authorizationWaiters.isEmpty else { return }
        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: current) }
    }

    #if os(visionOS)
    /// MapKit names the city and country; Core Location's geocoder is deprecated here.
    private static func reverseGeocode(_ location: CLLocation) async throws -> DeviceLocationPlace? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try await request.mapItems.first,
              let names = item.addressRepresentations else { return nil }
        return DeviceLocationPlace(city: names.cityName, country: names.regionName)
    }
    #else
    /// Core Location gives the address in parts (street, city, postal code) back to iOS 17.
    private static func reverseGeocode(_ location: CLLocation) async throws -> DeviceLocationPlace? {
        guard let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        return DeviceLocationPlace(
            street: street.isEmpty ? nil : street, neighborhood: placemark.subLocality,
            city: placemark.locality, region: placemark.administrativeArea,
            country: placemark.country, postalCode: placemark.postalCode)
    }
    #endif
}
