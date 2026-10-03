import Foundation

/// Demo mode's phone location: a made-up place in open water, never a real person's.
/// Turning Location on "allows" it, and iOS's precise-location question says yes.
@MainActor
final class DemoDeviceLocationProvider: DeviceLocationProviding {
    static let latitude = 12.3456
    static let longitude = -65.4321
    static let place = DeviceLocationPlace(
        street: "100 Example Street", neighborhood: "Harbor District", city: "Sampleton",
        region: "Example State", country: "Exampleland", postalCode: "00000")

    private(set) var authorization: DeviceLocationAuthorization = .notDetermined
    private(set) var accuracy: DeviceLocationAccuracy = .reduced

    func servicesEnabled() async -> Bool { true }

    func requestWhenInUse() async -> DeviceLocationAuthorization {
        authorization = .whenInUse
        return authorization
    }

    func requestPrecise(purposeKey: String) async -> DeviceLocationAccuracy {
        accuracy = .full
        return accuracy
    }

    func currentFix() async throws -> DeviceLocationFix {
        DeviceLocationFix(latitude: Self.latitude, longitude: Self.longitude, horizontalAccuracy: 12, timestamp: Date())
    }

    func place(for fix: DeviceLocationFix) async -> DeviceLocationPlace? { Self.place }
}
