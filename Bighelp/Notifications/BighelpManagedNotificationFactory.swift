import Foundation
import UIKit
import UserNotifications

@MainActor
struct BighelpManagedNotificationFactory {
    let permissions: PermissionCenter
    let isFixture: Bool

    func make(registry: BighelpHostRegistry) throws -> BighelpManagedNotificationService? {
        guard !isFixture else { return nil }
        return try makeService(registry: registry)
    }

    /// Production composition must use this non-optional entry point and install
    /// every returned hook. It deliberately has no fixture/no-op fallback.
    func makeRequiredIntegration(registry: BighelpHostRegistry) throws -> BighelpManagedNotificationIntegration {
        guard !isFixture else { throw DirectHermesError.invalidResponse }
        let service = try makeService(registry: registry)
        return BighelpManagedNotificationIntegration(service: service)
    }

    private func makeService(registry: BighelpHostRegistry) throws -> BighelpManagedNotificationService {
        let broker = BighelpNotificationBrokerClient()
        let identity = BighelpNotificationIdentityCoordinator(
            vault: BighelpNotificationKeychainIdentityVault(),
            broker: broker
        )
        let service = BighelpManagedNotificationService(identity: identity, api: broker,
            requestPermission: {
                await permissions.refresh()
                if permissions.status(for: .notification).authorization == .notDetermined {
                    _ = await permissions.request(.notification)
                }
                switch permissions.status(for: .notification).authorization {
                case .authorized, .provisional, .ephemeral: return true
                default: return false
                }
            }, registry: registry, ledger: try BighelpManagedNotificationLedger(),
            hostClient: { [weak registry] host, profile in
                guard let registry else { throw DirectHermesError.notConnected }
                return DirectHostNotificationClient(host: host, vault: registry.credentialVault(for: host), profile: profile,
                    connectionIsCurrent: { [weak registry] in
                        registry?.accountScope == host.accountScope && registry?.hosts.contains(where: {
                            $0.id == host.id && $0.principalIdentity == host.principalIdentity
                        }) == true
                    })
            })
        #if DEBUG
        let environment: BighelpLinkPushEnvironment = .sandbox
        #else
        let environment: BighelpLinkPushEnvironment = .production
        #endif
        let group = BighelpActivityGroupDriver(underlying: BighelpActivityKitDriver())
        // The shared card's direct push address is registered under its group ID; it goes when the card ends.
        group.onPhysicalEnded = { [weak service] physicalID in
            Task { await service?.pushRegistrar?.sharedCardEnded(physicalID: physicalID) }
        }
        service.activityRuntime = BighelpManagedNativeActivityRuntime(service: service, driver: group,
            environment: environment, topic: Bundle.main.bundleIdentifier ?? "app.loopdy.mobile")
        service.pushRegistrar = Self.makePushRegistrar(service: service, api: broker)
        return service
    }

    /// The direct push registration (see `BighelpPushRegistrar`). The token's environment is the one
    /// BuzzKit was given: the simulator is sandbox, a provisioning profile wins, and the build
    /// configuration is the fallback.
    private static func makePushRegistrar(service: BighelpManagedNotificationService,
                                          api: any BighelpManagedNotificationAccountAPI) -> BighelpPushRegistrar {
        let registrar = BighelpPushRegistrar(
            api: api,
            credentials: { [weak service] in service?.installationCredentials() },
            isTurningOff: { [weak service] in service?.turnOffPending ?? true },
            isAuthorized: {
                switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
                case .authorized, .provisional, .ephemeral: true
                default: false
                }
            },
            environment: {
                switch BighelpBuzzKitPushEnvironmentResolver.live.resolve(bundle: .main) {
                case .sandbox: .sandbox
                case .production: .production
                }
            },
            appVersion: BighelpPushRegistrar.currentAppVersion(),
            registerForRemoteNotifications: { UIApplication.shared.registerForRemoteNotifications() },
            startPushToStart: { handler in BighelpPushToStartObserver.shared.start(handler) },
            mutedTopics: {
                // The same choices Settings shows. Nothing readable, or none of the topics, means unknown.
                guard let preferences = try? await BighelpBuzzKitPreferencesClient().load(),
                      !preferences.isEmpty else { return nil }
                return preferences.filter { !$0.enabled }.map(\.id)
            },
            currentPushToStartToken: { await BighelpPushToStartObserver.shared.currentToken() })
        BighelpPushPreferenceChanges.handler = { [weak registrar] in registrar?.preferencesChanged() }
        return registrar
    }
}

