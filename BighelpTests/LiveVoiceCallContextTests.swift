import Foundation
import Testing
@testable import Bighelp

/// What a voice call tells the voice model about who is talking and where (plugin `native-voice-context-v1`).
@MainActor
struct LiveVoiceCallContextTests {
    @Test func theOfferNamesTheAgentThePersonThePlaceAndTheTimeZone() {
        let context = LiveVoiceCallContext(agentName: "Alfie", personName: "Sam",
                                           place: "Sampleton, Example State, Exampleland", timeZone: "America/Chicago")
        #expect(context.fields == ["agentName": .string("Alfie"), "personName": .string("Sam"),
                                   "place": .string("Sampleton, Example State, Exampleland"),
                                   "timeZone": .string("America/Chicago")])
    }

    @Test func emptyNamesAndThePlaceholderAreNeverSent() {
        #expect(LiveVoiceCallContext(agentName: " ", personName: "", place: nil, timeZone: "Europe/Paris").fields
                == ["timeZone": .string("Europe/Paris")])
        // "You" is what the app shows before a name is saved, never a name.
        #expect(LiveVoiceCallContext(agentName: nil, personName: UserIdentity.placeholderName, place: nil, timeZone: nil)
            .fields.isEmpty)
        let long = LiveVoiceCallContext(agentName: "Al\nfie", personName: String(repeating: "S", count: 90),
                                        place: nil, timeZone: nil)
        #expect(long.fields["agentName"] == .string("Al fie"))
        #expect(long.fields["personName"]?.string?.count == UserIdentity.maximumNameLength)
        // The plugin counts code points, not characters: 30 family emoji are 210 of them.
        let emoji = LiveVoiceCallContext(agentName: nil, personName: String(repeating: "👨‍👩‍👧‍👦", count: 30),
                                         place: nil, timeZone: nil)
        #expect((emoji.fields["personName"]?.string?.unicodeScalars.count ?? 0) <= UserIdentity.maximumNameLength)
    }

    @Test func onlyAComputerWhosePluginTakesItGetsTheContext() async {
        let place = LiveVoicePlace(isAllowed: { false }, provider: DemoDeviceLocationProvider())
        #expect(LiveVoiceCallContext.offerContext(features: ["native-voice-v1"], agentName: "Alfie",
                                                  personName: { "Sam" }, place: place) == nil)
        let context = LiveVoiceCallContext.offerContext(features: ["native-voice-v1", "native-voice-context-v1"],
                                                        agentName: "Alfie", personName: { "Sam" }, place: place)
        let fields = await context?()
        #expect(fields?["agentName"] == .string("Alfie"))
        #expect(fields?["personName"] == .string("Sam"))
        #expect(fields?["timeZone"] == .string(TimeZone.current.identifier))
        #expect(fields?["place"] == nil, "Location is off")
    }

    @Test func theSessionAddsTheContextOnlyWhenTheComputerTakesIt() async throws {
        for takesContext in [true, false] {
            let log = OfferLog()
            var context: NativeLiveVoiceSession.Context?
            if takesContext {
                context = { () async -> [String: BighelpJSONValue] in
                    ["personName": .string("Sam"), "timeZone": .string("America/Chicago")]
                }
            }
            let voice = NativeLiveVoiceSession(
                owner: .init(hostID: "native", authorizationID: "auth", agentID: "default", sessionID: "stored"),
                operation: { operation, payload in
                    if operation == .nativeVoiceGeminiOffer { log.payload = payload }
                    return ["voiceId": payload["voiceId"] ?? .null]
                }, isCurrent: { true }, submit: { _ in "" }, context: context)
            _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-\(takesContext)"),
                                                                    "provider": .string("gemini")])
            #expect(log.payload["personName"] == (takesContext ? .string("Sam") : nil))
            #expect(log.payload["timeZone"] == (takesContext ? .string("America/Chicago") : nil))
            #expect(log.payload["provider"] == .string("gemini"))
        }
    }

    @Test func aPlaceOnlyWhileLocationIsAllowedAndNeverTheStreet() async {
        var allowed = false
        let place = LiveVoicePlace(isAllowed: { allowed }, provider: DemoDeviceLocationProvider())
        #expect(await place.coarse() == nil)
        allowed = true
        #expect(await place.coarse() == "Sampleton, Example State, Exampleland")
        // Turned off again: nothing, cached or not.
        allowed = false
        #expect(await place.coarse() == nil)
    }

    @Test func aSlowFixNeverHoldsTheCallUpAndHelpsTheNextOne() async throws {
        let provider = SlowLocation()
        let place = LiveVoicePlace(isAllowed: { true }, provider: provider)
        let started = ContinuousClock.now
        #expect(await place.coarse(within: 0.5) == nil)
        #expect(ContinuousClock.now - started < .milliseconds(900), "The call waits its limit, not the search")
        try await Task.sleep(for: .seconds(1.8))
        #expect(await place.coarse(within: 0.5) == "Sampleton, Exampleland")
        #expect(provider.fixes == 1, "The next call used the place the slow fix found")
    }

    @MainActor private final class OfferLog {
        var payload: [String: BighelpJSONValue] = [:]
    }

    @MainActor private final class SlowLocation: DeviceLocationProviding {
        var authorization: DeviceLocationAuthorization = .whenInUse
        var accuracy: DeviceLocationAccuracy = .reduced
        var fixes = 0
        func servicesEnabled() async -> Bool { true }
        func requestWhenInUse() async -> DeviceLocationAuthorization { .whenInUse }
        func requestPrecise(purposeKey: String) async -> DeviceLocationAccuracy { .reduced }
        func currentFix() async throws -> DeviceLocationFix {
            fixes += 1
            try await Task.sleep(for: .seconds(2))
            return DeviceLocationFix(latitude: 12.3, longitude: -65.4, horizontalAccuracy: 3_000, timestamp: Date())
        }
        func place(for fix: DeviceLocationFix) async -> DeviceLocationPlace? {
            DeviceLocationPlace(street: "100 Example Street", city: "Sampleton", country: "Exampleland")
        }
    }
}
