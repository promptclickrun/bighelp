import Foundation
import Testing
import UIKit
@testable import Bighelp

/// The agent's `iphone_shortcuts` tool on the phone: the names the person allows, the checks before
/// anything opens, the URL that opens Shortcuts, and what comes back. Names and texts are made up.
@MainActor
struct DeviceShortcutsToolTests {
    // MARK: Catalog

    @Test func shortcutsRunIsJournaledButItsOutputIsNeverKept() {
        #expect(DeviceToolCapability.shortcuts.pluginFeature == "native-device-shortcuts-v1")
        let run = DeviceToolCatalog.operations["shortcuts.run"]
        #expect(run?.journaled == true)
        #expect(run?.liveOnlyKeys == ["output", "truncated"])
        #expect(run?.keptKeys == ["status"])
        #expect(DeviceToolCatalog.operations["shortcuts.list"]?.journaled == false)
        #expect(DeviceToolCatalog.durableKeys == ["id", "revision", "deleted"])
    }

    @Test func noIOSPermissionIsNeeded() async {
        let fixture = ToolFixture()
        #expect(await fixture.tool.status() == .available)
        #expect(await fixture.tool.request() == .available)
    }

    // MARK: Names

    @Test func theListHoldsExactNamesOnTheDevice() {
        let defaults = freshDefaults()
        let store = ShortcutNameStore(defaults: defaults)
        #expect(store.add("  Morning Routine \n") == .added)
        #expect(store.add("morning routine") == .added, "Names are exact, so case counts")
        #expect(store.add("Morning Routine") == .duplicate)
        #expect(store.add("   ") == .empty)
        #expect(store.add("Line\nBreak") == .invalid)
        #expect(store.add(String(repeating: "n", count: 101)) == .tooLong)
        #expect(store.add(String(repeating: "n", count: 100)) == .added)
        #expect(defaults.stringArray(forKey: "bighelp.device-tools.shortcuts.v1")?.first == "Morning Routine")
        #expect(ShortcutNameStore(defaults: defaults).names == store.names)
        store.remove("Morning Routine")
        #expect(ShortcutNameStore(defaults: defaults).names == ["morning routine", String(repeating: "n", count: 100)])
    }

