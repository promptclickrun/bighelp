import Foundation

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
            hostClient: { [weak registry] host in
                guard let registry else { throw DirectHermesError.notConnected }
                return DirectHostNotificationClient(host: host, vault: registry.credentialVault(for: host),
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
        service.activityRuntime = BighelpManagedNativeActivityRuntime(service: service,
            environment: environment, topic: Bundle.main.bundleIdentifier ?? "app.loopdy.mobile")
        return service
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
            for host in service.registry.hosts {
                try Task.checkCancellation()
                guard isCurrent() else { throw DirectHermesError.secureStorageChanged }
                try await activityRuntime.recover(host: host)
                guard isCurrent() else { throw DirectHermesError.secureStorageChanged }
            }
            await activityRuntime.flushPendingOperations()
            guard isCurrent() else { throw DirectHermesError.secureStorageChanged }
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
                try await recoverDelivery(isCurrent)
            },
            // A content-free wake reconciles existing delivery state. It must
            // not re-identify the shared provider and invalidate enrollment.
            recoverWake: recoverDelivery,
            didRegisterAPNSToken: { token in
                BighelpBuzzKitRuntime.shared.noteAPNSToken(token)
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
    private final class Binding {
        var previous: Task<Void, Never>?
        var ticket = UUID()
        var selections: [SelectionKey: Selection] = [:]
    }

    static func bind(service: BighelpManagedNotificationService, host: BighelpConfiguredHost, chat: DirectHermesChat) {
        // Serial task ownership preserves the admitted stream's callback order.
        // The callback owns neither its client nor its model; queued work checks
        // the exact captured session/epoch/registry generation after every await.
        let binding = Binding()
        let chatID = chat.id
        chat.client.onAdmittedActivity = { [weak service, weak client = chat.client, weak model = chat.model] change, turn, failed in
            guard let service, let client, model != nil,
                  !change.activities.isEmpty || change.terminal else { return }
            let profile = client.profile; let session = client.storedID
            let epoch = client.projection.epoch; let generation = service.registry.generation
            let before = binding.previous
            let ticket = UUID(); binding.ticket = ticket
            binding.previous = Task { @MainActor [weak service, weak client, weak model] in
                await before?.value
                defer { if binding.ticket == ticket { binding.previous = nil } }
                guard let service, let client, let model else { return }
                @MainActor func isCurrent() -> Bool {
                    !Task.isCancelled && client.connected && client.profile == profile && client.storedID == session
                        && client.projection.epoch == epoch && service.registry.generation == generation
                        && service.ownsChat(host: host, client: client)
                }
                guard isCurrent() else { return }
                let currentChat = DirectHermesChat(id: chatID, client: client, model: model)
                for event in change.activities {
                    guard isCurrent() else { return }
                    let key = SelectionKey(profile: profile, session: session, epoch: epoch, localTurn: event.turnID)
                    if binding.selections[key] == nil, !event.lifecycle.isTerminal {
                        // A null/failed read is a LOCAL fallback for this segment,
                        // not permission to guess a turn or query again per token.
                        guard binding.selections.count < 512 else { continue }
                        binding.selections[key] = .local
                        if let snapshot = try? await service.workSnapshot(host: host, profile: profile,
                            storedSessionID: session, isCurrent: isCurrent) {
                            guard isCurrent() else { return }
                            binding.selections[key] = .observed(snapshot)
                        }
                    }
                    guard isCurrent(), let selection = binding.selections[key] else { continue }
                    let snapshot = selection.snapshot
                    // Track the authoritative CURRENT work explicitly; no claim
                    // that its ID equals the projection segment's synthetic ID.
                    try? await service.activityRuntime?.receive(host: host, chat: currentChat, event: event,
                        canonicalHostTurnID: snapshot?.work?.turnId, workSnapshot: snapshot)
                }
                guard isCurrent() else { return }
                if change.terminal {
                    try? await service.activityRuntime?.finish(host: host, profile: profile,
                        storedSessionID: session, originalLocalTurnID: turn,
                        outcome: failed ? .failed : .succeeded)
                }
            }
        }
    }
}
