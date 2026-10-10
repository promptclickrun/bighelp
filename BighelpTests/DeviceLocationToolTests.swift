import Foundation
import Testing
@testable import Bighelp

/// The agent's `iphone_location` tool on the phone: the switch, iOS permission and
/// precise-location choice, and the bounded result. Every place here is made up.
@MainActor
struct DeviceLocationToolTests {
    private static let fix = DeviceLocationFix(latitude: 12.345_678_9, longitude: -65.432_109_8,
                                               horizontalAccuracy: 18.04,
                                               timestamp: Date(timeIntervalSince1970: 1_790_000_000))
    private static let place = DeviceLocationPlace(street: "100 Example Street", neighborhood: "Harbor District",
                                                   city: "Sampleton", region: "Example State",
                                                   country: "Exampleland", postalCode: "00000")

    // MARK: Capability

    @Test func locationIsItsOwnSwitchAndNeedsTheNewerPlugin() {
        #expect(DeviceToolCapability.allCases.contains(.location))
        #expect(DeviceToolCapability.location.rawValue == "location")
        #expect(DeviceToolCapability.location.pluginFeature == "native-device-location-v1")
        #expect(DeviceToolCapability.calendar.pluginFeature == nil)
        #expect(DeviceToolCapability.reminders.pluginFeature == nil)
    }

