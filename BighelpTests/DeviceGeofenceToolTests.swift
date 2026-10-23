import Foundation
import Testing
@testable import Bighelp

/// The agent's `iphone_geofences` tool on the phone: the switch and its two iOS questions, the
/// arguments, the places that survive a relaunch, and what an arrival or departure does. Every
/// place and coordinate here is made up.
@MainActor
struct DeviceGeofenceToolTests {
    private static let arrival = date("2026-10-22T17:42:00Z")

    // MARK: Message

    @Test func theMessageNamesThePlaceTheTimeAndTheNote() {
        let arrived = DeviceGeofenceMessage.text(placeName: "Grocery store", arrived: true, note: "buy milk",
                                                 date: Self.arrival, timeZone: .gmt, locale: Locale(identifier: "en_US"))
        #expect(Self.plain(arrived) == "\u{1F4CD} Arrived at \"Grocery store\" at 5:42 PM. Your note: buy milk.")
        let left = DeviceGeofenceMessage.text(placeName: "Grocery store", arrived: false, note: "",
                                              date: Self.arrival, timeZone: .gmt, locale: Locale(identifier: "en_US"))
        #expect(Self.plain(left) == "\u{1F4CD} Left \"Grocery store\" at 5:42 PM.")
    }

    @Test func theMessageStaysOnOneLineWhateverTheAgentWrote() {
        let text = DeviceGeofenceMessage.text(placeName: "The \"corner\"\nshop", arrived: true,
                                              note: "buy milk.\n\nAsk about eggs!", date: Self.arrival,
                                              timeZone: .gmt, locale: Locale(identifier: "en_US"))
        #expect(!text.contains("\n"))
        #expect(Self.plain(text) == "\u{1F4CD} Arrived at \"The 'corner' shop\" at 5:42 PM. Your note: buy milk. Ask about eggs!")
    }

    // MARK: Permission

    @Test func statusMapsIOSAuthorizationAndNeverAsks() async {
        let cases: [(DeviceLocationAuthorization, Bool, DeviceToolSystemAccess)] = [
            (.notDetermined, true, .notRequested),
            (.whenInUse, true, .available),
            (.always, true, .available),
            (.denied, true, .denied),
            (.restricted, true, .unavailable),
            (.always, false, .denied),
        ]
        for (authorization, servicesOn, expected) in cases {
            let fixture = GeofenceFixture(authorization: authorization, servicesEnabled: servicesOn)
            #expect(await fixture.tool.status() == expected)
            #expect(fixture.location.whenInUseRequests == 0)
            #expect(fixture.always.requests == 0)
        }
    }

    @Test func turningItOnAsksWhileUsingThenAlwaysOnce() async {
        let fixture = GeofenceFixture(authorization: .notDetermined)
        #expect(await fixture.tool.request() == .available)
        #expect(fixture.location.whenInUseRequests == 1)
        #expect(fixture.always.requests == 1)
        // iOS asks for Always one time; turning the switch on again must not wait on it.
        #expect(await fixture.tool.request() == .available)
        #expect(fixture.always.requests == 1)
    }

    @Test func aDeniedWhileUsingNeverAsksForAlways() async {
        let fixture = GeofenceFixture(authorization: .notDetermined)
        fixture.location.answerToWhenInUse = .denied
        #expect(await fixture.tool.request() == .denied)
        #expect(fixture.always.requests == 0)
    }

    @Test func anAlreadyAlwaysPhoneAsksNothing() async {
        let fixture = GeofenceFixture(authorization: .always)
        #expect(await fixture.tool.request() == .available)
        #expect(fixture.location.whenInUseRequests == 0)
        #expect(fixture.always.requests == 0)
    }

    @Test func locationServicesOffIsADenial() async {
        let fixture = GeofenceFixture(authorization: .notDetermined, servicesEnabled: false)
        #expect(await fixture.tool.request() == .denied)
        #expect(fixture.location.whenInUseRequests == 0)
    }

    @Test func demoModeNeverAsksIOS() async {
        let location = GeofenceFakeLocation(authorization: .notDetermined)
        let defaults = GeofenceFixture.makeDefaults()
        let engine = DeviceGeofenceMonitor(store: GeofenceFakeStore(), monitor: UnavailableDeviceGeofenceMonitor(),
                                           sender: GeofenceFakeSender(), notifier: GeofenceFakeNotifier())
        let tool = DeviceGeofenceTool(engine: engine, location: location, alwaysRequester: GeofenceFakeAlways(),
                                      defaults: defaults.defaults, usesFixtures: true)
        #expect(await tool.status() == .unavailable)
        #expect(await tool.request() == .unavailable)
        #expect(location.whenInUseRequests == 0)
        defaults.clear()
    }

    @Test func theSwitchNotesWhetherPlacesAreWatchedWithBighelpClosed() {
        #expect(DeviceGeofenceAccessNote.make(authorization: .always, accuracy: .full) == .watchedWhenClosed)
        #expect(DeviceGeofenceAccessNote.make(authorization: .whenInUse, accuracy: .full) == .watchedWhenOpen)
        #expect(DeviceGeofenceAccessNote.make(authorization: .whenInUse, accuracy: .reduced) == .needsPreciseLocation)
        #expect(DeviceGeofenceAccessNote.make(authorization: .always, accuracy: .reduced) == .needsPreciseLocation)
        #expect(DeviceGeofenceAccessNote.make(authorization: .denied, accuracy: .full) == nil)
        #expect(DeviceGeofenceAccessNote.make(authorization: .notDetermined, accuracy: .full) == nil)
        // Settings can only help while the answer isn't already the best one.
        #expect(!DeviceGeofenceAccessNote.watchedWhenClosed.offersSettings)
        #expect(DeviceGeofenceAccessNote.watchedWhenOpen.offersSettings)
        #expect(DeviceGeofenceAccessNote.needsPreciseLocation.offersSettings)
    }

    // MARK: Create

    @Test func createWatchesThePlaceForTheCallingChat() async throws {
        let fixture = GeofenceFixture()
        let result = try await fixture.create(Self.grocery.merging([
            "radiusMeters": .integer(200), "on": .string("both"), "note": .string("buy milk"), "repeats": .boolean(true),
        ]) { $1 })

        // Only the ID is journaled, so a retry never learns where anyone goes.
        #expect(Set(result.keys) == ["id"])
        #expect(Set(result.keys).isSubset(of: DeviceToolCatalog.durableKeys))
        let place = try #require(fixture.engine.places.first)
        #expect(result["id"] == .string(place.id))
        #expect(place.hostID == "host-a" && place.agentID == "agent-a" && place.sessionID == "session-a")
        #expect(place.name == "Grocery store" && place.note == "buy milk")
        #expect(place.radiusMeters == 200 && place.on == .both && place.repeats)
        #expect(place.isInside == false)
        // iOS is told the same place, assumed outside, and the place is on disk.
        let region = DeviceGeofenceRegion(identifier: place.id, latitude: 40.1, longitude: -75.2, radiusMeters: 200)
        #expect(fixture.monitor.added.map(\.region) == [region])
        #expect(fixture.monitor.added.map(\.state) == [.outside])
        #expect(fixture.store.saved == [place])
    }

    @Test func createUsesTheDefaultsFromTheContract() async throws {
        let fixture = GeofenceFixture()
        _ = try await fixture.create([
            "name": .string("Gym"), "latitude": .integer(40), "longitude": .integer(-75),
        ])
        let place = try #require(fixture.engine.places.first)
        #expect(place.radiusMeters == 150 && place.on == .arrive && place.note == "" && !place.repeats)
        #expect(place.latitude == 40 && place.longitude == -75)
    }

