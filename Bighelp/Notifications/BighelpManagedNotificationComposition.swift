import Foundation
import Observation

/// Retains the one managed-notification integration owned by the app root.
/// Construction may be retried, but root hooks are installed exactly once and
/// always resolve the currently retained integration at invocation time.
@MainActor
@Observable
final class BighelpManagedNotificationComposition: HostNotificationSetupServing {
    enum AutomaticRetryReason: Sendable {
        case startup
        case foreground
        case protectedDataAvailable
    }

    enum LoadFailureKind: Equatable, Sendable {
        case protectedStorageUnavailable
        case savedStateRejected
        case storageUnavailable
    }

    struct Owner: Equatable {
        fileprivate let compositionID: UUID
        fileprivate let serviceID: ObjectIdentifier
        let registryGeneration: UUID
    }

    @MainActor
    struct ApplicationHookInstallers {
        let installAPNSToken: @MainActor (@escaping BighelpAPNSTokenHookCenter.Handler) -> Void
        let installAPNSFailure: @MainActor (@escaping BighelpAPNSTokenHookCenter.FailureHandler) -> Void
        let installWake: @MainActor (@escaping BighelpLinkWakeCenter.Handler) -> Void
        let installManagedOpen: @MainActor (@escaping BighelpProactiveNotificationOpenCenter.Handler) -> Void

        static var live: Self {
            Self(
                installAPNSToken: { BighelpAPNSTokenHookCenter.shared.install($0) },
                installAPNSFailure: { BighelpAPNSTokenHookCenter.shared.installFailure($0) },
                installWake: { BighelpLinkWakeCenter.shared.install($0) },
                installManagedOpen: { BighelpProactiveNotificationOpenCenter.shared.installManaged($0) }
            )
        }
    }

    private(set) var integration: BighelpManagedNotificationIntegration?
    private(set) var constructionAttemptCount = 0
    private(set) var automaticAttemptCount = 0
    private(set) var rootHookInstallationCount = 0
    private(set) var revision = 0
    private(set) var loadFailureKind: LoadFailureKind?

    var service: BighelpManagedNotificationService? { integration?.service }

    @ObservationIgnored private weak var registry: BighelpHostRegistry?
    @ObservationIgnored private let isFixture: Bool
    @ObservationIgnored private let maximumAutomaticAttempts: Int
    @ObservationIgnored private let makeIntegration: @MainActor () throws -> BighelpManagedNotificationIntegration
    @ObservationIgnored private let compositionID = UUID()
    @ObservationIgnored private var pendingAPNSToken: Data?
    @ObservationIgnored private var pendingAPNSFailure: (any Error)?
    @ObservationIgnored private var publishedLoadError: String?

    convenience init(
        factory: BighelpManagedNotificationFactory,
        registry: BighelpHostRegistry,
        maximumAutomaticAttempts: Int = 3
    ) {
        self.init(
            isFixture: factory.isFixture,
            registry: registry,
            maximumAutomaticAttempts: maximumAutomaticAttempts,
            applicationHooks: .live,
            makeIntegration: {
                try factory.makeRequiredIntegration(registry: registry)
            }
        )
    }

    /// Injection seam for first-failure/then-success and hook-installation tests.
    /// Explicit user actions always make at most one construction attempt; the
    /// automatic lifecycle budget includes the startup attempt.
    init(
        isFixture: Bool,
        registry: BighelpHostRegistry,
        maximumAutomaticAttempts: Int = 3,
        applicationHooks: ApplicationHookInstallers,
        makeIntegration: @escaping @MainActor () throws -> BighelpManagedNotificationIntegration
    ) {
        self.isFixture = isFixture
        self.registry = registry
        self.maximumAutomaticAttempts = max(1, maximumAutomaticAttempts)
        self.makeIntegration = makeIntegration

        guard !isFixture else { return }
        installRootHooks(registry: registry, applicationHooks: applicationHooks)
        registry.notificationSetup = self
        _ = retryAutomatically(for: .startup)
    }

    @discardableResult
    func retryAfterForeground() -> Bool {
        retryAutomatically(for: .foreground)
    }

    @discardableResult
    func retryAfterProtectedDataBecomesAvailable() -> Bool {
        retryAutomatically(for: .protectedDataAvailable)
    }

    /// Captures the exact retained service and registry generation for async work.
    func captureOwner() -> Owner? {
        guard let integration, let registry else { return nil }
        return Owner(
            compositionID: compositionID,
            serviceID: ObjectIdentifier(integration.service),
            registryGeneration: registry.generation
        )
    }

    func isCurrent(_ owner: Owner) -> Bool {
        guard let integration, let registry else { return false }
        return owner.compositionID == compositionID
            && owner.serviceID == ObjectIdentifier(integration.service)
            && owner.registryGeneration == registry.generation
    }

    func owns(_ integration: BighelpManagedNotificationIntegration, registryGeneration: UUID) -> Bool {
        guard let retained = self.integration, let registry else { return false }
        return retained.service === integration.service && registry.generation == registryGeneration
    }