    @Test func coordinatorTreatsLocationAsAReadThatIsNeverJournaled() async {
        let fixture = LocationCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .location)
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.status == "completed")
        #expect(result.payload["latitude"] == .number(12.345679))
        #expect(fixture.journal.saves == 0, "Where someone is must never be written to the outcome journal")
    }

    @Test func coordinatorRefusesLocationWhenItsSwitchIsOff() async {
        let fixture = LocationCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .calendar)
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "permission_disabled")
        #expect(fixture.executions == 0)
    }

    @Test func coordinatorRefusesLocationWhileTheAppIsNotActive() async {
        let fixture = LocationCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .location)
        fixture.available = false
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "device_unavailable")
        #expect(fixture.executions == 0)
    }

    // MARK: Service validation

    @Test func serviceRejectsAnyArgumentToCurrentLocation() async {
        let provider = FakeLocationProvider()
        let service = AppleDeviceToolService(boundary: LocationOnlyBoundary(tool: DeviceLocationTool(provider: provider)))
        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await service.execute(operation: "location.current", arguments: ["precise": .boolean(true)],
                                      authorize: {})
        }
        #expect(provider.fixRequests == 0)
    }

    @Test func serviceNeedsIOSAccessBeforeLocating() async {
        for (authorization, expected) in [
            (DeviceLocationAuthorization.notDetermined, AppleDeviceToolError.authorizationRequired),
            (.denied, .authorizationRequired),
            (.restricted, .unavailable),
        ] {
            let provider = FakeLocationProvider(authorization: authorization)
            let service = AppleDeviceToolService(boundary: LocationOnlyBoundary(tool: DeviceLocationTool(provider: provider)))
            await #expect(throws: expected) {
                try await service.execute(operation: "location.current", arguments: [:], authorize: {})
            }
            #expect(provider.fixRequests == 0)
            #expect(provider.preciseRequests.isEmpty)
        }
    }

    @Test func serviceReturnsTheBoundedLocation() async throws {
        let provider = FakeLocationProvider(accuracy: .full)
        let service = AppleDeviceToolService(boundary: LocationOnlyBoundary(tool: DeviceLocationTool(provider: provider)))
        let result = try await service.execute(operation: "location.current", arguments: [:], authorize: {})
        #expect(result["precise"] == .boolean(true))
        #expect(result["place"]?.object?["city"] == .string("Sampleton"))
    }

    // MARK: Permission and accuracy decisions

    @Test func statusMapsIOSAuthorizationWithoutAsking() async {
        let cases: [(DeviceLocationAuthorization, Bool, DeviceToolSystemAccess)] = [
            (.notDetermined, true, .notRequested),
            (.whenInUse, true, .available),
            (.always, true, .available),
            (.denied, true, .denied),
            (.restricted, true, .unavailable),
            (.whenInUse, false, .denied),
        ]
        for (authorization, servicesOn, expected) in cases {
            let provider = FakeLocationProvider(authorization: authorization, servicesEnabled: servicesOn)
            #expect(await DeviceLocationTool(provider: provider).status() == expected)
            #expect(provider.whenInUseRequests == 0)
        }
    }

    @Test func turningLocationOnAsksOnlyForWhileUsingTheApp() async {
        let provider = FakeLocationProvider(authorization: .notDetermined)
        provider.answerToWhenInUse = .whenInUse
        let tool = DeviceLocationTool(provider: provider)
        #expect(await tool.request() == .available)
        #expect(provider.whenInUseRequests == 1)

        let denied = FakeLocationProvider(authorization: .notDetermined)
        denied.answerToWhenInUse = .denied
        #expect(await DeviceLocationTool(provider: denied).request() == .denied)

        let already = FakeLocationProvider(authorization: .whenInUse)
        #expect(await DeviceLocationTool(provider: already).request() == .available)
        #expect(already.whenInUseRequests == 0)
    }

    @Test func approximateLocationAsksForPreciseOnceAndUsesItWhenAllowed() async throws {
        let provider = FakeLocationProvider(accuracy: .reduced)
        provider.answerToPrecise = .full
        let result = try await DeviceLocationTool(provider: provider).current(authorize: {})
        #expect(provider.preciseRequests == [DeviceLocationTool.purposeKey])
        #expect(result["precise"] == .boolean(true))
        #expect(result["note"] == nil)
        #expect(result["place"]?.object?["street"] == .string("100 Example Street"))
    }

    @Test func keepingApproximateReturnsARoughAreaAndSaysSo() async throws {
        let provider = FakeLocationProvider(accuracy: .reduced)
        provider.answerToPrecise = .reduced
        provider.fix = DeviceLocationFix(latitude: 12.3, longitude: -65.4, horizontalAccuracy: 3_000,
                                         timestamp: Self.fix.timestamp)
        let result = try await DeviceLocationTool(provider: provider).current(authorize: {})
        #expect(result["precise"] == .boolean(false))
        #expect(result["horizontalAccuracyMeters"] == .integer(3_000))
        let note = try #require(result["note"]?.string)
        #expect(note.contains("approximate"))
        let place = try #require(result["place"]?.object)
        #expect(place["street"] == nil && place["neighborhood"] == nil && place["postalCode"] == nil,
                "An approximate fix must not be dressed up with a street")
        #expect(place["city"] == .string("Sampleton"))
    }

    @Test func preciseAccessDoesNotAskAgain() async throws {
        let provider = FakeLocationProvider(accuracy: .full)
        _ = try await DeviceLocationTool(provider: provider).current(authorize: {})
        #expect(provider.preciseRequests.isEmpty)
    }

    @Test func noLocationIsReadWhenAccessEndsDuringThePreciseQuestion() async {
        let provider = FakeLocationProvider(accuracy: .reduced)
        var allowed = true
        provider.onPreciseRequest = { allowed = false }
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await DeviceLocationTool(provider: provider).current(authorize: {
                guard allowed else { throw AppleDeviceToolError.authorizationRequired }
            })
        }
        #expect(provider.fixRequests == 0)
    }

    @Test func aGoneAppNeverShowsThePreciseQuestion() async {
        let provider = FakeLocationProvider(accuracy: .reduced)
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await DeviceLocationTool(provider: provider).current(authorize: {
                throw AppleDeviceToolError.authorizationRequired
            })
        }
        #expect(provider.preciseRequests.isEmpty)
    }

    @Test func noFixIsUnavailableAndAMissingAddressIsLeftOut() async throws {
        let failing = FakeLocationProvider(accuracy: .full)
        failing.fixFailure = true
        await #expect(throws: AppleDeviceToolError.unavailable) {
            try await DeviceLocationTool(provider: failing).current(authorize: {})
        }

        let noAddress = FakeLocationProvider(accuracy: .full)
        noAddress.place = nil
        let result = try await DeviceLocationTool(provider: noAddress).current(authorize: {})
        #expect(result["place"] == nil)
        #expect(result["latitude"] != nil)
    }

    @Test func cancelledLocationWaiterDoesNotStrandTheNextRequest() async throws {
        let requests = DeviceLocationRequestPool<Int>()
        var requestCount = 0
        let first = Task {
            try await requests.value {
                requestCount += 1
            }
        }
        while requests.pendingCount == 0 { await Task.yield() }

        first.cancel()
        do {
            _ = try await first.value
            Issue.record("A cancelled location waiter unexpectedly completed.")
        } catch is CancellationError {
            // Expected: cancellation must remove and resume this waiter.
        }
        #expect(requests.pendingCount == 0)

        let second = Task {
            try await requests.value {
                requestCount += 1
            }
        }
        while requests.pendingCount == 0 { await Task.yield() }
        #expect(requestCount == 2)

        requests.finish(returning: 42)
        #expect(try await second.value == 42)
        #expect(requests.pendingCount == 0)
    }

    // MARK: Result encoding and bounds

    @Test func payloadIsRoundedTimestampedAndSmall() throws {
        let payload = try DeviceLocationTool.payload(fix: Self.fix, precise: true, place: Self.place)
        #expect(payload["latitude"] == .number(12.345679))
        #expect(payload["longitude"] == .number(-65.43211))
        #expect(payload["horizontalAccuracyMeters"] == .integer(18))
        #expect(payload["timestamp"] == .string("2026-09-21T14:13:20Z"))
        #expect(payload["precise"] == .boolean(true))
        #expect(Set(payload.keys) == ["latitude", "longitude", "horizontalAccuracyMeters", "timestamp", "precise", "place"])
        #expect(payload["place"]?.object?.count == 6)
        let encoded = try JSONEncoder().encode(payload)
        #expect(encoded.count < 2_048)
    }

    @Test func impossibleFixesAreRejected() {
        for fix in [
            DeviceLocationFix(latitude: 91, longitude: 0, horizontalAccuracy: 5, timestamp: Self.fix.timestamp),
            DeviceLocationFix(latitude: 0, longitude: -181, horizontalAccuracy: 5, timestamp: Self.fix.timestamp),
            DeviceLocationFix(latitude: .nan, longitude: 0, horizontalAccuracy: 5, timestamp: Self.fix.timestamp),
            DeviceLocationFix(latitude: 0, longitude: 0, horizontalAccuracy: -1, timestamp: Self.fix.timestamp),
            DeviceLocationFix(latitude: 0, longitude: 0, horizontalAccuracy: .infinity, timestamp: Self.fix.timestamp),
        ] {
            #expect(throws: AppleDeviceToolError.unavailable) {
                try DeviceLocationTool.payload(fix: fix, precise: true, place: nil)
            }
        }
    }

    @Test func placeTextIsTrimmedCleanedAndBounded() throws {
        let messy = DeviceLocationPlace(street: "  1 Long\u{0007} Road\n", neighborhood: "   ",
                                        city: String(repeating: "x", count: 500), region: nil,
                                        country: "Exampleland", postalCode: "")
        let payload = try DeviceLocationTool.payload(fix: Self.fix, precise: true, place: messy)
        let place = try #require(payload["place"]?.object)
        #expect(place["street"] == .string("1 Long Road"))
        #expect(place["neighborhood"] == nil)
        #expect(place["postalCode"] == nil)
        #expect(place["region"] == nil)
        #expect(place["city"]?.string?.count == DeviceLocationTool.maximumFieldLength)
    }

    // MARK: Demo

    @Test func demoLocationIsMadeUpAndWorksWithoutAHost() async throws {
        let tool = DeviceLocationTool(provider: DemoDeviceLocationProvider())
        #expect(await tool.status() == .notRequested)
        #expect(await tool.request() == .available)
        let result = try await tool.current(authorize: {})
        #expect(result["precise"] == .boolean(true))
        #expect(result["place"]?.object?["city"] == .string(DemoDeviceLocationProvider.place.city ?? ""))
        #expect(DemoDeviceLocationProvider.place.country == "Exampleland")
    }

    @Test func toolFolderSaysWhatTheAgentDidInPlainWords() {
        let phrase = ChatToolPhrase.phrase(forTool: "iphone_location", arguments: #"{"operation":"current"}"#)
        #expect(phrase.live == "Checking where you are…")
        #expect(phrase.past == "Checked where you are")
    }
}