    @Test func createRejectsBadArgumentsBeforeAnythingChanges() async {
        let fixture = GeofenceFixture()
        let bad: [[String: BighelpJSONValue]] = [
            [:],
            ["latitude": .number(40), "longitude": .number(-75)],
            Self.grocery.merging(["name": .string("")]) { $1 },
            Self.grocery.merging(["name": .string("   ")]) { $1 },
            Self.grocery.merging(["name": .string(String(repeating: "a", count: 101))]) { $1 },
            Self.grocery.merging(["name": .string("Two\nlines")]) { $1 },
            Self.grocery.merging(["name": .integer(4)]) { $1 },
            ["name": .string("A"), "latitude": .number(40)],
            ["name": .string("A"), "longitude": .number(-75)],
            ["name": .string("A"), "latitude": .number(91), "longitude": .number(0)],
            ["name": .string("A"), "latitude": .number(0), "longitude": .number(-181)],
            ["name": .string("A"), "latitude": .string("40"), "longitude": .number(0)],
            ["name": .string("A"), "here": .boolean(true), "latitude": .number(40), "longitude": .number(-75)],
            ["name": .string("A"), "here": .string("yes")],
            ["name": .string("A"), "here": .boolean(false)],
            Self.grocery.merging(["radiusMeters": .integer(99)]) { $1 },
            Self.grocery.merging(["radiusMeters": .integer(5001)]) { $1 },
            Self.grocery.merging(["radiusMeters": .string("200")]) { $1 },
            Self.grocery.merging(["on": .string("enter")]) { $1 },
            Self.grocery.merging(["on": .boolean(true)]) { $1 },
            Self.grocery.merging(["note": .string(String(repeating: "n", count: 1001))]) { $1 },
            Self.grocery.merging(["repeats": .string("yes")]) { $1 },
            Self.grocery.merging(["unexpected": .boolean(true)]) { $1 },
        ]
        for arguments in bad {
            await #expect(throws: AppleDeviceToolError.invalidArguments) {
                try await fixture.create(arguments)
            }
        }
        #expect(fixture.engine.places.isEmpty)
        #expect(fixture.store.saveCount == 0)
        #expect(fixture.monitor.added.isEmpty)
        #expect(fixture.location.fixRequests == 0)
    }

    @Test func createAtTheEdgesOfTheRangesWorks() async throws {
        let fixture = GeofenceFixture()
        _ = try await fixture.create(Self.grocery.merging(["radiusMeters": .integer(100)]) { $1 })
        _ = try await fixture.create(Self.grocery.merging(["radiusMeters": .integer(5000), "note": .string(String(repeating: "n", count: 1000)),
                                                          "name": .string(String(repeating: "a", count: 100))]) { $1 })
        #expect(fixture.engine.places.count == 2)
    }

    @Test func hereUsesWhereThePhoneIsNowAndStartsInside() async throws {
        let fixture = GeofenceFixture()
        fixture.location.fix = DeviceLocationFix(latitude: 41.5, longitude: -76.5, horizontalAccuracy: 12,
                                                 timestamp: Self.arrival)
        _ = try await fixture.create(["name": .string("Home"), "here": .boolean(true)])
        let place = try #require(fixture.engine.places.first)
        #expect(place.latitude == 41.5 && place.longitude == -76.5)
        #expect(place.isInside)
        #expect(fixture.monitor.added.map(\.state) == [.inside])
        #expect(fixture.location.fixRequests == 1)
    }

    @Test func hereFailsCleanlyWhenThereIsNoFix() async {
        let fixture = GeofenceFixture()
        fixture.location.fixFailure = true
        await #expect(throws: AppleDeviceToolError.unavailable) {
            try await fixture.create(["name": .string("Home"), "here": .boolean(true)])
        }
        #expect(fixture.engine.places.isEmpty)
        #expect(fixture.monitor.added.isEmpty)
    }

    @Test func approximateLocationCannotWatchPlaces() async {
        // iOS turns region monitoring off for approximate location.
        let fixture = GeofenceFixture(accuracy: .reduced)
        await #expect(throws: DeviceGeofenceError.preciseLocationRequired) {
            try await fixture.create(Self.grocery)
        }
        #expect(DeviceGeofenceError.preciseLocationRequired.code == "precise_location_required")
        #expect(fixture.engine.places.isEmpty)
        #expect(fixture.monitor.added.isEmpty)
    }

    @Test func twentyPlacesIsTheMostAcrossEveryHost() async throws {
        let fixture = GeofenceFixture()
        for index in 0..<10 {
            _ = try await fixture.create(Self.grocery.merging(["name": .string("A\(index)")]) { $1 }, hostID: "host-a")
            _ = try await fixture.create(Self.grocery.merging(["name": .string("B\(index)")]) { $1 }, hostID: "host-b")
        }
        #expect(fixture.engine.places.count == 20)
        await #expect(throws: DeviceGeofenceError.limitReached) {
            try await fixture.create(Self.grocery, hostID: "host-c")
        }
        #expect(DeviceGeofenceError.limitReached.code == "limit_reached")
        #expect(fixture.engine.places.count == 20)
        #expect(fixture.monitor.added.count == 20)
    }

    @Test func aPlaceThatCannotBeSavedIsNeverWatched() async {
        let fixture = GeofenceFixture()
        fixture.store.failWrites = true
        await #expect(throws: DeviceGeofenceError.storageUnavailable) {
            try await fixture.create(Self.grocery)
        }
        #expect(fixture.engine.places.isEmpty)
        #expect(fixture.monitor.added.isEmpty)
    }

    @Test func aSwitchTurnedOffWhileAddingTakesThePlaceBack() async throws {
        let fixture = GeofenceFixture()
        let monitor = fixture.monitor
        let authorize: @MainActor () throws -> Void = {
            // The check after the place was added: the person just turned the switch off.
            if !monitor.added.isEmpty { throw AppleDeviceToolError.authorizationRequired }
        }
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await fixture.tool.execute(operation: "geofences.create", arguments: Self.grocery,
                                           context: GeofenceFixture.context(), authorize: authorize)
        }
        #expect(fixture.engine.places.isEmpty)
        #expect(fixture.store.saved.isEmpty)
        #expect(fixture.monitor.removed.count == 1)
    }

    // MARK: List and delete

    @Test func listShowsOnlyTheCallingHostsPlaces() async throws {
        let fixture = GeofenceFixture(authorization: .always)
        _ = try await fixture.create(Self.grocery.merging(["note": .string("buy milk")]) { $1 }, hostID: "host-a")
        _ = try await fixture.create(Self.grocery.merging(["name": .string("Other computer")]) { $1 }, hostID: "host-b")

        let list = try await fixture.tool.execute(operation: "geofences.list", arguments: [:],
                                                  context: GeofenceFixture.context(host: "host-a"), authorize: {})
        let places = try #require(list["geofences"]?.array)
        #expect(places.count == 1)
        let item = try #require(places.first?.object)
        #expect(item["name"] == .string("Grocery store"))
        #expect(item["on"] == .string("arrive") && item["repeats"] == .boolean(false))
        #expect(item["note"] == .string("buy milk"))
        #expect(item["radiusMeters"] == .integer(150))
        #expect(item["agentId"] == .string("agent-a"))
        #expect(Set(item.keys) == ["id", "name", "latitude", "longitude", "radiusMeters", "on", "note", "repeats", "created", "agentId"])
        #expect(item["created"]?.string?.hasSuffix("Z") == true)
        #expect(list["limit"] == .integer(20))
        #expect(list["background"] == .boolean(true))
        #expect(!String(describing: list).contains("Other computer"))
    }

    @Test func backgroundIsTrueOnlyWithAlways() async throws {
        for (authorization, expected) in [(DeviceLocationAuthorization.whenInUse, false), (.always, true)] {
            let fixture = GeofenceFixture(authorization: authorization)
            let list = try await fixture.tool.execute(operation: "geofences.list", arguments: [:],
                                                      context: GeofenceFixture.context(), authorize: {})
            #expect(list["background"] == .boolean(expected))
            #expect(list["geofences"] == .array([]))
        }
    }

    @Test func listTakesNoArguments() async {
        let fixture = GeofenceFixture()
        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await fixture.tool.execute(operation: "geofences.list", arguments: ["limit": .integer(5)],
                                           context: GeofenceFixture.context(), authorize: {})
        }
    }

    @Test func deleteStopsWatchingAndForgetsThePlace() async throws {
        let fixture = GeofenceFixture()
        let id = try #require(try await fixture.create(Self.grocery)["id"]?.string)
        let result = try await fixture.tool.execute(operation: "geofences.delete", arguments: ["id": .string(id)],
                                                    context: GeofenceFixture.context(), authorize: {})
        #expect(result == ["id": .string(id), "deleted": .boolean(true)])
        #expect(Set(result.keys).isSubset(of: DeviceToolCatalog.durableKeys))
        #expect(fixture.engine.places.isEmpty)
        #expect(fixture.store.saved.isEmpty)
        #expect(fixture.monitor.removed == [id])
    }

    @Test func aHostCannotDeleteAnotherHostsPlace() async throws {
        let fixture = GeofenceFixture()
        let id = try #require(try await fixture.create(Self.grocery, hostID: "host-b")["id"]?.string)
        await #expect(throws: DeviceGeofenceError.notFound) {
            try await fixture.tool.execute(operation: "geofences.delete", arguments: ["id": .string(id)],
                                           context: GeofenceFixture.context(host: "host-a"), authorize: {})
        }
        await #expect(throws: DeviceGeofenceError.notFound) {
            try await fixture.tool.execute(operation: "geofences.delete", arguments: ["id": .string("missing")],
                                           context: GeofenceFixture.context(host: "host-b"), authorize: {})
        }
        #expect(DeviceGeofenceError.notFound.code == "not_found")
        #expect(fixture.engine.places.count == 1)
        #expect(fixture.monitor.removed.isEmpty)
    }

    @Test func deleteNeedsExactlyAnID() async {
        let fixture = GeofenceFixture()
        for arguments: [String: BighelpJSONValue] in [[:], ["id": .string("")], ["id": .integer(1)],
                                                      ["id": .string("a"), "extra": .boolean(true)]] {
            await #expect(throws: AppleDeviceToolError.invalidArguments) {
                try await fixture.tool.execute(operation: "geofences.delete", arguments: arguments,
                                               context: GeofenceFixture.context(), authorize: {})
            }
        }
    }

    @Test func anUnknownOperationIsRefused() async {
        let fixture = GeofenceFixture()
        await #expect(throws: AppleDeviceToolError.unsupportedOperation) {
            try await fixture.tool.execute(operation: "geofences.update", arguments: [:],
                                           context: GeofenceFixture.context(), authorize: {})
        }
    }

    @Test func theRouterRefusesWithoutIOSAccessAndChangesNothing() async {
        let fixture = GeofenceFixture(authorization: .notDetermined)
        let router = DeviceToolRouter(apple: AppleDeviceToolService(boundary: GeofenceStubBoundary()), tools: [fixture.tool])
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await router.execute(operation: "geofences.create", arguments: Self.grocery,
                                     context: GeofenceFixture.context(), authorize: {})
        }
        #expect(fixture.engine.places.isEmpty)
        #expect(fixture.store.saveCount == 0)
    }

    @Test func theRouterRunsCreateWithIOSAccess() async throws {
        let fixture = GeofenceFixture(authorization: .whenInUse)
        let router = DeviceToolRouter(apple: AppleDeviceToolService(boundary: GeofenceStubBoundary()), tools: [fixture.tool])
        let result = try await router.execute(operation: "geofences.create", arguments: Self.grocery,
                                              context: GeofenceFixture.context(), authorize: {})
        #expect(result["id"]?.string != nil)
    }

    @Test func createAndDeleteAreJournaledAndListIsNot() {
        #expect(DeviceToolCatalog.operations["geofences.create"]?.journaled == true)
        #expect(DeviceToolCatalog.operations["geofences.delete"]?.journaled == true)
        #expect(DeviceToolCatalog.operations["geofences.list"]?.journaled == false)
        #expect(DeviceToolCatalog.capability(for: "geofences.create") == .geofences)
    }

    // MARK: Events

    @Test func anArrivalTellsTheChatThatMadeThePlace() async throws {
        let fixture = GeofenceFixture()
        _ = try await fixture.create(Self.grocery.merging(["note": .string("buy milk"), "repeats": .boolean(true)]) { $1 },
                                     host: "host-a", agent: "agent-a", session: "session-a")
        let id = try #require(fixture.engine.places.first?.id)

        await fixture.engine.handle(DeviceGeofenceEvent(identifier: id, state: .inside, date: Self.arrival))
        await fixture.engine.finishDeliveries()

        #expect(fixture.sender.sent.count == 1)
        let sent = try #require(fixture.sender.sent.first)
        #expect(Self.plain(sent.message) == "\u{1F4CD} Arrived at \"Grocery store\" at 5:42 PM. Your note: buy milk.")
        #expect(sent.place.hostID == "host-a" && sent.place.agentID == "agent-a" && sent.place.sessionID == "session-a")
        #expect(fixture.notifier.failures.isEmpty)
        // A repeating place is still watched, now known to be inside.
        #expect(fixture.engine.places.first?.isInside == true)
        #expect(fixture.monitor.removed.isEmpty)
        // iOS gave background time for the message and it was handed back.
        #expect(fixture.backgroundBegun == 1 && fixture.backgroundEnded == 1)
    }

    @Test func aDepartureSaysLeft() async throws {
        let fixture = GeofenceFixture()
        _ = try await fixture.create(["name": .string("Grocery store"), "here": .boolean(true), "on": .string("leave")])
        let id = try #require(fixture.engine.places.first?.id)
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: id, state: .outside, date: Self.arrival))
        await fixture.engine.finishDeliveries()
        #expect(fixture.sender.sent.map { Self.plain($0.message) } == ["\u{1F4CD} Left \"Grocery store\" at 5:42 PM."])
    }

    @Test func aPlaceThatDoesNotRepeatIsRemovedAfterItsFirstEvent() async throws {
        let fixture = GeofenceFixture()
        _ = try await fixture.create(Self.grocery.merging(["on": .string("both")]) { $1 })
        let id = try #require(fixture.engine.places.first?.id)

        await fixture.engine.handle(DeviceGeofenceEvent(identifier: id, state: .inside, date: Self.arrival))
        await fixture.engine.finishDeliveries()
        #expect(fixture.sender.sent.count == 1)
        #expect(fixture.engine.places.isEmpty)
        #expect(fixture.store.saved.isEmpty)
        #expect(fixture.monitor.removed == [id])

        // A late second event from iOS finds nothing to tell.
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: id, state: .outside, date: Self.arrival.addingTimeInterval(900)))
        await fixture.engine.finishDeliveries()
        #expect(fixture.sender.sent.count == 1)
    }

    @Test func onlyTheChosenDirectionTells() async throws {
        let fixture = GeofenceFixture()
        _ = try await fixture.create(Self.grocery.merging(["on": .string("arrive"), "repeats": .boolean(true)]) { $1 })
        let id = try #require(fixture.engine.places.first?.id)
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: id, state: .inside, date: Self.arrival))
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: id, state: .outside, date: Self.arrival.addingTimeInterval(1_000)))
        await fixture.engine.finishDeliveries()
        #expect(fixture.sender.sent.count == 1)
        #expect(Self.plain(fixture.sender.sent[0].message).contains("Arrived"))
        // Leaving was not told, but the place knows it's outside now.
        #expect(fixture.engine.places.first?.isInside == false)
    }

    @Test func aPlaceTellsOnceEveryFiveMinutesAtMost() async throws {
        let fixture = GeofenceFixture()
        _ = try await fixture.create(Self.grocery.merging(["on": .string("both"), "repeats": .boolean(true)]) { $1 })
        let id = try #require(fixture.engine.places.first?.id)
        let start = Self.arrival
        let script: [(TimeInterval, DeviceGeofenceState)] = [
            (0, .inside),      // told
            (100, .outside),   // inside the five minutes: not told
            (200, .inside),    // not told
            (299, .outside),   // not told
            (301, .inside),    // told
        ]
        for (offset, state) in script {
            await fixture.engine.handle(DeviceGeofenceEvent(identifier: id, state: state, date: start.addingTimeInterval(offset)))
        }
        await fixture.engine.finishDeliveries()
        #expect(fixture.sender.sent.map { Self.plain($0.message).contains("Arrived") } == [true, true])
        #expect(fixture.sender.sent.count == 2)
        #expect(fixture.engine.places.first?.isInside == true)
    }

    @Test func theStateIOSStartsAPlaceInIsNotAnEvent() async throws {
        let fixture = GeofenceFixture()
        _ = try await fixture.create(Self.grocery.merging(["on": .string("both"), "repeats": .boolean(true)]) { $1 })
        let outside = try #require(fixture.engine.places.first?.id)
        _ = try await fixture.create(["name": .string("Home"), "here": .boolean(true), "on": .string("both"), "repeats": .boolean(true)])
        let inside = try #require(fixture.engine.places.last?.id)

        // iOS reports the state each place was added in.
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: outside, state: .outside, date: Self.arrival))
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: inside, state: .inside, date: Self.arrival))
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: inside, state: .unknown, date: Self.arrival))
        await fixture.engine.finishDeliveries()
        #expect(fixture.sender.sent.isEmpty)
        #expect(fixture.backgroundBegun == 0)
    }

    @Test func aMessageThatFailsToSendNotifiesThePerson() async throws {
        let fixture = GeofenceFixture()
        fixture.sender.failure = DeviceGeofenceDeliveryError.notSent
        _ = try await fixture.create(Self.grocery.merging(["repeats": .boolean(true)]) { $1 })
        let id = try #require(fixture.engine.places.first?.id)
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: id, state: .inside, date: Self.arrival))
        await fixture.engine.finishDeliveries()
        #expect(fixture.sender.sent.isEmpty)
        #expect(fixture.notifier.failures.count == 1)
        #expect(fixture.notifier.failures.first?.place.name == "Grocery store")
        #expect(fixture.notifier.failures.first?.arrived == true)
        #expect(fixture.backgroundBegun == 1 && fixture.backgroundEnded == 1)
    }

    @Test func aSwitchTurnedOffRemovesThePlaceInsteadOfTellingTheChat() async throws {
        let fixture = GeofenceFixture()
        _ = try await fixture.create(Self.grocery.merging(["repeats": .boolean(true)]) { $1 })
        let id = try #require(fixture.engine.places.first?.id)
        fixture.grant.allowed = false
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: id, state: .inside, date: Self.arrival))
        await fixture.engine.finishDeliveries()
        #expect(fixture.sender.sent.isEmpty)
        #expect(fixture.notifier.failures.isEmpty)
        #expect(fixture.engine.places.isEmpty)
        #expect(fixture.monitor.removed == [id])
    }

    @Test func aPlaceIOSHoldsThatThePhoneForgotIsDropped() async {
        let fixture = GeofenceFixture()
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: "ghost", state: .inside, date: Self.arrival))
        #expect(fixture.monitor.removed == ["ghost"])
        #expect(fixture.sender.sent.isEmpty)
    }

    @Test func eventsFromIOSReachTheChatThroughTheStream() async throws {
        let fixture = GeofenceFixture()
        _ = try await fixture.create(Self.grocery.merging(["repeats": .boolean(true)]) { $1 })
        let id = try #require(fixture.engine.places.first?.id)
        fixture.monitor.emit(id, .inside, at: Self.arrival)
        #expect(await eventually { fixture.sender.sent.count == 1 })
        #expect(fixture.monitor.eventsCalls == 1)
    }

    // MARK: Relaunch

    @Test func relaunchRestoresPlacesAndStartsListeningBeforeAnythingElse() async throws {
        let first = GeofenceFixture()
        _ = try await first.create(Self.grocery.merging(["note": .string("buy milk"), "repeats": .boolean(true)]) { $1 })
        let place = try #require(first.engine.places.first)

        // The app was closed. iOS still holds the place and sees the person arrive.
        let second = first.relaunched()
        first.monitor.emit(place.id, .inside, at: Self.arrival)
        #expect(second.engine.places.isEmpty)
        #expect(await second.engine.start())

        #expect(second.engine.places.map(\.id) == [place.id])
        #expect(second.monitor.eventsCalls == 1)
        // The held arrival is delivered to the restored place.
        #expect(await eventually { second.sender.sent.count == 1 })
        #expect(Self.plain(second.sender.sent[0].message).contains("Arrived at \"Grocery store\""))
        #expect(second.sender.sent[0].place.sessionID == "session-a")
    }

    @Test func relaunchAddsPlacesIOSLostAndRemovesOnesThePhoneForgot() async throws {
        let first = GeofenceFixture()
        _ = try await first.create(Self.grocery)
        let place = try #require(first.engine.places.first)
        first.backing.set(DeviceGeofenceRegion(identifier: "stale", latitude: 1, longitude: 1, radiusMeters: 150))
        first.backing.remove(place.id)

        let second = first.relaunched()
        #expect(await second.engine.start())
        #expect(second.monitor.added.map(\.region.identifier) == [place.id])
        #expect(second.monitor.removed == ["stale"])
        #expect(second.backing.identifiers.sorted() == [place.id])
    }

    @Test func relaunchKeepsWhatIOSAlreadyHolds() async throws {
        let first = GeofenceFixture()
        _ = try await first.create(Self.grocery)
        let second = first.relaunched()
        #expect(await second.engine.start())
        // iOS keeps its own state for a place it still has, so nothing is added again.
        #expect(second.monitor.added.isEmpty)
        #expect(second.monitor.removed.isEmpty)
    }

    @Test func relaunchRemembersAPlaceTheyWereInside() async throws {
        let first = GeofenceFixture()
        _ = try await first.create(["name": .string("Home"), "here": .boolean(true), "on": .string("both"), "repeats": .boolean(true)])
        first.backing.removeAll()
        let second = first.relaunched()
        #expect(await second.engine.start())
        #expect(second.monitor.added.map(\.state) == [.inside])
    }

    @Test func relaunchDropsPlacesWhoseSwitchWentOff() async throws {
        let first = GeofenceFixture()
        _ = try await first.create(Self.grocery)
        let second = first.relaunched()
        second.grant.allowed = false
        #expect(await second.engine.start())
        #expect(second.engine.places.isEmpty)
        #expect(second.store.saved.isEmpty)
        #expect(second.backing.identifiers.isEmpty)
    }

    @Test func nothingOpensWithoutPlaces() async {
        let fixture = GeofenceFixture()
        #expect(await fixture.engine.start())
        #expect(fixture.monitor.eventsCalls == 0)
        #expect(fixture.monitor.identifierReads == 0)
    }

    @Test func startWaitsForTheFirstUnlockAfterARestart() async throws {
        let first = GeofenceFixture()
        _ = try await first.create(Self.grocery)
        let second = first.relaunched()
        second.store.readFailure = .unreadable
        let savesBefore = second.store.saveCount

        #expect(await second.engine.start() == false)
        #expect(second.monitor.eventsCalls == 0)
        #expect(second.monitor.identifierReads == 0)
        // Nothing may be created while the saved places can't be read: it would overwrite them.
        await #expect(throws: DeviceGeofenceError.storageUnavailable) {
            try await second.create(Self.grocery)
        }
        #expect(second.store.saveCount == savesBefore)

        second.store.readFailure = nil
        #expect(await second.engine.start())
        #expect(second.engine.places.count == 1)
        #expect(second.monitor.eventsCalls == 1)
    }

    @Test func startingTwiceListensOnce() async throws {
        let first = GeofenceFixture()
        _ = try await first.create(Self.grocery)
        let second = first.relaunched()
        #expect(await second.engine.start())
        #expect(await second.engine.start())
        #expect(second.monitor.eventsCalls == 1)
    }

    @Test func aDamagedFileStartsFreshAndIsReplacedByTheNextPlace() async throws {
        let fixture = GeofenceFixture()
        fixture.store.readFailure = .corrupt
        _ = try await fixture.create(Self.grocery)
        #expect(fixture.engine.places.count == 1)
        #expect(fixture.store.saved.count == 1)
    }


    // MARK: Turning the switch off

    @Test func turningTheSwitchOffForgetsThatHostsPlacesAtOnce() async throws {
        let fixture = GeofenceFixture()
        let a = try #require(try await fixture.create(Self.grocery, hostID: "host-a")["id"]?.string)
        let b = try #require(try await fixture.create(Self.grocery, hostID: "host-b")["id"]?.string)

        fixture.grant.blockedHosts = ["host-a"]
        await fixture.tool.grantsChanged()

        // The name, coordinates and note leave the disk and iOS, not only the grant.
        #expect(fixture.engine.places.map(\.id) == [b])
        #expect(fixture.store.saved.map(\.id) == [b])
        #expect(fixture.monitor.removed == [a])
        #expect(fixture.backing.identifiers == [b])
        #expect(fixture.engine.places(for: "host-a").isEmpty)
        // A second notice finds nothing more to do.
        await fixture.tool.grantsChanged()
        #expect(fixture.monitor.removed == [a])
    }

    @Test func aSwitchStillOnKeepsEveryPlace() async throws {
        let fixture = GeofenceFixture()
        _ = try await fixture.create(Self.grocery)
        await fixture.tool.grantsChanged()
        #expect(fixture.engine.places.count == 1)
        #expect(fixture.monitor.removed.isEmpty)
    }

    @Test func theSavedGrantChangingMakesTheToolForgetItsPlaces() async throws {
        let defaults = GeofenceFixture.makeDefaults()
        defer { defaults.clear() }
        let place = Self.samplePlace()
        let scope = DeviceToolScope(deviceID: "phone-a", authorizationEpoch: 1, hostID: place.hostID)
        defaults.defaults.set("phone-a", forKey: "loopdy.native-device-tools.device-id")
        defaults.defaults.set(["geofences"], forKey: scope.storageKey)

        let store = GeofenceFakeStore()
        try store.save([place])
        let backing = GeofenceFakeBacking()
        let monitor = GeofenceFakeMonitor(backing: backing)
        let d = defaults.defaults
        let engine = DeviceGeofenceMonitor(
            store: store, monitor: monitor, sender: GeofenceFakeSender(), notifier: GeofenceFakeNotifier(),
            grantAllows: { DeviceGeofenceTool.grantAllows($0, defaults: d) })
        let tool = DeviceGeofenceTool(engine: engine, location: GeofenceFakeLocation(),
                                      alwaysRequester: GeofenceFakeAlways(), defaults: d)
        tool.observeGrants()
        #expect(await engine.start())
        #expect(engine.places.count == 1)

        // The switch goes off: DeviceToolPermissions saves the list without "geofences", and
        // UserDefaults says so.
        d.set([String](), forKey: scope.storageKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: d)
        let gone = await eventually { engine.places.isEmpty }
        #expect(gone)
        #expect(store.saved.isEmpty)
        #expect(monitor.removed == [place.id])
    }

    // MARK: Tidying iOS

    @Test func aSavedFileWithNoPlacesStillTidiesWhatIOSHolds() async throws {
        let first = GeofenceFixture()
        let id = try #require(try await first.create(Self.grocery)["id"]?.string)
        _ = try await first.tool.execute(operation: "geofences.delete", arguments: ["id": .string(id)],
                                         context: GeofenceFixture.context(), authorize: {})
        // iOS kept a condition the phone forgot (a crash between the two writes, say).
        first.backing.set(DeviceGeofenceRegion(identifier: "ghost", latitude: 1, longitude: 1, radiusMeters: 150))

        let second = first.relaunched()
        #expect(await second.engine.start())
        #expect(second.monitor.removed == ["ghost"])
        #expect(second.backing.identifiers.isEmpty)
        // With nothing to watch there is nothing to listen to.
        #expect(second.monitor.eventsCalls == 0)
    }

    @Test func aDamagedFileStillTidiesWhatIOSHolds() async {
        let fixture = GeofenceFixture()
        fixture.store.readFailure = .corrupt
        fixture.backing.set(DeviceGeofenceRegion(identifier: "ghost", latitude: 1, longitude: 1, radiusMeters: 150))
        #expect(await fixture.engine.start())
        #expect(fixture.engine.places.isEmpty)
        #expect(fixture.monitor.removed == ["ghost"])
        #expect(fixture.backing.identifiers.isEmpty)
    }

    @Test func aFileThatCannotBeReadYetTouchesNothingInIOS() async {
        let fixture = GeofenceFixture()
        fixture.store.readFailure = .unreadable
        fixture.backing.set(DeviceGeofenceRegion(identifier: "held", latitude: 1, longitude: 1, radiusMeters: 150))
        #expect(await fixture.engine.start() == false)
        #expect(fixture.monitor.removed.isEmpty)
        #expect(fixture.backing.identifiers == ["held"])
    }

    // MARK: Where the person already is

    @Test func theFixDecidesWhetherAPlaceStartsInside() {
        func fix(_ lat: Double, _ lon: Double, accuracy: Double = 10) -> DeviceLocationFix {
            DeviceLocationFix(latitude: lat, longitude: lon, horizontalAccuracy: accuracy, timestamp: Self.arrival)
        }
        let start = DeviceGeofenceTool.startsInside
        #expect(start(fix(40.1, -75.2), 40.1, -75.2, 150) == true)
        #expect(start(fix(40.1005, -75.2), 40.1, -75.2, 150) == true)   // about 55 m away
        #expect(start(fix(40.103, -75.2), 40.1, -75.2, 150) == false)   // about 330 m away
        // No fix, a fix that failed, or one wider than the place can't say.
        #expect(start(nil, 40.1, -75.2, 150) == nil)
        #expect(start(fix(40.1, -75.2, accuracy: -1), 40.1, -75.2, 150) == nil)
        #expect(start(fix(40.1, -75.2, accuracy: 500), 40.1, -75.2, 150) == nil)
    }

    @Test func aPlaceMadeWhereThePersonAlreadyIsStartsInsideAndSaysNothing() async throws {
        let fixture = GeofenceFixture()
        fixture.location.fix = DeviceLocationFix(latitude: 40.1, longitude: -75.2, horizontalAccuracy: 10, timestamp: Self.arrival)
        _ = try await fixture.create(Self.grocery.merging(["on": .string("both"), "repeats": .boolean(true)]) { $1 })
        let place = try #require(fixture.engine.places.first)
        #expect(place.isInside && place.ignoresChangesUntil == nil)
        #expect(fixture.monitor.added.map(\.state) == [.inside])

        // iOS confirms the starting state: not an arrival.
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: place.id, state: .inside, date: Self.arrival.addingTimeInterval(5)))
        await fixture.engine.finishDeliveries()
        #expect(fixture.sender.sent.isEmpty)
        // Leaving later still tells.
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: place.id, state: .outside, date: Self.arrival.addingTimeInterval(900)))
        await fixture.engine.finishDeliveries()
        #expect(fixture.sender.sent.map { Self.plain($0.message).contains("Left") } == [true])
    }

    @Test func aPlaceMadeAwayFromThePersonTellsOnTheirFirstArrival() async throws {
        let fixture = GeofenceFixture()   // the fix is far from the place
        _ = try await fixture.create(Self.grocery.merging(["repeats": .boolean(true)]) { $1 })
        let place = try #require(fixture.engine.places.first)
        #expect(!place.isInside && place.ignoresChangesUntil == nil)
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: place.id, state: .inside, date: Self.arrival.addingTimeInterval(5)))
        await fixture.engine.finishDeliveries()
        #expect(fixture.sender.sent.count == 1)
    }

    @Test func withoutAClearFixTheFirstReportOnlyConfirmsTheStartingState() async throws {
        let failing = GeofenceFixture()
        failing.location.fixFailure = true
        let vague = GeofenceFixture()
        vague.location.fix = DeviceLocationFix(latitude: 40.1, longitude: -75.2, horizontalAccuracy: 900, timestamp: Self.arrival)
        for fixture in [failing, vague] {
            _ = try await fixture.create(Self.grocery.merging(["on": .string("both"), "repeats": .boolean(true)]) { $1 })
            let place = try #require(fixture.engine.places.first)
            #expect(place.isInside == false)
            #expect(place.ignoresChangesUntil == Self.arrival.addingTimeInterval(120))

            // The person was already there: iOS reports it at once. Nothing is told.
            await fixture.engine.handle(DeviceGeofenceEvent(identifier: place.id, state: .inside, date: Self.arrival.addingTimeInterval(30)))
            await fixture.engine.finishDeliveries()
            #expect(fixture.sender.sent.isEmpty)
            #expect(fixture.engine.places.first?.isInside == true)
            #expect(fixture.engine.places.first?.ignoresChangesUntil == nil)
            #expect(fixture.backgroundBegun == 0)

            // Leaving afterwards is a real change.
            await fixture.engine.handle(DeviceGeofenceEvent(identifier: place.id, state: .outside, date: Self.arrival.addingTimeInterval(400)))
            await fixture.engine.finishDeliveries()
            #expect(fixture.sender.sent.map { Self.plain($0.message).contains("Left") } == [true])
        }
    }

    @Test func withoutAFixAnArrivalAfterTheWindowStillTells() async throws {
        let fixture = GeofenceFixture()
        fixture.location.fixFailure = true
        _ = try await fixture.create(Self.grocery.merging(["repeats": .boolean(true)]) { $1 })
        let place = try #require(fixture.engine.places.first)
        await fixture.engine.handle(DeviceGeofenceEvent(identifier: place.id, state: .inside, date: Self.arrival.addingTimeInterval(121)))
        await fixture.engine.finishDeliveries()
        #expect(fixture.sender.sent.count == 1)
        #expect(fixture.engine.places.first?.ignoresChangesUntil == nil)
    }

    @Test func aPlaceMadeHereNeedsNoWindow() async throws {
        let fixture = GeofenceFixture()
        _ = try await fixture.create(["name": .string("Home"), "here": .boolean(true), "on": .string("leave")])
        #expect(fixture.engine.places.first?.ignoresChangesUntil == nil)
        #expect(fixture.location.fixRequests == 1)
    }

    @Test func theStartingWindowSurvivesARelaunch() async throws {
        let first = GeofenceFixture()
        first.location.fixFailure = true
        _ = try await first.create(Self.grocery)
        let second = first.relaunched()
        #expect(await second.engine.start())
        #expect(second.engine.places.first?.ignoresChangesUntil == Self.arrival.addingTimeInterval(120))
    }

    // MARK: Finding the chat

    @Test func thePlaceKeepsTheChatIDTheCatalogKnows() async throws {
        let fixture = GeofenceFixture(resolveSession: { id in id == "session-a" ? "chat-in-catalog" : nil })
        _ = try await fixture.create(Self.grocery)
        #expect(fixture.engine.places.first?.sessionID == "chat-in-catalog")
        // A chat the catalog doesn't know keeps the ID the call carried.
        _ = try await fixture.create(Self.grocery, host: "host-a", agent: "agent-a", session: "unknown-chat")
        #expect(fixture.engine.places.last?.sessionID == "unknown-chat")
    }

    @Test func aChatIsFoundByItsAppIDItsStoredOrRuntimeIDOrByLoadingIt() async {
        let chats = GeofenceFakeChats()
        chats.known = ["app-chat"]
        chats.visible = ["stored-1": "app-chat", "runtime-1": "app-chat"]
        chats.loadable = ["host-only-chat"]

        #expect(await DeviceGeofenceChats.resolve("app-chat", in: chats) == "app-chat")
        #expect(chats.hydrated.isEmpty)
        #expect(await DeviceGeofenceChats.resolve("stored-1", in: chats) == "app-chat")
        #expect(await DeviceGeofenceChats.resolve("runtime-1", in: chats) == "app-chat")
        #expect(chats.hydrated.isEmpty)
        #expect(await DeviceGeofenceChats.resolve("host-only-chat", in: chats) == "host-only-chat")
        #expect(chats.hydrated == ["host-only-chat"])
    }

    @Test func aChatNoOneKnowsIsNotFoundAndNeverMadeUp() async {
        let chats = GeofenceFakeChats()
        chats.known = ["app-chat"]
        // A mapping to a chat the catalog doesn't hold doesn't count.
        chats.visible = ["stale": "deleted-chat"]
        #expect(await DeviceGeofenceChats.resolve("nothing", in: chats) == nil)
        #expect(await DeviceGeofenceChats.resolve("stale", in: chats) == nil)
    }

    // MARK: Which computer

    @Test func aMessageNeverSwitchesTheComputerUnderSomeoneUsingTheApp() {
        let plan = DeviceGeofenceHostPlan.make
        // The place's computer is the one in use, or nothing says otherwise.
        #expect(plan("host-a", "host-a", true, true) == .useCurrent)
        #expect(plan("host-a", "host-a", false, false) == .useCurrent)
        #expect(plan(nil, "host-a", true, false) == .useCurrent)
        // Another computer: only with bighelp in the background, and only if it can switch.
        #expect(plan("host-b", "host-a", true, true) == .refuse)
        #expect(plan("host-b", "host-a", true, false) == .refuse)
        #expect(plan("host-b", "host-a", false, true) == .switchHost)
        #expect(plan("host-b", "host-a", false, false) == .refuse)
    }

    // MARK: Saved places

    @Test func savedPlacesRoundTripThroughAProtectedFileKeptOutOfBackups() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "geofence-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "device-geofences-v1.json")
        let store = DeviceGeofenceFileStore(url: url)
        #expect(try store.load().isEmpty)

        let place = Self.samplePlace()
        try store.save([place])
        #expect(try DeviceGeofenceFileStore(url: url).load() == [place])
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func aFileWithTooManyPlacesOrNonsenseIsCorrupt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "geofence-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "places.json")
        let store = DeviceGeofenceFileStore(url: url)

        try Data("not json".utf8).write(to: url)
        #expect(throws: DeviceGeofenceStoreError.corrupt) { try store.load() }

        try store.save(Array(repeating: Self.samplePlace(), count: 21))
        #expect(throws: DeviceGeofenceStoreError.corrupt) { try store.load() }
    }

    @Test func aPlaceIsAllowedWhileItsHostsSwitchIsOn() {
        let fixture = GeofenceFixture.makeDefaults()
        defer { fixture.clear() }
        let place = Self.samplePlace()
        // Before the app knows its phone ID nothing is taken away.
        #expect(DeviceGeofenceTool.grantAllows(place, defaults: fixture.defaults))

        fixture.defaults.set("phone-a", forKey: "loopdy.native-device-tools.device-id")
        #expect(!DeviceGeofenceTool.grantAllows(place, defaults: fixture.defaults))

        let scope = DeviceToolScope(deviceID: "phone-a", authorizationEpoch: 1, hostID: place.hostID)
        fixture.defaults.set(["geofences", "photos"], forKey: scope.storageKey)
        #expect(DeviceGeofenceTool.grantAllows(place, defaults: fixture.defaults))

        fixture.defaults.set(["photos"], forKey: scope.storageKey)
        #expect(!DeviceGeofenceTool.grantAllows(place, defaults: fixture.defaults))
    }

    // MARK: Helpers

    static let grocery: [String: BighelpJSONValue] = [
        "name": .string("Grocery store"), "latitude": .number(40.1), "longitude": .number(-75.2),
    ]

    static func samplePlace() -> DeviceGeofencePlace {
        DeviceGeofencePlace(
            id: UUID().uuidString.lowercased(), hostID: "host-a", agentID: "agent-a", sessionID: "session-a",
            name: "Grocery store", latitude: 40.1, longitude: -75.2, radiusMeters: 150, on: .both,
            note: "buy milk", repeats: true, created: Date(timeIntervalSince1970: 1_790_000_000),
            isInside: false, lastEventAt: Date(timeIntervalSince1970: 1_790_000_100))
    }

    static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// iOS puts a narrow no-break space before "PM"; the plain space is what a person reads.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