    func recoverForeground(isCurrent externalIsCurrent: @escaping @MainActor () -> Bool) async {
        guard let integration, let owner = captureOwner() else { return }
        do {
            try await integration.hooks.recoverForeground {
                !Task.isCancelled && externalIsCurrent() && self.isCurrent(owner)
            }
            guard !Task.isCancelled, externalIsCurrent(), isCurrent(owner) else { return }
            clearPublishedLoadError()
        } catch is CancellationError {
            return
        } catch {
            guard externalIsCurrent(), isCurrent(owner) else { return }
            registry?.notificationSetupError = "Notification recovery is pending. Chat remains available. Retry in Accounts and Devices."
        }
    }

    func receiveNativeEvent(_ host: BighelpConfiguredHost, _ event: DirectHermesEvent) async {
        guard let integration, let owner = captureOwner(), isCurrent(owner) else { return }
        await integration.hooks.receiveNativeEvent(host, event)
        guard isCurrent(owner) else { return }
    }

    func enroll(
        host: BighelpConfiguredHost,
        connection: DirectHermesSavedConnection,
        isCurrent externalIsCurrent: @escaping @MainActor () -> Bool
    ) async throws -> HostNotificationSetupResult {
        let integration = try requireIntegrationForExplicitAction()
        guard let owner = captureOwner(), isCurrent(owner), externalIsCurrent() else {
            throw DirectHermesError.secureStorageChanged
        }
        return try await integration.service.enroll(host: host, connection: connection) {
            !Task.isCancelled && externalIsCurrent() && self.isCurrent(owner)
        }
    }

    func removeLocalEnrollment(host: BighelpConfiguredHost) throws {
        let integration = try requireIntegrationForExplicitAction()
        guard let owner = captureOwner(), isCurrent(owner) else {
            throw DirectHermesError.secureStorageChanged
        }
        try integration.service.removeLocalEnrollment(host: host)
        guard isCurrent(owner) else { throw DirectHermesError.secureStorageChanged }
    }

    @discardableResult
    private func retryAutomatically(for reason: AutomaticRetryReason) -> Bool {
        guard !isFixture else { return false }
        guard integration == nil else { return true }
        guard automaticAttemptCount < maximumAutomaticAttempts else { return false }
        automaticAttemptCount += 1
        do {
            try adopt(makeIntegrationAttempt())
            return true
        } catch {
            publishLoadFailure(error, reason: reason)
            return false
        }
    }

    private func requireIntegrationForExplicitAction() throws -> BighelpManagedNotificationIntegration {
        if let integration { return integration }
        guard !isFixture else { throw DirectHermesError.invalidResponse }
        do {
            let created = try makeIntegrationAttempt()
            try adopt(created)
            return created
        } catch {
            publishLoadFailure(error, reason: nil)
            throw error
        }
    }

    private func makeIntegrationAttempt() throws -> BighelpManagedNotificationIntegration {
        constructionAttemptCount += 1
        return try makeIntegration()
    }

    private func adopt(_ created: BighelpManagedNotificationIntegration) throws {
        guard integration == nil else { return }
        // A factory result for another registry is never adopted into this root.
        guard let registry, created.service.registry === registry else {
            throw DirectHermesError.secureStorageChanged
        }
        integration = created
        revision &+= 1
        loadFailureKind = nil
        clearPublishedLoadError()
        if let pendingAPNSToken {
            self.pendingAPNSToken = nil
            created.hooks.didRegisterAPNSToken(Data(pendingAPNSToken))
        }
        if let pendingAPNSFailure {
            self.pendingAPNSFailure = nil
            created.hooks.didFailAPNsRegistration(pendingAPNSFailure)
        }
    }

    private func installRootHooks(
        registry: BighelpHostRegistry,
        applicationHooks: ApplicationHookInstallers
    ) {
        guard rootHookInstallationCount == 0 else { return }
        rootHookInstallationCount = 1

        let priorNativeChatPrepared = registry.nativeChatPrepared
        registry.nativeChatPrepared = { [weak self] host, chat in
            priorNativeChatPrepared?(host, chat)
            self?.scheduleChatPreparation(host: host, chat: chat)
        }

        let priorPrepareChat = registry.prepareChat
        registry.prepareChat = { [weak self, weak registry] host, chat in
            if let priorPrepareChat {
                let generation = registry?.generation
                Task { @MainActor in
                    do {
                        try await priorPrepareChat(host, chat)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard let registry, registry.generation == generation else { return }
                        registry.notificationSetupError = "Chat is connected, but an existing notification observer could not prepare this session."
                    }
                }
            }
            self?.scheduleChatPreparation(host: host, chat: chat)
        }

        applicationHooks.installAPNSToken { [weak self] token in
            guard let self else { return }
            if let integration = self.integration {
                integration.hooks.didRegisterAPNSToken(token)
            } else {
                self.pendingAPNSToken = Data(token)
            }
        }

        applicationHooks.installAPNSFailure { [weak self] error in
            guard let self else { return }
            if let integration = self.integration {
                integration.hooks.didFailAPNsRegistration(error)
            } else {
                self.pendingAPNSFailure = error
            }
        }

        // Wire up the previously dead Link wake handler: a loopdy_link wake
        // push reconciles managed notification state the way a foreground
        // recovery would, instead of returning .failed and inviting iOS
        // background-wake throttling.
        applicationHooks.installWake { [weak self] in
            await self?.handleLinkWake() ?? false
        }

        applicationHooks.installManagedOpen { [weak self] open in
            await self?.openManagedNotification(open)
        }
    }

