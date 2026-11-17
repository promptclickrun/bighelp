import Foundation
import UIKit
import UserNotifications

/// Sends the shares the share sheet marked for the default bot (`PendingShare.sendsItself`, #1069), with
/// no review. Each goes in a new chat with the default bot on the computer in use, through that chat's
/// message box (`ChatModel.placeShare`, then `send`): the ledger, the AI data agreement and the
/// attachment rules are the ones every share has, and a share is spent only when Hermes takes it.
///
/// It runs when bighelp comes to the front, when the share sheet says a share is saved and when iOS
/// starts bighelp for one (`PendingShareWakeReceiver`). A share that doesn't go stays saved and is tried
/// again on the next run, `maximumTries` times in one run of the app; after that, or when the person has
/// to look first (`goesAlone`), it's offered in the review like any other share. One the person placed,
/// or that may have reached Hermes, is never taken over or sent again.
@MainActor
final class PendingShareSender {
    /// A chat with the default bot on the computer in use, ready for a message.
    struct Target {
        let chat: ChatModel
        let destination: PendingShareDestination
        let agentName: String
        /// Saves the chat, as every send from outside the app does.
        var flush: @MainActor () -> Void = {}
    }

    enum Failure: Error, Equatable {
        /// Nothing to send with yet: the AI data agreement, a computer, or time in the background.
        /// Not counted as a try.
        case notReady
        /// The person has to look first: no bot, a share that isn't one plain message.
        case needsReview
        /// The computer didn't answer, or the chat couldn't be made.
        case unreachable
        /// A file didn't attach, or the chat didn't take the message.
        case refused
    }

    /// Connects, and returns a new chat with the default bot, or the chat an earlier try made
    /// (`earlier`) while it is still that bot's on this computer and still empty.
    typealias Open = @MainActor (_ earlier: PendingShareDestination?) async throws -> Target

    static let shared = PendingShareSender(center: .shared)
    static let maximumTries = 3
    /// Less background time than this and nothing new is started.
    static let minimumBackgroundTime: TimeInterval = 10

    private let center: PendingShareCenter
    /// Nil until the app has its computer wiring (`bind`): nothing is sent before.
    private var open: Open?
    var appIsActive: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
    var backgroundTimeLeft: @MainActor () -> TimeInterval = { UIApplication.shared.backgroundTimeRemaining }
    var tellNotSent: @MainActor (_ agentName: String?) async -> Void = PendingShareSender.postNotSent
    /// How long a run waits for Hermes to take a message before it leaves the chat to finish alone.
    var settleLimit: Duration = .seconds(20)
    /// The sheet's notification, the launch for it and coming to the front can follow each other in
    /// a second: a share that just failed isn't tried again at once, so one bad moment is one try.
    var retryGap: Duration = .seconds(15)

    private var tries: [String: Int] = [:]
    private var lastFailure: [String: ContinuousClock.Instant] = [:]
    private var told: Set<String> = []
    private var last: Task<Void, Never>?

    init(center: PendingShareCenter, open: Open? = nil) {
        self.center = center
        self.open = open
    }

    func bind(_ open: @escaping Open) { self.open = open }

    /// Sends what waits, after any run already under way.
    func run() async {
        let before = last
        let run = Task { @MainActor in
            await before?.value
            await self.sendWaiting()
        }
        last = run
        await run.value
    }

    /// What bighelp sends with nobody watching: one plain message. Not a share whose words would run
    /// as a command (the message box reads a first "/" that way, and nobody looked at it), and not a
    /// file over the message box's own size, which goes up in pieces for minutes with a progress tile
    /// and a Try again the person has to see.
    static func goesAlone(_ share: PendingShare) -> Bool {
        !share.composerText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
            && !share.files.contains { $0.kind == .file && $0.byteCount > ChatAttachment.maximumBytes }
    }

    /// An empty chat nobody has used: the only kind this sender types into, sends from and clears.
    static func isBlank(_ chat: ChatModel) -> Bool {
        chat.items.isEmpty && !PendingShare.hasWords(chat.draft) && chat.orderedDraftAttachments.isEmpty
            && chat.stagedSends.isEmpty
    }

    /// Still this sender's to send: meant for the default bot, not given up, in no chat, and never
    /// one the person placed or that may have reached Hermes (`PendingShareCenter.sendsItself`).
    private func waiting(_ id: String? = nil) -> [(PendingShare, PendingSharePlacement?)] {
        center.entries.compactMap { entry in
            guard case .share(let share, let placement) = entry, id == nil || share.id == id,
                  center.sendsItself(entry), !center.isHeld(share.id) else { return nil }
            return (share, placement)
        }
    }