/// Required root hooks for notification composition. Chat recovery/send remains
/// owned by the foreground native runtime; these hooks only subscribe its exact
/// authenticated session and maintain independent background BuzzKit delivery.
@MainActor
struct BighelpManagedNotificationIntegration {
    let service: BighelpManagedNotificationService
    let hooks: Hooks

    struct Hooks {
        let prepareChat: @MainActor (BighelpConfiguredHost, DirectHermesChat) async throws -> Void
        let receiveNativeEvent: @MainActor (BighelpConfiguredHost, DirectHermesEvent) async -> Void
        let recoverForeground: @MainActor (
            @escaping @MainActor () -> Bool
        ) async throws -> Void
        let recoverWake: @MainActor (
            @escaping @MainActor () -> Bool
        ) async throws -> Void
        let didRegisterAPNSToken: @MainActor (Data) -> Void
        let didFailAPNsRegistration: @MainActor (any Error) -> Void
        let openManagedEvent: @MainActor (
            String,
            String,
            @escaping @MainActor () -> Bool
        ) async throws -> DirectHermesChat
    }

    init(service: BighelpManagedNotificationService) {
        self.service = service
        let recoverDelivery: @MainActor (@escaping @MainActor () -> Bool) async throws -> Void = { isCurrent in
            guard isCurrent(), let activityRuntime = service.activityRuntime else {
                throw DirectHermesError.invalidResponse
            }
            try await service.reconcilePendingRevocations()
            guard isCurrent() else { throw DirectHermesError.secureStorageChanged }
            // A failed recovery is reported, but never before the flush: the flush retries card
            // registrations and repairs cards, and one stuck revoke must not hold those back.
            var firstFailure: (any Error)?
            for host in service.registry.hosts {
                try Task.checkCancellation()
                guard isCurrent() else { throw DirectHermesError.secureStorageChanged }
                do { try await activityRuntime.recover(host: host) }
                catch is CancellationError { throw CancellationError() }
                catch { firstFailure = firstFailure ?? error }
                guard isCurrent() else { throw DirectHermesError.secureStorageChanged }
            }
            await activityRuntime.flushPendingOperations()
            guard isCurrent() else { throw DirectHermesError.secureStorageChanged }
            if let firstFailure { throw firstFailure }
        }
        hooks = Hooks(
            prepareChat: { host, chat in
                // Bind the Live Activity observer first. The host grant now
                // covers every session in its profile, so a failed per-chat
                // opt-in must not also cost the user their Live Activity.
                BighelpManagedActivityBridge.bind(service: service, host: host, chat: chat)
                try await service.onChatOpened(host: host, chat: chat)
            },
            receiveNativeEvent: { host, event in
                await service.receive(host: host, event: event)
            },
            recoverForeground: { isCurrent in
                if service.turnOffPending {
                    // Finish a turn-off the notification service hadn't confirmed.
                    if (try? await service.turnOffNotifications()) != nil { BighelpNotificationDeviceCleanup.run() }
                    return
                }
                await service.retryPendingHostCleanups()
                do {
                    _ = try await service.refreshNotificationIdentity()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Launch identification is retried on the next foreground or
                    // explicit enable. It must not block app-owned grant recovery.
                }
                // A phone that already has notifications sends its direct push address now, with nothing
                // shown. After BuzzKit identified, because the person's alert choices come from BuzzKit.
                await service.pushRegistrar?.refreshAtForeground()
                try await recoverDelivery(isCurrent)
                // A computer that dropped this phone's setup is set up again here, without Set Up Again.
                for host in service.hostsWithNotifications() {
                    guard isCurrent() else { break }
                    await service.repairIfDropped(host: host)
                }
            },
            // A content-free wake reconciles existing delivery state. It must
            // not re-identify the shared provider and invalidate enrollment.
            recoverWake: recoverDelivery,
            didRegisterAPNSToken: { token in
                BighelpBuzzKitRuntime.shared.noteAPNSToken(token)
                service.pushRegistrar?.tokenReceived(token)
            },
            didFailAPNsRegistration: { error in
                BighelpBuzzKitRuntime.shared.noteAPNsRegistrationFailure(error)
            },
            openManagedEvent: { eventID, eventType, isCurrent in
                return try await service.openVerifiedEvent(
                    eventID: eventID,
                    eventType: eventType,
                    isCurrent: {
                        !Task.isCancelled && isCurrent()
                    }
                )
            }
        )
    }
}

