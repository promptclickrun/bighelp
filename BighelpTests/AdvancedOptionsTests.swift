import Foundation
import Testing
@testable import Bighelp

@MainActor
struct AdvancedOptionsTests {
    private func option(_ id: String) throws -> AdvancedOption {
        try #require(AdvancedOptionsCatalog.groups.flatMap(\.options).first { $0.id == id })
    }

    private func makeStore(
        _ host: any SimpleBotHostConfiguring = SimpleBotDemoConfiguration(),
        profile: String = "default"
    ) -> AdvancedOptionsStore {
        AdvancedOptionsStore(client: host, profile: profile)
    }

    @Test func theCatalogHoldsEachSettingOnceAndExplainsEveryChoice() {
        let options = AdvancedOptionsCatalog.groups.flatMap(\.options)
        #expect(!options.isEmpty)
        #expect(Set(options.map(\.id)).count == options.count)
        for option in options {
            #expect(!option.title.isEmpty)
            #expect(!option.detail.isEmpty)
            #expect(option.id == option.path.joined(separator: "."))
            if case .choice(let choices) = option.kind {
                #expect(choices.count >= 2)
                #expect(choices.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
                #expect(choices.contains { $0.matches(option.defaultValue) })
            }
        }
    }

    @Test func approvalsOffersSmartManualAndOffEachWithAShortExplanation() throws {
        let approvals = try option("approvals.mode")
        guard case .choice(let choices) = approvals.kind else {
            Issue.record("Approvals should be a choice")
            return
        }
        #expect(choices.map(\.title) == ["Smart", "Manual", "Off"])
        #expect(choices.map(\.value) == [.string("smart"), .string("manual"), .string("off")])
        #expect(choices.allSatisfy { $0.detail.count < 160 })
    }

    @Test func settingsReadFromTheHostShowTheirFriendlyChoice() async throws {
        let host = SimpleBotDemoConfiguration()
        try await host.write([
            "approvals": .object(["mode": .string("manual"), "timeout": .integer(120)]),
            "display": .object(["busy_input_mode": .string("queue"), "show_reasoning": .boolean(false)]),
        ], profile: "default")
        let store = makeStore(host)
        await store.refresh()

        #expect(store.load == .loaded)
        #expect(try store.selectedChoice(for: option("approvals.mode"))?.title == "Manual")
        #expect(try store.selectedChoice(for: option("approvals.timeout"))?.value == .integer(120))
        #expect(try store.selectedChoice(for: option("display.busy_input_mode"))?.title == "Wait")
        #expect(try store.isOn(option("display.show_reasoning")) == false)
    }

    @Test func aSettingTheHostNeverStoredShowsHermesDefault() async throws {
        let store = makeStore()
        await store.refresh()
        let timeout = try option("approvals.timeout")

        #expect(store.currentValue(for: timeout) == nil)
        #expect(store.displayedValue(for: timeout) == timeout.defaultValue)
        #expect(try store.isOn(option("memory.memory_enabled")))
        #expect(try store.isOn(option("checkpoints.enabled")) == false)
    }

    @Test func approvalsTurnedOffInYamlIsReadAsOff() async throws {
        // YAML 1.1 reads an unquoted `off` as the boolean false.
        for stored in [BighelpJSONValue.boolean(false), .string("false"), .string("off")] {
            let host = SimpleBotDemoConfiguration()
            try await host.write(["approvals": .object(["mode": stored])], profile: "default")
            let store = makeStore(host)
            await store.refresh()
            #expect(try store.selectedChoice(for: option("approvals.mode"))?.title == "Off")
        }
    }

    @Test func aValueTheCatalogDoesNotKnowIsShownAsCustomNotGuessed() async throws {
        let host = SimpleBotDemoConfiguration()
        try await host.write(["approvals": .object(["mode": .string("paranoid")])], profile: "default")
        let store = makeStore(host)
        await store.refresh()
        let approvals = try option("approvals.mode")

        #expect(store.selectedChoice(for: approvals) == nil)
        #expect(store.customDescription(for: approvals) == "paranoid")
    }

    @Test func choosingApprovalsOffIsAllowedHere() async throws {
        let host = SimpleBotDemoConfiguration()
        let store = makeStore(host)
        await store.refresh()
        let approvals = try option("approvals.mode")

        await store.set(approvals, to: .string("off"))

        #expect(store.errorMessage == nil)
        #expect(try await host.read(profile: "default")["approvals"]?.object?["mode"] == .string("off"))
        #expect(store.selectedChoice(for: approvals)?.title == "Off")
    }

