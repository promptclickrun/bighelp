import Foundation
import Testing
@testable import Bighelp

/// Every way notification setup stops has its own short code and plain message (#443).
@MainActor struct NotificationErrorCodeTests {
    typealias Code = BighelpNotificationErrorCode

    // MARK: The catalog

    @Test func everyCodeIsShortUniqueAndHasAMessage() {
        let codes = Code.allCases.map(\.rawValue)
        #expect(Set(codes).count == codes.count)
        for code in Code.allCases {
            #expect(code.rawValue.range(of: "^NS-[1-59][0-9]{2}$", options: .regularExpression) != nil, "\(code)")
            #expect(code.message.count > 20 && code.message.count <= 240, "\(code.rawValue)")
            #expect(!code.message.contains("  "), "\(code.rawValue)")
        }
        let messages = Code.allCases.map(\.message)
        // Codes that share words say the same thing for the same reason (a wrong clock, a
        // build that can't use notifications); everything else reads differently.
        let shared = Dictionary(grouping: Code.allCases, by: \.message).filter { $0.value.count > 1 }.values
        #expect(Set(shared.map { Set($0) }) == [[.signUpClockWrong, .grantClockWrong], [.pushKeyMissing, .pushAddressInvalid]])
        #expect(messages.count == Code.allCases.count)
    }

    /// "Check again" or "try again" only where trying again can help.
    @Test func retryAdviceOnlyWhereRetryingCanHelp() {
        for code in Code.allCases {
            let words = code.message.lowercased()
            if code.canRetry {
                #expect(words.contains("try again") || words.contains("wait"), "\(code.rawValue) says what to try")
            } else {
                #expect(!words.contains("try again") && !words.contains("check again"), "\(code.rawValue) can't be fixed by retrying")
            }
        }
    }

    @Test func messagesUsePlainBighelpWords() {
        for code in Code.allCases {
            let message = code.message
            for banned in ["bighelp account", "Link", "OpenAI", "Anthropic", "BuzzKit", "APNs", "grant", "Loopdy", "loopdy"] {
                #expect(!message.contains(banned), "\(code.rawValue) says \(banned)")
            }
        }
    }