// MARK: Fixtures

/// A phone with the tool, its engine and fakes that behave like iOS: places persist under the
/// monitor's name across launches, and an event iOS can't deliver is held until someone listens.
@MainActor
private final class GeofenceFixture {
    let backing: GeofenceFakeBacking
    let store: GeofenceFakeStore
    let monitor: GeofenceFakeMonitor
    let sender = GeofenceFakeSender()
    let notifier = GeofenceFakeNotifier()
    let location: GeofenceFakeLocation
    let always = GeofenceFakeAlways()
    let grant = GeofenceGrant()
    let clock = GeofenceClock()
    let defaults = GeofenceFixture.makeDefaults()
    let engine: DeviceGeofenceMonitor
    let tool: DeviceGeofenceTool
    private let backgroundCounter = GeofenceCounter()

    init(authorization: DeviceLocationAuthorization = .whenInUse, accuracy: DeviceLocationAccuracy = .full,
         servicesEnabled: Bool = true, backing: GeofenceFakeBacking = GeofenceFakeBacking(),
         store: GeofenceFakeStore = GeofenceFakeStore(), location: GeofenceFakeLocation? = nil,
         resolveSession: @escaping @MainActor (String) async -> String? = { _ in nil }) {
        self.backing = backing
        self.store = store
        monitor = GeofenceFakeMonitor(backing: backing)
        self.location = location ?? GeofenceFakeLocation(authorization: authorization, accuracy: accuracy,
                                                         servicesEnabled: servicesEnabled)
        let grant = grant, counter = backgroundCounter, clock = clock
        engine = DeviceGeofenceMonitor(
            store: store, monitor: monitor, sender: sender, notifier: notifier,
            backgroundTask: { _ in
                counter.begun += 1
                return { counter.ended += 1 }
            },
            grantAllows: { grant.allows($0) },
            timeZone: .gmt, locale: Locale(identifier: "en_US"), clock: { clock.now })
        tool = DeviceGeofenceTool(engine: engine, location: self.location, alwaysRequester: always,
                                  defaults: defaults.defaults, resolveSession: resolveSession)
    }