@MainActor
enum BighelpManagedActivityBridge {
    private struct SelectionKey: Hashable {
        let profile: String
        let session: String
        let epoch: String
        let localTurn: String
    }
    private enum Selection {
        case local
        case observed(BighelpManagedWorkSnapshot)
        var snapshot: BighelpManagedWorkSnapshot? {
            if case let .observed(value) = self { return value }
            return nil
        }
    }
    @MainActor private final class Binding {
        var previous: Task<Void, Never>?
        var ticket = UUID()
        var selections: [SelectionKey: Selection] = [:]
        /// Turns still asking the computer which work they are (`snapshotRetryWaits`).
        var retries: [SelectionKey: Task<Void, Never>] = [:]
        /// Each running turn's newest event, for the ask that takes its card later.
        var latest: [SelectionKey: ChatActivityEvent] = [:]

        /// Runs `work` after everything queued before it, so the admitted stream keeps its order.
        @discardableResult
        func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
            let before = previous
            let ticket = UUID(); self.ticket = ticket
            let task = Task { @MainActor in
                await before?.value
                await work()
                if self.ticket == ticket { self.previous = nil }
            }
            previous = task
            return task
        }
    }
    /// The chat, connection and registry a queued step was made for. Every step checks it after each wait.
    private struct Scope {
        let host: BighelpConfiguredHost
        let chatID: String
        let profile: String
        let session: String
        let epoch: String
        let generation: UUID

        @MainActor func isCurrent(_ service: BighelpManagedNotificationService, _ client: DirectHermesConversationClient) -> Bool {
            !Task.isCancelled && client.connected && client.profile == profile && client.storedID == session
                && client.projection.epoch == epoch && service.registry.generation == generation
                && service.ownsChat(host: host, client: client)
        }
        func key(_ localTurn: String) -> SelectionKey {
            .init(profile: profile, session: session, epoch: epoch, localTurn: localTurn)
        }
    }

    /// How long to wait before each further ask about a turn the computer didn't know at its start.
    /// The phone asks the moment a turn starts; the computer learns of the turn at its first model
    /// request, once its memory and context are ready. That is usually a second or two later, and
    /// longer for a chat that was idle. Most asks come early, while bighelp is likely still open.
    static let snapshotRetryWaits: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8),
                                                 .seconds(15), .seconds(30), .seconds(60)]

    /// Asks the computer which work a turn is, and gives the turn's card to that work: at once, then
    /// after each of `waits` while the turn runs and nothing has taken its card.
    ///
    /// The computer learns of a turn at its first model request, which comes after the first ask.
    /// Asked only once, the card stayed this phone's for the whole turn: it got no update with bighelp
    /// away, and no detail. The read runs beside the stream, never in it: the computer may hold its
    /// answer for a turn that is starting, and the card's own updates must not wait behind that.
    /// Taking the card runs in the stream's order. A waiting ask holds neither the chat nor its model.
    private static func ask(_ scope: Scope, _ binding: Binding, service: BighelpManagedNotificationService,
                            chat: DirectHermesChat, turnID: String, waits: [Duration]) {
        let key = scope.key(turnID)
        binding.retries[key]?.cancel()
        binding.retries[key] = Task { @MainActor [weak service, weak client = chat.client, weak model = chat.model] in
            for wait in [.zero] + waits {
                if wait > .zero { try? await Task.sleep(for: wait) }
                guard !Task.isCancelled else { return }
                // Done once the card went to the computer's turn, the turn is over, or notifications are off here.
                guard let service, let client, case .local = binding.selections[key],
                      client.projection.running, client.projection.turnID == turnID,
                      (try? service.credentials(for: scope.host)) != nil else { break }
                // A chat between connections waits for its next ask.
                guard scope.isCurrent(service, client) else { continue }
                let isCurrent: @MainActor () -> Bool = { [weak service, weak client] in
                    guard let service, let client else { return false }
                    return scope.isCurrent(service, client)
                }
                let snapshot: BighelpManagedWorkSnapshot
                do {
                    // No answer at all: this chat's agent has no Live Activity setup to ask.
                    guard let answer = try await service.workSnapshot(host: scope.host, profile: scope.profile,
                        storedSessionID: scope.session, isCurrent: isCurrent) else { break }
                    snapshot = answer
                } catch { continue }
                // No work, or only the chat's last turn: the computer hasn't seen this one yet.
                guard snapshot.work?.terminal == false else { continue }
                await binding.enqueue { [weak service, weak client, weak model] in
                    guard let service, let client, let model, scope.isCurrent(service, client),
                          case .local = binding.selections[key], client.projection.turnID == turnID,
                          let event = binding.latest[key] else { return }
                    let chat = DirectHermesChat(id: scope.chatID, client: client, model: model)
                    do {
                        if try await service.activityRuntime?.promote(host: scope.host, chat: chat,
                            localTurn: turnID, snapshot: snapshot) != true {
                            try await service.activityRuntime?.receive(host: scope.host, chat: chat, event: event,
                                canonicalHostTurnID: snapshot.work?.turnId, workSnapshot: snapshot)
                        }
                        guard scope.isCurrent(service, client) else { return }
                        binding.selections[key] = .observed(snapshot)
                    } catch {
                        // Keep the admitted local row; a later ask must not guess a new host turn.
                    }
                }.value
            }
            if !Task.isCancelled { binding.retries[key] = nil }
        }
    }

    static func bind(service: BighelpManagedNotificationService, host: BighelpConfiguredHost, chat: DirectHermesChat,
                     snapshotRetryWaits: [Duration] = BighelpManagedActivityBridge.snapshotRetryWaits) {
        // Serial task ownership preserves the admitted stream's callback order.
        // The callback owns neither its client nor its model; queued work checks
        // the exact captured session/epoch/registry generation after every await.
        let binding = Binding()
        let chatID = chat.id
        chat.client.onSendStarted = { [weak service, weak client = chat.client, weak model = chat.model] in
            guard let service, let client, let model else { return }
            service.activityRuntime?.arm(host: host, chat: DirectHermesChat(id: chatID, client: client, model: model))
        }
        chat.client.onAdmittedActivity = { [weak service, weak client = chat.client, weak model = chat.model] change, turn, failed in
            guard let service, let client, model != nil,
                  !change.activities.isEmpty || change.terminal else { return }
            let scope = Scope(host: host, chatID: chatID, profile: client.profile, session: client.storedID,
                              epoch: client.projection.epoch, generation: service.registry.generation)
            binding.enqueue { [weak service, weak client, weak model] in
                guard let service, let client, let model, scope.isCurrent(service, client) else { return }
                let currentChat = DirectHermesChat(id: chatID, client: client, model: model)
                for event in change.activities {
                    guard scope.isCurrent(service, client) else { return }
                    let key = scope.key(event.turnID)
                    if binding.selections[key] == nil, !event.lifecycle.isTerminal {
                        // The card starts as this phone's. `ask` gives it to the computer's turn once the
                        // computer names one; nothing here guesses a turn, and no event asks again.
                        guard binding.selections.count < 512 else { continue }
                        binding.selections[key] = .local
                        binding.latest[key] = event
                        // Start while the confirmed live turn is foregrounded.
                        // Token registration can wait for its exact host snapshot.
                        try? await service.activityRuntime?.receive(host: host, chat: currentChat, event: event,
                            canonicalHostTurnID: nil)
                        guard scope.isCurrent(service, client) else { return }
                        ask(scope, binding, service: service, chat: currentChat, turnID: event.turnID, waits: snapshotRetryWaits)
                    }
                    guard scope.isCurrent(service, client), let selection = binding.selections[key] else { continue }
                    if !event.lifecycle.isTerminal { binding.latest[key] = event }
                    let snapshot = selection.snapshot
                    // Track the authoritative CURRENT work explicitly; no claim
                    // that its ID equals the projection segment's synthetic ID.
                    try? await service.activityRuntime?.receive(host: host, chat: currentChat, event: event,
                        canonicalHostTurnID: snapshot?.work?.turnId, workSnapshot: snapshot)
                }
                guard scope.isCurrent(service, client) else { return }
                if change.terminal {
                    // The turn ended: nothing is left to ask the computer about.
                    for key in binding.selections.keys where key.localTurn == turn {
                        binding.retries.removeValue(forKey: key)?.cancel()
                        binding.latest[key] = nil
                    }
                    try? await service.activityRuntime?.finish(host: host, profile: scope.profile,
                        storedSessionID: scope.session, originalLocalTurnID: turn,
                        outcome: failed ? .failed : .succeeded)
                }
            }
        }
        // Preparation also runs after reconnect. A live authoritative running
        // snapshot may have arrived before this observer was installed.
        if chat.client.connected, !chat.client.isHydrating, !chat.client.needsRecovery,
           !chat.client.requiresDurableReattachment, chat.client.projection.running {
            let event = ChatActivityEvent(eventID: "live-turn-" + chat.client.projection.turnID,
                sessionID: chat.client.conversationID, turnID: chat.client.projection.turnID,
                kind: .reasoning, lifecycle: .running, title: "Preparing a response",
                summary: nil, detail: nil, occurredAt: Int(Date().timeIntervalSince1970))
            chat.client.onAdmittedActivity?(.init(activities: [event]), chat.client.projection.turnID, false)
        }
    }
}
