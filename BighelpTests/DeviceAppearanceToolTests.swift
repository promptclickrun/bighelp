import Foundation
import Testing
@testable import Bighelp

/// The agent's `iphone_appearance` tool on the phone: the switch (on until the person turns it off),
/// the names and colors it accepts, and the rule that it changes the look only while the chat is open.
@MainActor
struct DeviceAppearanceToolTests {
    // MARK: Capability and switch

    @Test func appearanceIsItsOwnToolAndNeedsTheNewerPlugin() {
        #expect(DeviceToolCapability.appearance.rawValue == "appearance")
        #expect(DeviceToolCapability.appearance.pluginFeature == "native-device-appearance-v1")
        #expect(!DeviceToolCapability.appearance.sharesPersonalData)
        #expect([DeviceToolCapability.calendar, .reminders, .location].allSatisfy { $0.sharesPersonalData })
    }

    @Test func switchIsOnByDefaultWithoutAskingIOS() async {
        let fixture = AppearanceFixture()
        #expect(fixture.permissions.isEnabled(.appearance))
        #expect(fixture.permissions.status(for: .appearance) == .available)
        await fixture.permissions.refresh()
        #expect(fixture.permissions.isEnabled(.appearance))
        #expect(fixture.systemRequests.isEmpty, "Appearance shares no data, so iOS is never asked")
        #expect(!fixture.permissions.isEnabled(.location), "Data tools stay off until the person allows them")
    }