    /// Background `loopdy_link` wake handler. A wake push is a prompt to
    /// reconcile, not a data delivery: report no new data rather than .failed
    /// so iOS does not throttle future wakes for a wake the app handled.
    private func handleLinkWake() async -> Bool {
        let renewed = await renewSignInsWhileAway()
        guard let integration, let owner = captureOwner(), isCurrent(owner) else { return renewed }
        do {
            try await integration.hooks.recoverWake { !Task.isCancelled && self.isCurrent(owner) }
        } catch {
            // A failed recovery is still a handled wake; fall through to the
            // truthful no-new-data result instead of .failed.
        }
        return renewed
    }

    /// Renews every computer's rotating sign-in that isn't connected right now.
    private func renewSignInsWhileAway() async -> Bool {
        guard let registry else { return false }
        var renewed = false
        for host in registry.hosts {
            if await registry.workspace(for: host).renewSignInWhileAway() { renewed = true }
        }
        return renewed
    }

    private func scheduleChatPreparation(host: BighelpConfiguredHost, chat: DirectHermesChat) {
        guard let registry, let integration, let owner = captureOwner() else { return }
        guard let current = registry.hosts.first(where: {
            $0.id == host.id && $0.principalIdentity == host.principalIdentity
        }) else { return }
        Task { @MainActor [weak self, weak registry] in
            guard let self, let registry, self.isCurrent(owner) else { return }
            do {
                try await integration.hooks.prepareChat(current, chat)
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrent(owner),
                      registry.hosts.contains(where: {
                          $0.id == current.id && $0.principalIdentity == current.principalIdentity
                              && $0.notificationBinding == current.notificationBinding
                      }) else { return }
                registry.notificationSetupError = "Chat is connected, but notifications for this session could not be prepared. Retry notification setup in Accounts and Devices."
            }
        }
    }

    private func openManagedNotification(_ open: BighelpProactiveNotificationOpen) async {
        guard let integration, let owner = captureOwner(), isCurrent(owner) else {
            publishLoadFailureGuidanceIfNeeded()
            return
        }
        guard let type = open.eventType else {
            registry?.notificationSetupError = "This managed notification did not contain a valid event type. No conversation was opened."
            return
        }
        do {
            let chat = try await integration.hooks.openManagedEvent(open.eventID, type) {
                !Task.isCancelled && self.isCurrent(owner)
            }
            BighelpExternalSessionOpenCenter.shared.request(
                profileID: chat.client.profile, storedSessionID: chat.client.storedID)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(owner) else { return }
            registry?.notificationSetupError = "This notification's original host or event is unavailable. No other conversation was opened."
        }
    }

    private func publishLoadFailure(_ error: any Error, reason _: AutomaticRetryReason?) {
        let kind = Self.classify(error)
        loadFailureKind = kind
        let message: String
        switch kind {
        case .protectedStorageUnavailable:
            message = "Saved notification setup is temporarily unavailable. Unlock the device, then retry in Accounts and Devices. Chat remains available; no stored data was replaced."
        case .savedStateRejected:
            message = "Saved notification setup could not be read safely. Retry in Accounts and Devices. Chat remains available; no stored data was replaced."
        case .storageUnavailable:
            message = "Saved notification setup could not be loaded. Retry in Accounts and Devices. Chat remains available; no stored data was replaced."
        }
        publishedLoadError = message
        registry?.notificationSetupError = message
    }

    private func publishLoadFailureGuidanceIfNeeded() {
        guard let publishedLoadError else {
            registry?.notificationSetupError = "Managed notifications are temporarily unavailable. Retry notification setup in Accounts and Devices. Chat remains available."
            return
        }
        registry?.notificationSetupError = publishedLoadError
    }

    private func clearPublishedLoadError() {
        guard let publishedLoadError else { return }
        if registry?.notificationSetupError == publishedLoadError {
            registry?.notificationSetupError = nil
        }
        self.publishedLoadError = nil
    }

    private static func classify(_ error: any Error) -> LoadFailureKind {
        if let direct = error as? DirectHermesError {
            switch direct {
            case .secureStorageUnavailable:
                return .protectedStorageUnavailable
            case .savedConnectionInvalid, .invalidResponse, .invalidCredentials:
                return .savedStateRejected
            default:
                return .storageUnavailable
            }
        }
        if error is DecodingError { return .savedStateRejected }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain,
           cocoa.code == CocoaError.Code.fileReadNoPermission.rawValue {
            return .protectedStorageUnavailable
        }
        return .storageUnavailable
    }
}