// MARK: - Fakes

@MainActor
final class FakeLocationProvider: DeviceLocationProviding {
    var authorization: DeviceLocationAuthorization
    var accuracy: DeviceLocationAccuracy
    var servicesOn: Bool
    var answerToWhenInUse: DeviceLocationAuthorization = .whenInUse
    var answerToPrecise: DeviceLocationAccuracy = .full
    var fix = DeviceLocationFix(latitude: 12.345_678_9, longitude: -65.432_109_8, horizontalAccuracy: 18,
                                timestamp: Date(timeIntervalSince1970: 1_790_000_000))
    var place: DeviceLocationPlace? = DeviceLocationPlace(street: "100 Example Street", neighborhood: "Harbor District",
                                                          city: "Sampleton", region: "Example State",
                                                          country: "Exampleland", postalCode: "00000")
    var fixFailure = false
    var onPreciseRequest: (() -> Void)?
    private(set) var whenInUseRequests = 0
    private(set) var preciseRequests: [String] = []
    private(set) var fixRequests = 0

    init(authorization: DeviceLocationAuthorization = .whenInUse, accuracy: DeviceLocationAccuracy = .full,
         servicesEnabled: Bool = true) {
        self.authorization = authorization
        self.accuracy = accuracy
        servicesOn = servicesEnabled
    }