    @Test func switchNeedsAHostButCountsForEveryHost() {
        let fixture = AppearanceFixture()
        fixture.permissions.bind(nil)
        #expect(!fixture.permissions.isEnabled(.appearance))
        #expect(fixture.permissions.appearanceAllowed)
        fixture.permissions.bind(.init(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-b"))
        #expect(fixture.permissions.isEnabled(.appearance))
        fixture.permissions.setAppearanceAllowed(false)
        fixture.permissions.bind(fixture.scope)
        #expect(!fixture.permissions.isEnabled(.appearance))
    }

    @Test func turningItOffIsSavedAndRetiresWorkInFlight() async {
        let fixture = AppearanceFixture()
        let revision = fixture.permissions.revision
        fixture.permissions.disable(.appearance)
        #expect(fixture.permissions.revision != revision)
        #expect(fixture.saved == [false])
        #expect(!fixture.makePermissions(saved: false).appearanceAllowed)
        await fixture.permissions.setEnabled(true, for: .appearance)
        #expect(fixture.permissions.isEnabled(.appearance))
        #expect(fixture.saved == [false, true])
        #expect(fixture.systemRequests.isEmpty)
    }

    // MARK: get

    @Test func getReportsTheLookAndTheChoices() throws {
        let fixture = AppearanceFixture()
        fixture.settings.appearance = .dark
        let payload = try fixture.tool.execute(operation: "appearance.get", arguments: [:], authorize: {})
        #expect(payload["mode"] == .string("dark"))
        #expect(payload["color"] == .string("lavender"))
        #expect(payload["modes"] == .array(["system", "light", "dark"].map(BighelpJSONValue.string)))
        let colors = payload["colors"]?.array?.compactMap(\.string) ?? []
        #expect(colors.first == "lavender")
        #expect(colors.contains("ocean") && colors.contains("ink"))
        #expect(colors.count == BighelpBubbleColor.allCases.count)
        fixture.settings.customBubbleHex = "0E7C66"
        let custom = try fixture.tool.execute(operation: "appearance.get", arguments: [:], authorize: {})
        #expect(custom["color"] == .string("#0E7C66"))
    }

    // MARK: set

    @Test func setAppliesModeAndNamedColorAndReturnsWhatItShows() throws {
        let fixture = AppearanceFixture()
        fixture.settings.customBubbleHex = "123456"
        let payload = try fixture.tool.execute(operation: "appearance.set",
                                               arguments: ["mode": .string("dark"), "color": .string("Rose")],
                                               authorize: {})
        #expect(fixture.settings.appearance == .dark)
        #expect(fixture.settings.bubbleColor == .rose)
        #expect(fixture.settings.customBubbleHex == nil, "A named color replaces a custom one, like in Appearance")
        #expect(payload == ["mode": .string("dark"), "color": .string("rose")])
    }

    @Test func setTakesAnyHexColorAndKeepsTheOtherSetting() throws {
        let fixture = AppearanceFixture()
        fixture.settings.appearance = .light
        let payload = try fixture.tool.execute(operation: "appearance.set",
                                               arguments: ["color": .string("#0e7c66")], authorize: {})
        #expect(fixture.settings.customBubbleHex == "0E7C66")
        #expect(fixture.settings.appearance == .light)
        #expect(payload == ["mode": .string("light"), "color": .string("#0E7C66")])
        _ = try fixture.tool.execute(operation: "appearance.set", arguments: ["mode": .string("system")], authorize: {})
        #expect(fixture.settings.appearance == .system)
        #expect(fixture.settings.customBubbleHex == "0E7C66")
    }

    @Test func lavenderAndInkUseTheNamesPeopleSee() throws {
        let fixture = AppearanceFixture()
        _ = try fixture.tool.execute(operation: "appearance.set", arguments: ["color": .string("ink")], authorize: {})
        #expect(fixture.settings.bubbleColor == .graphite)
        let payload = try fixture.tool.execute(operation: "appearance.set",
                                               arguments: ["color": .string("lavender")], authorize: {})
        #expect(fixture.settings.bubbleColor == nil, "Lavender is the default, saved as no choice")
        #expect(payload["color"] == .string("lavender"))
    }

    @Test func refusedRequestsChangeNothing() {
        let cases: [([String: BighelpJSONValue], String)] = [
            ([:], "invalid_arguments"),
            (["mode": .string("dim")], "invalid_arguments"),
            (["mode": .boolean(true)], "invalid_arguments"),
            (["color": .string("#12345")], "invalid_arguments"),
            (["color": .string("#12345G")], "invalid_arguments"),
            (["color": .integer(7)], "invalid_arguments"),
            (["color": .string(String(repeating: "a", count: 25))], "invalid_arguments"),
            (["theme": .string("nous")], "invalid_arguments"),
            (["mode": .string("dark"), "color": .string("violet")], "unknown_color"),
            (["color": .string("graphite")], "unknown_color"),
        ]
        for (arguments, code) in cases {
            let fixture = AppearanceFixture()
            #expect(throws: DeviceAppearanceTool.Failure(rawValue: code)!) {
                try fixture.tool.execute(operation: "appearance.set", arguments: arguments, authorize: {})
            }
            #expect(fixture.settings.appearance == .system, "\(arguments)")
            #expect(fixture.settings.bubbleColor == nil && fixture.settings.customBubbleHex == nil, "\(arguments)")
        }
        let fixture = AppearanceFixture()
        #expect(throws: DeviceAppearanceTool.Failure.invalidArguments) {
            try fixture.tool.execute(operation: "appearance.get", arguments: ["mode": .string("dark")], authorize: {})
        }
        #expect(throws: DeviceAppearanceTool.Failure.unsupportedOperation) {
            try fixture.tool.execute(operation: "appearance.reset", arguments: [:], authorize: {})
        }
    }

    @Test func nothingChangesWhenTheChatIsNoLongerCurrent() {
        let fixture = AppearanceFixture()
        struct Gone: Error {}
        #expect(throws: Gone.self) {
            try fixture.tool.execute(operation: "appearance.set", arguments: ["mode": .string("dark")],
                                     authorize: { throw Gone() })
        }
        #expect(fixture.settings.appearance == .system)
    }

    // MARK: Through the coordinator

    @Test func coordinatorAppliesTheChangeWithoutJournalingIt() async {
        let fixture = AppearanceFixture()
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.status == "completed")
        #expect(result.payload == ["mode": .string("dark"), "color": .string("rose")])
        #expect(fixture.settings.appearance == .dark && fixture.settings.bubbleColor == .rose)
        #expect(fixture.journal.saves == 0, "Setting a look twice is the same as once; nothing to reconcile")
    }

    @Test func coordinatorRefusesWhenTheSwitchIsOff() async {
        let fixture = AppearanceFixture()
        fixture.permissions.setAppearanceAllowed(false)
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "permission_disabled")
        #expect(fixture.settings.appearance == .system)
    }

    @Test func coordinatorRefusesWhenTheChatClosedOrTheAppLeftTheForeground() async {
        let closed = AppearanceFixture()
        let notCurrent = await closed.coordinator.handle(closed.request(), owner: closed.scope, isCurrent: { false })
        #expect(notCurrent.code == "owner_changed")
        #expect(closed.settings.appearance == .system)

        let background = AppearanceFixture()
        background.available = false
        let inactive = await background.coordinator.handle(background.request(), owner: background.scope,
                                                           isCurrent: { true })
        #expect(inactive.code == "device_unavailable")
        #expect(background.settings.appearance == .system)
    }

    @Test func coordinatorPassesTheToolsOwnCode() async {
        let fixture = AppearanceFixture()
        let result = await fixture.coordinator.handle(fixture.request(arguments: ["color": .string("violet")]),
                                                      owner: fixture.scope, isCurrent: { true })
        #expect(result.status == "failed")
        #expect(result.code == "unknown_color")
        #expect(result.payload.isEmpty)
    }

    // MARK: What Device access says

    @Test func appearanceAloneNeverAsksThePersonToOpenAChatOrCheckThePlugin() {
        #expect(DeviceToolChannelNote.noChat(enabled: [.appearance]) == nil)
        #expect(DeviceToolChannelNote.noChat(enabled: [.appearance, .calendar]) != nil)
        #expect(DeviceToolChannelNote.failed(enabled: [.appearance], needsNewerPlugin: []) == nil)
        #expect(DeviceToolChannelNote.failed(enabled: [.appearance, .calendar], needsNewerPlugin: [])
                == "Device access is not connected. Check the bighelp plugin on this host, then reopen the chat.")
    }

    @Test func anOlderPluginNamesWhatNeedsTheUpdate() {
        #expect(DeviceToolChannelNote.connected(needsNewerPlugin: []) == nil)
        #expect(DeviceToolChannelNote.connected(needsNewerPlugin: [.location])
                == "To share your location, update the bighelp plugin on this computer.")
        #expect(DeviceToolChannelNote.connected(needsNewerPlugin: [.appearance])
                == "To let agents change how bighelp looks, update the bighelp plugin on this computer.")
        #expect(DeviceToolChannelNote.failed(enabled: [.appearance, .location], needsNewerPlugin: [.appearance, .location])
                == "To share your location and let agents change how bighelp looks, update the bighelp plugin on this computer.")
    }
}

