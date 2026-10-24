import CryptoKit
import Foundation
import Testing
@testable import Bighelp

/// A phone that already gets notifications must enroll itself in direct delivery after an update,
/// with no screen and no action, and must keep working against a Worker that doesn't have the
/// routes yet. The fake Worker below answers like `services/link` does (CONTRACTS §1): it checks
/// the signature, the body's exact keys and values, and answers with the contract's status codes.
@MainActor struct PushRegistrarTests {
    private static let token = Data(repeating: 0xAB, count: 32)
    private static let tokenHex = String(repeating: "ab", count: 32)
    private static let otherToken = Data(repeating: 0xCD, count: 32)
    private static let day: TimeInterval = 24 * 3600

    // MARK: The Worker

    @MainActor final class TestClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    @MainActor final class FakeWorker: BighelpLinkHTTPTransport {
        enum Mode: Equatable {
            case deployed
            /// An older Worker: the route doesn't exist.
            case notDeployed
            /// An older Worker that answers a page, not JSON.
            case notDeployedPlainText
            case failing(status: Int, code: String)
        }

        struct Call {
            let method: String
            let path: String
            let body: [String: Any]
        }

        var mode = Mode.deployed
        /// Gives other work a turn while a request is out, like a real network.
        var suspends = false
        private(set) var calls: [Call] = []
        private(set) var targets: [String: [String: Any]] = [:]
        private(set) var badSignatures = 0
        private(set) var revokedInstallations: [String] = []
        var publicKey: P256.Signing.PublicKey?
        var installationID = ""
        var epoch = 1

        var puts: [Call] { calls.filter { $0.method == "PUT" } }
        var deletes: [Call] { calls.filter { $0.method == "DELETE" } }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try #require(request.url)
            let path = url.path
            let method = request.httpMethod ?? "GET"
            let bodyData = request.httpBody ?? Data()
            let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
            calls.append(Call(method: method, path: path, body: body))
            if suspends { await Task.yield() }
            func reply(_ status: Int, _ object: Any?) throws -> (Data, HTTPURLResponse) {
                let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
                guard let object else { return (Data("Not Found".utf8), response) }
                return (try JSONSerialization.data(withJSONObject: object), response)
            }
            guard signatureIsValid(request, method: method, path: path, body: bodyData) else {
                badSignatures += 1
                return try reply(401, ["version": 1, "error": ["code": "notification_signature_invalid"]])
            }
            switch mode {
            case .notDeployed: return try reply(404, ["version": 1, "error": ["code": "not_found"]])
            case .notDeployedPlainText: return try reply(404, nil)
            case .failing(let status, let code): return try reply(status, ["version": 1, "error": ["code": code]])
            case .deployed: break
            }
            let invalid = ["version": 1, "error": ["code": "notification_push_target_invalid"]] as [String: Any]
            let updatedAt = 1_767_225_600
            switch (method, path) {
            case ("PUT", BighelpPushRegistrar.pushTargetPath):
                let topics = ["chat-replies-completions", "scheduled-tasks-deliveries", "questions-approvals", "subagent-completions"]
                guard Set(body.keys) == ["version", "token", "environment", "appVersion", "mutedTopics"], body["version"] as? Int == 1,
                      let muted = body["mutedTopics"] as? [String], Set(muted).count == muted.count,
                      muted.allSatisfy(topics.contains),
                      let token = body["token"] as? String, Self.valid(token: token, lengths: 64...200),
                      let environment = body["environment"] as? String, ["sandbox", "production"].contains(environment),
                      let version = body["appVersion"] as? String,
                      version.range(of: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}\([0-9]{1,7}\)$"#, options: .regularExpression) != nil
                else { return try reply(400, invalid) }
                targets["alert"] = body
                return try reply(200, ["version": 1, "target": ["kind": "alert", "environment": environment, "updatedAt": updatedAt]])
            case ("DELETE", BighelpPushRegistrar.pushTargetPath):
                guard body as NSDictionary == ["version": 1] as NSDictionary else { return try reply(400, invalid) }
                targets["alert"] = nil
                return try reply(200, ["version": 1, "target": NSNull()])
            case ("PUT", BighelpPushRegistrar.liveActivityTargetPath):
                guard body["version"] as? Int == 1, let kind = body["kind"] as? String,
                      let token = body["token"] as? String, Self.valid(token: token, lengths: 2...512),
                      let environment = body["environment"] as? String, ["sandbox", "production"].contains(environment)
                else { return try reply(400, invalid) }
                if kind == "pts", Set(body.keys) == ["version", "kind", "token", "environment"] {
                    targets["pts"] = body
                    return try reply(200, ["version": 1, "target": ["kind": "pts", "environment": environment, "updatedAt": updatedAt]])
                }
                if kind == "liveactivity", Set(body.keys) == ["version", "kind", "token", "environment", "activityId"],
                   let id = body["activityId"] as? String,
                   id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil {
                    targets["liveactivity:" + id] = body
                    return try reply(200, ["version": 1, "target": [
                        "kind": "liveactivity", "activityId": id, "environment": environment, "updatedAt": updatedAt]])
                }
                return try reply(400, invalid)
            case ("DELETE", BighelpPushRegistrar.liveActivityTargetPath):
                guard body["version"] as? Int == 1, let kind = body["kind"] as? String else { return try reply(400, invalid) }
                if kind == "pts", body.count == 2 { targets["pts"] = nil }
                else if kind == "liveactivity", body.count == 3, let id = body["activityId"] as? String {
                    targets["liveactivity:" + id] = nil
                } else { return try reply(400, invalid) }
                return try reply(200, ["version": 1, "target": NSNull()])
            case ("DELETE", BighelpNotificationBrokerClient.currentInstallationPath):
                revokedInstallations.append(installationID)
                return try reply(200, ["version": 2, "installation": ["installationId": installationID, "state": "revoked"]])
            default:
                return try reply(404, ["version": 1, "error": ["code": "not_found"]])
            }
        }