    /// The FAQ lists every code, so a person with one can look it up.
    @Test func everyCodeIsDocumented() throws {
        let doc = try String(contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "docs/NOTIFICATION_ERROR_CODES.md"), encoding: .utf8)
        for code in Code.allCases {
            #expect(doc.contains("| \(code.rawValue) |"), "\(code.rawValue) is missing from the FAQ")
        }
    }

    // MARK: Each failure gets its own code

    private func code(_ error: any Error, at step: BighelpNotificationSetupStep) -> Code {
        BighelpNotificationSetupFailure(step: step, error: error).code
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, Code.offline), (.dataNotAllowed, .offline),
        (.cannotFindHost, .serviceUnreachable), (.cannotConnectToHost, .serviceUnreachable),
        (.dnsLookupFailed, .serviceUnreachable), (.networkConnectionLost, .serviceUnreachable),
        (.timedOut, .serviceTimedOut), (.secureConnectionFailed, .serviceInsecure),
        (.serverCertificateUntrusted, .serviceInsecure), (.badServerResponse, .serviceAnswerUnreadable),
        (.cannotParseResponse, .serviceAnswerUnreadable), (.cancelled, .interrupted),
        (.backgroundSessionWasDisconnected, .networkProblem),
    ])
    func urlErrorsAtSignUpNameTheNetworkProblem(error: URLError.Code, expected: Code) {
        #expect(code(URLError(error), at: .serviceSignUp) == expected)
        #expect(code(URLError(error), at: .serviceGrant) == expected, "The same service at another step")
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, Code.computerConnectionFailed), (.timedOut, .computerTimedOut),
        (.secureConnectionFailed, .computerInsecure), (.badServerResponse, .computerAnswerUnreadable),
    ])
    func urlErrorsAtTheComputerNameTheComputer(error: URLError.Code, expected: Code) {
        #expect(code(URLError(error), at: .computerEnroll) == expected)
    }

    /// Every notification service code the app knows has its own app code.
    @Test func everyNotificationServiceCodeHasItsOwnAppCode() {
        for (serverCode, expected) in Code.serviceCodes {
            let error = BighelpLinkAPIError.requestFailed(status: 409, code: serverCode)
            #expect(code(error, at: .serviceSignUp) == expected, "\(serverCode)")
            #expect(![Code.serviceRefusedUnknown, .serviceProblem, .unexpected].contains(expected))
        }
        for serverCode in Code.serviceRequestCodes {
            #expect(code(BighelpLinkAPIError.requestFailed(status: 400, code: serverCode), at: .serviceGrant)
                == .serviceRequestRefused, "\(serverCode)")
        }
        #expect(code(BighelpLinkAPIError.requestFailed(status: 400, code: "notification_new_thing"), at: .serviceGrant)
            == .serviceRefusedUnknown)
        #expect(code(BighelpLinkAPIError.requestFailed(status: 500, code: "internal_error"), at: .serviceSignUp) == .serviceProblem)
        #expect(code(BighelpLinkAPIError.requestFailed(status: 429, code: "managed_notification_request_failed"),
                     at: .serviceSignUp) == .serviceBusy)
        #expect(code(BighelpLinkAPIError.invalidResponse, at: .serviceSignUp) == .serviceAnswerUnreadable)
        #expect(code(BighelpLinkAPIError.invalidConfiguration, at: .serviceSignUp) == .appProblem)
    }

    /// The maintainer's named cases, each by its server code.
    @Test(arguments: [
        ("notification_bootstrap_conflict", Code.signUpKeyConflict),
        ("notification_bootstrap_rate_limited", .signUpRateLimited),
        ("notification_credentials_revoked", .signUpEnded),
        ("notification_bootstrap_stale", .signUpClockWrong),
        ("notification_grant_expiry_invalid", .grantClockWrong),
        ("notification_idempotency_conflict", .grantRetryConflict),
    ])
    func namedServiceCodes(serverCode: String, expected: Code) {
        #expect(code(BighelpLinkAPIError.requestFailed(status: 409, code: serverCode), at: .serviceSignUp) == expected)
    }

    /// Every plugin code the app knows has its own app code.
    @Test func everyPluginCodeHasItsOwnAppCode() {
        for (pluginCode, expected) in Code.pluginCodes {
            let error = DirectHostNotificationError.rejected(status: 503, code: pluginCode)
            #expect(code(error, at: .computerEnroll) == expected, "\(pluginCode)")
            #expect(![Code.pluginRefusedUnknown, .hermesProblem, .unexpected].contains(expected))
        }
        #expect(code(DirectHostNotificationError.rejected(status: 409, code: "notification_new_thing"), at: .computerEnroll)
            == .pluginRefusedUnknown)
        #expect(code(DirectHostNotificationError.backendRestartRequired, at: .computerCheck) == .restartHermes)
        #expect(code(DirectHostNotificationError.featureUnavailable, at: .computerCheck) == .pluginTooOld)
    }

    /// A computer's own words never reach the code; only its short codes do.
    @Test func pluginRejectionsKeepOnlyShortCodes() throws {
        let known = try JSONSerialization.data(withJSONObject: ["detail": ["code": "notification_service_unavailable"]])
        #expect(DirectHostNotificationClient.pluginRejection(status: 503, body: known)
            == .rejected(status: 503, code: "notification_service_unavailable"))
        for odd in ["https://studio.example.com/x", "notification_6f1c2a7e-9b1d-4c1a-8e8e-123456789abc", "Not allowed", ""] {
            let body = try JSONSerialization.data(withJSONObject: ["detail": ["code": odd]])
            #expect(DirectHostNotificationClient.pluginRejection(status: 403, body: body) == nil, "\(odd)")
        }
        let validation = try JSONSerialization.data(withJSONObject: ["detail": [["loc": ["body"], "msg": "field required"]]])
        #expect(DirectHostNotificationClient.pluginRejection(status: 422, body: validation) == nil)
        #expect(DirectHostNotificationClient.pluginRejection(status: 200, body: known) == nil)
    }

    /// Every push service diagnostic the app knows has its own app code.
    @Test func everyPushDiagnosticHasItsOwnAppCode() {
        for (diagnostic, expected) in Code.providerCodes {
            for stage in [BighelpManagedNotificationSetupError.Stage.providerIdentity, .deviceRegistration, .providerReadiness] {
                #expect(code(BighelpManagedNotificationSetupError(stage: stage, code: diagnostic), at: .pushRegistration)
                    == expected, "\(diagnostic)")
            }
        }
        let readiness = BighelpManagedNotificationSetupError.self
        #expect(code(readiness.init(stage: .providerReadiness, code: "readiness_no_active_push_credential_production"),
                     at: .pushCheck) == .noPushCredential)
        #expect(code(readiness.init(stage: .providerReadiness, code: "link_backend_503_buzzkit_transport_unavailable"),
                     at: .pushCheck) == .pushServiceOutOfReach)
        #expect(code(readiness.init(stage: .providerReadiness, code: "link_backend_403_notification_credentials_revoked"),
                     at: .pushCheck) == .signUpEnded)
        #expect(code(readiness.init(stage: .providerIdentity, code: "identity_provider_quota_exceeded"),
                     at: .pushSignIn) == .pushSignInRefused)
        #expect(code(readiness.init(stage: .notificationPermission), at: .permission) == .permissionOff)
        #expect(code(readiness.init(stage: .providerReadiness, code: "readiness_reason_from_later"), at: .pushCheck)
            == .pushCheckFailed)
    }

    /// What really went wrong under a push step names it: the network, or the service's answer.
    @Test func theCauseUnderAPushStepNamesIt() {
        let offline = BighelpManagedNotificationSetupError(
            stage: .providerIdentity, code: "identity_connection_failed",
            underlying: BighelpNotificationErrorKind(URLError(.notConnectedToInternet)))
        #expect(code(offline, at: .pushSignIn) == .offline)
        let filtered = BighelpManagedNotificationSetupError(
            stage: .providerIdentity, code: "identity_connection_failed",
            underlying: BighelpNotificationErrorKind(URLError(.cannotFindHost)))
        #expect(code(filtered, at: .pushSignIn) == .serviceUnreachable)
        let revoked = BighelpManagedNotificationSetupError(
            stage: .providerIdentity, code: "notification_credentials_revoked",
            underlying: .service(status: 403, code: "notification_credentials_revoked"))
        #expect(code(revoked, at: .pushSignIn) == .signUpEnded)
        let pushServiceDown = BighelpManagedNotificationSetupError(
            stage: .deviceRegistration, code: "buzzkit_device_registration_failed",
            underlying: BighelpNotificationErrorKind(URLError(.cannotConnectToHost)))
        #expect(code(pushServiceDown, at: .pushRegistration) == .pushServiceUnreachable)
        let mismatch = BighelpManagedNotificationSetupError(
            stage: .deviceRegistration, code: "buzzkit_subscription_registration_failed",
            underlying: .hermes(.invalidResponse))
        #expect(code(mismatch, at: .pushRegistration) == .pushSubscriptionUnconfirmed)
        let unreadable = BighelpManagedNotificationSetupError(stage: .providerReadiness, underlying: .hermes(.invalidResponse))
        #expect(code(unreadable, at: .pushCheck) == .serviceAnswerUnreadable)
        let nested = BighelpManagedNotificationSetupError(
            stage: .providerIdentity, code: "identity_request_failed",
            underlying: .provider(.init(stage: .providerBootstrap, code: "buzzkit_sdk_not_awaitable")))
        #expect(code(nested, at: .pushSignIn) == .appProblem)
    }

    @Test(arguments: [
        (DirectHermesError.notConnected, BighelpNotificationSetupStep.pluginCheck, Code.computerNotConnected),
        (.identityChanged, .pluginCheck, .computerSignInChanged),
        (.connectionFailed, .computerCheck, .computerConnectionFailed),
        (.timedOut(outcomeUnknown: true), .computerEnroll, .computerTimedOut),
        (.tlsRequired, .computerCheck, .computerInsecure),
        (.invalidResponse, .pluginCheck, .computerAnswerUnreadable),
        (.invalidResponse, .serviceGrant, .serviceAnswerUnreadable),
        (.serverUnavailable, .computerEnroll, .hermesProblem),
        (.rateLimited, .computerEnroll, .computerBusy),
        (.invalidCredentials, .computerCheck, .computerSignInRefused),
        (.unsupportedAuthentication, .computerEnroll, .notificationRoutesMissing),
        (.rpcRejected(code: -32601), .pluginInstall, .pluginInstallUnsupported),
        (.rpcRejected(code: 403), .pluginInstall, .pluginInstallNotAllowed),
        (.rpcRejected(code: 5026), .pluginEnable, .pluginRejected),
        (.rpcRejected(code: 42), .pluginInstall, .pluginChangeRefused),
        (.secureStorageUnavailable, .serviceSignUp, .keychainUnavailable),
        (.savedConnectionInvalid, .serviceSignUp, .savedSetupDamaged),
        (.secureStorageChanged, .contextCheck, .interrupted),
        (.tooManyRequests, .contextCheck, .alreadyRunning),
    ])
    func hermesErrorsByStep(error: DirectHermesError, step: BighelpNotificationSetupStep, expected: Code) {
        #expect(code(error, at: step) == expected)
    }

    @Test func phoneErrorsNameThePhone() {
        #expect(code(CancellationError(), at: .serviceGrant) == .interrupted)
        #expect(code(CocoaError(.fileWriteOutOfSpace), at: .savingSetup) == .saveFailed)
        #expect(code(CocoaError(.fileReadNoPermission), at: .loadingSetup) == .keychainUnavailable)
        #expect(code(BighelpLinkCryptoError.invalidBase64URL, at: .serviceSignUp) == .savedSetupDamaged)
        #expect(code(BighelpRelayTrustError.keychain(-25308), at: .computerEnroll) == .keychainUnavailable)
        #expect(BighelpNotificationErrorKind(BighelpRelayTrustError.keychain(-25308)).description == "Keychain -25308")
        #expect(code(BighelpRelayTrustError.invalidSenderKey, at: .computerEnroll) == .grantFailedChecks)
        #expect(code(URLError(.timedOut), at: .pluginRelease) == .pluginReleaseUnavailable)
        struct Novel: Error {}
        #expect(code(Novel(), at: .serviceSignUp) == .unexpected)
    }

    @Test(arguments: [
        (URLError(.notConnectedToInternet) as any Error, Code.turnOffServiceUnreachable),
        (BighelpLinkAPIError.requestFailed(status: 503, code: "notification_revocation_unconfirmed"), .turnOffUnconfirmed),
        (BighelpLinkAPIError.requestFailed(status: 503, code: "notification_cleanup_unavailable"), .turnOffUnconfirmed),
        (BighelpLinkAPIError.requestFailed(status: 403, code: "notification_signature_invalid"), .turnOffRefused),
        (DirectHermesError.secureStorageUnavailable, .turnOffPhoneDataFailed),
        (CancellationError(), .turnOffInterrupted),
    ])
    func turnOffFailures(error: any Error, expected: Code) {
        #expect(code(error, at: .turnOff) == expected)
    }

    /// Naming a failure never moves setup somewhere else: each error leaves the state it always did.
    @Test func statesStayWhereTheyWere() {
        typealias Failure = BighelpNotificationSetupFailure
        #expect(Failure(step: .pushCheck, error: BighelpManagedNotificationSetupError(stage: .providerReadiness)).state
            == .prerequisitesRequired)
        #expect(Failure(step: .pluginCheck, error: DirectHermesError.notConnected).state == .notConnected)
        #expect(Failure(step: .pluginCheck, error: DirectHermesError.identityChanged).state == .signInChanged)
        #expect(Failure(step: .pluginInstall, error: DirectHermesError.rpcRejected(code: -32601)).state == .unsupported)
        #expect(Failure(step: .pluginInstall, error: DirectHermesError.rpcRejected(code: 403)).state == .permissionDenied)
        #expect(Failure(step: .pluginInstall, error: DirectHermesError.rpcRejected(code: 5026)).state == .managementRejected)
        #expect(Failure(step: .serviceSignUp, error: BighelpLinkAPIError.requestFailed(status: 404, code: "not_found")).state
            == .prerequisitesRequired)
        #expect(Failure(step: .serviceSignUp, error: URLError(.notConnectedToInternet)).state == .outcomeUnknown)
        #expect(Failure(step: .serviceGrant, error: CancellationError()).state == .outcomeUnknown)
        let named = Failure(.computerKeyChanged, step: .serviceGrant, check: "computer_key_changed",
                            was: DirectHermesError.identityChanged)
        #expect(named.state == .signInChanged)
        #expect(Failure(step: .computerEnroll, error: named) == named, "A named failure keeps its name")
    }

    // MARK: Copied details and logs

    /// Copy Details holds the code, the step, the kind of error, the app and the system, and
    /// nothing that names a computer, a person or a sign-in.
    @Test func copiedDetailsCarryNoAddressOrIdentifier() {
        let secrets = ["studio.example.com", "alice", "6f1c2a7e", "fixture-token", "Studio Mac"]
        let failures: [BighelpNotificationSetupFailure] = [
            .init(step: .pluginInstall, error: DirectHermesError.rpcRejected(
                code: 5026, message: HermesRefusalMessage("Install refused for alice on https://studio.example.com"))),
            .init(step: .serviceSignUp, error: BighelpLinkAPIError.requestFailed(
                status: 403, code: "https://studio.example.com/fixture-token")),
            .init(step: .serviceGrant, error: BighelpLinkAPIError.requestFailed(
                status: 409, code: "notification_6f1c2a7e9b1d4c1a8e8e123456789abc")),
            .init(step: .pushRegistration, error: BighelpManagedNotificationSetupError(
                stage: .deviceRegistration, code: "identity_provider_Studio Mac alice")),
            .init(step: .computerEnroll, error: DirectHermesError.webPageInsteadOfHermes(throughCloudflare: true)),
            .init(step: .serviceSignUp, error: URLError(.cannotFindHost, userInfo: [
                NSURLErrorFailingURLStringErrorKey: "https://studio.example.com/v1"])),
        ]
        for failure in failures {
            let text = BighelpNotificationFailureReport.text(failure)
            for secret in secrets { #expect(!text.contains(secret), "\(text)") }
            #expect(text.contains("Code: \(failure.code.rawValue)"))
            #expect(text.contains("Step: \(failure.step.title)"))
            #expect(text.contains("App: ") && text.contains("System: "))
        }
        let rpc = BighelpNotificationFailureReport.text(failures[0])
        #expect(rpc.contains("rpcRejected(5026)"))
        let url = BighelpNotificationFailureReport.text(failures[5])
        #expect(url.contains("URLError -1003"))
        #expect(BighelpNotificationFailureReport.text(failures[1]).contains("HTTP 403 unrecognized"))
    }

    @Test func detailsNameTheKindOfError() {
        #expect(BighelpNotificationErrorKind(URLError(.notConnectedToInternet)).description == "URLError -1009")
        #expect(BighelpNotificationErrorKind(BighelpLinkAPIError.requestFailed(status: 409, code: "notification_bootstrap_conflict"))
            .description == "Notification service HTTP 409 notification_bootstrap_conflict")
        #expect(BighelpNotificationErrorKind(DirectHostNotificationError.rejected(status: 503, code: "notification_service_unavailable"))
            .description == "Plugin HTTP 503 notification_service_unavailable")
        #expect(BighelpNotificationErrorKind(DirectHermesError.identityChanged).description == "DirectHermesError.identityChanged")
        #expect(BighelpNotificationErrorKind(BighelpManagedNotificationSetupError(
            stage: .deviceRegistration, code: "apns_registration_failed")).description == "Push deviceRegistration apns_registration_failed")
        #expect(BighelpNotificationErrorKind(CancellationError()).description == "CancellationError")
    }

    @Test func lastFailureIsKeptForThisBuildAndHost() throws {
        let suite = "bighelp.test.last-failure." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UUID()
        let failure = BighelpNotificationSetupFailure(step: .serviceSignUp, error: URLError(.notConnectedToInternet))
        BighelpNotificationLastFailure.save(failure, hostID: host, now: Date(timeIntervalSince1970: 1_800_000_000),
                                            defaults: defaults)
        let saved = try #require(BighelpNotificationLastFailure.load(defaults))
        #expect(saved.code == .offline && saved.step == .serviceSignUp && saved.hostID == host)
        #expect(saved.kind == "URLError -1009")
        #expect(saved.state == .outcomeUnknown)
        #expect(saved.build == BighelpNotificationFailureReport.build)
        #expect(BighelpNotificationFailureReport.text(saved) == BighelpNotificationFailureReport.text(failure))
        BighelpNotificationLastFailure.clear(defaults)
        #expect(BighelpNotificationLastFailure.load(defaults) == nil)
    }
}