@MainActor
private final class AppearanceFixture {
    let scope = DeviceToolScope(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-a")
    let suite = "bighelp.device-appearance-tests.\(UUID().uuidString)"
    let settings: SettingsStore
    let tool: DeviceAppearanceTool
    let journal = AppearanceJournal()
    var systemRequests: [DeviceToolCapability] = []
    var saved: [Bool] = []
    var available = true
    lazy var permissions = makePermissions(saved: true)
    lazy var coordinator = DeviceToolCoordinator(
        permissions: permissions, journal: journal, clock: { 1_000 }, available: { [unowned self] in available }
    ) { [unowned self] operation, arguments, authorize in
        try tool.execute(operation: operation, arguments: arguments, authorize: authorize)
    }

    init() {
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        tool = DeviceAppearanceTool(settings: settings)
        permissions.bind(scope)
    }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    func makePermissions(saved allowed: Bool) -> DeviceToolPermissions {
        DeviceToolPermissions(
            status: { _ in .notRequested },
            request: { [unowned self] kind in systemRequests.append(kind); return .available },
            isForeground: { true }, readGrants: { _ in [] }, writeGrants: { _, _ in },
            appearanceAllowed: allowed, saveAppearanceAllowed: { [unowned self] in saved.append($0) })
    }

    func request(arguments: [String: BighelpJSONValue] = ["mode": .string("dark"), "color": .string("rose")])
        -> DeviceToolRequest {
        DeviceToolRequest(version: 1, type: "device.tool.request", requestId: "request-appearance-01",
                          deviceId: scope.deviceID, hostId: scope.hostID, authorizationEpoch: 1,
                          sessionId: "session-1", agentId: "default", turnId: "turn-1",
                          operation: "appearance.set", arguments: arguments, sentAt: 1_000, expiresAt: 1_030)
    }
}

@MainActor
private final class AppearanceJournal: DeviceToolJournal {
    private(set) var saves = 0
    func entry(requestID: String, scope: DeviceToolScope) throws -> DeviceToolJournalEntry? { nil }
    func save(_ entry: DeviceToolJournalEntry, requestID: String, scope: DeviceToolScope) throws { saves += 1 }
}