    deinit { defaults.clear() }

    var backgroundBegun: Int { backgroundCounter.begun }
    var backgroundEnded: Int { backgroundCounter.ended }

    /// The app started again: new objects, the same disk and the same iOS state.
    func relaunched() -> GeofenceFixture {
        monitor.disconnect()
        return GeofenceFixture(authorization: location.authorization, accuracy: location.accuracy,
                        backing: backing, store: store)
    }

    static func context(host: String = "host-a", agent: String = "agent-a", session: String = "session-a") -> DeviceToolCallContext {
        DeviceToolCallContext(requestID: UUID().uuidString.lowercased(), hostID: host, agentID: agent,
                              sessionID: session, turnID: "turn-a")
    }

    @discardableResult
    func create(_ arguments: [String: BighelpJSONValue], hostID: String = "host-a") async throws -> [String: BighelpJSONValue] {
        try await create(arguments, host: hostID, agent: "agent-a", session: "session-a")
    }

    @discardableResult
    func create(_ arguments: [String: BighelpJSONValue], host: String, agent: String, session: String) async throws -> [String: BighelpJSONValue] {
        try await tool.execute(operation: "geofences.create", arguments: arguments,
                               context: Self.context(host: host, agent: agent, session: session), authorize: {})
    }

    /// Cleared from the fixture's deinit, which runs off the main actor; UserDefaults is thread-safe.
    struct Defaults: @unchecked Sendable {
        let name: String
        let defaults: UserDefaults
        func clear() { UserDefaults.standard.removePersistentDomain(forName: name) }
    }

