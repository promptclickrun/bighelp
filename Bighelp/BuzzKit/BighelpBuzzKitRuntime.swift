import BuzzKit
import CryptoKit
import Foundation
import UserNotifications

struct BighelpBuzzKitIdentity: Decodable, Equatable, Sendable {
    let externalId: String
    let identityHash: String

    func validate() throws {
        guard externalId.utf8.count <= 128,
              externalId.range(of: "^(acct|notify)_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              identityHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw DirectHermesError.invalidResponse
        }
    }
}

struct BighelpBuzzKitIdentityEnvelope: Decodable, Sendable {
    let version: Int
    let identity: BighelpBuzzKitIdentity
}

struct BighelpBuzzKitProviderReadiness: Decodable, Equatable, Sendable {
    struct Credential: Decodable, Equatable, Sendable {
        let environment: String?
        let status: String
        let validatedAt: String?
        let lastError: String?
    }
    struct Subscriber: Decodable, Equatable, Sendable {
        struct CurrentDevice: Decodable, Equatable, Sendable {
            let matched: Bool
            let environment: String
            let enabled: Bool
            let active: Bool
            let subscriptionId: String?
        }
        let identified: Bool
        let verified: Bool
        let activeIOSPushEnvironments: [String?]
        let currentDevice: CurrentDevice?
    }
    let configured: Bool
    let pushCredentials: [Credential]
    let subscriber: Subscriber
    let topicSlugs: [String]

    func validate() throws {
        guard configured,
              pushCredentials.count <= 16,
              pushCredentials.allSatisfy({ credential in
                  ["unvalidated", "active", "invalid"].contains(credential.status)
                      && (credential.environment == nil
                          || credential.environment == "sandbox"
                          || credential.environment == "production")
                      && (credential.lastError?.utf8.count ?? 0) <= 256
              }),
              subscriber.activeIOSPushEnvironments.count <= 64,
              subscriber.activeIOSPushEnvironments.allSatisfy({
                  $0 == nil || $0 == "sandbox" || $0 == "production"
              }),
              subscriber.currentDevice.map({
                  ["sandbox", "production"].contains($0.environment)
                      && ($0.subscriptionId?.utf8.count ?? 0) <= 128
                      && (!$0.matched || $0.subscriptionId != nil)
              }) ?? true,
              Set(topicSlugs).count == topicSlugs.count,
              Set(topicSlugs).isSubset(of: Set(BighelpBuzzKitTopic.allCases.map(\.rawValue))) else {
            throw DirectHermesError.invalidResponse
        }
    }

    func isReady(environment: String) -> Bool {
        configured && subscriber.identified && subscriber.verified
            && pushCredentials.contains { $0.status == "active" && ($0.environment == nil || $0.environment == environment) }
            && subscriber.currentDevice?.matched == true
            && subscriber.currentDevice?.enabled == true
            && subscriber.currentDevice?.active == true
            && subscriber.currentDevice?.environment == environment
            && Set(topicSlugs) == Set(BighelpBuzzKitTopic.allCases.map(\.rawValue))
    }

    /// Names the first unmet readiness prerequisite so an explicit enrollment
    /// attempt reports why the provider is not ready instead of a flat error.
    /// Mirrors isReady(environment:) check for check.
    func unreadyReason(environment: String) -> String {
        if !configured { return "readiness_provider_not_configured" }
        if !subscriber.identified { return "readiness_subscriber_unidentified" }
        if !subscriber.verified { return "readiness_subscriber_unverified" }
        if !pushCredentials.contains(where: {
            $0.status == "active" && ($0.environment == nil || $0.environment == environment)
        }) {
            return "readiness_no_active_push_credential_\(environment)"
        }
        if subscriber.currentDevice?.matched != true { return "readiness_device_unmatched" }
        if subscriber.currentDevice?.enabled != true { return "readiness_device_push_disabled" }
        if subscriber.currentDevice?.active != true { return "readiness_device_inactive" }
        if subscriber.currentDevice?.environment != environment { return "readiness_device_wrong_environment" }
        return "readiness_topics_incomplete"
    }
}

struct BighelpBuzzKitReadinessEnvelope: Decodable, Sendable {
    let version: Int
    let readiness: BighelpBuzzKitProviderReadiness
}

