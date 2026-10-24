import CryptoKit
import Foundation
import os

/// Gives the notification service this device's Apple push address, so it can send alerts
/// straight to Apple instead of through BuzzKit (docs/NOTIFICATION_ERROR_CODES.md, NS-123).
///
/// A phone that already has a notification installation and notification permission enrolls
/// itself at launch, with nothing shown. BuzzKit stays fully in place: this registration is
/// in addition. The notification service uses it only when it has one for the installation
/// and direct sending is on; otherwise it sends through BuzzKit as before.
///
/// - Runs signed with the installation's own key, like every other request to the service.
/// - A 404 means the service has no such route yet: nothing is logged, and it asks again in a day.
/// - Any other failure gets a code (NS-123 to NS-126) in the log and is retried with backoff.
/// - Nothing here is shown to the person or can stop notification setup.
/// - Every registration carries the topics the person turned off in Settings › Notifications, because
///   the service applies them itself when it sends straight to Apple. If they can't be read, nothing
///   is sent (the service then keeps using BuzzKit for this phone), and it tries again later.
@MainActor
final class BighelpPushRegistrar {
    static let pushTargetPath = "/v1/notifications/push-target"
    static let liveActivityTargetPath = "/v1/notifications/live-activity-target"
    /// The service keeps a registration for 60 days; refreshing weekly keeps it well inside that.
    static let refreshInterval: TimeInterval = 7 * 24 * 3600
    /// How long a 404 ("not available yet") waits before asking again.
    static let unavailableInterval: TimeInterval = 24 * 3600
    /// Waits after the first, second, third and later failures.
    static let backoff: [TimeInterval] = [5 * 60, 15 * 60, 3600, 6 * 3600]
    /// Asking iOS for the token on every foreground is wasteful; once in a while is enough.
    static let registerInterval: TimeInterval = 30 * 60
    /// The service counts address writes in windows of ten minutes per installation: four for the
    /// alert address and the push-to-start token together, forty for Live Activities and two per
    /// activity. The phone stays under that by itself: launches may use two of the four, so a change to
    /// the person's alert choices, which is rare and matters, always has room.
    static let writeWindow: TimeInterval = 600
    static let launchWriteLimit = 2
    static let preferenceWriteLimit = 3
    static let activityWriteLimit = 30
    static let activityWritePerIDLimit = 2
    private static let stateKey = "bighelp.direct-push.state.v1"
    private static let maximumPending = 8
    private static let log = Logger(subsystem: "app.loopdy.mobile", category: "DirectPush")

    /// What was last sent, and for which installation. The token itself is not kept: only a digest.
    struct Sent: Codable, Equatable {
        var installationID: String
        var digest: String
        var environment: String
        var at: Date
        /// The muted topics this registration carried (alert addresses only).
        var mutedTopics: [String]?
    }

    struct State: Codable, Equatable {
        var alert: Sent?
        var pushToStart: Sent?
        /// The service answered 404: it has no such route yet. Nothing is sent before this time.
        var unavailableUntil: Date?
        /// The alert address isn't sent before this time: the backoff after a failure.
        var retryAfter: Date?
        var failures = 0
        /// The person's alert choices changed and the service may not have the new list yet. Kept on the
        /// phone, so a failed send or a quit app can't lose the change; cleared only by a send that carried it.
        var mutedPending = false
        /// When the alert and push-to-start addresses were last written, within the service's window.
        var writes: [Date] = []
        /// Live Activity and push-to-start addresses back off on their own, so a problem there never holds
        /// up the alert address.
        var activityRetryAfter: Date?
        var activityFailures = 0
        /// The last failure's code, for the log and for tests; never shown.
        var lastErrorCode: String?
    }

    private enum PendingTarget: Equatable {
        case activity(String)
        case pushToStart(String)
    }