    static func makeDefaults() -> Defaults {
        let name = "geofence-tests-\(UUID().uuidString)"
        return Defaults(name: name, defaults: UserDefaults(suiteName: name)!)
    }
}

@MainActor
private final class GeofenceGrant {
    var allowed = true
    var blockedHosts: Set<String> = []
    func allows(_ place: DeviceGeofencePlace) -> Bool { allowed && !blockedHosts.contains(place.hostID) }
}

/// The engine's clock: tests move it instead of waiting.
final class GeofenceClock: @unchecked Sendable {
    /// 2026-10-22T17:42:00Z, the same moment as the tests' arrival.
    var now = Date(timeIntervalSince1970: 1_792_690_920)
}

@MainActor
private final class GeofenceCounter {
    var begun = 0
    var ended = 0
}

/// What iOS keeps under a monitor's name: places that outlive the app, and events it holds for a
/// monitor that isn't open yet.
final class GeofenceFakeBacking: @unchecked Sendable {
    private let lock = NSLock()
    private var conditions: [String: DeviceGeofenceRegion] = [:]
    private var pending: [DeviceGeofenceEvent] = []

    var identifiers: [String] { lock.withLock { Array(conditions.keys) } }
    func region(_ identifier: String) -> DeviceGeofenceRegion? { lock.withLock { conditions[identifier] } }
    func set(_ region: DeviceGeofenceRegion) { lock.withLock { conditions[region.identifier] = region } }
    func remove(_ identifier: String) { lock.withLock { conditions[identifier] = nil } }
    func removeAll() { lock.withLock { conditions.removeAll() } }
    func hold(_ event: DeviceGeofenceEvent) { lock.withLock { pending.append(event) } }
    func takeHeld() -> [DeviceGeofenceEvent] { lock.withLock { let held = pending; pending = []; return held } }
}