private struct BighelpBuzzKitRegistrationProof: Equatable, Sendable {
    let generation: UInt64
    let externalId: String
    let tokenHash: String
    let environment: String
    let subscriptionId: String?
}

enum BighelpBuzzKitPushEnvironment: String, Sendable {
    case sandbox
    case production

    var sdkValue: BuzzKit.PushEnvironment {
        switch self {
        case .sandbox: .sandbox
        case .production: .production
        }
    }
}

@MainActor
protocol BighelpBuzzKitPushEnvironmentSource: Sendable {
    func resolve(bundle: Bundle) -> BighelpBuzzKitPushEnvironment
}

/// Matches BuzzKit iOS 1.0.0: the simulator is always sandbox, an embedded
/// provisioning profile wins over the compilation configuration, and DEBUG is
/// only the profile-missing fallback.
struct BighelpBuzzKitPushEnvironmentResolver: BighelpBuzzKitPushEnvironmentSource {
    let isSimulator: Bool
    let fallback: BighelpBuzzKitPushEnvironment

    static var live: Self {
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        #if DEBUG
        let fallback = BighelpBuzzKitPushEnvironment.sandbox
        #else
        let fallback = BighelpBuzzKitPushEnvironment.production
        #endif
        return Self(isSimulator: isSimulator, fallback: fallback)
    }

    func resolve(bundle: Bundle) -> BighelpBuzzKitPushEnvironment {
        guard !isSimulator else { return .sandbox }
        guard let profileURL = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: profileURL),
              let profile = String(data: data, encoding: .isoLatin1),
              let key = profile.range(of: "<key>aps-environment</key>") else {
            return fallback
        }
        let remainder = profile[key.upperBound...]
        guard let open = remainder.range(of: "<string>"),
              let close = remainder.range(of: "</string>"),
              open.upperBound <= close.lowerBound else {
            return fallback
        }
        let value = remainder[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return fallback }
        return value == "development" ? .sandbox : .production
    }
}

@MainActor
protocol BighelpBuzzKitSDK: AnyObject {
    var isConfigured: Bool { get }
    func identify(_ externalId: String, identityHash: String)
    func logout()
    func retireIdentityForLocalErasure() async
    func notificationPermission() async -> UNAuthorizationStatus
    func registerForPush() async throws
    func migrateLegacyPreferences() async throws
    func observeActivities()
}

extension BighelpBuzzKitSDK {
    func retireIdentityForLocalErasure() async {
        logout()
    }
}

@MainActor
protocol BighelpAwaitableBuzzKitSDK: BighelpBuzzKitSDK {
    func identifyAndWait(_ externalId: String, identityHash: String) async throws
    func logoutAndWait() async throws
    func registerPushSubscription(
        deviceToken: Data
    ) async throws -> BuzzKit.PushSubscriptionRegistration
}

@MainActor
private final class BighelpLiveBuzzKitSDK: BighelpAwaitableBuzzKitSDK {
    var isConfigured: Bool { BuzzKit.isConfigured }

    func identify(_ externalId: String, identityHash: String) {
        BuzzKit.identify(externalId, identityHash: identityHash)
    }

    func identifyAndWait(_ externalId: String, identityHash: String) async throws {
        try await BuzzKit.identifyAndWait(externalId, identityHash: identityHash)
    }

    func logout() {
        BuzzKit.retireCurrentIdentity(appGroup: BighelpBuzzKitRuntime.appGroup)
    }

    func logoutAndWait() async throws {
        try await BuzzKit.retireCurrentIdentityAndWait(appGroup: BighelpBuzzKitRuntime.appGroup)
    }

    func retireIdentityForLocalErasure() async {
        BuzzKit.retireCurrentIdentity(appGroup: BighelpBuzzKitRuntime.appGroup)
    }

    func notificationPermission() async -> UNAuthorizationStatus {
        await BuzzKit.notificationPermission()
    }

    func registerForPush() async throws {
        _ = try await BuzzKit.registerForPush(provisional: false)
    }

    func registerPushSubscription(deviceToken: Data) async throws -> BuzzKit.PushSubscriptionRegistration {
        try await BuzzKit.registerPushSubscription(deviceToken: deviceToken)
    }

    func migrateLegacyPreferences() async throws {
        try await BighelpBuzzKitPreferencesClient().migrateLegacyPreferences()
    }