    private func sendWaiting() async {
        guard let open, let inbox = center.inbox else { return }
        await center.refresh(resumesReview: false)
        let now = ContinuousClock.now
        let waiting = waiting().filter { share, _ in lastFailure[share.id].map { now - $0 >= retryGap } ?? true }
        guard !waiting.isEmpty else { return }
        // The connection stays up, and iOS is asked for time; when the time runs out the task is
        // handed back, so bighelp is suspended, not ended, and what is saved says how far each got.
        let releaseConnection = BighelpShortcutService.holdHostConnection()
        let endBackgroundTask = DeviceGeofenceBackgroundTasks.begin("Bighelp share")
        defer {
            releaseConnection()
            endBackgroundTask()
        }
        for (listed, _) in waiting {
            // Read again: the shares before it took time, and the person may have opened or deleted it.
            guard let (share, placement) = self.waiting(listed.id).first else { continue }
            // From here nobody else may open it (`PendingShareCenter.isHeld`).
            center.beginSending(share.id)
            await send(share, earlier: placement?.destination, from: inbox, open: open)
            center.endSending(share.id)
        }
    }

    private func send(_ share: PendingShare, earlier: PendingShareDestination?, from inbox: PendingShareInbox,
                      open: Open) async {
        let isActive = appIsActive()
        var agentName: String?
        do {
            guard Self.goesAlone(share) else { throw Failure.needsReview }
            guard isActive || backgroundTimeLeft() > Self.minimumBackgroundTime else { throw Failure.notReady }
            let target = try await open(earlier)
            agentName = target.agentName
            guard Self.isBlank(target.chat) else { throw Failure.refused }
            do {
                // Refused when the person placed it, or a message took it, while the chat was made.
                try await center.place(share, at: target.destination, agentName: target.agentName, automatic: true)
            } catch {
                throw Failure.refused
            }
            let placed = await target.chat.placeShare(share, from: inbox, tracker: center)
            guard placed == .placed, target.chat.draftAttachmentFailures.isEmpty else {
                takeBack(share, from: target.chat)
                throw Failure.refused
            }
            var sendEnded = false
            Task { @MainActor in
                await target.chat.send()
                sendEnded = true
            }
            let limit = isActive ? settleLimit : min(settleLimit, .seconds(min(60, max(2, backgroundTimeLeft() - 5))))
            let deadline = ContinuousClock.now + limit
            while isListed(share), ContinuousClock.now < deadline {
                if sendEnded, !target.chat.holdsShare(share.id) || isInBox(share, of: target.chat) { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            target.flush()
            guard isListed(share) else {
                // Hermes has it.
                told.remove(share.id)
                lastFailure[share.id] = nil
                return
            }
            // Still waiting for a connection that didn't come: back in the box, then out of it.
            let waitedForConnection = !target.chat.stagedSends.isEmpty
            if waitedForConnection { target.chat.returnStagedSendsToBox() }
            if isInBox(share, of: target.chat), sendEnded || waitedForConnection {
                takeBack(share, from: target.chat)
                throw waitedForConnection ? Failure.unreachable : Failure.refused
            }
            // Out of the chat and still saved: refused for good unless it may have arrived, which the
            // center has put in the list, saying so.
            if !target.chat.holdsShare(share.id), placement(of: share)?.recovery != .maybeSent {
                center.release(share.id, resumesReview: false)
                throw Failure.refused
            }
            // On its way: the chat settles it by itself.
        } catch {
            let failure = error as? Failure ?? .unreachable
            if failure != .notReady {
                tries[share.id, default: 0] += 1
                lastFailure[share.id] = .now
            }
            if failure == .needsReview || tries[share.id, default: 0] >= Self.maximumTries { center.giveUp(share.id) }
            // In front, the person sees the share waiting; in the background nothing else says so.
            if !isActive, told.insert(share.id).inserted { await tellNotSent(agentName) }
        }
    }

    private func isListed(_ share: PendingShare) -> Bool { center.entries.contains { $0.id == share.id } }

    private func placement(of share: PendingShare) -> PendingSharePlacement? {
        guard case .share(_, let placement)? = center.entries.first(where: { $0.id == share.id }) else { return nil }
        return placement
    }

    /// In the message box, not in a message that waits in the chat or is on its way.
    private func isInBox(_ share: PendingShare, of chat: ChatModel) -> Bool {
        chat.shareLedger.inBox.contains { $0.id == share.id }
    }

    /// Nobody sees this chat's message box, so a share that stays in it would never be offered
    /// again: the box is emptied and the share is free for the next try or for the person. Only ever
    /// a chat that was empty when the share went in (`isBlank`), so nothing of the person's is touched.
    private func takeBack(_ share: PendingShare, from chat: ChatModel) {
        chat.retireShares()
        let words = share.composerText
        if !words.isEmpty, chat.draft.contains(words) {
            chat.draft = chat.draft.replacingOccurrences(of: words, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for attachment in chat.orderedDraftAttachments
        where attachment.sourceAttachmentID.hasPrefix("attachment_share_\(share.id)_") {
            chat.removeDraftAttachment(id: attachment.sourceAttachmentID)
        }
        chat.draftAttachmentFailures.removeAll { failure in share.files.contains { $0.name == failure.name } }
        center.release(share.id, resumesReview: false)
    }

    /// A share bighelp was started for and couldn't send. Opening bighelp runs the sender again, or
    /// shows the share for the person to send.
    static func postNotSent(agentName: String?) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Not sent yet")
        if let agentName, !agentName.isEmpty {
            content.body = String(localized: "Bighelp couldn't send what you shared to \(agentName). Open Bighelp to send it.")
        } else {
            content.body = String(localized: "Bighelp couldn't send what you shared. Open Bighelp to send it.")
        }
        content.threadIdentifier = "bighelp.share"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "bighelp.share.not-sent", content: content, trigger: nil))
    }
}

extension PendingShareSender {
    /// The live path: the computer in use, as Shortcuts reach it, and its default bot.
    static func live(_ workspace: @escaping @MainActor () async throws -> BighelpShortcutWorkspace,
                     scope: @escaping @MainActor () -> String?) -> Open {
        { earlier in
            let connected: BighelpShortcutWorkspace
            do {
                connected = try await workspace()
            } catch BighelpShortcutServiceError.aiDataNotAgreed {
                throw Failure.notReady
            } catch {
                throw Failure.unreachable
            }
            guard let scope = scope() else { throw Failure.notReady }
            // The bot the widgets, and so the share sheet, name (`BighelpWidgetSnapshotPublisher`).
            guard let agent = connected.agents.resolvedAgent(explicitID: nil) ?? connected.agents.profiles.first else {
                throw Failure.needsReview
            }
            let reused = earlier.flatMap { $0.scope == scope && $0.agentID == agent.id ? $0.sessionID : nil }
            do {
                var (sessionID, chat) = try await connected.readyChat(agentID: agent.id, reusing: reused)
                // The earlier try's chat was used since (the person found it, or its bot wrote): a new one.
                if reused != nil, !isBlank(chat) {
                    (sessionID, chat) = try await connected.readyChat(agentID: agent.id, reusing: nil)
                }
                return Target(chat: chat,
                              destination: PendingShareDestination(scope: scope, agentID: agent.id, sessionID: sessionID),
                              agentName: agent.name, flush: { connected.featureStore.flushChatPersistence() })
            } catch {
                throw Failure.unreachable
            }
        }
    }
}

/// bighelp's side of `PendingShareWake`: it hears the share sheet while bighelp runs, and takes the
/// share sheet's background session when iOS starts bighelp for it. Either way the sender runs.
@MainActor
final class PendingShareWakeReceiver: NSObject, URLSessionDownloadDelegate {
    static let shared = PendingShareWakeReceiver()
    /// iOS gives an app it started for a background session about half a minute.
    static let limit: Duration = .seconds(25)

    private var session: URLSession?
    private var isListening = false

    /// At launch. The notification carries nothing; the sender reads the inbox.
    func listen() {
        guard !isListening else { return }
        isListening = true
        // A C callback: it can capture nothing, so it reaches the sender through `shared`.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in Task { @MainActor in await PendingShareSender.shared.run() } },
            PendingShareWake.notificationName as CFString, nil, .deliverImmediately)
    }

    /// `handleEventsForBackgroundURLSession` for the share sheet's session. `completion` tells iOS
    /// bighelp is done; it's called once the sender has run, or when the time is up.
    func handleEvents(completion: @escaping @Sendable () -> Void) {
        // Taking the session over is what marks its result as delivered.
        if session == nil {
            session = URLSession(configuration: PendingShareWake.configuration(), delegate: self, delegateQueue: nil)
        }
        Task { @MainActor in
            var finished = false
            Task { @MainActor in
                await PendingShareSender.shared.run()
                finished = true
            }
            let deadline = ContinuousClock.now + Self.limit
            while !finished, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(200)) }
            completion()
        }
    }

    /// The answer isn't read: the request only asked iOS to start bighelp.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {}
}
