import Foundation
import Testing
@testable import Bighelp

/// Hermes' `manage_connections` card: what bighelp reads from `connection.request` / `.update`
/// (made-up apps and links), and what it sends back.
@MainActor
struct ConnectorCardTests {
    // MARK: Decoding

    @Test func aRequestDecodesItsTargets() throws {
        let operation = try ConnectorOperation(payload: Self.request())
        #expect(operation.id == "op-1")
        #expect(operation.sequence == 1)
        #expect(operation.timeout == 300)
        #expect(!operation.isSettled)
        let mail = try #require(operation.targets.first)
        #expect(mail.kind == .connector && mail.action == .connect && mail.state == .initiated)
        #expect(mail.connectURL?.absoluteString == "https://connect.example.com/start/abc")
        #expect(mail.isOpen)
        let tool = try #require(operation.targets.last)
        #expect(tool.kind == .mcp && tool.action == .install && tool.state == .pending)
        #expect(tool.requiredEnvironment.map(\.name) == ["WEATHER_API_KEY"])
    }

    @Test(arguments: ["http://connect.example.com/x", "https://user:pw@connect.example.com/x", "javascript:alert(1)", "hermes://x"])
    func onlyAPlainHTTPSPageIsOpened(raw: String) throws {
        var payload = Self.request()
        payload["targets"] = .array([Self.target("example_mail", state: "initiated", url: raw)])
        let operation = try ConnectorOperation(payload: payload)
        #expect(operation.targets.first?.connectURL == nil)
    }

    @Test func unknownWordsDontBreakTheCard() throws {
        var payload = Self.request()
        payload["future_field"] = .string("ignored")
        payload["targets"] = .array([.object(["name": .string("example_mail"), "kind": .string("hologram"),
                                              "action": .string("teleport"), "state": .string("thinking")])])
        let target = try #require(try ConnectorOperation(payload: payload).targets.first)
        #expect(target.kind == .other && target.action == .other && target.state == .other)
    }

    @Test func aTargetNamedTwiceIsRefused() {
        var payload = Self.request()
        payload["targets"] = .array([Self.target("example_mail"), Self.target("example_mail")])
        #expect(throws: (any Error).self) { try ConnectorOperation(payload: payload) }
    }

    @Test func resolvedFollowsTheStateWhenHermesLeavesItOut() throws {
        var payload = Self.request()
        payload["targets"] = .array([.object(["name": .string("a"), "kind": .string("connector"), "state": .string("connected")]),
                                     .object(["name": .string("b"), "kind": .string("connector"), "state": .string("expired")])])
        let operation = try ConnectorOperation(payload: payload)
        #expect(operation.targets.map(\.isOpen) == [false, true])
        #expect(operation.targets.last?.canRetry == true)
    }

    // MARK: The card

    @Test func aCardOpensOnlyForAChatOnScreen() {
        let (store, connection, _) = Self.store()
        store.accept(Self.event(runtime: "other"), connection: connection)
        #expect(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first == nil)
        store.accept(Self.event(runtime: "runtime"), connection: connection)
        #expect(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first?.id == "op-1")
        #expect(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first?.visibleSessionID == "chat")
    }

    /// Each request is its own card, so the agent can ask for several apps without one waiting on another.
    @Test func severalRequestsWaitSideBySide() {
        let (store, connection, _) = Self.store()
        store.accept(Self.event(runtime: "runtime"), connection: connection)
        var second = Self.request()
        second["op_id"] = .string("op-2")
        second["deadline_at"] = .number(1_800_000_100)
        store.accept(DirectHermesEvent(type: "connection.request", sessionID: "runtime", payload: second, sequence: nil),
                     connection: connection)
        #expect(store.cards(runtimeID: "runtime", visibleSessionID: "chat").map(\.id) == ["op-1", "op-2"])
        #expect(store.cards(runtimeID: "runtime", visibleSessionID: "other-chat").isEmpty)
    }