    func observeActivities() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst) // Vision Pro has no Live Activities.
        if #available(iOS 16.2, *) {
            BuzzKit.activities.observe(LoopdySessionActivityAttributes.self)
        }
        #endif
    }
}

@MainActor
final class BighelpBuzzKitRuntime {
    static let shared = BighelpBuzzKitRuntime()
    static let appGroup = "group.app.loopdy.mobile.buzzkit"

    enum State: Equatable, Sendable {
        case notConfigured(reason: String)
        case configured
        case identitySubmitted(externalId: String)
        case registered(externalId: String)
        case ready(externalId: String, activePushRegistrations: Int)
        case failed(code: String)
    }

    private(set) var state: State = .notConfigured(reason: "buzzkit_not_started")
    private(set) var providerReadiness: BighelpBuzzKitProviderReadiness?
    private var identity: BighelpBuzzKitIdentity?
    private var identityCredentials: BighelpManagedNotificationCredentials?
    private var identityGeneration: UInt64?
    private var registrationProof: BighelpBuzzKitRegistrationProof?
    private var generation: UInt64 = 0
    private var activitiesObserved = false
    private var currentTokenData: Data?
    private var currentToken: String?
    private var currentTokenHash: String?
    private var tokenCallbackEpoch: UInt64 = 0
    private struct TokenWaiter {
        let afterEpoch: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var tokenWaiters: [UUID: TokenWaiter] = [:]
    /// Epoch of the latest APNs registration failure. A failure that lands
    /// before registerCurrentDevice starts waiting still fails fast instead of
    /// hanging until the timeout below.
    private var tokenFailureEpoch: UInt64 = 0
    private var lastAPNsFailure: BighelpManagedNotificationSetupError?
    /// The vendored SDK waits 15s for the APNs token in
    /// PushManager.requestDeviceToken(). This attempt must outlast that wait so
    /// the app never gives up before the SDK's own timeout does.
    private static let tokenWaitTimeoutNanoseconds: UInt64 = 20_000_000_000
    private var configuredEnvironment: BighelpBuzzKitPushEnvironment?
    private let sdk: any BighelpBuzzKitSDK
    private let environmentSource: any BighelpBuzzKitPushEnvironmentSource
    private let allowsOfflineFixtureConfiguration: Bool

    private init() {
        sdk = BighelpLiveBuzzKitSDK()
        environmentSource = BighelpBuzzKitPushEnvironmentResolver.live
        allowsOfflineFixtureConfiguration = false
    }

    /// Focused test seam. A fake SDK can exercise this runtime's real
    /// identify/register/readiness state machine without provider traffic or OS
    /// permission prompts. The shared production runtime always uses the live SDK.
    init(
        testingSDK sdk: any BighelpBuzzKitSDK,
        environmentSource: any BighelpBuzzKitPushEnvironmentSource = BighelpBuzzKitPushEnvironmentResolver(
            isSimulator: true,
            fallback: .sandbox
        )
    ) {
        self.sdk = sdk
        self.environmentSource = environmentSource
        allowsOfflineFixtureConfiguration = true
    }