    @Test func aChangeWritesOnlyThatKeyAndKeepsItsSiblings() async throws {
        let host = RecordingConfiguration()
        host.config = [
            "approvals": .object(["mode": .string("smart"), "timeout": .integer(300)]),
            "display": .object(["busy_input_mode": .string("steer")]),
        ]
        let store = makeStore(host)
        await store.refresh()

        await store.set(try option("approvals.mode"), to: .string("manual"))

        #expect(host.writes.count == 1)
        #expect(host.writes.first?.config == ["approvals": .object(["mode": .string("manual")])])
        #expect(host.writes.first?.profile == "default")
        #expect(host.config["approvals"]?.object?["timeout"] == .integer(300))
        #expect(host.config["display"]?.object?["busy_input_mode"] == .string("steer"))
    }

    @Test func aSettingSavesForTheBotItBelongsTo() async throws {
        let host = SimpleBotDemoConfiguration()
        let store = makeStore(host, profile: "nova")
        await store.refresh()
        await store.set(try option("memory.write_approval"), to: .boolean(true))

        #expect(try await host.read(profile: "nova")["memory"]?.object?["write_approval"] == .boolean(true))
        #expect(try await host.read(profile: "default")["memory"] == nil)
    }

    @Test func numbersCompareEqualWhetherTheHostSendsThemAsIntegersOrDoubles() async throws {
        let host = SimpleBotDemoConfiguration()
        try await host.write(["approvals": .object(["timeout": .number(300)])], profile: "default")
        let store = makeStore(host)
        await store.refresh()

        #expect(try store.selectedChoice(for: option("approvals.timeout"))?.title != nil)
        #expect(try store.selectedChoice(for: option("approvals.timeout"))?.value == .integer(300))
    }

    @Test func aSaveTheHostSilentlyIgnoresIsReportedAndShowsTheRealValue() async throws {
        let host = DroppingConfiguration()
        host.config = ["approvals": .object(["mode": .string("smart")])]
        let store = makeStore(host)
        await store.refresh()
        let approvals = try option("approvals.mode")

        await store.set(approvals, to: .string("manual"))

        #expect(store.errorMessage != nil)
        #expect(store.selectedChoice(for: approvals)?.title == "Smart")
        #expect(!store.isSaving)
    }

    @Test func aFailedSaveSaysSoPlainlyAndKeepsTheOldValue() async throws {
        let host = ThrowingConfiguration()
        host.config = ["display": .object(["show_reasoning": .boolean(true)])]
        let store = makeStore(host)
        await store.refresh()
        let reasoning = try option("display.show_reasoning")

        await store.set(reasoning, to: .boolean(false))

        #expect(store.errorMessage == "The computer didn't save that. Try again in a moment.")
        #expect(store.isOn(reasoning))
        #expect(!store.isSaving)
    }

    @Test func aComputerThatCannotBeReadIsUnavailableNotEmpty() async {
        let host = ThrowingConfiguration()
        host.failsReads = true
        let store = makeStore(host)
        await store.refresh()
        #expect(store.load == .unavailable)
    }

    @Test func settingsAreNotWrittenBeforeTheComputerHasBeenRead() async throws {
        let host = RecordingConfiguration()
        let store = makeStore(host)
        await store.set(try option("approvals.mode"), to: .string("manual"))
        #expect(host.writes.isEmpty)
    }
}

@MainActor
private final class RecordingConfiguration: SimpleBotHostConfiguring {
    var config: [String: BighelpJSONValue] = [:]
    var writes: [(config: [String: BighelpJSONValue], profile: String)] = []

    func read(profile: String) async throws -> [String: BighelpJSONValue] { config }

    func write(_ config: [String: BighelpJSONValue], profile: String) async throws {
        writes.append((config, profile))
        self.config = SimpleBotDemoConfiguration.merge(self.config, config)
    }
}

/// Accepts every save and answers ok, but keeps nothing.
@MainActor
private final class DroppingConfiguration: SimpleBotHostConfiguring {
    var config: [String: BighelpJSONValue] = [:]
    func read(profile: String) async throws -> [String: BighelpJSONValue] { config }
    func write(_ config: [String: BighelpJSONValue], profile: String) async throws {}
}

@MainActor
private final class ThrowingConfiguration: SimpleBotHostConfiguring {
    var config: [String: BighelpJSONValue] = [:]
    var failsReads = false
    func read(profile: String) async throws -> [String: BighelpJSONValue] {
        if failsReads { throw WorkspaceClientError.transportUnavailable }
        return config
    }
    func write(_ config: [String: BighelpJSONValue], profile: String) async throws {
        throw WorkspaceClientError.transportUnavailable
    }
}
