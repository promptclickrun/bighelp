import Foundation
import Testing
@testable import Bighelp

/// Settings › Notifications › Channels: what this device asks every computer for.
@MainActor
struct ChannelAlertsTests {
    private func defaults() -> UserDefaults {
        let name = "ChannelAlertsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aDeviceThatNeverPickedGetsEveryChannel() {
        let defaults = defaults()
        #expect(BighelpChannelAlerts.mode(defaults) == .all)
        #expect(BighelpChannelAlerts.current(defaults) == .init(other: true, choices: [:]))
    }

    @Test func eachModeBecomesTheRulesAComputerKeeps() {
        let defaults = defaults()
        defaults.set(BighelpChannelAlerts.json(["imsg": false, "telegram": true]), forKey: BighelpChannelAlerts.choicesKey)
        defaults.set(false, forKey: BighelpChannelAlerts.otherKey)

        defaults.set("bighelp", forKey: BighelpChannelAlerts.modeKey)
        #expect(BighelpChannelAlerts.current(defaults) == .init(other: false, choices: [:]), "Choose's picks stay out")

        defaults.set("choose", forKey: BighelpChannelAlerts.modeKey)
        #expect(BighelpChannelAlerts.current(defaults) == .init(other: false, choices: ["imsg": false, "telegram": true]))

        defaults.set("all", forKey: BighelpChannelAlerts.modeKey)
        #expect(BighelpChannelAlerts.current(defaults) == .init(other: true, choices: [:]))

        defaults.set("something-newer", forKey: BighelpChannelAlerts.modeKey)
        #expect(BighelpChannelAlerts.mode(defaults) == .all, "An unknown saved mode is All channels")
    }

    @Test func onlyRealChannelNamesAreKeptAndSent() {
        #expect(BighelpChannelAlerts.isChannel("imsg"))
        #expect(BighelpChannelAlerts.isChannel("whatsapp_cloud"))
        #expect(!BighelpChannelAlerts.isChannel("bighelp"), "bighelp always notifies, so it has no switch")
        #expect(!BighelpChannelAlerts.isChannel("Telegram"))
        #expect(!BighelpChannelAlerts.isChannel("_imsg"))
        #expect(!BighelpChannelAlerts.isChannel("i message"))
        #expect(!BighelpChannelAlerts.isChannel("télégram"))
        #expect(!BighelpChannelAlerts.isChannel(String(repeating: "a", count: 41)))
        #expect(BighelpChannelAlerts.choices(from: #"{"imsg":true,"Bad":false,"bighelp":false}"#) == ["imsg": true])
        #expect(BighelpChannelAlerts.choices(from: "not json").isEmpty)
    }

    @Test func choicesStayWithinWhatAComputerAccepts() {
        let defaults = defaults()
        let many = Dictionary(uniqueKeysWithValues: (0..<80).map { ("c\($0)", false) })
        defaults.set(BighelpChannelAlerts.json(many), forKey: BighelpChannelAlerts.choicesKey)
        defaults.set("choose", forKey: BighelpChannelAlerts.modeKey)
        #expect(BighelpChannelAlerts.current(defaults).choices.count == BighelpChannelAlerts.maximumChoices)
    }

    @Test func aComputersAnswerMustMatchExactly() {
        let sent = BighelpChannelAlerts.Rules(other: false, choices: ["imsg": true])
        #expect(BighelpChannelAlerts.Rules(sent.body) == sent)
        #expect(BighelpChannelAlerts.Rules(.object(["other": .boolean(false)])) == nil)
        #expect(BighelpChannelAlerts.Rules(.object(["other": .boolean(false), "choices": .object(["imsg": .string("yes")])])) == nil)
        #expect(BighelpChannelAlerts.Rules(.object(["other": .boolean(true), "choices": .object([:]), "mode": .string("all")])) == nil)
        #expect(BighelpChannelAlerts.Rules(nil) == nil)
    }

    @Test func channelsFromEveryComputerShowOnceByName() {
        let first = [BighelpChannelAlerts.Channel(id: "telegram", name: "Telegram"),
                     BighelpChannelAlerts.Channel(id: "imsg", name: "iMessage")].compactMap { $0 }
        let second = [BighelpChannelAlerts.Channel(id: "imsg", name: "Messages"),
                      BighelpChannelAlerts.Channel(id: "discord", name: "Discord")].compactMap { $0 }
        let merged = BighelpChannelAlerts.merged([first, second])
        #expect(merged.map(\.id) == ["discord", "imsg", "telegram"])
        #expect(merged.first { $0.id == "imsg" }?.name == "iMessage", "The first computer's name wins")
        #expect(BighelpChannelAlerts.Channel(id: "imsg", name: "  ") == nil)
        #expect(BighelpChannelAlerts.Channel(id: "bighelp", name: "bighelp") == nil)
    }

    @Test func aLedgerFromAnOlderBuildStillReads() throws {
        let older = #"{"accountScope":"a","accountID":"b","hostConnectionID":"c","profile":"default","enrollmentID":"e","richLiveActivitySupported":true,"enabled":true,"revokePending":false,"subscriptions":[]}"#
        let record = try JSONDecoder().decode(BighelpManagedEnrollmentRecord.self, from: Data(older.utf8))
        #expect(record.channelAlertsSent == nil)
        var updated = record
        updated.channelAlertsSent = .init(other: false, choices: ["imsg": true])
        let again = try JSONDecoder().decode(BighelpManagedEnrollmentRecord.self, from: JSONEncoder().encode(updated))
        #expect(again.channelAlertsSent == updated.channelAlertsSent)
    }
}