        private static func valid(token: String, lengths: ClosedRange<Int>) -> Bool {
            lengths.contains(token.utf8.count) && token.utf8.count.isMultiple(of: 2)
                && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }

        /// The `loopdy-notification-device-v1` transcript, signed by the installation's key.
        private func signatureIsValid(_ request: URLRequest, method: String, path: String, body: Data) -> Bool {
            func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
            guard let publicKey, header("x-loopdy-notification-installation") == installationID,
                  let timestamp = header("x-loopdy-timestamp"), let nonce = header("x-loopdy-nonce"),
                  header("x-loopdy-authorization-epoch") == String(epoch),
                  let encoded = header("x-loopdy-signature"),
                  let raw = try? BighelpLinkBase64URL.decode(encoded),
                  let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
            let digest = BighelpLinkBase64URL.encode(Data(SHA256.hash(data: body)))
            let transcript = ["loopdy-notification-device-v1", method, path, installationID, timestamp, nonce,
                              String(epoch), digest].joined(separator: "\n")
            return publicKey.isValidSignature(signature, for: Data(transcript.utf8))
        }
    }

    // MARK: The phone

    /// One phone: an installation, a Worker, a clock, and the registrar between them.
    @MainActor final class Phone {
        let worker = FakeWorker()
        let clock = TestClock()
        let signingKey = P256.Signing.PrivateKey()
        let suite = "bighelp.test.direct-push." + UUID().uuidString
        let defaults: UserDefaults
        var installationID: String? = UUID().uuidString.lowercased()
        var authorized = true
        var turningOff = false
        var environment = BighelpLinkPushEnvironment.production
        /// What the settings screen says is turned off; nil when BuzzKit can't be asked.
        var muted: [String]? = []
        private(set) var registerRequests = 0
        private(set) var pushToStartHandler: (@MainActor (Data) async -> Void)?
        private(set) var registrar: BighelpPushRegistrar!

        init(appVersion: String = "2.7.0(160)") {
            defaults = UserDefaults(suiteName: suite)!
            let broker = BighelpNotificationBrokerClient(transport: worker, now: { [clock] in clock.now })
            registrar = BighelpPushRegistrar(
                api: broker,
                credentials: { [unowned self] in
                    installationID.map {
                        BighelpManagedNotificationCredentials(deviceID: $0, authorizationEpoch: 1, signingPrivateKey: signingKey)
                    }
                },
                isTurningOff: { [unowned self] in turningOff },
                isAuthorized: { [unowned self] in authorized },
                environment: { [unowned self] in environment },
                appVersion: appVersion,
                registerForRemoteNotifications: { [unowned self] in registerRequests += 1 },
                startPushToStart: { [unowned self] handler in pushToStartHandler = handler },
                mutedTopics: { [unowned self] in muted },
                debounce: .milliseconds(20),
                defaults: defaults,
                now: { [clock] in clock.now })
            worker.publicKey = signingKey.publicKey
            syncWorkerIdentity()
        }

        func syncWorkerIdentity() { worker.installationID = installationID ?? "" }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
    }

    // MARK: Auto-enrollment at launch

    @Test func aPhoneWithAnInstallationAndPermissionEnrollsItselfAtLaunch() async throws {
        let phone = Phone()
        defer { phone.cleanup() }
        // Launch: the app asks iOS for its token, with nothing shown.
        await phone.registrar.refreshAtForeground()
        #expect(phone.registerRequests == 1)
        #expect(phone.worker.calls.isEmpty, "Nothing is sent until iOS answers with the token")
        // iOS answers; the token goes to the service, signed with the installation's key.
        await phone.registrar.receiveToken(Self.token)
        let put = try #require(phone.worker.puts.first)
        #expect(phone.worker.calls.count == 1)
        #expect(put.path == "/v1/notifications/push-target")
        #expect(put.body["token"] as? String == Self.tokenHex)
        #expect(put.body["environment"] as? String == "production")
        #expect(put.body["appVersion"] as? String == "2.7.0(160)")
        #expect(put.body["version"] as? Int == 1)
        #expect(phone.worker.badSignatures == 0)
        #expect(phone.worker.targets["alert"] != nil)
        #expect(phone.registrar.state.alert?.installationID == phone.installationID)
        #expect(phone.registrar.state.lastErrorCode == nil)
        // The token itself isn't kept on the phone, only its digest.
        let saved = try #require(phone.defaults.data(forKey: "bighelp.direct-push.state.v1"))
        #expect(!String(decoding: saved, as: UTF8.self).contains(Self.tokenHex))
    }

    @Test func theSimulatorAndDebugBuildsSendTheirOwnEnvironment() async throws {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.environment = .sandbox
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.first?.body["environment"] as? String == "sandbox")
        #expect(phone.worker.targets["alert"] != nil)
    }

    @Test func aPhoneWithoutAnInstallationSendsNothingAndAsksForNothing() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.installationID = nil
        await phone.registrar.refreshAtForeground()
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.registerRequests == 0)
        #expect(phone.worker.calls.isEmpty)
        #expect(phone.pushToStartHandler == nil, "No push-to-start watching either")
    }

    @Test func aPhoneWithoutNotificationPermissionSendsNothing() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.authorized = false
        await phone.registrar.refreshAtForeground()
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.registerRequests == 0)
        #expect(phone.worker.calls.isEmpty)
    }

    @Test func nothingIsSentWhileNotificationsAreTurningOff() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.turningOff = true
        await phone.registrar.refreshAtForeground()
        await phone.registrar.receiveToken(Self.token)
        await phone.registrar.registerActivity(id: "activity_one", token: Self.token)
        #expect(phone.registerRequests == 0)
        #expect(phone.worker.calls.isEmpty)
    }

    @Test func theSameTokenIsNotSentAgainAtEveryLaunch() async {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.receiveToken(Self.token)
        phone.clock.advance(3600)
        await phone.registrar.receiveToken(Self.token)
        phone.clock.advance(3 * Self.day)
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 1)
    }

    @Test func aNewTokenIsSentAgain() async {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.receiveToken(Self.token)
        await phone.registrar.receiveToken(Self.otherToken)
        #expect(phone.worker.puts.map { $0.body["token"] as? String }
            == [Self.tokenHex, String(repeating: "cd", count: 32)])
        #expect(phone.worker.targets["alert"]?["token"] as? String == String(repeating: "cd", count: 32))
    }

    @Test func aTokenSentWhileAnotherIsOutIsNotLost() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.worker.suspends = true
        let first = Task { await phone.registrar.receiveToken(Self.token) }
        await Task.yield() // the first is now waiting for the Worker
        await phone.registrar.receiveToken(Self.otherToken)
        await first.value
        #expect(phone.worker.puts.map { $0.body["token"] as? String } == [Self.tokenHex, String(repeating: "cd", count: 32)])
        #expect(phone.worker.targets["alert"]?["token"] as? String == String(repeating: "cd", count: 32),
                "The service ends up with the newest token")
    }

    @Test func aWeekOldRegistrationIsRefreshed() async {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.receiveToken(Self.token)
        phone.clock.advance(7 * Self.day - 60)
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 1, "Still fresh just under seven days")
        phone.clock.advance(120)
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 2, "Over seven days: sent again, with the same token")
        phone.clock.advance(Self.day)
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 2)
    }

    @Test func aNewInstallationOrEnvironmentIsSentAgain() async {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.receiveToken(Self.token)
        phone.installationID = UUID().uuidString.lowercased()
        phone.syncWorkerIdentity()
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 2, "Turning notifications off and on again makes a new installation")
        phone.environment = .sandbox
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 3)
        #expect(phone.worker.badSignatures == 0)
    }

    @Test func aTokenThatIsNotAnApnsTokenIsNeverSent() async {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.receiveToken(Data([0x01, 0x02]))
        #expect(phone.worker.calls.isEmpty)
        #expect(phone.registrar.state.lastErrorCode == BighelpNotificationErrorCode.directPushRefused.rawValue)
    }

    @Test func iOSIsAskedForTheTokenOnlyOnceInAWhile() async {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.refreshAtForeground()
        await phone.registrar.refreshAtForeground()
        #expect(phone.registerRequests == 1)
        phone.clock.advance(BighelpPushRegistrar.registerInterval + 1)
        await phone.registrar.refreshAtForeground()
        #expect(phone.registerRequests == 2)
    }

    @Test func finishingSetupSendsTheTokenThatIsAlreadyKnown() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.installationID = nil
        await phone.registrar.receiveToken(Self.token) // iOS answered before the installation existed
        #expect(phone.worker.calls.isEmpty)
        phone.installationID = UUID().uuidString.lowercased()
        phone.syncWorkerIdentity()
        await phone.registrar.enrollmentFinished()
        #expect(phone.worker.puts.count == 1)
        // With no token yet, it asks iOS for one.
        let fresh = Phone()
        defer { fresh.cleanup() }
        await fresh.registrar.enrollmentFinished()
        #expect(fresh.registerRequests == 1)
    }

    // MARK: The person's alert choices

    @Test func theRegistrationCarriesTheTopicsTurnedOff() async throws {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.muted = ["subagent-completions", "scheduled-tasks-deliveries"]
        await phone.registrar.receiveToken(Self.token)
        let put = try #require(phone.worker.puts.first)
        #expect(put.body["mutedTopics"] as? [String] == ["scheduled-tasks-deliveries", "subagent-completions"])
        #expect(phone.worker.targets["alert"] != nil)
        // Nothing turned off is an empty list, which is different from an unknown one.
        let open = Phone()
        defer { open.cleanup() }
        await open.registrar.receiveToken(Self.token)
        #expect(open.worker.puts.first?.body["mutedTopics"] as? [String] == [])
    }

    @Test func topicsTheServiceDoesNotKnowAreLeftOut() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.muted = ["questions-approvals", "questions-approvals", "something-new"]
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.first?.body["mutedTopics"] as? [String] == ["questions-approvals"])
    }

    @Test func changingWhatToHearAboutSendsTheNewListOnce() async throws {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 1)
        // Several quick changes become one request, after the debounce.
        phone.muted = ["questions-approvals"]
        phone.registrar.preferencesChanged()
        phone.muted = ["questions-approvals", "subagent-completions"]
        phone.registrar.preferencesChanged()
        for _ in 0..<500 where phone.worker.puts.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(phone.worker.puts.count == 2)
        let put = try #require(phone.worker.puts.last)
        #expect(put.body["mutedTopics"] as? [String] == ["questions-approvals", "subagent-completions"])
        #expect(put.body["token"] as? String == Self.tokenHex)
        // A change that ends where it began sends nothing.
        phone.muted = []
        phone.registrar.preferencesChanged()
        phone.muted = ["questions-approvals", "subagent-completions"]
        try? await Task.sleep(for: .milliseconds(120))
        #expect(phone.worker.puts.count == 2)
    }

    @Test func aChangeBeforeTheTokenIsKnownRidesOnTheFirstRegistration() async {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.sendPreferenceChange()
        #expect(phone.registerRequests == 1)
        #expect(phone.worker.calls.isEmpty)
        phone.muted = ["chat-replies-completions"]
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.first?.body["mutedTopics"] as? [String] == ["chat-replies-completions"])
    }

    @Test func choicesThatCannotBeReadSendNothingAndTryAgainLater() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.muted = nil
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.calls.isEmpty, "An empty list would be wrong; so is none")
        #expect(phone.registrar.state.alert == nil)
        #expect(phone.registrar.state.failures == 1)
        #expect(phone.registrar.state.retryAfter == phone.clock.now.addingTimeInterval(5 * 60))
        // Still unreadable after the wait: still nothing.
        phone.clock.advance(6 * 60)
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.calls.isEmpty)
        // Readable again: sent, with the list.
        phone.muted = ["subagent-completions"]
        phone.clock.advance(16 * 60)
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 1)
        #expect(phone.worker.puts.first?.body["mutedTopics"] as? [String] == ["subagent-completions"])
        #expect(phone.registrar.state.failures == 0)
    }

    @Test func aChangeIsNotLostWhenTheChoicesCannotBeReadAtThatMoment() async {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.receiveToken(Self.token)
        phone.muted = nil
        await phone.registrar.sendPreferenceChange()
        #expect(phone.worker.puts.count == 1)
        phone.muted = ["questions-approvals"]
        phone.clock.advance(6 * 60)
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 2, "The pending change goes with the next try")
        #expect(phone.worker.puts.last?.body["mutedTopics"] as? [String] == ["questions-approvals"])
    }

    // MARK: A Worker that doesn't have the routes yet

    @Test(arguments: [FakeWorker.Mode.notDeployed, .notDeployedPlainText])
    func aWorkerWithoutTheRouteIsLeftAloneForADay(mode: FakeWorker.Mode) async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.worker.mode = mode
        await phone.registrar.refreshAtForeground()
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 1)
        // "Not available yet": no failure, no code, nothing to show.
        #expect(phone.registrar.state.lastErrorCode == nil)
        #expect(phone.registrar.state.failures == 0)
        #expect(phone.registrar.state.alert == nil)
        let until = phone.registrar.state.unavailableUntil
        #expect(until == phone.clock.now.addingTimeInterval(Self.day))

        // Opening the app again within the day asks for nothing and sends nothing.
        phone.clock.advance(Self.day - 60)
        await phone.registrar.refreshAtForeground()
        await phone.registrar.receiveToken(Self.otherToken)
        await phone.registrar.registerActivity(id: "activity_one", token: Self.token)
        await phone.registrar.registerPushToStart(Self.token)
        #expect(phone.registerRequests == 1)
        #expect(phone.worker.calls.count == 1)

        // A day later it tries again, and once the Worker has the routes it works.
        phone.clock.advance(120)
        phone.worker.mode = .deployed
        await phone.registrar.refreshAtForeground()
        #expect(phone.registerRequests == 2)
        await phone.registrar.receiveToken(Self.otherToken)
        #expect(phone.worker.puts.count == 2)
        #expect(phone.worker.targets["alert"]?["token"] as? String == String(repeating: "cd", count: 32))
        #expect(phone.registrar.state.unavailableUntil == nil)
        #expect(phone.registrar.state.alert != nil)
    }

    @Test func aWorkerThatIsStillWithoutTheRouteAfterADayWaitsAnotherDay() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.worker.mode = .notDeployed
        await phone.registrar.receiveToken(Self.token)
        phone.clock.advance(Self.day + 1)
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 2)
        phone.clock.advance(Self.day / 2)
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 2)
    }

    // MARK: Other failures

    @Test(arguments: [
        (500, "internal_error", BighelpNotificationErrorCode.directPushUnreachable),
        (503, "notification_service_unavailable", .directPushUnreachable),
        (429, "rate_limited", .directPushUnreachable),
        (400, "notification_push_target_invalid", .directPushRefused),
        (401, "notification_signature_invalid", .directPushRefused),
        (403, "notification_scope_invalid", .directPushRefused),
    ])
    func otherFailuresGetACodeAndBackOff(status: Int, serverCode: String, expected: BighelpNotificationErrorCode) async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.worker.mode = .failing(status: status, code: serverCode)
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.registrar.state.lastErrorCode == expected.rawValue)
        #expect(phone.registrar.state.failures == 1)
        #expect(phone.registrar.state.alert == nil)
        #expect(phone.registrar.state.unavailableUntil == nil)
        #expect(phone.registrar.state.retryAfter == phone.clock.now.addingTimeInterval(5 * 60))
        // Within the wait: nothing. The person never sees any of this.
        phone.clock.advance(4 * 60)
        await phone.registrar.receiveToken(Self.token)
        await phone.registrar.refreshAtForeground()
        #expect(phone.worker.puts.count == 1)
        #expect(phone.registerRequests == 0)
        // After it: tries again, waits longer when it fails again.
        phone.clock.advance(2 * 60)
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 2)
        #expect(phone.registrar.state.failures == 2)
        #expect(phone.registrar.state.retryAfter == phone.clock.now.addingTimeInterval(15 * 60))
        // And recovers by itself.
        phone.worker.mode = .deployed
        phone.clock.advance(16 * 60)
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.puts.count == 3)
        #expect(phone.registrar.state.failures == 0)
        #expect(phone.registrar.state.retryAfter == nil)
        #expect(phone.registrar.state.lastErrorCode == nil)
        #expect(phone.registrar.state.alert != nil)
    }

    @Test func theBackoffGrowsAndStopsAtSixHours() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.worker.mode = .failing(status: 500, code: "internal_error")
        var waits: [TimeInterval] = []
        for _ in 0..<6 {
            await phone.registrar.receiveToken(Self.token)
            let wait = (phone.registrar.state.retryAfter ?? .distantPast).timeIntervalSince(phone.clock.now)
            waits.append(wait)
            phone.clock.advance(wait + 1)
        }
        #expect(waits == [300, 900, 3600, 21600, 21600, 21600])
    }

    @Test func aFailureCodeIsInTheCatalogAndNeverShownAsASetupError() {
        for code in [BighelpNotificationErrorCode.directPushRefused, .directPushUnreachable,
                     .directPushActivityFailed, .directPushRemoveFailed] {
            #expect(code.rawValue.hasPrefix("NS-12"))
            #expect(code.message.contains("Alerts still arrive") || code == .directPushRemoveFailed)
        }
        #expect(BighelpNotificationErrorCode.directPushRemoveFailed.canRetry == false)
        #expect(BighelpNotificationErrorCode.directPushRefused.canRetry)
    }

    // MARK: Live Activities

    @Test func aLiveActivitysTokenIsRegisteredAndRemoved() async throws {
        let phone = Phone()
        defer { phone.cleanup() }
        let id = "activity_" + String(repeating: "A", count: 43)
        await phone.registrar.registerActivity(id: id, token: Self.token)
        let put = try #require(phone.worker.puts.first)
        #expect(put.path == "/v1/notifications/live-activity-target")
        #expect(put.body["kind"] as? String == "liveactivity")
        #expect(put.body["activityId"] as? String == id)
        #expect(put.body["token"] as? String == Self.tokenHex)
        #expect(put.body["environment"] as? String == "production")
        #expect(put.body["version"] as? Int == 1)
        #expect(phone.worker.targets["liveactivity:" + id] != nil)
        #expect(phone.worker.badSignatures == 0)

        // The system rotates the token: the newest one replaces it.
        await phone.registrar.registerActivity(id: id, token: Self.otherToken)
        #expect(phone.worker.targets["liveactivity:" + id]?["token"] as? String == String(repeating: "cd", count: 32))

        await phone.registrar.removeActivity(id: id)
        let delete = try #require(phone.worker.deletes.first)
        #expect(delete.path == "/v1/notifications/live-activity-target")
        #expect(delete.body as NSDictionary == ["version": 1, "kind": "liveactivity", "activityId": id] as NSDictionary)
        #expect(phone.worker.targets["liveactivity:" + id] == nil)
        #expect(phone.worker.badSignatures == 0)
    }

    @Test func aLiveActivityNeedsNoNotificationPermissionButNeedsAnInstallation() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.authorized = false
        await phone.registrar.registerActivity(id: "activity_one", token: Self.token)
        #expect(phone.worker.puts.count == 1, "Live Activities have their own permission")
        let none = Phone()
        defer { none.cleanup() }
        none.installationID = nil
        await none.registrar.registerActivity(id: "activity_one", token: Self.token)
        await none.registrar.removeActivity(id: "activity_one")
        #expect(none.worker.calls.isEmpty)
    }

    @Test func aFailedLiveActivityRegistrationIsRetriedAtTheNextForeground() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.worker.mode = .failing(status: 503, code: "notification_service_unavailable")
        await phone.registrar.registerActivity(id: "activity_one", token: Self.token)
        #expect(phone.registrar.state.lastErrorCode == BighelpNotificationErrorCode.directPushActivityFailed.rawValue)
        #expect(phone.worker.targets.isEmpty)
        phone.worker.mode = .deployed
        await phone.registrar.refreshAtForeground()
        for _ in 0..<500 where phone.worker.targets.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(phone.worker.targets["liveactivity:activity_one"] != nil)
        let calls = phone.worker.calls.count
        await phone.registrar.refreshAtForeground()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(phone.worker.calls.count == calls, "Sent once it worked")
    }

    @Test func aRemovedLiveActivityIsNotRetried() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.worker.mode = .failing(status: 503, code: "notification_service_unavailable")
        await phone.registrar.registerActivity(id: "activity_one", token: Self.token)
        await phone.registrar.removeActivity(id: "activity_one")
        phone.worker.mode = .deployed
        await phone.registrar.refreshAtForeground()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(phone.worker.targets.isEmpty)
    }

    @Test func thePushToStartTokenIsWatchedAndRegisteredOncePerChange() async throws {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.refreshAtForeground()
        let handler = try #require(phone.pushToStartHandler, "Watching starts once the phone has notifications")
        await handler(Self.token)
        let put = try #require(phone.worker.puts.last)
        #expect(put.path == "/v1/notifications/live-activity-target")
        #expect(put.body["kind"] as? String == "pts")
        #expect(Set(put.body.keys) == ["version", "kind", "token", "environment"])
        #expect(phone.worker.targets["pts"] != nil)
        await handler(Self.token)
        #expect(phone.worker.puts.count == 1)
        await handler(Self.otherToken)
        #expect(phone.worker.puts.count == 2)
        phone.clock.advance(8 * Self.day)
        await handler(Self.otherToken)
        #expect(phone.worker.puts.count == 3, "Refreshed after a week")
    }

    // MARK: Turning off

    @Test func turningOffRemovesTheAddressesAndForgetsWhatWasSent() async {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.refreshAtForeground()
        await phone.registrar.receiveToken(Self.token)
        await phone.pushToStartHandler?(Self.token)
        #expect(phone.worker.targets.keys.sorted() == ["alert", "pts"])
        await phone.registrar.removeAll()
        #expect(phone.worker.targets.isEmpty)
        #expect(phone.worker.deletes.map(\.path) == [BighelpPushRegistrar.pushTargetPath, BighelpPushRegistrar.liveActivityTargetPath])
        #expect(phone.registrar.state == BighelpPushRegistrar.State())
        #expect(phone.worker.badSignatures == 0)
        // Turned on again later: sent again.
        await phone.registrar.receiveToken(Self.token)
        #expect(phone.worker.targets["alert"] != nil)
    }

    @Test func aTurnOffThatCannotReachTheServiceStillClearsThePhone() async {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.receiveToken(Self.token)
        phone.worker.mode = .failing(status: 503, code: "notification_service_unavailable")
        await phone.registrar.removeAll()
        #expect(phone.registrar.state.alert == nil)
        #expect(phone.registrar.state.lastErrorCode == nil, "Cleared with the rest")
    }

    @Test func turningOffAgainstAWorkerWithoutTheRoutesIsQuiet() async {
        let phone = Phone()
        defer { phone.cleanup() }
        phone.worker.mode = .notDeployed
        await phone.registrar.removeAll()
        #expect(phone.registrar.state == BighelpPushRegistrar.State())
    }

    // MARK: The signed request

    @Test func theRoutesAreSignedExactlyLikeTheOtherInstallationRequests() async throws {
        let phone = Phone()
        defer { phone.cleanup() }
        await phone.registrar.receiveToken(Self.token)
        // The fake Worker rejects a wrong key, installation or epoch.
        #expect(phone.worker.badSignatures == 0)
        phone.worker.installationID = UUID().uuidString.lowercased()
        await phone.registrar.receiveToken(Self.otherToken)
        #expect(phone.worker.badSignatures == 1)
        #expect(phone.registrar.state.lastErrorCode == BighelpNotificationErrorCode.directPushRefused.rawValue)
    }

    @Test func appVersionIsMarketingVersionThenBuild() {
        #expect(BighelpPushRegistrar.valid(appVersion: "2.6.19(159)"))
        #expect(BighelpPushRegistrar.valid(appVersion: "2.7(1)"))
        #expect(!BighelpPushRegistrar.valid(appVersion: "2.6.19"))
        #expect(!BighelpPushRegistrar.valid(appVersion: "2.6.19-beta(1)"))
        let current = BighelpPushRegistrar.currentAppVersion(bundle: .main)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        #expect(current == "\(version)(\(build))")
    }
}