    @Test func anOlderFrameNeverMovesTheCardBack() {
        let (store, connection, _) = Self.store()
        store.accept(Self.event(runtime: "runtime", sequence: 3, state: "connected"), connection: connection)
        store.accept(Self.event(runtime: "runtime", type: "connection.update", sequence: 2, state: "initiated"), connection: connection)
        #expect(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first?.operation.sequence == 3)
        #expect(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first?.operation.targets.first?.state == .connected)
    }

    @Test func aSettledUpdateClosesTheCard() {
        let (store, connection, _) = Self.store()
        store.accept(Self.event(runtime: "runtime"), connection: connection)
        store.accept(Self.event(runtime: "runtime", type: "connection.update", sequence: 2, settled: true), connection: connection)
        #expect(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first == nil)
    }

    @Test func anAccountUpdateIsNotAChatCard() {
        let (store, connection, _) = Self.store()
        var event = Self.event(runtime: "runtime", type: "connection.update")
        var payload = event.payload
        payload["owner"] = .object(["type": .string("account")])
        event = DirectHermesEvent(type: event.type, sessionID: event.sessionID, payload: payload, sequence: nil)
        store.accept(event, connection: connection)
        #expect(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first == nil)
    }

    @Test func skipAnswersForTheChatsRuntimeSession() async throws {
        let (store, connection, calls) = Self.store()
        store.accept(Self.event(runtime: "runtime"), connection: connection)
        let card = try #require(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first)
        await store.skipAll(card)
        let call = try #require(calls.values.last)
        #expect(call.method == "connection.respond")
        #expect(call.params["owner"] == .object(["type": .string("session"), "session_id": .string("runtime")]))
        #expect(call.params["profile"] == .string("juniper"))
        #expect(call.params["op_id"] == .string("op-1"))
        let names = call.params["result"]?.object?["targets"]?.array?.compactMap { $0.object?["name"]?.string }
        #expect(names == ["example_mail", "weather"])
        #expect(call.params["result"]?.object?["targets"]?.array?.allSatisfy {
            $0.object?["status"] == .string("skipped")
        } == true)
    }

    @Test func anApprovalSendsOnlyTheValuesTheToolAskedFor() async throws {
        let (store, connection, calls) = Self.store()
        store.accept(Self.event(runtime: "runtime"), connection: connection)
        let card = try #require(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first)
        let tool = try #require(card.operation.targets.last)
        await store.approve(tool, in: card, environment: ["WEATHER_API_KEY": "made-up-key", "HOME": "/tmp"])
        let answer = try #require(calls.values.last?.params["result"]?.object?["targets"]?.array?.first?.object)
        #expect(answer["status"] == .string("approved"))
        #expect(answer["env"] == .object(["WEATHER_API_KEY": .string("made-up-key")]))
    }

    @Test func tryAgainAsksHermesForANewLink() async throws {
        let (store, connection, calls) = Self.store()
        store.accept(Self.event(runtime: "runtime", state: "expired", action: "reconnect", alias: "work"), connection: connection)
        let card = try #require(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first)
        let target = try #require(card.operation.targets.first)
        await store.retry(target, in: card)
        let call = try #require(calls.values.last)
        #expect(call.method == "connectors.connect")
        #expect(call.params["connectors"] == .array([.string("example_mail")]))
        #expect(call.params["reconnect"] == .boolean(true))
        #expect(call.params["alias"] == .string("work"))
    }

    @Test func aCardHermesNoLongerKnowsCloses() async throws {
        let (store, connection, calls) = Self.store()
        calls.failure = DirectHermesError.rpcRejected(code: 4004)
        store.accept(Self.event(runtime: "runtime"), connection: connection)
        let card = try #require(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first)
        await store.skipAll(card)
        #expect(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first == nil)
    }

    @Test func aResumedChatGetsTheCardItMissed() {
        let (store, connection, _) = Self.store()
        store.acceptPending(.object(Self.request()), runtimeID: "runtime", connection: connection)
        #expect(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first?.id == "op-1")
    }

    @Test func nothingIsSentAfterTheConnectionIsGone() async throws {
        let (store, connection, calls) = Self.store()
        store.accept(Self.event(runtime: "runtime"), connection: connection)
        let card = try #require(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first)
        store.retireConnection(connection)
        await store.skipAll(card)
        #expect(calls.values.isEmpty)
        #expect(store.cards(runtimeID: "runtime", visibleSessionID: "chat").first == nil)
    }

    @Test func catalogNamesTheApps() {
        let apps = ConnectorCardStore.apps(in: .object(["connectors": .array([
            .object(["slug": .string("example_mail"), "name": .string("Example Mail"),
                     "logo_url": .string("https://logos.example.com/mail.png")]),
            .object(["slug": .string("bad"), "name": .string("")]),
        ])]))
        #expect(apps["example_mail"]?.name == "Example Mail")
        #expect(apps["bad"] == nil)
        #expect(ConnectorNames.readable("google_calendar") == "Google Calendar")
    }

    // MARK: Fixtures

    final class Calls {
        var values: [(method: String, params: [String: BighelpJSONValue])] = []
        var failure: (any Error)?
    }

    static func store() -> (ConnectorCardStore, DirectHermesPromptConnection, Calls) {
        let store = ConnectorCardStore()
        let calls = Calls()
        let connection = DirectHermesPromptConnection(owner: UUID(), principalIdentity: "host",
            clientIdentity: ObjectIdentifier(calls), transportGeneration: .init(UUID()))
        store.beginConnection(connection) { method, params in
            calls.values.append((method, params))
            if let failure = calls.failure { throw failure }
            return .object(["status": .string("ok"), "settled": .boolean(false)])
        }
        store.bind(profile: "juniper", runtimeID: "runtime", visibleSessionID: "chat", connection: connection)
        return (store, connection, calls)
    }

    static func target(_ name: String, state: String = "initiated", url: String? = "https://connect.example.com/start/abc",
                       action: String = "connect", alias: String? = nil) -> BighelpJSONValue {
        var object: [String: BighelpJSONValue] = ["name": .string(name), "kind": .string("connector"),
                                                  "action": .string(action), "state": .string(state)]
        if let url { object["connect_url"] = .string(url) }
        if let alias { object["alias"] = .string(alias) }
        return .object(object)
    }

    static func request(sequence: Int = 1, state: String = "initiated", action: String = "connect", alias: String? = nil,
                        settled: Bool = false) -> [String: BighelpJSONValue] {
        [
            "op_id": .string("op-1"), "seq": .integer(sequence), "timeout_seconds": .integer(300),
            "deadline_at": .number(1_800_000_000), "settled": .boolean(settled), "tool_call_id": .string("call-1"),
            "targets": .array([
                target("example_mail", state: state, action: action, alias: alias),
                .object(["name": .string("weather"), "kind": .string("mcp"), "action": .string("install"),
                         "state": .string("pending"), "resolved": .boolean(false),
                         "required_env": .array([.object(["name": .string("WEATHER_API_KEY"), "required": .boolean(true),
                                                          "secret": .boolean(true), "default": .string("")])])]),
            ]),
        ]
    }

    static func event(runtime: String, type: String = "connection.request", sequence: Int = 1, state: String = "initiated",
                      action: String = "connect", alias: String? = nil, settled: Bool = false) -> DirectHermesEvent {
        DirectHermesEvent(type: type, sessionID: runtime,
                          payload: request(sequence: sequence, state: state, action: action, alias: alias, settled: settled),
                          sequence: nil)
    }
}