    private let api: any BighelpManagedNotificationAccountAPI
    private let credentials: @MainActor () -> BighelpManagedNotificationCredentials?
    private let isTurningOff: @MainActor () -> Bool
    private let isAuthorized: @MainActor () async -> Bool
    private let environment: @MainActor () -> BighelpLinkPushEnvironment
    private let appVersion: String
    private let registerForRemoteNotifications: @MainActor () -> Void
    private let startPushToStart: @MainActor (@escaping @MainActor (Data) async -> Void) -> Void
    private let mutedTopics: @MainActor () async -> [String]?
    private let currentPushToStartToken: @MainActor () async -> Data?
    private let sleep: @Sendable (Duration) async -> Void
    private let debounce: Duration
    private let defaults: UserDefaults
    private let now: () -> Date

    private var latestToken: String?
    private var sending = false
    private var sendAgain = false
    private var lastRegisterRequest: Date?
    /// Counts the choices changes, so a send knows whether a newer change arrived while it was out.
    private var mutedGeneration = 0
    /// Nothing is sent before BuzzKit has identified this phone and moved the saved choices: until then
    /// the choices could still be the old ones.
    private var isReady = false
    private let removalTimeout: Duration
    private var debounceTask: Task<Void, Never>?
    private var pending: [String: PendingTarget] = [:]
    private var deferredSend: Task<Void, Never>?
    private var pushToStartInFlight: String?
    private var activityInFlight: [String: String] = [:]
    private var sentActivities: [String: String] = [:]
    private var activityWrites: [String: [Date]] = [:]

    init(api: any BighelpManagedNotificationAccountAPI,
         credentials: @escaping @MainActor () -> BighelpManagedNotificationCredentials?,
         isTurningOff: @escaping @MainActor () -> Bool,
         isAuthorized: @escaping @MainActor () async -> Bool,
         environment: @escaping @MainActor () -> BighelpLinkPushEnvironment,
         appVersion: String,
         registerForRemoteNotifications: @escaping @MainActor () -> Void,
         startPushToStart: @escaping @MainActor (@escaping @MainActor (Data) async -> Void) -> Void = { _ in },
         mutedTopics: @escaping @MainActor () async -> [String]?,
         currentPushToStartToken: @escaping @MainActor () async -> Data? = { nil },
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         debounce: Duration = .seconds(2),
         removalTimeout: Duration = .seconds(5),
         startsReady: Bool = false,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.api = api; self.credentials = credentials; self.isTurningOff = isTurningOff
        self.isAuthorized = isAuthorized; self.environment = environment
        self.appVersion = Self.valid(appVersion: appVersion) ? appVersion : "0(0)"
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.startPushToStart = startPushToStart
        self.mutedTopics = mutedTopics; self.debounce = debounce
        self.currentPushToStartToken = currentPushToStartToken; self.sleep = sleep; self.removalTimeout = removalTimeout
        isReady = startsReady
        self.defaults = defaults; self.now = now
    }

