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

    private func loadedStore(_ config: [String: BighelpJSONValue]) async -> (AdvancedOptionsStore, FakeHost) {
        let host = FakeHost()
        host.config = config
        let store = makeStore(host)
        await store.refresh()
        return (store, host)
    }

    // MARK: The catalog

    @Test func theCatalogHoldsEachSettingOnceAndExplainsEveryChoice() {
        let rows = AdvancedOptionsCatalog.groups.flatMap(\.rows)
        #expect(Set(rows.map(\.id)).count == rows.count)
        for option in AdvancedOptionsCatalog.groups.flatMap(\.options) {
            #expect(!option.title.isEmpty && !option.detail.isEmpty)
            switch option.kind {
            case .choice(let choices, let unknownMeans):
                #expect(choices.count >= 2)
                #expect(choices.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty && $0.detail.count < 160 })
                #expect(choices.contains { $0.matches(option.defaultValue) })
                if let unknownMeans { #expect(choices.contains { $0.matches(unknownMeans) }) }
            case .duration(let seconds):
                #expect(seconds.contains(option.defaultValue.integer ?? -1))
            case .toggle, .text:
                break
            }
        }
        #expect(AdvancedOptionsCatalog.groups.last?.id == "experts", "Expert pages come last")
    }

    @Test func approvalsOffersSmartManualAndOffAndOnlyOffAsksFirst() throws {
        guard case .choice(let choices, _) = try option("approvals.mode").kind else {
            Issue.record("Approvals should be a choice")
            return
        }
        #expect(choices.map(\.title) == ["Smart", "Manual", "Off"])
        #expect(choices.map(\.value) == [.string("smart"), .string("manual"), .string("off")])
        #expect(choices.map { $0.confirmation != nil } == [false, false, true])
    }

    // MARK: Reading

    @Test func settingsReadFromTheHostShowTheirFriendlyChoice() async throws {
        let (store, _) = await loadedStore([
            "approvals": .object(["mode": .string("manual"), "timeout": .integer(120), "cron_mode": .string("approve")]),
            "display": .object(["show_reasoning": .boolean(false)]),
        ])
        #expect(store.load == .loaded)
        #expect(try store.valueText(for: option("approvals.mode")) == "Manual")
        #expect(try store.valueText(for: option("approvals.timeout")) == "2 minutes")
        #expect(try store.valueText(for: option("approvals.cron_mode")) == "Allow")
        #expect(try store.isOn(option("display.show_reasoning")) == false)
    }

    @Test func aSettingTheHostNeverStoredShowsHermesDefault() async throws {
        let (store, _) = await loadedStore([:])
        let timeout = try option("approvals.timeout")
        #expect(store.currentValue(for: timeout) == nil)
        #expect(store.valueText(for: timeout) == "5 minutes")
        #expect(try store.valueText(for: option("approvals.mode")) == "Smart")
        #expect(try store.isOn(option("memory.memory_enabled")))
        #expect(try store.isOn(option("checkpoints.enabled")) == false)
    }

    @Test func yamlBooleansReadTheWayHermesReadsThem() async throws {
        // YAML 1.1 reads bare on/off/yes/no as booleans. Hermes runs approvals `true` as manual,
        // `false` as off, and any other word as manual.
        let cases: [(BighelpJSONValue, String)] = [
            (.boolean(false), "Off"), (.boolean(true), "Manual"), (.string("OFF"), "Off"),
            (.string("paranoid"), "Manual"), (.string("false"), "Manual"),
        ]
        for (stored, expected) in cases {
            let (store, _) = await loadedStore(["approvals": .object(["mode": stored])])
            #expect(try store.valueText(for: option("approvals.mode")) == expected, "\(stored)")
        }
        for (stored, expected) in [(BighelpJSONValue.boolean(true), "On"), (.boolean(false), "Off")] {
            let (store, _) = await loadedStore(["display": .object(["memory_notifications": stored])])
            #expect(try store.valueText(for: option("display.memory_notifications")) == expected)
        }
    }

    @Test func aValueNoChoiceNamesIsShownAsItIsNotGuessed() async throws {
        let (store, _) = await loadedStore(["display": .object(["memory_notifications": .string("quiet")])])
        let notes = try option("display.memory_notifications")
        #expect(store.selectedChoice(for: notes) == nil)
        #expect(store.valueText(for: notes) == "quiet")
    }

    @Test func aWaitIsShownInMinutesWhateverTheComputerSaved() async throws {
        let timeout = try option("approvals.timeout")
        for (stored, expected) in [(BighelpJSONValue.integer(900), "15 minutes"), (.number(300), "5 minutes"),
                                   (.string("600"), "10 minutes"), (.integer(450), "7 minutes, 30 seconds")] {
            let (store, _) = await loadedStore(["approvals": .object(["timeout": stored])])
            #expect(store.valueText(for: timeout) == expected)
        }
    }

    @Test func rowsShowOnlyWhereTheyApply() async throws {
        let rules = try option("approvals.smart_policy")
        let askFirst = try option("memory.write_approval")
        let (smart, _) = await loadedStore(["memory": .object(["write_approval": .boolean(true)])])
        #expect(smart.isShown(rules), "Rules for Smart under Smart, Hermes' default")
        #expect(smart.isShown(askFirst), "Ask before saving shows while it's on, so it can be turned off")

        let (manual, _) = await loadedStore(["approvals": .object(["mode": .string("manual")])])
        #expect(!manual.isShown(rules))
        #expect(!manual.isShown(askFirst))
    }

    // MARK: Saving

    @Test func approvalsOffWaitsForAYes() async throws {
        let (store, host) = await loadedStore(["approvals": .object(["mode": .string("smart")])])
        let approvals = try option("approvals.mode")
        guard case .choice(let choices, _) = approvals.kind, let off = choices.last else {
            Issue.record("Approvals should be a choice")
            return
        }

        await store.choose(off, for: approvals)
        #expect(host.writes.isEmpty, "Nothing is saved before the yes")
        #expect(store.pendingChoice?.choice == off)
        store.cancelPendingChoice()
        #expect(store.pendingChoice == nil)
        #expect(host.writes.isEmpty)

        await store.choose(off, for: approvals)
        let pending = try #require(store.pendingChoice)
        await store.confirm(pending)
        #expect(host.writes.map { $0.config } == [["approvals": .object(["mode": .string("off")])]])
        #expect(store.valueText(for: approvals) == "Off")
        #expect(store.pendingChoice == nil)
    }

    @Test func backgroundJobsIsAnOnOffSwitchThatLeavesOtherValuesAlone() async throws {
        let follow = try option("display.background_process_notifications")
        let (store, host) = await loadedStore(["display": .object(["background_process_notifications": .string("all")])])
        #expect(store.isOn(follow), "Every value but off follows up")
        #expect(host.writes.isEmpty)
        #expect(host.config["display"]?.object?["background_process_notifications"] == .string("all"))

        await store.setOn(follow, false)
        #expect(host.config["display"]?.object?["background_process_notifications"] == .string("off"))
        #expect(!store.isOn(follow))
        await store.setOn(follow, true)
        #expect(host.config["display"]?.object?["background_process_notifications"] == .string("concise"))

        let (bare, _) = await loadedStore(["display": .object(["background_process_notifications": .boolean(false)])])
        #expect(!bare.isOn(follow), "YAML's bare off")
    }

    @Test func aChangeWritesOnlyThatKeyAndKeepsItsSiblings() async throws {
        let (store, host) = await loadedStore([
            "approvals": .object(["mode": .string("smart"), "timeout": .integer(300)]),
        ])
        await store.setSeconds(try option("approvals.timeout"), 900)

        #expect(host.writes.map { $0.config } == [["approvals": .object(["timeout": .integer(900)])]])
        #expect(host.writes.first?.profile == "default")
        #expect(host.config["approvals"]?.object?["mode"] == .string("smart"))
        #expect(store.message == nil)
    }

    @Test func rulesForSmartAreSavedTrimmed() async throws {
        let (store, host) = await loadedStore([:])
        let rules = try option("approvals.smart_policy")
        #expect(store.valueText(for: rules) == "None")
        await store.setText(rules, "  Always ask before deleting files.  ")
        #expect(host.config["approvals"]?.object?["smart_policy"] == .string("Always ask before deleting files."))
        #expect(store.valueText(for: rules) == "Set")
    }

    @Test func aSettingSavesForTheBotItBelongsTo() async throws {
        let host = SimpleBotDemoConfiguration()
        let store = makeStore(host, profile: "nova")
        await store.refresh()
        await store.setOn(try option("checkpoints.enabled"), true)

        #expect(try await host.read(profile: "nova")["checkpoints"]?.object?["enabled"] == .boolean(true))
        #expect(try await host.read(profile: "default")["checkpoints"] == nil)
    }

    @Test func aSaveTheHostSilentlyIgnoresIsReportedAndShowsTheRealValue() async throws {
        let (store, host) = await loadedStore(["approvals": .object(["mode": .string("smart")])])
        host.dropsWrites = true
        let approvals = try option("approvals.mode")
        await store.set(approvals, to: .string("manual"))

        #expect(store.message == .notKept)
        #expect(store.valueText(for: approvals) == "Smart")
        #expect(!store.isSaving)
    }

    @Test func aFailedSaveSaysSoPlainlyAndKeepsTheOldValue() async throws {
        let (store, host) = await loadedStore(["display": .object(["show_reasoning": .boolean(true)])])
        host.failsWrites = true
        let reasoning = try option("display.show_reasoning")
        await store.setOn(reasoning, false)

        #expect(store.message == .notSaved)
        #expect(store.message?.isProblem == true)
        #expect(store.isOn(reasoning))
        #expect(!store.isSaving)
    }

    @Test func aSaveThatCouldNotBeCheckedSaysItWasSentNotThatItFailed() async throws {
        let (store, host) = await loadedStore(["display": .object(["show_reasoning": .boolean(true)])])
        host.stopsAnsweringAfterAWrite = true
        let reasoning = try option("display.show_reasoning")
        await store.setOn(reasoning, false)

        #expect(host.config["display"]?.object?["show_reasoning"] == .boolean(false), "The save went through")
        #expect(store.message == .sentUnchecked)
        #expect(store.message?.isProblem == false)
        #expect(!(store.message?.text.contains("didn't save") ?? true))
        #expect(!store.isOn(reasoning), "It shows what was sent")
    }

    @Test func settingsAreNotWrittenBeforeTheComputerHasBeenRead() async throws {
        let host = FakeHost()
        let store = makeStore(host)
        await store.set(try option("approvals.mode"), to: .string("manual"))
        #expect(host.writes.isEmpty)
    }

    // MARK: Refreshing

    @Test func aComputerThatCannotBeReadIsUnavailableNotEmpty() async {
        let host = FakeHost()
        host.failsReads = true
        let store = makeStore(host)
        await store.refresh()
        #expect(store.load == .unavailable)
    }

    @Test func aFailedRefreshSaysTheValuesMayBeOutOfDateAndKeepsThem() async throws {
        let (store, host) = await loadedStore(["approvals": .object(["mode": .string("manual")])])
        host.failsReads = true
        await store.refresh()

        #expect(store.load == .loaded)
        #expect(store.message == .outOfDate)
        #expect(try store.valueText(for: option("approvals.mode")) == "Manual")

        host.failsReads = false
        await store.refresh()
        #expect(store.message == nil)
    }

    @Test func aReadThatStartedBeforeASaveDoesNotUndoIt() async throws {
        let (store, host) = await loadedStore(["approvals": .object(["mode": .string("smart")])])
        let approvals = try option("approvals.mode")
        host.holdsNextRead = true
        let reread = Task { await store.refresh() }
        while !host.isHoldingARead { await Task.yield() }

        await store.set(approvals, to: .string("manual"))
        host.releaseHeldRead()
        await reread.value

        #expect(store.valueText(for: approvals) == "Manual", "The older read answered last but is dropped")
    }
}

