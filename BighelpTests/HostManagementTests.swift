import Foundation
import Testing
@testable import Bighelp

@MainActor struct HostManagementTests {
    @Test(arguments: [BighelpManagedNotificationSetupError.Stage.providerBootstrap, .providerIdentity,
                      .notificationPermission, .deviceRegistration, .providerReadiness])
    func providerFailureDoesNotClaimPluginOrHostFailure(stage: BighelpManagedNotificationSetupError.Stage) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        let error = BighelpManagedNotificationSetupError(stage: stage)
        setup.error = error
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management)
        await model.enable()
        #expect(model.state == .prerequisitesRequired)
        #expect(model.providerFailure == error)
        #expect(model.failure?.code.rawValue.hasPrefix("NS-2") == true, "A push failure is this phone's")
        #expect(model.message == model.failure?.message)
        #expect(management.actions == ["list"])
        setup.error = nil
        await model.enable()
        #expect(model.state == .enabled)
        #expect(model.providerFailure == nil)
    }

    @Test(arguments: [true, false])
    func openingPluginDetailsReadsInstalledStateWithoutMutation(installed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = installed ? [fixture.plugin(enabled: true)] : []
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management, enrollNotifications: false)
        await model.refreshInstalledState()
        #expect(model.state == (installed ? .installed : .notConfigured))
        #expect(management.actions == ["list"])
        #expect(fixture.registry.hosts.first?.pluginIntent == nil)
        #expect(fixture.registry.hosts.first?.notificationState == fixture.host.notificationState)
    }

    @Test func disconnectedNotificationSetupDoesNotClaimAnUnconfirmedInstall() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.isConnected = false
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management)

        await model.enable()
        #expect(model.state == .notConnected)
        #expect(model.failure?.code == .computerNotConnected)
        #expect(model.message == BighelpNotificationErrorCode.computerNotConnected.message)
        #expect(model.actionTitle == "Retry Connection")
        #expect(management.actions.isEmpty)
        #expect(setup.calls == 0)
        #expect(fixture.registry.hosts.first?.notificationState == .notConnected)

        management.isConnected = true
        await model.enable()
        #expect(model.state == .enabled)
        #expect(management.actions == ["list"])
        #expect(setup.calls == 1)
    }

    /// A connection signed in to another computer (or as someone else) asks to sign in to this
    /// computer again, and setup reads nothing from it.
    @Test func aChangedSignInAsksToSignInToThisComputerAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let other = DirectHermesSavedConnection(endpoint: fixture.saved.endpoint, authentication: .bearer(
            accessToken: UUID().uuidString, refreshToken: nil, expiresAt: nil), provider: "basic", userID: "someone-else")
        let management = Manager(saved: other)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management)

        await model.enable()
        #expect(model.state == .signInChanged)
        #expect(model.failure?.code == .computerSignInChanged)
        #expect(model.message == "This computer's sign-in changed. Sign in to this computer again, then try again.")
        #expect(model.actionTitle == "Check Setup Again")
        #expect(management.actions.isEmpty, "Nothing is read from another computer's connection")
        #expect(setup.calls == 0)
        #expect(fixture.registry.hosts.first?.notificationState == .notConnected, "Saved as a state older builds read")
    }

    /// The setup log and Copy Details name what kind of error stopped setup, and nothing the
    /// computer or service wrote: a server's code only when it is one of its short codes.
    @Test func setupLogNamesOnlyTheKindOfError() {
        #expect(BighelpNotificationErrorKind(DirectHermesError.identityChanged).description == "DirectHermesError.identityChanged")
        #expect(BighelpNotificationErrorKind(BighelpLinkAPIError.requestFailed(status: 409, code: "fixture-detail")).description
            == "Notification service HTTP 409 unrecognized")
        #expect(BighelpNotificationErrorKind(BighelpManagedNotificationSetupError(stage: .deviceRegistration, code: "fixture-detail"))
            .description == "Push deviceRegistration unrecognized")
        #expect(BighelpNotificationErrorKind(CancellationError()).description == "CancellationError")
    }

    /// Everything that used to end in "Couldn't confirm setup" (#443) now says which step
    /// stopped and why, with a code people can send us. Where setup stands doesn't change.
    @Test(arguments: [
        (URLError(.notConnectedToInternet) as any Error, BighelpNotificationErrorCode.offline),
        (URLError(.cannotFindHost), .serviceUnreachable),
        (URLError(.secureConnectionFailed), .serviceInsecure),
        (BighelpLinkAPIError.requestFailed(status: 409, code: "notification_bootstrap_conflict"), .signUpKeyConflict),
        (BighelpLinkAPIError.requestFailed(status: 429, code: "notification_bootstrap_rate_limited"), .signUpRateLimited),
        (BighelpLinkAPIError.requestFailed(status: 401, code: "notification_bootstrap_stale"), .signUpClockWrong),
        (BighelpLinkAPIError.invalidResponse, .serviceAnswerUnreadable),
        (DirectHostNotificationError.rejected(status: 503, code: "notification_service_unavailable"), .computerCannotReachService),
        (DirectHermesError.secureStorageUnavailable, .keychainUnavailable),
        (DirectHermesError.tooManyRequests, .alreadyRunning),
        (CancellationError(), .interrupted),
    ])
    func failuresThatSaidCouldNotConfirmNameTheirCause(error: any Error, expected: BighelpNotificationErrorCode) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        setup.error = error
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management, defaults: fixture.defaults)
        await model.enable()
        #expect(model.state == BighelpNotificationSetupFailure.state(after: error), "The state is what it always was")
        #expect(model.failure?.code == expected)
        #expect(model.message == expected.message)
        #expect(model.message != HostNotificationState.outcomeUnknown.message)
        #expect(BighelpNotificationLastFailure.load(fixture.defaults)?.code == expected)
    }

    @Test func pluginFailuresNameThePluginStep() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.installError = .rpcRejected(code: 5026)
        fixture.registry.notificationSetup = Enrollment()
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management, defaults: fixture.defaults)
        await model.enable()
        #expect(model.state == .managementRejected)
        #expect(model.failure?.code == .pluginRejected && model.failure?.step == .pluginInstall)

        management.installError = .timedOut(outcomeUnknown: true)
        await model.enable()
        #expect(model.state == .outcomeUnknown)
        #expect(model.failure?.code == .computerTimedOut && model.failure?.step == .pluginInstall)

        let restart = Enrollment()
        restart.result = .backendRestartRequired
        fixture.registry.notificationSetup = restart
        management.installError = nil
        management.rows = [fixture.plugin(enabled: true)]
        await model.enable()
        #expect(model.state == .backendRestartRequired)
        #expect(model.failure?.code == .restartHermes)

        restart.result = .prerequisitesRequired
        await model.enable()
        #expect(model.state == .prerequisitesRequired)
        #expect(model.failure?.code == .pluginTooOld)

        restart.result = .enabled
        await model.enable()
        #expect(model.state == .enabled)
        #expect(model.failure == nil)
    }

    /// No Check Again for a failure that trying again can't fix: its message says what to do.
    @Test func failuresRetryingCannotFixOfferNoRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        setup.error = BighelpLinkAPIError.requestFailed(status: 403, code: "notification_credentials_revoked")
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management, defaults: fixture.defaults)
        await model.enable()
        #expect(model.failure?.code == .signUpEnded)
        #expect(!model.offersRetry)
        #expect(model.actionTitle == nil)
        #expect(!model.message.localizedCaseInsensitiveContains("check again"))

        setup.error = URLError(.notConnectedToInternet)
        await model.enable()
        #expect(model.offersRetry)
        #expect(model.actionTitle != nil)
    }

    /// Settings opened again shows the same code, on this build, and lets people try again:
    /// what stopped it may be fixed by now.
    @Test func aStoppedSetupKeepsItsCodeWhenSetupOpensAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        setup.error = BighelpLinkAPIError.requestFailed(status: 409, code: "notification_bootstrap_conflict")
        fixture.registry.notificationSetup = setup
        let first = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management, defaults: fixture.defaults)
        await first.enable()
        #expect(!first.offersRetry)

        let reopened = HostNotificationSetupModel(host: try #require(fixture.registry.hosts.first), registry: fixture.registry,
            pin: fixture.pin, management: management, defaults: fixture.defaults)
        #expect(reopened.failure?.code == .signUpKeyConflict)
        #expect(reopened.failureIsFromEarlierRun)
        #expect(reopened.offersRetry)

        var other = try #require(fixture.registry.hosts.first)
        other.notificationState = .notConfigured
        let unrelated = HostNotificationSetupModel(host: other, registry: fixture.registry,
            pin: fixture.pin, management: management, defaults: fixture.defaults)
        #expect(unrelated.failure == nil, "A different state is a different setup")
    }

    @Test func unreachableGitHubHasItsCode() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            releases: FixedPluginReleases(.failure(.unreachable)), management: Manager(saved: fixture.saved),
            enrollNotifications: false, defaults: fixture.defaults)
        await model.enable()
        #expect(model.state == .releaseUnavailable)
        #expect(model.failure?.code == .pluginReleaseUnavailable && model.failure?.step == .pluginRelease)
    }

    @Test func savedNotificationOptInDoesNotPromptAgainOnReopen() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var host = fixture.host
        host.notificationState = .enabled
        try fixture.registry.update(host)
        let management = Manager(saved: fixture.saved)
        let model = HostNotificationSetupModel(host: host, registry: fixture.registry,
            pin: fixture.pin, management: management)
        #expect(model.state == .enabled)
        #expect(model.actionTitle == nil)
        #expect(management.actions.isEmpty)
    }

    @Test func unrelatedPluginStatusCannotBlockExactInstalledBighelp() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [
            .object(["name": .string("unrelated-plugin"), "status": .string("future-status")]),
            fixture.plugin(enabled: true)
        ]
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management, enrollNotifications: false)
        await model.enable()
        #expect(model.state == .installed)
        #expect(management.actions == ["list"])
    }

    @Test func bighelpTargetReadbackStillRejectsInvalidOrDuplicateRows() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for rows in [
            [fixture.plugin(enabled: true), fixture.plugin(enabled: true)],
            [.object(["name": .string("loopdy"), "key": .string("loopdy"), "status": .string("future-status")])],
            [.object(["name": .string("loopdy"), "key": .string("loopdy"), "status": .string("enabled"), "pinned_sha": .string("invalid")])]
        ] {
            #expect(throws: DirectHermesError.self) {
                try HostInstalledPlugin.decodeList(.object(["plugins": .array(rows)]))
            }
        }
    }

    @Test(arguments: [true, false])
    func featurePluginSetupNeverEnrollsNotificationsOrChangesTheirState(alreadyInstalled: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        if alreadyInstalled { management.rows = [fixture.plugin(enabled: true)] }
        management.onInstall = { management.rows = [fixture.plugin(enabled: true)] }
        let enrollment = Enrollment()
        fixture.registry.notificationSetup = enrollment
        let previousState = fixture.host.notificationState
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management, enrollNotifications: false)
        await model.enable()
        #expect(model.state == .installed)
        #expect(enrollment.calls == 0)
        #expect(fixture.registry.hosts.first?.notificationState == previousState)
        #expect(management.actions.filter { $0 == "install" }.count == (alreadyInstalled ? 0 : 1))
    }

    @Test func featureSetupEnablesExactPinnedPluginWithoutReinstalling() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        let existingRevision = fixture.pin.revision
        func row(_ enabled: Bool) -> BighelpJSONValue {
            .object(["name": .string("loopdy"), "key": .string("loopdy"),
                     "status": .string(enabled ? "enabled" : "disabled"),
                     "pinned_sha": .string(existingRevision)])
        }
        management.rows = [row(false)]
        management.onToggle = { management.rows = [row(true)] }
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management, enrollNotifications: false)
        await model.enable()
        #expect(model.state == .installed)
        #expect(management.actions == ["list", "toggle", "list"])
        #expect(!management.actions.contains("install"))
    }

    /// No app build pins the plugin: an install uses the newest release on GitHub.
    @Test func featureSetupInstallsTheNewestRelease() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        let releases = try FixedPluginReleases.release("3.0.0", "c")
        management.onInstall = { management.rows = [fixture.row(sha: String(repeating: "c", count: 40), version: "3.0.0")] }
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry, releases: releases,
                                               management: management, enrollNotifications: false)
        await model.enable()
        #expect(model.state == .installed)
        let install = try #require(management.requests.first { $0["action"] == .string("install") })
        #expect(install["ref"] == .string(String(repeating: "c", count: 40)))
        #expect(install["force"] == .boolean(false))
    }

    @Test func anOlderPluginIsUpdatedAndANewerOrEqualOneIsKept() async throws {
        for (installed, replaced) in [("2.19.0", true), ("3.0.0", false), ("3.1.0", false)] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let management = Manager(saved: fixture.saved)
            management.rows = [fixture.row(sha: String(repeating: "e", count: 40), version: installed)]
            management.onInstall = { management.rows = [fixture.row(sha: String(repeating: "c", count: 40), version: "3.0.0")] }
            let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
                releases: try FixedPluginReleases.release("3.0.0", "c"), management: management, enrollNotifications: false)
            await model.enable()
            #expect(model.state == .installed, "\(installed)")
            let install = management.requests.first { $0["action"] == .string("install") }
            #expect((install != nil) == replaced, "\(installed)")
            if replaced { #expect(install?["force"] == .boolean(true)) }
        }
    }

    /// A lost reply may still be installing on the host: that same commit is
    /// reconciled, never a newer release installed on top of it.
    @Test func anUnfinishedInstallIsFinishedWithItsOwnCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var host = fixture.host
        let requested = String(repeating: "b", count: 40)
        host.pluginIntent = .init(identifier: fixture.pin.identifier, revision: requested, profile: nil, phase: .installRequested)
        try fixture.registry.update(host)
        let management = Manager(saved: fixture.saved)
        let releases = try FixedPluginReleases.release("3.0.0", "c")
        let model = HostNotificationSetupModel(host: host, registry: fixture.registry, releases: releases,
                                               management: management, enrollNotifications: false)
        await model.enable()
        #expect(model.state == .outcomeUnknown)
        #expect(!management.actions.contains("install"))
        management.rows = [fixture.row(sha: requested, version: "2.19.0", enabled: true)]
        await model.enable()
        #expect(model.state == .installed)
        #expect(!management.actions.contains("install"))
    }

    @Test func unreachableGitHubIsExplainedAndInstallsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            releases: FixedPluginReleases(.failure(.unreachable)), management: management, enrollNotifications: false)
        await model.enable()
        #expect(model.state == .releaseUnavailable)
        #expect(model.actionTitle == "Try Again")
        #expect(!management.actions.contains("install"))
    }

    @Test func remoteDashboardOffersItsExistingSessionTokenMode() throws {
        let endpoint = try HostAddressInput.endpoint(address: "https://hermes.example.ts.net", port: "9119", allowPrivateHTTP: false)
        let discovery = HostAuthenticationDiscovery(endpoint: endpoint, requiresAuthentication: false, nativePKCE: false, providers: [])
        #expect(discovery.supportsToken)
        #expect(discovery.endpoint.baseURL.port == 9119)
    }

    @Test func aBarePrivateAddressUsesHTTPOnlyWhenAllowed() throws {
        let vpn = try HostAddressInput.endpoint(address: "10.8.0.5:9119", port: "", allowPrivateHTTP: true)
        #expect(vpn.baseURL.absoluteString == "http://10.8.0.5:9119")
        let lan = try HostAddressInput.endpoint(address: "hermes.lan", port: "9119", allowPrivateHTTP: true)
        #expect(lan.baseURL.absoluteString == "http://hermes.lan:9119")
        // A Tailscale name is private too: plain HTTP, not a certificate error.
        let tailnet = try HostAddressInput.endpoint(address: "mac.tail1234.ts.net:9119", port: "", allowPrivateHTTP: true)
        #expect(tailnet.baseURL.absoluteString == "http://mac.tail1234.ts.net:9119")
        // Without the switch, or for a public name, or when https:// is typed, TLS stays.
        #expect(try HostAddressInput.endpoint(address: "10.8.0.5:9119", port: "", allowPrivateHTTP: false).baseURL.scheme == "https")
        #expect(try HostAddressInput.endpoint(address: "hermes.example.com", port: "", allowPrivateHTTP: true).baseURL.scheme == "https")
        #expect(try HostAddressInput.endpoint(address: "https://10.8.0.5:9119", port: "", allowPrivateHTTP: true).baseURL.scheme == "https")
    }

    @Test func workspaceHealthDoesNotRequireAProviderLogin() throws {
        try DirectHermesReleaseContract.validateHealth([
            "ok": .boolean(true), "auth_required": .boolean(false), "version": .string("0.21.2")
        ])
    }

    @Test func dashboardBootstrapIsBoundedAndNeverTreatsALoginPageAsAnonymous() throws {
        let page = #"<html><script>window.__HERMES_SESSION_TOKEN__="fixture-token";window.__HERMES_AUTH_REQUIRED__=false;</script></html>"#
        #expect(try DirectHermesDashboardBootstrap.token(from: Data(page.utf8)) == "fixture-token")
        for invalid in [page.replacingOccurrences(of: "false", with: "true"), page + page,
                        "<html>Login required</html>", page.replacingOccurrences(of: "fixture-token", with: "") ] {
            #expect(throws: DirectHermesError.self) { try DirectHermesDashboardBootstrap.token(from: Data(invalid.utf8)) }
        }
    }

    @Test func dashboardScopeNeverClaimsAProviderUserOrChangesThePort() throws {
        let endpoint = try DirectHermesEndpoint(address: "https://hermes.example.ts.net:9119")
        let saved = DirectHermesSavedConnection(endpoint: endpoint, authentication: .dashboardSession(token: "fixture", automatic: true))
        try saved.validate()
        #expect(saved.provider == nil && saved.userID == nil)
        let authority = try #require(saved.workspaceAuthority)
        #expect(authority.providerID == nil)
        #expect(authority.endpointIdentity == endpoint.identity)
        #expect(try JSONDecoder().decode(WorkspaceAuthority.self, from: JSONEncoder().encode(authority)) == authority)
        let named = try WorkspaceAuthority.direct(endpointIdentity: endpoint.identity, providerID: "password", userID: "person")
        #expect(authority != named && authority.cacheScopeID != named.cacheScopeID)
        var changed = saved
        changed.authentication = .dashboardSession(token: "rotated-fixture", automatic: true)
        #expect(saved.identity == changed.identity)
        #expect(saved.workspaceAuthority == changed.workspaceAuthority)
    }

    @Test func hostProviderMethodsAreOfferedWithoutChangingItsConfiguration() throws {
        let endpoint = try DirectHermesEndpoint(address: "https://hermes.example.ts.net:9119")
        let discovery = HostAuthenticationDiscovery(endpoint: endpoint, requiresAuthentication: true, nativePKCE: true,
            providers: [.init(id: "basic", name: "Password", supportsPassword: true), .init(id: "oauth", name: "Dashboard", supportsPassword: false)])
        #expect(discovery.supportsToken && discovery.supportsPassword && discovery.supportsBrowser)
        #expect(!discovery.supportsDashboard)
    }

    @Test func separatePortKeepsURLPrefixAndRejectsConflictingAuthority() throws {
        let address = try HostAddressInput.endpoint(address: "https://example.com/hermes", port: "9443", allowPrivateHTTP: false)
        #expect(address.identity == "https://example.com:9443/hermes")
        #expect(throws: DirectHermesError.self) { try HostAddressInput.endpoint(address: "https://example.com:443", port: "9443", allowPrivateHTTP: false) }
        #expect(throws: DirectHermesError.self) { try HostAddressInput.endpoint(address: "https://user:secret@example.com", port: "443", allowPrivateHTTP: false) }
    }

    @Test func exactInstalledPinNeedsActualEnrollmentAndNeverReinstalls() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        setup.result = .backendRestartRequired
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management)
        await model.enable()
        #expect(management.actions == ["list"])
        #expect(model.state == .backendRestartRequired)
        #expect(setup.calls == 1)
    }

    @Test func lostInstallReplyReconcilesExactPinWithoutReplay() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.onInstall = { management.rows = [fixture.plugin(enabled: true)] }
        management.installError = .disconnected(outcomeUnknown: true)
        let setup = Enrollment()
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry, pin: fixture.pin, management: management)
        await model.enable()
        #expect(management.actions.filter { $0 == "install" }.count == 1)
        #expect(model.state == .enabled)
        await model.enable()
        #expect(management.actions.filter { $0 == "install" }.count == 1)
        #expect(management.requests.allSatisfy { $0["force"] != .boolean(true) && $0["profile"] == nil })
    }

    @Test(arguments: [true, false])
    func installedPluginUsesEnrollmentCompatibilityInsteadOfInstallPin(pinned: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [.object(["name": .string("loopdy"), "key": .string("loopdy"),
            "status": .string("enabled"),
            "pinned_sha": pinned ? .string(String(repeating: "b", count: 40)) : .null])]
        let setup = Enrollment()
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management)

        await model.enable()

        #expect(model.state == .enabled)
        #expect(management.actions == ["list"])
        #expect(setup.calls == 1)
        #expect(fixture.registry.hosts.first?.pluginIntent == nil)
    }

    @Test func installedPluginCanEnrollAfterAppInstallPinChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var host = fixture.host
        host.pluginIntent = .init(identifier: fixture.pin.identifier,
            revision: String(repeating: "b", count: 40), profile: nil, phase: .verified)
        try fixture.registry.update(host)
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: host, registry: fixture.registry,
            pin: fixture.pin, management: management)

        await model.enable()

        #expect(model.state == .enabled)
        #expect(management.actions == ["list"])
        #expect(setup.calls == 1)
    }

    @Test func existingPluginDoesNotNeedANewInstallationPinOrInventReadiness() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        setup.result = .prerequisitesRequired
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: nil, management: management)

        await model.enable()

        #expect(model.state == .prerequisitesRequired)
        #expect(management.actions == ["list"])
        #expect(setup.calls == 1)
    }

    @Test func unavailableOptionalNotificationRouteIsReportedAsPrerequisites() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        setup.error = BighelpLinkAPIError.requestFailed(status: 404, code: "not_found")
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management)

        await model.enable()

        #expect(model.state == .prerequisitesRequired)
        #expect(management.actions == ["list"])
        #expect(setup.calls == 1)
    }

    @Test func unknownAbsentInstallNeverRetriesAndObservedPluginIsReused() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.installError = .disconnected(outcomeUnknown: true)
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry, pin: fixture.pin, management: management)
        await model.enable()
        await model.enable()
        #expect(management.actions.filter { $0 == "install" }.count == 1)
        #expect(model.state == .outcomeUnknown)
        management.rows = [.object(["name": .string("loopdy"), "key": .string("loopdy"), "status": .string("enabled"), "pinned_sha": .string(String(repeating: "b", count: 40))])]
        await model.enable()
        #expect(model.state == .prerequisitesRequired)
        #expect(management.actions.filter { $0 == "install" }.count == 1)
    }

    @Test func accountSwitchKeepsLegacyHostMetadataPrivateUntilExplicitMigration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(fixture.registry.hosts.count == 1)
        #expect(fixture.registry.selectedWorkspace?.isConnected == false)
        fixture.registry.bind(deviceID: "other-account", authorizationEpoch: 1)
        #expect(fixture.registry.hosts.isEmpty)
        fixture.registry.bind(deviceID: "test-account", authorizationEpoch: 1)
        #expect(fixture.registry.hosts == [fixture.host])
    }

    private final class Enrollment: HostNotificationSetupServing {
        var calls = 0
        var result: HostNotificationSetupResult = .enabled
        var error: (any Error)?
        func enroll(host: BighelpConfiguredHost, connection: DirectHermesSavedConnection,
                    isCurrent: @escaping @MainActor () -> Bool) async throws -> HostNotificationSetupResult {
            guard isCurrent() else { throw DirectHermesError.secureStorageChanged }
            calls += 1
            if let error { throw error }
            return result
        }
        func removeLocalEnrollment(host: BighelpConfiguredHost) throws {}
    }
    private final class Manager: HostPluginManagementServing {
        var isConnected = true
        var savedConnection: DirectHermesSavedConnection?
        var rows: [BighelpJSONValue] = []
        var actions: [String] = []
        var requests: [[String: BighelpJSONValue]] = []
        var installError: DirectHermesError?
        var onInstall: (() -> Void)?
        var onToggle: (() -> Void)?
        init(saved: DirectHermesSavedConnection) { savedConnection = saved }
        func reconnect() async {}
        func managePlugins(_ params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            requests.append(params)
            let action = params["action"]?.string ?? ""
            actions.append(action)
            if action == "install" { onInstall?(); if let installError { throw installError } }
            if action == "toggle" { onToggle?() }
            return .object(["plugins": .array(rows)])
        }
    }
    @MainActor private struct Fixture {
        let registry: BighelpHostRegistry
        let host: BighelpConfiguredHost
        let saved: DirectHermesSavedConnection
        let pin: HostPluginPin
        let root: URL
        let defaultsSuite = "bighelp.test.host-management." + UUID().uuidString
        var defaults: UserDefaults { UserDefaults(suiteName: defaultsSuite)! }
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            registry = BighelpHostRegistry(root: root, keychainService: "app.loopdy.test.host-management." + UUID().uuidString)
            registry.bind(deviceID: "test-account", authorizationEpoch: 1)
            let scope = try #require(registry.accountScope)
            let endpoint = try DirectHermesEndpoint(address: "https://host.example")
            saved = DirectHermesSavedConnection(endpoint: endpoint, authentication: .bearer(accessToken: UUID().uuidString, refreshToken: nil, expiresAt: nil), provider: "basic", userID: "fixture")
            host = BighelpConfiguredHost(id: UUID(), accountScope: scope, accountID: "test-account", endpoint: endpoint, principalIdentity: saved.identity, name: "Fixture host")
            struct Snapshot: Encodable { let version = 1; let hosts: [BighelpConfiguredHost]; let selected: UUID? }
            try JSONEncoder().encode(Snapshot(hosts: [host], selected: host.id)).write(to: root.appending(path: scope + ".json"))
            registry.bind(deviceID: "test-account", authorizationEpoch: 1, forceReload: true)
            pin = try HostPluginPin(revision: String(repeating: "a", count: 40))
        }
        func row(sha: String, version: String, enabled: Bool = true) -> BighelpJSONValue {
            .object(["name": .string("loopdy"), "key": .string("loopdy"), "status": .string(enabled ? "enabled" : "disabled"),
                     "pinned_sha": .string(sha), "version": .string(version)])
        }
        func plugin(enabled: Bool) -> BighelpJSONValue {
            .object(["name": .string("loopdy"), "key": .string("loopdy"), "status": .string(enabled ? "enabled" : "disabled"), "pinned_sha": .string(pin.revision)])
        }
        func cleanup() {
            registry.bind(deviceID: nil, authorizationEpoch: nil); try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
    }
}