    @discardableResult
    func configureIfPossible(bundle: Bundle = .main) -> Bool {
        let environment = environmentSource.resolve(bundle: bundle)
        if let configuredEnvironment, configuredEnvironment != environment {
            state = .notConfigured(reason: "buzzkit_push_environment_changed")
            return false
        }
        configuredEnvironment = environment
        #if DEBUG
        let process = ProcessInfo.processInfo
        if !allowsOfflineFixtureConfiguration && (process.arguments.contains("-use-demo-fixtures")
            || process.arguments.contains("-disable-demo-delays")
            || process.environment["XCTestConfigurationFilePath"] != nil) {
            // A real public key must not turn offline UI/unit fixtures into
            // production subscribers or analytics traffic.
            state = .notConfigured(reason: "offline_fixture")
            return false
        }
        #endif
        if sdk.isConfigured {
            if BuzzKit.delegate == nil { BuzzKit.delegate = BighelpBuzzKitPresentation.shared }
            if case .notConfigured = state { state = .configured }
            observeActivitiesIfNeeded()
            return true
        }
        guard !allowsOfflineFixtureConfiguration else {
            state = .notConfigured(reason: "test_sdk_not_configured")
            return false
        }
        guard let key = bundle.object(forInfoDictionaryKey: "BighelpBuzzKitClientKey") as? String,
              key.hasPrefix("bk_pk_"), key.utf8.count >= 16 else {
            state = .notConfigured(reason: "buzzkit_client_key_missing")
            return false
        }
        let apiURLString = (bundle.object(forInfoDictionaryKey: "BighelpBuzzKitAPIURL") as? String)
            ?? "https://api.buzzkit.dev"
        guard let apiURL = URL(string: apiURLString), apiURL.scheme == "https",
              apiURL.user == nil, apiURL.password == nil, apiURL.fragment == nil,
              apiURL.query == nil else {
            state = .notConfigured(reason: "buzzkit_api_url_invalid")
            return false
        }
        BuzzKit.configure(with: BuzzKit.Configuration(
            apiKey: key,
            apiURL: apiURL,
            logLevel: .warn,
            foregroundPresentation: .banner,
            automaticSessionTracking: true,
            appGroup: Self.appGroup,
            pushEnvironment: environment.sdkValue,
            automaticPushHandling: false
        ))
        // Foreground presentation: quiet for the chat you're looking at.
        BuzzKit.delegate = BighelpBuzzKitPresentation.shared
        state = .configured
        observeActivitiesIfNeeded()
        return true
    }

    func identify(
        accountAPI: any BighelpManagedNotificationAccountAPI,
        credentials: BighelpManagedNotificationCredentials
    ) async throws {
        guard configureIfPossible() else {
            throw BighelpManagedNotificationSetupError(stage: .providerBootstrap)
        }
        let operationGeneration = advanceGeneration()
        providerReadiness = nil
        do {
            let response = try await accountAPI.managedNotificationRequest(
                path: BighelpManagedNotificationService.root + "/buzzkit/identity",
                method: "GET",
                body: nil,
                credentials: credentials
            )
            try requireCurrent(operationGeneration)
            let envelope = try ManagedNotificationValidation.decode(
                BighelpBuzzKitIdentityEnvelope.self,
                from: response
            )
            guard envelope.version == 1 || envelope.version == 2 else { throw DirectHermesError.invalidResponse }
            try envelope.identity.validate()
            try requireCurrent(operationGeneration)
            if let awaitedSDK = sdk as? any BighelpAwaitableBuzzKitSDK {
                try await awaitedSDK.identifyAndWait(
                    envelope.identity.externalId,
                    identityHash: envelope.identity.identityHash
                )
                try requireCurrent(operationGeneration)
            } else {
                guard allowsOfflineFixtureConfiguration else {
                    throw BighelpManagedNotificationSetupError(stage: .providerBootstrap)
                }
                sdk.identify(
                    envelope.identity.externalId,
                    identityHash: envelope.identity.identityHash
                )
            }
            identity = envelope.identity
            identityCredentials = credentials
            identityGeneration = operationGeneration
            if let registered = registeredState(for: envelope.identity) {
                // Keep the exact receipt visible across idempotent launch
                // identification, but its old generation cannot authorize a new
                // enrollment attempt.
                state = registered
            } else {
                registrationProof = nil
                state = .identitySubmitted(externalId: envelope.identity.externalId)
            }
        } catch let error as CancellationError {
            throw error
        } catch let error as BighelpLinkAPIError {
            if generation == operationGeneration {
                if identityCredentials == credentials,
                   let identity,
                   let registered = registeredState(for: identity) {
                    state = registered
                } else {
                    state = .failed(code: "buzzkit_identity_unavailable")
                }
            }
            let code: String? = Self.identityLinkCode(for: error)
            throw BighelpManagedNotificationSetupError(stage: .providerIdentity, code: code)
        } catch {
            if generation == operationGeneration {
                if identityCredentials == credentials,
                   let identity,
                   let registered = registeredState(for: identity) {
                    state = registered
                } else {
                    state = .failed(code: "buzzkit_identity_unavailable")
                }
            }
            throw BighelpManagedNotificationSetupError(
                stage: .providerIdentity, code: Self.identityDiagnosticCode(for: error))
        }
    }