final class GeofenceFakeMonitor: DeviceGeofenceMonitoring, @unchecked Sendable {
    struct Added: Equatable { let region: DeviceGeofenceRegion; let state: DeviceGeofenceState }
    let backing: GeofenceFakeBacking
    private let lock = NSLock()
    private var continuation: AsyncStream<DeviceGeofenceEvent>.Continuation?
    private var _added: [Added] = []
    private var _removed: [String] = []
    private var _eventsCalls = 0
    private var _identifierReads = 0

    init(backing: GeofenceFakeBacking) { self.backing = backing }

    var added: [Added] { lock.withLock { _added } }
    var removed: [String] { lock.withLock { _removed } }
    var eventsCalls: Int { lock.withLock { _eventsCalls } }
    var identifierReads: Int { lock.withLock { _identifierReads } }

    func identifiers() async -> [String] {
        lock.withLock { _identifierReads += 1 }
        return backing.identifiers
    }

    func add(_ region: DeviceGeofenceRegion, assuming state: DeviceGeofenceState) async {
        lock.withLock { _added.append(Added(region: region, state: state)) }
        backing.set(region)
    }

    func remove(identifier: String) async {
        lock.withLock { _removed.append(identifier) }
        backing.remove(identifier)
    }

    func events() -> AsyncStream<DeviceGeofenceEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceGeofenceEvent.self)
        lock.withLock {
            _eventsCalls += 1
            self.continuation = continuation
        }
        // Whatever iOS held while no monitor was listening comes first.
        for event in backing.takeHeld() { continuation.yield(event) }
        return stream
    }

    /// The app was closed: nobody listens, so iOS holds what happens next.
    func disconnect() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    /// iOS reporting a place, listened to or not. A place iOS doesn't hold sends nothing.
    func emit(_ identifier: String, _ state: DeviceGeofenceState, at date: Date) {
        guard backing.region(identifier) != nil else { return }
        let event = DeviceGeofenceEvent(identifier: identifier, state: state, date: date)
        if let continuation = lock.withLock({ self.continuation }) { continuation.yield(event) }
        else { backing.hold(event) }
    }
}