    @Test func theListHoldsFiftyAtMost() {
        let store = ShortcutNameStore(defaults: freshDefaults())
        for index in 1...50 { #expect(store.add("Shortcut \(index)") == .added) }
        #expect(store.add("One more") == .full)
        #expect(store.names.count == 50)
        store.remove("Shortcut 7")
        #expect(store.add("One more") == .added)
    }

    @Test func aDamagedSavedListLoadsOnlyWellFormedNames() {
        let defaults = freshDefaults()
        let stored = ["Good", "Good", "", "Bad\u{0}Name", String(repeating: "x", count: 101)]
            + (1...80).map { "Name \($0)" }
        defaults.set(stored, forKey: "bighelp.device-tools.shortcuts.v1")
        let names = ShortcutNameStore(defaults: defaults).names
        #expect(names.count == 50)
        #expect(names.first == "Good" && names.filter { $0 == "Good" }.count == 1)
        #expect(!names.contains(""))
    }

    @Test func demoModeKeepsNamesOnlyForTheLaunch() {
        let defaults = freshDefaults()
        let store = ShortcutNameStore(defaults: defaults, persists: false)
        #expect(store.add("Morning Routine") == .added)
        #expect(defaults.object(forKey: "bighelp.device-tools.shortcuts.v1") == nil)
        #expect(ShortcutNameStore(defaults: defaults, persists: false).names.isEmpty)
    }

    @Test func listReturnsTheNamesAndNothingElse() async throws {
        let fixture = ToolFixture()
        let result = try await fixture.execute("shortcuts.list")
        #expect(result == ["shortcuts": .array([.object(["name": .string("Morning Routine")]),
                                                .object(["name": .string("Water Plants")])])])
        await #expect(throws: DeviceShortcutsTool.Failure.invalidArguments) {
            try await fixture.execute("shortcuts.list", ["name": .string("Morning Routine")])
        }
        #expect(fixture.app.opened.isEmpty)
    }

    // MARK: Checks before anything opens

    @Test func badArgumentsOpenNothing() async {
        let fixture = ToolFixture()
        let bad: [[String: BighelpJSONValue]] = [
            [:],
            ["name": .string("")],
            ["name": .integer(3)],
            ["name": .string("Morning Routine"), "extra": .string("x")],
            ["name": .string("Morning Routine"), "input": .integer(1)],
            ["name": .string("Morning Routine"), "input": .string(String(repeating: "i", count: 4001))],
            ["name": .string(String(repeating: "n", count: 101))],
        ]
        for arguments in bad {
            await #expect(throws: DeviceShortcutsTool.Failure.invalidArguments) {
                try await fixture.execute("shortcuts.run", arguments)
            }
        }
        #expect(fixture.app.opened.isEmpty)
        #expect(!fixture.handoff.isActive)
    }

    @Test func aNameThatIsNotOnTheListIsNotAllowed() async {
        let fixture = ToolFixture()
        for name in ["Delete Everything", "morning routine", "Morning Routine "] {
            await #expect(throws: DeviceShortcutsTool.Failure.notAllowed) {
                try await fixture.execute("shortcuts.run", ["name": .string(name)])
            }
        }
        #expect(fixture.app.opened.isEmpty)
    }

    @Test func withNoNamesAddedNothingRuns() async {
        let fixture = ToolFixture(names: [])
        await #expect(throws: DeviceShortcutsTool.Failure.notAllowed) {
            try await fixture.execute("shortcuts.run", ["name": .string("Morning Routine")])
        }
        #expect(fixture.app.opened.isEmpty)
    }

    @Test func authorizationIsCheckedBeforeOpeningAndAfterTheCallback() async {
        let fixture = ToolFixture()
        fixture.allow = false
        await #expect(throws: TestRetired.self) {
            try await fixture.execute("shortcuts.run", ["name": .string("Morning Routine")])
        }
        #expect(fixture.app.opened.isEmpty, "A retired call must not leave for Shortcuts")

        // Retired while Shortcuts runs: the answer is never delivered.
        let later = ToolFixture()
        later.app.behavior = .output("secret")
        later.app.onOpen = { later.allow = false }
        await #expect(throws: TestRetired.self) {
            try await later.execute("shortcuts.run", ["name": .string("Morning Routine")])
        }
        #expect(!later.handoff.isActive)
    }

    // MARK: Opening Shortcuts

    @Test func theRunURLIsShortcutsXCallbackURLWithOneValuePerPart() throws {
        let id = UUID()
        let name = "Plan & Go = 100% #1+café"
        let input = "line one\nline two & more=ok?"
        let url = try #require(DeviceShortcutsTool.runURL(name: name, input: input, runID: id))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "shortcuts" && components.host == "x-callback-url" && components.path == "/run-shortcut")
        let items = components.queryItems ?? []
        #expect(items.map(\.name) == ["name", "input", "text", "x-success", "x-cancel", "x-error"])
        #expect(items[0].value == name)
        #expect(items[1].value == "text" && items[2].value == input)
        // The raw query splits into exactly those six parts, so no value can add a parameter.
        #expect(components.percentEncodedQuery?.split(separator: "&").count == 6)
        for (item, kind) in zip(items.suffix(3), [DeviceToolHandoff.CallbackKind.success, .cancel, .error]) {
            #expect(item.value == DeviceToolHandoff.callbackURL(tool: "shortcuts", kind: kind, runID: id)?.absoluteString)
        }
        #expect(DeviceShortcutsTool.runURL(name: name, input: nil, runID: id).flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
        } == ["name", "x-success", "x-cancel", "x-error"])
    }

    @Test func eachRunGetsItsOwnUnguessableID() async throws {
        let fixture = ToolFixture()
        fixture.app.behavior = .output("a")
        let first = try await fixture.execute("shortcuts.run", ["name": .string("Morning Routine")])
        let second = try await fixture.execute("shortcuts.run", ["name": .string("Morning Routine")])
        let ids = [first, second].compactMap { $0["id"]?.string }
        #expect(ids.count == 2 && ids[0] != ids[1])
        for id in ids { #expect(UUID(uuidString: id) != nil && id == id.lowercased()) }
        #expect(fixture.app.opened.count == 2)
        #expect(fixture.app.opened[0].absoluteString.contains(ids[0]))
        #expect(!fixture.app.opened[0].absoluteString.contains(ids[1]))
    }

    // MARK: What comes back

    @Test func aFinishedShortcutReturnsItsOutput() async throws {
        let fixture = ToolFixture()
        fixture.app.behavior = .output("Three plants watered.\nAll done ✓")
        let result = try await fixture.execute("shortcuts.run", ["name": .string("Water Plants"), "input": .string("front room")])
        #expect(result["status"] == .string("completed"))
        #expect(result["output"] == .string("Three plants watered.\nAll done ✓"))
        #expect(result["truncated"] == .boolean(false))
        #expect(Set(result.keys) == ["id", "status", "output", "truncated"])
        #expect(fixture.app.lastInput == "front room")
        #expect(fixture.app.lastName == "Water Plants")
        #expect(fixture.time.ended == 1 && fixture.time.releases == 1)
    }

    @Test func aShortcutWithNoOutputReturnsEmptyText() async throws {
        let fixture = ToolFixture()
        fixture.app.behavior = .output("")
        let result = try await fixture.execute("shortcuts.run", ["name": .string("Water Plants")])
        #expect(result["status"] == .string("completed") && result["output"] == .string(""))
    }

    @Test func aLongOutputIsCutAndSaysSo() async throws {
        let fixture = ToolFixture()
        fixture.app.behavior = .output(String(repeating: "é", count: 8001))
        let cut = try await fixture.execute("shortcuts.run", ["name": .string("Water Plants")])
        #expect(cut["output"]?.string?.count == 8000 && cut["truncated"] == .boolean(true))
        fixture.app.behavior = .output(String(repeating: "é", count: 8000))
        let whole = try await fixture.execute("shortcuts.run", ["name": .string("Water Plants")])
        #expect(whole["output"]?.string?.count == 8000 && whole["truncated"] == .boolean(false))
    }

    @Test func controlCharactersAreDroppedFromTheOutput() {
        let result = DeviceShortcutsTool.payload(id: "x", status: "completed", text: "a\u{0}b\u{7}c\nd\te\r\u{1B}[0m")
        #expect(result["output"] == .string("abc\nd\te[0m"))
        #expect(DeviceShortcutsTool.payload(id: "x", status: "cancelled", text: nil)["output"] == .string(""))
    }

    @Test func cancellingInShortcutsIsCancelled() async throws {
        let fixture = ToolFixture()
        fixture.app.behavior = .cancel
        let result = try await fixture.execute("shortcuts.run", ["name": .string("Water Plants")])
        #expect(result["status"] == .string("cancelled") && result["output"] == .string(""))
    }

    @Test func aShortcutThatErrorsIsFailedWithShortcutsOwnWords() async throws {
        let fixture = ToolFixture()
        fixture.app.behavior = .error("The shortcut could not find a photo.")
        let result = try await fixture.execute("shortcuts.run", ["name": .string("Water Plants")])
        #expect(result["status"] == .string("failed"))
        #expect(result["output"] == .string("The shortcut could not find a photo."))
    }

    @Test func shortcutsThatCannotBeOpenedIsUnavailableAndNothingRan() async {
        let fixture = ToolFixture()
        fixture.app.behavior = .refuse
        await #expect(throws: AppleDeviceToolError.unavailable) {
            try await fixture.execute("shortcuts.run", ["name": .string("Water Plants")])
        }
        #expect(!fixture.handoff.isActive)
        #expect(fixture.time.ended == 1)
    }

    @Test func noAnswerByTheDeadlineIsAnUnknownOutcomeNotAFailure() async {
        let fixture = ToolFixture(timeout: .milliseconds(50))
        fixture.app.behavior = .silent
        await #expect(throws: DeviceShortcutsTool.Failure.outcomeUnknown) {
            try await fixture.execute("shortcuts.run", ["name": .string("Water Plants")])
        }
        #expect(!fixture.handoff.isActive)
        #expect(fixture.time.ended == 1 && fixture.time.releases == 1)
    }

    @Test func aLateCallbackAfterTheDeadlineChangesNothing() async throws {
        let fixture = ToolFixture(timeout: .milliseconds(50))
        fixture.app.behavior = .silent
        await #expect(throws: DeviceShortcutsTool.Failure.outcomeUnknown) {
            try await fixture.execute("shortcuts.run", ["name": .string("Water Plants")])
        }
        let success = try #require(fixture.app.callbackURL(.success, output: "too late"))
        #expect(fixture.handoff.handleCallback(success), "It is still one of ours, so it never opens a screen")
        #expect(!fixture.handoff.isActive)
        #expect(fixture.time.ended == 1)
    }

    @Test func aSecondRunWhileOneIsOutIsBusy() async throws {
        let fixture = ToolFixture()
        fixture.app.behavior = .silent
        let first = Task { @MainActor in
            try? await fixture.execute("shortcuts.run", ["name": .string("Water Plants")])
        }
        for _ in 0..<200 where !fixture.handoff.isActive { try await Task.sleep(for: .milliseconds(5)) }
        await #expect(throws: DeviceShortcutsTool.Failure.busy) {
            try await fixture.execute("shortcuts.run", ["name": .string("Morning Routine")])
        }
        #expect(fixture.app.opened.count == 1, "The refused run must not open Shortcuts")
        first.cancel()
        _ = await first.value
    }

    // MARK: Through the coordinator, across leaving the app

    @Test func theCallStaysAliveWhileBighelpIsInTheBackground() async {
        let fixture = CoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .shortcuts)
        fixture.tool.app.behavior = .output("Three plants watered.")
        fixture.tool.app.onOpen = { fixture.applicationState = .background }
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.status == "completed", "\(result.code ?? "")")
        #expect(result.payload["output"] == .string("Three plants watered."))
        #expect(result.payload["status"] == .string("completed"))
        #expect(fixture.tool.app.opened.count == 1)
    }

    @Test func withoutTheHandoffLeavingTheAppRetiresTheCall() async {
        // The same flow with the app's old rule (open means active): the call fails after the callback.
        let fixture = CoordinatorFixture(usesHandoff: false)
        await fixture.permissions.setEnabled(true, for: .shortcuts)
        fixture.tool.app.behavior = .output("Three plants watered.")
        fixture.tool.app.onOpen = { fixture.applicationState = .background }
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.status == "failed" && result.code == "device_unavailable")
        #expect(result.payload.isEmpty)
    }

    @Test func theOutputNeverReachesTheJournalAndARetryNeverRunsItAgain() async {
        let fixture = CoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .shortcuts)
        fixture.tool.app.behavior = .output("private words from a shortcut")
        let request = fixture.request()
        let first = await fixture.coordinator.handle(request, owner: fixture.scope, isCurrent: { true })
        #expect(first.payload["output"] == .string("private words from a shortcut"))

        let saved = fixture.journal.entries.values.compactMap(\.result)
        #expect(saved.count == 1)
        #expect(Set(saved[0].payload.keys) == ["id", "status"])
        #expect(saved[0].payload["id"] == first.payload["id"])

        let retry = await fixture.coordinator.handle(request, owner: fixture.scope, isCurrent: { true })
        #expect(retry.status == "completed")
        #expect(retry.payload["output"] == nil && retry.payload["id"] == first.payload["id"])
        #expect(retry.payload["status"] == first.payload["status"])
        #expect(fixture.tool.app.opened.count == 1, "A retry must never run the shortcut twice")
    }

    @Test func anUnknownOutcomeIsRememberedSoARetryDoesNotRunItAgain() async {
        let fixture = CoordinatorFixture(timeout: .milliseconds(50))
        await fixture.permissions.setEnabled(true, for: .shortcuts)
        fixture.tool.app.behavior = .silent
        let request = fixture.request()
        let first = await fixture.coordinator.handle(request, owner: fixture.scope, isCurrent: { true })
        #expect(first.code == "outcome_unknown")
        let retry = await fixture.coordinator.handle(request, owner: fixture.scope, isCurrent: { true })
        #expect(retry.code == "outcome_unknown")
        #expect(fixture.tool.app.opened.count == 1)
    }

    @Test func turningTheSwitchOffWhileShortcutsRunsRetiresTheCall() async {
        let fixture = CoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .shortcuts)
        fixture.tool.app.behavior = .silent
        fixture.tool.app.onOpen = { fixture.permissions.disable(.shortcuts) }
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "permission_disabled")
        #expect(!fixture.tool.handoff.isActive)
    }
}