/// Settings › Apps.
@MainActor
struct ConnectorAppsModelTests {
    final class Service: ConnectorAppsService {
        var calls: [String] = []
        var failures: [String: any Error] = [:]
        var statusState = "connected"

        func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            calls.append(method)
            if let failure = failures[method] { throw failure }
            switch method {
            case "connectors.catalog":
                return .object(["connectors": .array([
                    .object(["slug": .string("example_notes"), "name": .string("Example Notes"), "description": .string("Notes")]),
                    .object(["slug": .string("example_mail"), "name": .string("Example Mail"), "description": .string("Mail")]),
                ])])
            case "connectors.accounts":
                return .object(["accounts": .array([.object([
                    "connection_id": .string("acc-1"), "connector": .string("example_mail"), "status": .string("active"),
                    "label": .string("sam@example.com"), "active": .boolean(true), "disabled": .boolean(false),
                ])])])
            case "connectors.connect":
                return .object(["op_id": .string("op-9"), "seq": .integer(1), "targets": .array([
                    ConnectorCardTests.target("example_notes"),
                ])])
            case "connectors.operation.status":
                return .object(["op_id": .string("op-9"), "seq": .integer(2), "targets": .array([
                    ConnectorCardTests.target("example_notes", state: statusState),
                ])])
            default:
                return .object([:])
            }
        }
    }

    private func model(_ service: Service, setUp: Bool) -> ConnectorAppsModel {
        let defaults = UserDefaults(suiteName: "connector-apps-tests-\(UUID().uuidString)")!
        if setUp { defaults.set(true, forKey: "bighelp.connectors.set-up.host") }
        return ConnectorAppsModel(service: service, scope: "host", defaults: defaults)
    }

    @Test func openingThePageCallsNothingUntilThePersonSetsItUp() async {
        let service = Service()
        let model = model(service, setUp: false)
        await model.appear()
        #expect(model.phase == .intro)
        #expect(service.calls.isEmpty, "Any account call makes Hermes create the computer's connector identity")
        await model.setUp()
        #expect(service.calls == ["connectors.list", "connectors.catalog", "connectors.accounts"])
        #expect(model.phase == .ready)
        #expect(model.connected.map(\.name) == ["Example Mail"])
        #expect(model.others.map(\.name) == ["Example Notes"])
    }

    @Test(arguments: [(-32601, ConnectorAppsModel.Phase.needsUpdate), (4031, .turnedOff), (4032, .intro)])
    func hostAnswersBecomePlainStates(code: Int, phase: ConnectorAppsModel.Phase) async {
        let service = Service()
        service.failures["connectors.catalog"] = DirectHermesError.rpcRejected(code: code)
        let model = model(service, setUp: true)
        await model.appear()
        #expect(model.phase == phase)
    }

    @Test func connectingOpensThePageThenWaitsForTheAccount() async throws {
        let service = Service()
        let model = model(service, setUp: true)
        await model.appear()
        let notes = try #require(model.others.first)
        let url = await model.connect(notes)
        #expect(url?.absoluteString == "https://connect.example.com/start/abc")
        #expect(model.signIn?.opID == "op-9")
        let connected = await model.watchSignIn(pollInterval: .milliseconds(1))
        #expect(connected)
        #expect(model.signIn == nil)
    }

    @Test func closingThePageWithoutSigningInStopsTheWait() async throws {
        let service = Service()
        service.statusState = "initiated"
        let model = model(service, setUp: true)
        await model.appear()
        let notes = try #require(model.others.first)
        _ = await model.connect(notes)
        await model.pageClosed()
        #expect(service.calls.contains("connectors.operation.wake"))
        let connected = await model.watchSignIn(pollInterval: .milliseconds(1), graceAfterClose: 0)
        #expect(!connected)
        #expect(model.signIn == nil)
    }

    @Test(arguments: [("Work", "work"), (" home office ", "home-office"), ("a", "a")])
    func anAccountNameBecomesHermesAlias(typed: String, alias: String) {
        #expect(ConnectorAppsModel.alias(typed) == alias)
    }

    @Test(arguments: ["", "-work", "work!", String(repeating: "a", count: 33)])
    func aNameHermesWouldRefuseIsRefusedHere(typed: String) {
        #expect(ConnectorAppsModel.alias(typed) == nil)
    }
}