    /// Maps an identify() failure to a stable diagnostic code so a failed
    /// provider-identity stage always names its failure mode. Server error
    /// codes pass through unchanged so enroll()'s revoked-credential retry
    /// (code == "notification_credentials_revoked") stays reachable.
    private static func identityLinkCode(for error: BighelpLinkAPIError) -> String? {
        switch error {
        case .requestFailed(_, let code): return code
        case .invalidResponse: return "identity_invalid_response"
        case .invalidConfiguration: return "identity_invalid_configuration"
        }
    }

    private static func identityDiagnosticCode(for error: Error) -> String {
        if let link = error as? BighelpLinkAPIError {
            return identityLinkCode(for: link) ?? "identity_request_failed"
        }
        if let hermes = error as? DirectHermesError {
            switch hermes {
            case .invalidResponse: return "identity_invalid_response"
            case .notConnected, .connectionFailed, .disconnected: return "identity_connection_failed"
            case .timedOut: return "identity_request_timed_out"
            case .authenticationRequired, .invalidCredentials: return "identity_auth_failed"
            case .serverUnavailable, .rateLimited, .tooManyRequests: return "identity_server_unavailable"
            default: return "identity_request_failed"
            }
        }
        if error is DecodingError { return "identity_decode_failed" }
        if let buzz = error as? BuzzKitError {
            switch buzz {
            case .api(let code, _):
                let safe = code.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
                } && !code.isEmpty && code.utf8.count <= 64
                return safe ? "identity_provider_\(code)" : "identity_provider_rejected"
            case .network: return "identity_provider_unreachable"
            case .invalidResponse: return "identity_provider_invalid_response"
            case .notConfigured: return "identity_provider_not_configured"
            case .notIdentified: return "identity_provider_not_identified"
            case .permissionDenied: return "identity_provider_permission_denied"
            }
        }
        if error is URLError { return "identity_connection_failed" }
        return "identity_request_failed"
    }

    /// Maps a refreshProviderReadiness() failure to a stable diagnostic code.
    /// Backend HTTP failures keep the real status and server error code so the
    /// failing enrollment step is diagnosable from the device.
    private static func readinessDiagnosticCode(for error: Error) -> String {
        if let link = error as? BighelpLinkAPIError {
            switch link {
            case .requestFailed(let status, let code): return "link_backend_\(status)_\(code)"
            case .invalidResponse: return "readiness_invalid_response"
            case .invalidConfiguration: return "readiness_invalid_configuration"
            }
        }
        if error is DecodingError { return "readiness_decode_failed" }
        return "readiness_request_failed"
    }