// MARK: Fixtures

private struct TestRetired: Error {}

private func freshDefaults() -> UserDefaults {
    let name = "bighelp.tests.shortcuts." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Shortcuts as the tool sees it: opened with `shortcuts://x-callback-url/run-shortcut`, then a
/// callback to `x-success` with `result` appended, to `x-error` with `errorMessage`, or to `x-cancel`.
@MainActor
private final class FakeShortcutsApp {
    enum Behavior { case output(String), cancel, error(String), silent, refuse }

    var behavior: Behavior = .output("")
    var onOpen: (@MainActor () -> Void)?
    private(set) var opened: [URL] = []
    private(set) var lastName: String?
    private(set) var lastInput: String?
    private let handoff: DeviceToolHandoff

    init(handoff: DeviceToolHandoff) { self.handoff = handoff }

    func open(_ url: URL) async -> Bool {
        opened.append(url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        lastName = items.first { $0.name == "name" }?.value
        lastInput = items.first { $0.name == "text" }?.value
        onOpen?()
        let callback: URL?
        switch behavior {
        case .refuse: return false
        case .silent: return true
        case .output(let text): callback = callbackURL(.success, output: text, in: items)
        case .cancel: callback = callbackURL(.cancel, output: nil, in: items)
        case .error(let message): callback = callbackURL(.error, output: message, in: items)
        }
        guard let callback else { return true }
        Task { @MainActor [handoff] in
            try? await Task.sleep(for: .milliseconds(30))
            handoff.handleCallback(callback)
        }
        return true
    }

    /// The callback for the most recent run, the way Shortcuts forms it.
    func callbackURL(_ kind: DeviceToolHandoff.CallbackKind, output: String?) -> URL? {
        guard let url = opened.last else { return nil }
        return callbackURL(kind, output: output, in: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
    }

    private func callbackURL(_ kind: DeviceToolHandoff.CallbackKind, output: String?, in items: [URLQueryItem]) -> URL? {
        let key = ["success": "x-success", "cancel": "x-cancel", "error": "x-error"][kind.rawValue]!
        guard let base = items.first(where: { $0.name == key })?.value else { return nil }
        guard let output else { return URL(string: base) }
        let name = kind == .error ? "errorMessage" : "result"
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return URL(string: base + "?\(name)=" + (output.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""))
    }
}

@MainActor
private final class ToolFixture {
    let time: FakeHandoffBackgroundTime
    let handoff: DeviceToolHandoff
    let store: ShortcutNameStore
    let app: FakeShortcutsApp
    let tool: DeviceShortcutsTool
    var allow = true
    var authorizeCalls = 0

    init(names: [String] = ["Morning Routine", "Water Plants"], timeout: Duration = .seconds(5)) {
        let time = FakeHandoffBackgroundTime()
        let handoff = DeviceToolHandoff(backgroundTime: time.backgroundTime, holdConnection: time.holdConnection,
                                        returnGrace: .milliseconds(20))
        let store = ShortcutNameStore(defaults: freshDefaults())
        for name in names { store.add(name) }
        let app = FakeShortcutsApp(handoff: handoff)
        self.time = time
        self.handoff = handoff
        self.store = store
        self.app = app
        tool = DeviceShortcutsTool(store: store, handoff: handoff, timeout: timeout, opener: { await app.open($0) })
    }

    @discardableResult
    func execute(_ operation: String, _ arguments: [String: BighelpJSONValue] = [:]) async throws -> [String: BighelpJSONValue] {
        try await tool.execute(
            operation: operation, arguments: arguments,
            context: DeviceToolCallContext(requestID: "request-1", hostID: "host-a", agentID: "default",
                                           sessionID: "session-1", turnID: "turn-1"),
            authorize: { [self] in
                authorizeCalls += 1
                if !allow { throw TestRetired() }
            })
    }
}

/// The tool behind the real router and coordinator, with a fake of the app's open/background state.
@MainActor
private final class CoordinatorFixture {
    let scope = DeviceToolScope(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-a")
    let permissions = DeviceToolPermissions(status: { _ in .available }, request: { _ in .available },
                                            isForeground: { true }, readGrants: { _ in [] }, writeGrants: { _, _ in })
    let journal = MemoryShortcutsJournal()
    let tool: Wrapper
    var applicationState: UIApplication.State = .active
    lazy var coordinator = DeviceToolCoordinator(
        permissions: permissions, journal: journal, clock: { 1_000 },
        available: { [self] in usesHandoff ? tool.handoff.isAppOpen(applicationState) : applicationState == .active },
        execute: { [self] operation, arguments, context, authorize in
            try await router.execute(operation: operation, arguments: arguments, context: context, authorize: authorize)
        })
    private let usesHandoff: Bool
    private lazy var router = DeviceToolRouter(apple: AppleDeviceToolService(), tools: [tool.tool])

    /// The tool with its fakes, kept together so the fixture can reach both.
    @MainActor
    final class Wrapper {
        let time: FakeHandoffBackgroundTime
        let handoff: DeviceToolHandoff
        let app: FakeShortcutsApp
        let tool: DeviceShortcutsTool

        init(timeout: Duration) {
            let time = FakeHandoffBackgroundTime()
            let handoff = DeviceToolHandoff(backgroundTime: time.backgroundTime, holdConnection: time.holdConnection,
                                            returnGrace: .milliseconds(20))
            let store = ShortcutNameStore(defaults: freshDefaults())
            store.add("Morning Routine")
            let app = FakeShortcutsApp(handoff: handoff)
            self.time = time
            self.handoff = handoff
            self.app = app
            tool = DeviceShortcutsTool(store: store, handoff: handoff, timeout: timeout, opener: { await app.open($0) })
        }
    }

    init(usesHandoff: Bool = true, timeout: Duration = .seconds(5)) {
        self.usesHandoff = usesHandoff
        tool = Wrapper(timeout: timeout)
        permissions.bind(scope)
    }

    func request() -> DeviceToolRequest {
        DeviceToolRequest(version: 1, type: "device.tool.request", requestId: "request-shortcut-01",
                          deviceId: scope.deviceID, hostId: scope.hostID, authorizationEpoch: 1,
                          sessionId: "session-1", agentId: "default", turnId: "turn-1",
                          operation: "shortcuts.run", arguments: ["name": .string("Morning Routine")],
                          sentAt: 1_000, expiresAt: 1_030)
    }
}

@MainActor
private final class MemoryShortcutsJournal: DeviceToolJournal {
    private(set) var entries: [String: DeviceToolJournalEntry] = [:]
    func entry(requestID: String, scope: DeviceToolScope) throws -> DeviceToolJournalEntry? { entries[requestID] }
    func save(_ entry: DeviceToolJournalEntry, requestID: String, scope: DeviceToolScope) throws {
        entries[requestID] = entry
    }
}