    func servicesEnabled() async -> Bool { servicesOn }

    func requestWhenInUse() async -> DeviceLocationAuthorization {
        whenInUseRequests += 1
        authorization = answerToWhenInUse
        return authorization
    }

    func requestPrecise(purposeKey: String) async -> DeviceLocationAccuracy {
        preciseRequests.append(purposeKey)
        onPreciseRequest?()
        accuracy = answerToPrecise
        return accuracy
    }

    func currentFix() async throws -> DeviceLocationFix {
        fixRequests += 1
        if fixFailure { throw AppleDeviceToolError.unavailable }
        return fix
    }

    func place(for fix: DeviceLocationFix) async -> DeviceLocationPlace? { place }
}

@MainActor
private final class LocationOnlyBoundary: AppleDeviceToolNativeBoundary {
    let tool: DeviceLocationTool
    init(tool: DeviceLocationTool) { self.tool = tool }
    func status(for capability: DeviceToolCapability) async -> DeviceToolSystemAccess {
        capability == .location ? await tool.status() : .unavailable
    }
    func request(_ capability: DeviceToolCapability) async -> DeviceToolSystemAccess {
        capability == .location ? await tool.request() : .unavailable
    }
    func execute(operation: String, arguments: [String: BighelpJSONValue],
                 authorize: @escaping @MainActor () throws -> Void) async throws -> [String: BighelpJSONValue] {
        guard operation == "location.current" else { throw AppleDeviceToolError.unsupportedOperation }
        return try await tool.current(authorize: authorize)
    }
}

@MainActor
private final class LocationCoordinatorFixture {
    let scope = DeviceToolScope(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-a")
    let permissions = DeviceToolPermissions(status: { _ in .available }, request: { _ in .available },
                                            isForeground: { true }, readGrants: { _ in [] }, writeGrants: { _, _ in })
    let journal = CountingJournal()
    var executions = 0
    var available = true
    lazy var coordinator = DeviceToolCoordinator(permissions: permissions, journal: journal, clock: { 1_000 },
                                                 available: { self.available }) { operation, _, authorize in
        try authorize()
        self.executions += 1
        #expect(operation == "location.current")
        return try DeviceLocationTool.payload(
            fix: DeviceLocationFix(latitude: 12.345_678_9, longitude: -65.4, horizontalAccuracy: 10,
                                   timestamp: Date(timeIntervalSince1970: 1_000)),
            precise: true, place: nil)
    }

    init() { permissions.bind(scope) }

    func request() -> DeviceToolRequest {
        DeviceToolRequest(version: 1, type: "device.tool.request", requestId: "request-location-01",
                          deviceId: scope.deviceID, hostId: scope.hostID, authorizationEpoch: 1,
                          sessionId: "session-1", agentId: "default", turnId: "turn-1",
                          operation: "location.current", arguments: [:], sentAt: 1_000, expiresAt: 1_030)
    }
}

@MainActor
private final class CountingJournal: DeviceToolJournal {
    private(set) var saves = 0
    func entry(requestID: String, scope: DeviceToolScope) throws -> DeviceToolJournalEntry? { nil }
    func save(_ entry: DeviceToolJournalEntry, requestID: String, scope: DeviceToolScope) throws { saves += 1 }
}