    /// Call only from the user's explicit notification-enable action after the
    /// app's existing OS permission surface has confirmed authorization.
    func registerCurrentDevice() async throws {
        guard let identity, identityCredentials != nil, identityGeneration == generation else {
            throw BighelpManagedNotificationSetupError(stage: .providerIdentity)
        }
        let operationGeneration = generation
        let status = await sdk.notificationPermission()
        try requireCurrent(operationGeneration, identity: identity)
        guard [.authorized, .provisional, .ephemeral].contains(status) else {
            if generation == operationGeneration {
                state = .failed(code: "notification_permission_required")
            }
            throw BighelpManagedNotificationSetupError(stage: .notificationPermission)
        }
        let callbackEpoch = tokenCallbackEpoch
        let failureEpoch = tokenFailureEpoch
        do {
            try await sdk.registerForPush()
            // A cached SDK token is not proof of this attempt's APNs result. Accept
            // a callback delivered during the SDK await, otherwise wait boundedly
            // for a strictly newer callback before registering exact bytes. A
            // failure that predates this wait is stale: the new SDK registration
            // attempt gets its own chance to deliver a token or a fresh failure.
            try await awaitCurrentToken(after: callbackEpoch, failureAfter: failureEpoch)
        } catch let error as CancellationError {
            throw error
        } catch let setup as BighelpManagedNotificationSetupError {
            // Preserve the real failure mode (APNs registration failure, token
            // wait timeout) instead of flattening it into a generic error.
            if generation == operationGeneration {
                state = .failed(code: setup.code ?? "buzzkit_device_registration_failed")
            }
            throw setup
        } catch {
            try requireCurrent(operationGeneration, identity: identity)
            // With no cached token BuzzKit throws from registerForPush before
            // our token wait begins. Keep the fresh delegate failure rather
            // than replacing it with the SDK's generic network wrapper.
            if tokenFailureEpoch > failureEpoch, tokenCallbackEpoch <= callbackEpoch,
               let failure = lastAPNsFailure {
                state = .failed(code: failure.code ?? "apns_registration_failed")
                throw failure
            }
            state = .failed(code: "buzzkit_device_registration_failed")
            throw BighelpManagedNotificationSetupError(
                stage: .deviceRegistration, code: "buzzkit_device_registration_failed")
        }
        try requireCurrent(operationGeneration, identity: identity)
        guard let currentTokenData, let currentToken, let currentTokenHash else {
            state = .failed(code: "current_apns_token_readback_required")
            throw BighelpManagedNotificationSetupError(stage: .deviceRegistration)
        }
        guard let requiredEnvironment = configuredEnvironment else {
            state = .failed(code: "buzzkit_push_environment_unavailable")
            throw BighelpManagedNotificationSetupError(stage: .providerBootstrap)
        }
        let registration: BuzzKit.PushSubscriptionRegistration?
        do {
            if let awaitedSDK = sdk as? any BighelpAwaitableBuzzKitSDK {
                let result = try await awaitedSDK.registerPushSubscription(deviceToken: currentTokenData)
                try requireCurrent(operationGeneration, identity: identity)
                guard self.currentTokenHash == currentTokenHash,
                      self.currentTokenData == currentTokenData else {
                    throw CancellationError()
                }
                guard result.externalId == identity.externalId,
                      result.endpoint == currentToken,
                      result.environment.rawValue == requiredEnvironment.rawValue else {
                    throw DirectHermesError.invalidResponse
                }
                registration = result
            } else {
                guard allowsOfflineFixtureConfiguration else {
                    throw BighelpManagedNotificationSetupError(stage: .providerBootstrap)
                }
                registration = nil
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            if generation == operationGeneration {
                state = .failed(code: "buzzkit_device_registration_failed")
            }
            throw BighelpManagedNotificationSetupError(stage: .deviceRegistration)
        }
        do {
            try await sdk.migrateLegacyPreferences()
        } catch let error as CancellationError {
            throw error
        } catch {
            if generation == operationGeneration {
                state = .failed(code: "buzzkit_preference_migration_failed")
            }
            throw BighelpManagedNotificationSetupError(stage: .deviceRegistration)
        }
        try requireCurrent(operationGeneration, identity: identity)
        guard self.currentTokenHash == currentTokenHash,
              self.currentTokenData == currentTokenData else { throw CancellationError() }
        registrationProof = BighelpBuzzKitRegistrationProof(
            generation: operationGeneration,
            externalId: identity.externalId,
            tokenHash: currentTokenHash,
            environment: requiredEnvironment.rawValue,
            subscriptionId: registration?.id
        )
        // Production proof is the vendored SDK's awaited exact-token write.
        // Privileged backend diagnostics may add detail but are not authority.
        state = .registered(externalId: identity.externalId)
    }

    func refreshProviderReadiness(
        accountAPI: any BighelpManagedNotificationAccountAPI,
        credentials: BighelpManagedNotificationCredentials
    ) async throws -> BighelpBuzzKitProviderReadiness {
        try await refreshProviderReadiness(
            accountAPI: accountAPI,
            credentials: credentials,
            requiringCurrentRegistration: false
        )
    }

    func refreshProviderReadiness(
        accountAPI: any BighelpManagedNotificationAccountAPI,
        credentials: BighelpManagedNotificationCredentials,
        requiringCurrentRegistration: Bool
    ) async throws -> BighelpBuzzKitProviderReadiness {
        guard let identity, identityGeneration == generation,
              identityCredentials == credentials else {
            throw BighelpManagedNotificationSetupError(stage: .providerIdentity)
        }
        guard let currentTokenHash else {
            state = .failed(code: "current_apns_token_readback_required")
            throw BighelpManagedNotificationSetupError(stage: .deviceRegistration)
        }
        let operationGeneration = generation
        guard let requiredEnvironment = configuredEnvironment?.rawValue else {
            state = .failed(code: "buzzkit_push_environment_unavailable")
            throw BighelpManagedNotificationSetupError(stage: .providerBootstrap)
        }
        let requiredProof: BighelpBuzzKitRegistrationProof?
        if requiringCurrentRegistration {
            guard let proof = registrationProof,
                  proof.generation == operationGeneration,
                  proof.externalId == identity.externalId,
                  proof.tokenHash == currentTokenHash,
                  proof.environment == requiredEnvironment else {
                state = .failed(code: "buzzkit_registration_required")
                throw BighelpManagedNotificationSetupError(stage: .deviceRegistration)
            }
            requiredProof = proof
        } else {
            requiredProof = nil
        }
        let readiness: BighelpBuzzKitProviderReadiness
        do {
            let body = try ManagedNotificationValidation.data(BighelpJSONValue.object([
                "version": .integer(2),
                "tokenHash": .string(currentTokenHash),
                "environment": .string(requiredEnvironment),
            ]))
            let response = try await accountAPI.managedNotificationRequest(
                path: BighelpManagedNotificationService.root + "/buzzkit/status",
                method: "POST",
                body: body,
                credentials: credentials
            )
            try requireCurrent(operationGeneration, identity: identity, credentials: credentials)
            guard self.currentTokenHash == currentTokenHash else { throw CancellationError() }
            let envelope = try ManagedNotificationValidation.decode(
                BighelpBuzzKitReadinessEnvelope.self,
                from: response
            )
            guard envelope.version == 2 else { throw DirectHermesError.invalidResponse }
            try envelope.readiness.validate()
            try requireCurrent(operationGeneration, identity: identity, credentials: credentials)
            readiness = envelope.readiness
        } catch let error as CancellationError {
            throw error
        } catch {
            // Propagate the real backend failure (status code + server error
            // code) instead of flattening every readiness failure into one
            // opaque error.
            throw BighelpManagedNotificationSetupError(
                stage: .providerReadiness,
                code: Self.readinessDiagnosticCode(for: error)
            )
        }
        providerReadiness = readiness
        if let subscriptionId = requiredProof?.subscriptionId,
           readiness.subscriber.currentDevice?.subscriptionId != subscriptionId {
            throw BighelpManagedNotificationSetupError(
                stage: .providerReadiness, code: "readiness_subscription_mismatch")
        }
        guard readiness.isReady(environment: requiredEnvironment) else {
            if requiringCurrentRegistration {
                throw BighelpManagedNotificationSetupError(
                    stage: .providerReadiness,
                    code: readiness.unreadyReason(environment: requiredEnvironment)
                )
            }
            return readiness
        }
        state = .ready(
            externalId: identity.externalId,
            activePushRegistrations: 1
        )
        return readiness
    }

    func retireIdentity() {
        _ = advanceGeneration()
        identity = nil
        identityCredentials = nil
        identityGeneration = nil
        registrationProof = nil
        providerReadiness = nil
        state = sdk.isConfigured ? .configured : .notConfigured(reason: "buzzkit_not_started")
    }

    /// Durably retires SDK authority before queuing provider cleanup. Cleanup failure
    /// remains SDK-owned retry state and does not restore this runtime's identity.
    func logout() {
        retireIdentity()
        sdk.logout()
    }

    func logoutAndWait() async throws {
        retireIdentity()
        do {
            if let awaitedSDK = sdk as? any BighelpAwaitableBuzzKitSDK {
                try await awaitedSDK.logoutAndWait()
            } else {
                guard allowsOfflineFixtureConfiguration else {
                    throw BighelpManagedNotificationSetupError(stage: .providerBootstrap)
                }
                sdk.logout()
            }
            state = .configured
        } catch {
            state = .failed(code: "buzzkit_logout_failed")
            throw error
        }
    }

    /// Service-facing local-erasure seam. This waits only for the injected provider
    /// adapter to durably fence local SDK authority; live provider DELETE stays queued
    /// and retryable so availability cannot block app-owned erasure.
    func retireIdentityForLocalErasure() async {
        retireIdentity()
        await sdk.retireIdentityForLocalErasure()
    }

    /// Turn off notifications: forget this device's push token, here and in
    /// BuzzKit's saved settings. Turning notifications on asks iOS for a new one.
    func forgetPushToken() {
        currentTokenData = nil
        currentToken = nil
        currentTokenHash = nil
        registrationProof = nil
        providerReadiness = nil
        let shared = UserDefaults(suiteName: Self.appGroup)
        // BuzzKit's own keys ("dev.buzzkit." + name). Identity fields stay: the
        // SDK still needs them to finish deleting its retired subscription.
        for key in ["deviceToken", "deviceTokenEnvironment", "permissionStatus"] {
            shared?.removeObject(forKey: "dev.buzzkit." + key)
        }
    }

    /// Mandatory app-delegate hook. Hash the exact lowercase token string that
    /// BuzzKit registers; no APNs token is persisted in bighelp notification state.
    func noteAPNSToken(_ token: Data) {
        let encoded = token.map { String(format: "%02x", $0) }.joined()
        let nextHash = SHA256.hash(data: Data(encoded.utf8))
            .map { String(format: "%02x", $0) }.joined()
        currentTokenData = Data(token)
        currentToken = encoded
        tokenCallbackEpoch &+= 1
        let completed = tokenWaiters.filter { $0.value.afterEpoch < tokenCallbackEpoch }
        for (id, waiter) in completed {
            tokenWaiters[id] = nil
            waiter.continuation.resume()
        }
        guard nextHash != currentTokenHash else { return }
        currentTokenHash = nextHash
        registrationProof = nil
        providerReadiness = nil
        if let identity, identityGeneration == generation {
            state = .identitySubmitted(externalId: identity.externalId)
        }
    }

    /// Mandatory app-delegate hook. A failed APNs registration means no token
    /// callback can satisfy an in-flight wait: wake the waiters with the real
    /// failure so registerCurrentDevice surfaces it instead of timing out.
    func noteAPNsRegistrationFailure(_ error: any Error) {
        let failure = BighelpManagedNotificationSetupError(stage: .deviceRegistration, code: "apns_registration_failed")
        tokenFailureEpoch &+= 1
        lastAPNsFailure = failure
        let waiters = tokenWaiters
        tokenWaiters = [:]
        for (_, waiter) in waiters {
            waiter.continuation.resume(throwing: failure)
        }
    }

    @discardableResult
    private func advanceGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    private func requireCurrent(
        _ operationGeneration: UInt64,
        identity expectedIdentity: BighelpBuzzKitIdentity? = nil,
        credentials expectedCredentials: BighelpManagedNotificationCredentials? = nil
    ) throws {
        try Task.checkCancellation()
        guard generation == operationGeneration else { throw CancellationError() }
        if let expectedIdentity {
            guard identityGeneration == operationGeneration, identity == expectedIdentity else {
                throw CancellationError()
            }
        }
        if let expectedCredentials {
            guard identityCredentials == expectedCredentials else { throw CancellationError() }
        }
    }

    private func awaitCurrentToken(after callbackEpoch: UInt64, failureAfter failureEpoch: UInt64) async throws {
        guard tokenCallbackEpoch <= callbackEpoch else { return }
        if tokenFailureEpoch > failureEpoch, let failure = lastAPNsFailure {
            throw failure
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if tokenCallbackEpoch > callbackEpoch {
                    continuation.resume()
                    return
                }
                if tokenFailureEpoch > failureEpoch, let failure = self.lastAPNsFailure {
                    continuation.resume(throwing: failure)
                    return
                }
                tokenWaiters[id] = TokenWaiter(afterEpoch: callbackEpoch, continuation: continuation)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.tokenWaitTimeoutNanoseconds)
                    self?.finishTokenWait(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishTokenWait(id)
            }
        }
        try Task.checkCancellation()
        guard tokenCallbackEpoch > callbackEpoch, currentToken != nil else {
            throw BighelpManagedNotificationSetupError(stage: .deviceRegistration, code: "apns_token_wait_timed_out")
        }
    }

    private func finishTokenWait(_ id: UUID) {
        tokenWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    private func registeredState(for identity: BighelpBuzzKitIdentity) -> State? {
        guard let proof = registrationProof,
              proof.externalId == identity.externalId,
              proof.tokenHash == currentTokenHash,
              proof.environment == configuredEnvironment?.rawValue else { return nil }
        return .registered(externalId: identity.externalId)
    }

    private func observeActivitiesIfNeeded() {
        guard !activitiesObserved else { return }
        activitiesObserved = true
        // Required at every process launch so existing activity tokens,
        // rotations, and iOS 17.2+ push-to-start tokens are registered.
        sdk.observeActivities()
    }
}