/// A computer's config for these tests, merged like Hermes merges a save.
@MainActor
private final class FakeHost: SimpleBotHostConfiguring {
    var config: [String: BighelpJSONValue] = [:]
    private(set) var writes: [(config: [String: BighelpJSONValue], profile: String)] = []
    var failsReads = false
    var failsWrites = false
    /// Answers every save but keeps nothing.
    var dropsWrites = false
    /// A save goes through, then the computer stops answering.
    var stopsAnsweringAfterAWrite = false
    /// The next read waits for `releaseHeldRead()`, then answers with what was saved when it began.
    var holdsNextRead = false
    private var heldRead: CheckedContinuation<Void, Never>?

    var isHoldingARead: Bool { heldRead != nil }

    func read(profile: String) async throws -> [String: BighelpJSONValue] {
        if failsReads { throw WorkspaceClientError.transportUnavailable }
        let snapshot = config
        if holdsNextRead {
            holdsNextRead = false
            await withCheckedContinuation { heldRead = $0 }
        }
        return snapshot
    }

    func write(_ config: [String: BighelpJSONValue], profile: String) async throws {
        if failsWrites { throw WorkspaceClientError.transportUnavailable }
        writes.append((config, profile))
        if !dropsWrites { self.config = SimpleBotDemoConfiguration.merge(self.config, config) }
        if stopsAnsweringAfterAWrite { failsReads = true }
    }

    func releaseHeldRead() {
        heldRead?.resume()
        heldRead = nil
    }
}