@MainActor
final class GeofenceFakeStore: DeviceGeofenceStoring {
    private(set) var saved: [DeviceGeofencePlace] = []
    private(set) var saveCount = 0
    private var hasFile = false
    var readFailure: DeviceGeofenceStoreError?
    var failWrites = false

    var exists: Bool { hasFile || readFailure != nil }

    func load() throws -> [DeviceGeofencePlace] {
        if let readFailure { throw readFailure }
        return saved
    }

    func save(_ places: [DeviceGeofencePlace]) throws {
        if failWrites { throw DeviceGeofenceStoreError.unwritable }
        saveCount += 1
        hasFile = true
        saved = places
    }
}

@MainActor
final class GeofenceFakeSender: DeviceGeofenceMessageSending {
    struct Sent { let message: String; let place: DeviceGeofencePlace }
    private(set) var sent: [Sent] = []
    var failure: (any Error)?

    func send(_ message: String, to place: DeviceGeofencePlace) async throws {
        if let failure { throw failure }
        sent.append(Sent(message: message, place: place))
    }
}

@MainActor
final class GeofenceFakeNotifier: DeviceGeofenceNotifying {
    struct Failure { let place: DeviceGeofencePlace; let arrived: Bool }
    private(set) var failures: [Failure] = []

    func notifyDeliveryFailed(place: DeviceGeofencePlace, arrived: Bool) async {
        failures.append(Failure(place: place, arrived: arrived))
    }
}