    /// What was saved, for tests and diagnostics.
    var state: State {
        guard let data = defaults.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    // MARK: Launch, foreground and token changes

    /// At launch and whenever bighelp comes back: a phone that already has an installation and
    /// permission asks iOS for its token again, which comes back through `tokenReceived`.
    /// Does nothing for a phone that has neither.
    func refreshAtForeground() async {
        guard await eligibleCredentials() != nil else { return }
        // Called after BuzzKit identified and moved the saved choices, so they can be read now.
        isReady = true
        // A token that arrived earlier in the launch waits for this point.
        if latestToken != nil { Task { await runSendLoop() } }
        startPushToStart { [weak self] token in await self?.registerPushToStart(token) }
        // The stream may not repeat the token it already gave, so the current one is read each time too.
        // The same token is never written twice: it is compared with what the service has.
        Task { if let token = await currentPushToStartToken() { await registerPushToStart(token) } }
        // Earlier Live Activity tries go again in the background; they never hold up the launch.
        if !pending.isEmpty { Task { await retryPending() } }
        if isWaiting { return }
        if let last = lastRegisterRequest, now().timeIntervalSince(last) < Self.registerInterval { return }
        lastRegisterRequest = now()
        registerForRemoteNotifications()
    }

    /// iOS gave the app its token (at every launch, and again when it changes).
    func tokenReceived(_ token: Data) {
        Task { await receiveToken(token) }
    }

    /// The person changed what they want to hear about. A moment later (they often change several)
    /// the service is told, so it stops or starts sending those alerts straight to Apple.
    func preferencesChanged() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            await self.sendPreferenceChange()
        }
    }

    func sendPreferenceChange() async {
        mutedGeneration += 1
        update { $0.mutedPending = true }
        guard isReady else { return }
        if latestToken != nil {
            await runSendLoop()
        } else if await eligibleCredentials() != nil {
            // The token isn't known yet; it carries the new list when iOS gives it.
            lastRegisterRequest = now()
            registerForRemoteNotifications()
        }
    }

    func receiveToken(_ token: Data) async {
        latestToken = Self.hex(token)
        await runSendLoop()
    }

    private func runSendLoop() async {
        guard isReady else { return }
        // A send already running picks the newest token up when it finishes.
        guard !sending else { sendAgain = true; return }
        sending = true
        defer { sending = false }
        repeat {
            sendAgain = false
            await sendLatestToken()
        } while sendAgain
    }

    /// Setup just finished for the first time on this phone: its token is already known.
    func enrollmentFinished() async {
        // Setup identified the phone and moved the saved choices before this. A wait from a read that
        // failed before then is over: setup's own registration goes out at once.
        isReady = true
        update { $0.retryAfter = nil; $0.failures = 0 }
        if let latestToken, let data = Self.data(hex: latestToken) {
            await receiveToken(data)
        } else {
            lastRegisterRequest = now()
            registerForRemoteNotifications()
        }
    }

    private func sendLatestToken() async {
        guard let hex = latestToken, let credentials = await eligibleCredentials() else { return }
        let environment = environment()
        let digest = Self.digest(hex)
        if isWaiting {
            // A change to the choices must not sit until the next foreground: it goes when the wait ends.
            if state.mutedPending, let end = waitEnd { scheduleSend(after: end.timeIntervalSince(now()) + 1) }
            return
        }
        let previous = state.alert
        let isCurrent = previous.map {
            $0.installationID == credentials.deviceID && $0.digest == digest
                && $0.environment == environment.rawValue && Self.isFresh($0.at, now: now())
        } ?? false
        guard Self.valid(alertToken: hex) else {
            fail(.directPushRefused, stage: "token", kind: .check("token_invalid"))
            return
        }
        let generation = mutedGeneration
        // Without the person's choices the service can't apply them, so nothing is sent. They are read on
        // every pass, so a change the service missed (a failed send, an app quit meanwhile) is found.
        guard let muted = await loadMutedTopics() else {
            // A registration that is current has nothing to send; the next pass reads them again.
            if isCurrent { return }
            backOff()
            fail(.directPushUnreachable, stage: "preferences", kind: .check("preferences_unavailable"))
            return
        }
        if isCurrent, previous?.mutedTopics == muted {
            if generation == mutedGeneration, state.mutedPending { update { $0.mutedPending = false } }
            return
        }
        // A change to the person's choices has its own room in the budget.
        let isChoicesChange = isCurrent || state.mutedPending
        guard hasBudget(choicesChange: isChoicesChange) else {
            if isChoicesChange, let oldest = writesInWindow().min() {
                scheduleSend(after: oldest.addingTimeInterval(Self.writeWindow).timeIntervalSince(now()) + 1)
            }
            return
        }
        spendWrite()
        do {
            let body = try ManagedNotificationValidation.data(BighelpJSONValue.object([
                "version": .integer(1), "token": .string(hex), "environment": .string(environment.rawValue),
                "appVersion": .string(appVersion), "mutedTopics": .array(muted.map(BighelpJSONValue.string)),
            ]))
            let response = try await api.managedNotificationRequest(
                path: Self.pushTargetPath, method: "PUT", body: body, credentials: credentials)
            guard let target = response.object?["target"]?.object, target["kind"]?.string == "alert",
                  target["environment"]?.string == environment.rawValue else {
                throw BighelpLinkAPIError.invalidResponse
            }
            // The installation or the token can change while the request is out.
            guard self.credentials() == credentials, !isTurningOff() else { return }
            let unchanged = generation == mutedGeneration
            update {
                $0.alert = Sent(installationID: credentials.deviceID, digest: digest,
                                environment: environment.rawValue, at: now(), mutedTopics: muted)
                if unchanged { $0.mutedPending = false }
                $0.retryAfter = nil; $0.unavailableUntil = nil; $0.failures = 0; $0.lastErrorCode = nil
            }
        } catch is CancellationError {
            return
        } catch {
            handle(error, stage: "push-target", code: Self.code(for: error))
        }
    }

    // MARK: Live Activities

    /// A Live Activity's token. Best effort: BuzzKit and the notification service have it already.
    func registerActivity(id: String, token: Data) async {
        await sendActivityTarget(key: id, token: Self.hex(token), isPushToStart: false)
    }

    /// The app's push-to-start token (iOS 17.2 and later). Registration only; nothing starts from it yet.
    func registerPushToStart(_ token: Data) async {
        await sendActivityTarget(key: "pts", token: Self.hex(token), isPushToStart: true)
    }

    func removeActivity(id: String) async {
        pending[id] = nil
        sentActivities[id] = nil
        pruneActivityWrites()
        // A removal is a DELETE, which the service never limits; it spends none of the write budget.
        guard let credentials = installationCredentials(), !isWaitingForActivity else { return }
        do {
            _ = try await delete(Self.liveActivityTargetPath, credentials: credentials,
                                 body: ["version": .integer(1), "kind": .string("liveactivity"), "activityId": .string(id)])
        } catch is CancellationError {
            return
        } catch {
            // The service drops a Live Activity's target by itself after twelve hours.
            if !Self.isNotFound(error) { fail(.directPushActivityFailed, stage: "live-activity-remove", kind: .init(error)) }
        }
    }

    private func sendActivityTarget(key: String, token: String, isPushToStart: Bool) async {
        guard let credentials = installationCredentials() else { return }
        let environment = environment()
        let digest = Self.digest(token)
        if isPushToStart, let sent = state.pushToStart, sent.installationID == credentials.deviceID,
           sent.digest == digest, sent.environment == environment.rawValue,
           Self.isFresh(sent.at, now: now()) {
            pending[key] = nil
            return
        }
        guard Self.isHex(token), !token.isEmpty, token.utf8.count <= 512 else {
            fail(.directPushActivityFailed, stage: "live-activity-token", kind: .check("token_invalid"))
            return
        }
        if isPushToStart {
            // The same token is never written twice at once, nor again while the service has it.
            guard pushToStartInFlight != digest else { return }
        } else {
            // Neither the same token again, nor the same one twice at once.
            if sentActivities[key] == digest || activityInFlight[key] == digest { return }
            pruneActivityWrites()
            let recent = activityWrites[key] ?? []
            let all = activityWrites.values.flatMap { $0 }
            if recent.count >= Self.activityWritePerIDLimit || all.count >= Self.activityWriteLimit {
                hold(key: key, token: token, isPushToStart: false, whileUnavailable: false)
                return
            }
        }
        if isPushToStart, !isWaitingForActivity, !hasBudget(choicesChange: false) {
            hold(key: key, token: token, isPushToStart: true, whileUnavailable: false)
            return
        }
        if isWaitingForActivity {
            // Backing off, or the service has no such route yet. The push-to-start token waits (the
            // foreground pass also reads the current one, so it is found again either way); a Live
            // Activity's token is worthless by the time a day passes, so only a short backoff keeps it.
            hold(key: key, token: token, isPushToStart: isPushToStart, whileUnavailable: isUnavailable)
            return
        }
        var body: [String: BighelpJSONValue] = [
            "version": .integer(1), "kind": .string(isPushToStart ? "pts" : "liveactivity"),
            "token": .string(token), "environment": .string(environment.rawValue),
        ]
        if !isPushToStart { body["activityId"] = .string(key) }
        if isPushToStart {
            pushToStartInFlight = digest
            spendWrite()
        } else {
            activityWrites[key, default: []].append(now())
            activityInFlight[key] = digest
        }
        defer {
            if isPushToStart { pushToStartInFlight = nil } else { activityInFlight[key] = nil }
        }
        do {
            let response = try await api.managedNotificationRequest(
                path: Self.liveActivityTargetPath, method: "PUT",
                body: ManagedNotificationValidation.data(BighelpJSONValue.object(body)), credentials: credentials)
            guard let target = response.object?["target"]?.object,
                  target["kind"]?.string == (isPushToStart ? "pts" : "liveactivity") else {
                throw BighelpLinkAPIError.invalidResponse
            }
            pending[key] = nil
            if !isPushToStart {
                if sentActivities.count >= 64 { sentActivities.removeAll() }
                sentActivities[key] = digest
            }
            guard self.credentials() == credentials, !isTurningOff() else { return }
            update {
                $0.activityRetryAfter = nil; $0.activityFailures = 0
                if isPushToStart {
                    $0.pushToStart = Sent(installationID: credentials.deviceID, digest: digest,
                                          environment: environment.rawValue, at: now(), mutedTopics: nil)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if Self.isNotFound(error) {
                update { $0.unavailableUntil = now().addingTimeInterval(Self.unavailableInterval) }
                hold(key: key, token: token, isPushToStart: isPushToStart, whileUnavailable: true)
                return
            }
            let limited = Self.isRateLimited(error)
            update {
                $0.activityFailures += 1
                let wait = Self.backoff[min($0.activityFailures, Self.backoff.count) - 1]
                $0.activityRetryAfter = now().addingTimeInterval(limited ? max(wait, Self.writeWindow) : wait)
            }
            hold(key: key, token: token, isPushToStart: isPushToStart, whileUnavailable: false)
            fail(.directPushActivityFailed, stage: isPushToStart ? "push-to-start" : "live-activity", kind: .init(error))
        }
    }

    /// Keeps a token to send later. A Live Activity's isn't kept through a day-long wait.
    private func hold(key: String, token: String, isPushToStart: Bool, whileUnavailable: Bool) {
        if whileUnavailable && !isPushToStart { pending[key] = nil; return }
        guard pending.count < Self.maximumPending || pending[key] != nil else { return }
        pending[key] = isPushToStart ? .pushToStart(token) : .activity(token)
    }

    /// Live Activity targets whose first try failed go again at the next foreground.
    private func retryPending() async {
        for (key, target) in pending.sorted(by: { $0.key < $1.key }) {
            switch target {
            case .activity(let token): await sendActivityTarget(key: key, token: token, isPushToStart: false)
            case .pushToStart(let token): await sendActivityTarget(key: key, token: token, isPushToStart: true)
            }
        }
    }

    // MARK: Turning off

    /// Turning notifications off: the service forgets this phone's addresses (best effort, because
    /// revoking the installation removes them too) and this phone forgets what it sent.
    func removeAll() async {
        pending = [:]
        sentActivities = [:]
        deferredSend?.cancel()
        if let credentials = credentials() {
            // Both at once, and not for long: revoking the installation removes them anyway.
            let timeout = removalTimeout
            let removals = [
                Task { await remove(Self.pushTargetPath, body: ["version": .integer(1)], stage: "push-target-remove",
                                    credentials: credentials) },
                Task { await remove(Self.liveActivityTargetPath, body: ["version": .integer(1), "kind": .string("pts")],
                                    stage: "push-to-start-remove", credentials: credentials) },
            ]
            let cap = Task {
                try? await Task.sleep(for: timeout)
                for removal in removals { removal.cancel() }
            }
            for removal in removals { await removal.value }
            cap.cancel()
        }
        forgetLocalState()
    }

    private func remove(_ path: String, body: [String: BighelpJSONValue], stage: String,
                        credentials: BighelpManagedNotificationCredentials) async {
        do {
            _ = try await delete(path, credentials: credentials, body: body)
        } catch is CancellationError {
            return
        } catch {
            if !Self.isNotFound(error) { fail(.directPushRemoveFailed, stage: stage, kind: .init(error)) }
        }
    }

    /// This phone no longer has an installation, or its addresses are gone from the service.
    func forgetLocalState() {
        defaults.removeObject(forKey: Self.stateKey)
        lastRegisterRequest = nil
    }

    // MARK: Pieces

    private func delete(_ path: String, credentials: BighelpManagedNotificationCredentials,
                        body: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        try await api.managedNotificationRequest(
            path: path, method: "DELETE", body: ManagedNotificationValidation.data(BighelpJSONValue.object(body)),
            credentials: credentials)
    }

    /// A wait further ahead than the longest one we ever set means the clock moved: it is over.
    private func isAhead(_ date: Date?, within maximum: TimeInterval) -> Bool {
        guard let date else { return false }
        let remaining = date.timeIntervalSince(now())
        return remaining > 0 && remaining <= maximum
    }

    private static var longestBackoff: TimeInterval { max(backoff.max() ?? 0, writeWindow) }

    /// The service said 404 not long ago.
    private var isUnavailable: Bool {
        isAhead(state.unavailableUntil, within: Self.unavailableInterval)
    }

    private var isBackingOff: Bool { isAhead(state.retryAfter, within: Self.longestBackoff) }

    /// Unavailable, or backing off after a failure.
    private var isWaiting: Bool { isUnavailable || isBackingOff }

    /// The same, and the Live Activity addresses' own backoff.
    private var isWaitingForActivity: Bool {
        isWaiting || isAhead(state.activityRetryAfter, within: Self.longestBackoff)
    }

    /// When the current wait for the alert address ends.
    private var waitEnd: Date? {
        var ends: [Date] = []
        if isUnavailable, let until = state.unavailableUntil { ends.append(until) }
        if isBackingOff, let until = state.retryAfter { ends.append(until) }
        return ends.max()
    }

    /// The installation, only while it may be used: not while turning off, and (for alerts) only
    /// with notification permission.
    private func installationCredentials() -> BighelpManagedNotificationCredentials? {
        guard !isTurningOff() else { return nil }
        return credentials()
    }

    private func eligibleCredentials() async -> BighelpManagedNotificationCredentials? {
        guard let credentials = installationCredentials(), await isAuthorized() else { return nil }
        // Permission can be taken away while the question is asked.
        return installationCredentials() == credentials ? credentials : nil
    }

    private func update(_ change: (inout State) -> Void) {
        var next = state
        change(&next)
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.stateKey) }
    }

    private func handle(_ error: any Error, stage: String, code: BighelpNotificationErrorCode) {
        if Self.isNotFound(error) {
            // The service has no such route yet (an older Worker). Quiet; ask again tomorrow.
            update { $0.unavailableUntil = now().addingTimeInterval(Self.unavailableInterval); $0.failures = 0 }
            Self.log.info("Direct push is not available yet")
            return
        }
        backOff(afterRateLimit: Self.isRateLimited(error))
        fail(code, stage: stage, kind: .init(error))
    }

    /// A rate limit lasts a whole window, so the wait is at least that.
    private func backOff(afterRateLimit: Bool = false) {
        update {
            $0.failures += 1
            let wait = Self.backoff[min($0.failures, Self.backoff.count) - 1]
            $0.retryAfter = now().addingTimeInterval(afterRateLimit ? max(wait, Self.writeWindow) : wait)
        }
    }

    // MARK: The service's write budget

    /// Forgets the writes of activities whose last write left the window (ended or old ones).
    private func pruneActivityWrites() {
        let current = now()
        activityWrites = activityWrites.compactMapValues { dates in
            let recent = dates.filter { Self.isInWindow($0, now: current) }
            return recent.isEmpty ? nil : recent
        }
    }

    /// A write counts only if it is in the past and inside the window: a clock that was set back
    /// can't leave the budget stuck.
    private static func isInWindow(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < writeWindow
    }

    /// A registration younger than a week and not from the future.
    private static func isFresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < refreshInterval
    }

    private func writesInWindow() -> [Date] {
        state.writes.filter { Self.isInWindow($0, now: now()) }
    }

    private func hasBudget(choicesChange: Bool) -> Bool {
        writesInWindow().count < (choicesChange ? Self.preferenceWriteLimit : Self.launchWriteLimit)
    }

    /// Counted when sent, so a failed try counts too: the service may have counted it.
    private func spendWrite() {
        let recent = writesInWindow() + [now()]
        update { $0.writes = recent }
    }

    /// Runs the send loop again after `seconds` (at most a day; a newer call replaces an older one).
    private func scheduleSend(after seconds: TimeInterval) {
        let wait = min(max(1, seconds), Self.unavailableInterval + 60)
        deferredSend?.cancel()
        let sleep = self.sleep
        deferredSend = Task { [weak self] in
            await sleep(.seconds(wait))
            guard !Task.isCancelled, let self else { return }
            await self.runSendLoop()
        }
    }

    /// The topics turned off for push, among the four the service knows; nil when they can't be read.
    private func loadMutedTopics() async -> [String]? {
        guard let topics = await mutedTopics() else { return nil }
        return Array(Set(topics).intersection(Self.knownTopics)).sorted()
    }

    static let knownTopics: Set<String> = Set(BighelpBuzzKitTopic.allCases.map(\.rawValue))

    private func fail(_ code: BighelpNotificationErrorCode, stage: String, kind: BighelpNotificationErrorKind) {
        update { $0.lastErrorCode = code.rawValue }
        Self.log.error("Direct push: \(code.rawValue, privacy: .public) at \(stage, privacy: .public) (\(kind.description, privacy: .public))")
    }

    static func code(for error: any Error) -> BighelpNotificationErrorCode {
        if case BighelpLinkAPIError.requestFailed(let status, _) = error {
            // 429 and 5xx are the service being busy or down; everything else is a refusal.
            return status == 429 || status >= 500 ? .directPushUnreachable : .directPushRefused
        }
        if case BighelpLinkAPIError.invalidResponse = error { return .directPushRefused }
        if case BighelpLinkAPIError.invalidConfiguration = error { return .directPushRefused }
        return .directPushUnreachable
    }

    static func isRateLimited(_ error: any Error) -> Bool {
        if case BighelpLinkAPIError.requestFailed(let status, _) = error { return status == 429 }
        return false
    }

    static func isNotFound(_ error: any Error) -> Bool {
        if case BighelpLinkAPIError.requestFailed(let status, _) = error { return status == 404 }
        return false
    }

    // MARK: Encoding

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func data(hex: String) -> Data? {
        guard isHex(hex), hex.utf8.count.isMultiple(of: 2) else { return nil }
        var data = Data(); var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            data.append(byte); index = end
        }
        return data
    }

    static func isHex(_ value: String) -> Bool {
        value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The route accepts 64 to 200 lowercase hex characters, an even number.
    static func valid(alertToken hex: String) -> Bool {
        isHex(hex) && hex.utf8.count.isMultiple(of: 2) && (64...200).contains(hex.utf8.count)
    }

    static func valid(appVersion value: String) -> Bool {
        value.range(of: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}\([0-9]{1,7}\)$"#, options: .regularExpression) != nil
    }

    private static func digest(_ hex: String) -> String {
        SHA256.hash(data: Data(hex.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// "2.6.19(159)", from the app's own version and build.
    static func currentAppVersion(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version)(\(build))"
    }
}

/// Tells the push registrar that the person changed Settings › Notifications › Notify Me About.
@MainActor
enum BighelpPushPreferenceChanges {
    static var handler: (@MainActor () -> Void)?
    static func notify() { handler?() }
}