@MainActor
final class GeofenceFakeAlways: DeviceGeofenceAlwaysRequesting {
    private(set) var requests = 0
    func requestAlways() { requests += 1 }
}

@MainActor
final class GeofenceFakeLocation: DeviceLocationProviding {
    var authorization: DeviceLocationAuthorization
    var accuracy: DeviceLocationAccuracy
    var servicesOn: Bool
    var answerToWhenInUse: DeviceLocationAuthorization = .whenInUse
    /// Far from every place the tests make, unless a test moves it.
    var fix = DeviceLocationFix(latitude: 42.0, longitude: -77.0, horizontalAccuracy: 10,
                                timestamp: Date(timeIntervalSince1970: 1_790_000_000))
    var fixFailure = false
    private(set) var whenInUseRequests = 0
    private(set) var fixRequests = 0

    init(authorization: DeviceLocationAuthorization = .whenInUse, accuracy: DeviceLocationAccuracy = .full,
         servicesEnabled: Bool = true) {
        self.authorization = authorization; self.accuracy = accuracy; servicesOn = servicesEnabled
    }

    func servicesEnabled() async -> Bool { servicesOn }

    func requestWhenInUse() async -> DeviceLocationAuthorization {
        whenInUseRequests += 1
        authorization = answerToWhenInUse
        return authorization
    }

    func requestPrecise(purposeKey: String) async -> DeviceLocationAccuracy { accuracy }

    func currentFix() async throws -> DeviceLocationFix {
        fixRequests += 1
        if fixFailure { throw AppleDeviceToolError.unavailable }
        return fix
    }

    func place(for fix: DeviceLocationFix) async -> DeviceLocationPlace? { nil }
}

@MainActor
final class GeofenceFakeChats: DeviceGeofenceChatLookup {
    var known: Set<String> = []
    var visible: [String: String] = [:]
    var loadable: Set<String> = []
    private(set) var hydrated: [String] = []

    func hasChat(id: String) -> Bool { known.contains(id) }
    func visibleChatID(resolving id: String) -> String? { visible[id] }
    func hydrate(id: String) async -> Bool {
        hydrated.append(id)
        guard loadable.contains(id) else { return false }
        known.insert(id)
        return true
    }
}

/// Calendar, Reminders and Location are not what these tests run; the router just needs a service.
@MainActor
private final class GeofenceStubBoundary: AppleDeviceToolNativeBoundary {
    func status(for capability: DeviceToolCapability) async -> DeviceToolSystemAccess { .unavailable }
    func request(_ capability: DeviceToolCapability) async -> DeviceToolSystemAccess { .unavailable }
    func execute(operation: String, arguments: [String: BighelpJSONValue],
                 authorize: @escaping @MainActor () throws -> Void) async throws -> [String: BighelpJSONValue] {
        throw AppleDeviceToolError.unsupportedOperation
    }
}
