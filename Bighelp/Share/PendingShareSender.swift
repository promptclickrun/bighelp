import Foundation
import OSLog
import UIKit
import UserNotifications

/// Sends the shares the share sheet marked for the default bot (`PendingShare.sendsItself`, #1069), with
/// no review. Each goes to the default bot on the computer in use, in a new chat or in its ongoing
/// chat as Settings › Chat › From other apps says (`PendingShareTarget`, #1071), through that chat's
/// message box (`ChatModel.placeShare`, then `send`): the ledger, the AI data agreement and the
/// attachment rules are the ones every share has, and a share is spent only when Hermes takes it.
///
/// The ongoing chat is the one a tap on the bot opens: the one the app has saved, else the computer's.
/// A computer that gives none is tried again like any failure; the last try sends to a new chat, as a
/// tap on the bot then opens its latest chat or a new one.
///
/// The ongoing chat is the person's own. A share goes in only while its message box is empty, so
/// nothing they typed goes with it; while they have something there, or a turn is just starting, the
/// share waits (`Failure.busy`) and is looked at again every `busyRecheck` while bighelp is open, for
/// `busyLimit` at most. While the bot works there, the share waits in Hermes' queue for its turn: it
/// never steers the work under way.
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
        /// The bot's ongoing chat can't take it yet: something of the person's is in its message box,
        /// or a turn is starting. Not a try.
        case busy
        /// The computer answered but gave the bot no ongoing chat (some can't). A try; the last one
        /// sends to a new chat instead, as a tap on the bot then opens its latest chat or a new one.
        case noOngoingChat
    }

    /// Connects, and returns the chat `into` asks for: a new chat with the default bot (or the one an
    /// earlier try made, `earlier`, while it is still that bot's on this computer and still empty), or
    /// that bot's ongoing chat.
    typealias Open = @MainActor (_ earlier: PendingShareDestination?, _ into: PendingShareTarget) async throws -> Target

    static let shared = PendingShareSender(center: .shared)
    /// Why a share didn't go, in fixed words: never what was shared.
    static let log = Logger(subsystem: "app.loopdy.mobile", category: "ShareSender")
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
    /// Read at each try, so a change in Settings counts for the next one.
    var target: @MainActor () -> PendingShareTarget = { PendingShareTarget.current }
    /// A busy ongoing chat is looked at again this often while bighelp is open (nil: only at the next
    /// run), and for this long at most; then the review offers the share.
    var busyRecheck: Duration? = .seconds(30)
    var busyLimit: Duration = .seconds(600)

    private var tries: [String: Int] = [:]
    private var lastFailure: [String: ContinuousClock.Instant] = [:]
    private var busySince: [String: ContinuousClock.Instant] = [:]
    private var waitsOnBusyChat = false
    private var recheck: Task<Void, Never>?
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
        scheduleBusyRecheck()
    }

    /// One look again later while a share waits for the ongoing chat and bighelp is open. Coming to
    /// the front and the share sheet run the sender anyway.
    private func scheduleBusyRecheck() {
        guard waitsOnBusyChat, recheck == nil, let busyRecheck, appIsActive() else { return }
        recheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: busyRecheck)
            guard let self, !Task.isCancelled else { return }
            self.recheck = nil
            await self.run()
        }
    }

    /// What bighelp sends with nobody watching: one plain message. Not a share whose words would run
    /// as a command (the message box reads a first "/" that way, and nobody looked at it), and not a
    /// file over the message box's own size, which goes up in pieces for minutes with a progress tile
    /// and a Try again the person has to see.
    static func goesAlone(_ share: PendingShare) -> Bool {
        !share.composerText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
            && !share.files.contains { $0.kind == .file && $0.byteCount > ChatAttachment.maximumBytes }
    }

    /// An empty chat nobody has used: the only new chat this sender types into, sends from and clears.
    static func isBlank(_ chat: ChatModel) -> Bool {
        chat.items.isEmpty && !PendingShare.hasWords(chat.draft) && chat.orderedDraftAttachments.isEmpty
            && chat.stagedSends.isEmpty
    }

    /// The bot's ongoing chat can take a share now: nothing of the person's in its message box (Send
    /// takes the whole box, so it would go with the share), no message waiting there, no other share
    /// on its way, and either no turn or a live one whose queue takes it.
    static func isFree(_ chat: ChatModel) -> Bool { whyBusy(chat) == nil }

    /// What keeps the ongoing chat from taking a share now, for `isFree` and the log.
    static func whyBusy(_ chat: ChatModel) -> String? {
        if PendingShare.hasWords(chat.draft) || chat.replyDraft != nil || chat.boardCardDraft != nil
            || chat.blueprintDraft != nil || !chat.referenceSelections.isEmpty
            || chat.richDraftRecovery.hasUnexportedChanges { return "words in the box" }
        if !chat.orderedDraftAttachments.isEmpty || !chat.draftAttachments.isEmpty
            || !chat.draftAttachmentFailures.isEmpty || chat.draftAttachmentImport != nil
            || chat.isPDFDraftSendInFlight { return "files in the box" }
        if !chat.stagedSends.isEmpty { return "a message waits" }
        // Only a share still on its way: one sent without an answer waits for a receipt for as long
        // as the chat lives, and must not hold up every share after it.
        let ledger = chat.shareLedger
        if !ledger.inBox.isEmpty || !ledger.placing.isEmpty
            || ledger.messages.contains(where: { $0.state == .staged || $0.state == .sending }) { return "another share" }
        if chat.isAwaitingAuthoritativeSessionAllocation { return "chat not made yet" }
        // Until its history is read, whether its bot is working is a guess from the saved list.
        if chat.isHydratingHistory { return "opening" }
        if !chat.isSending { return chat.directTransportIsReady ? nil : "not connected" }
        if !chat.isMidSessionTurnLive { return "turn starting" }
        return chat.hasExclusiveMidSessionSubmission ? "interrupt on its way" : nil
    }

    /// The box holds this share and nothing else: its words exactly, and only its files. Checked in
    /// the same turn as Send takes the box, so what the person typed meanwhile never goes with it.
    static func boxHoldsOnly(_ share: PendingShare, _ chat: ChatModel) -> Bool {
        let prefix = "attachment_share_\(share.id)_"
        return chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            == share.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
            && chat.orderedDraftAttachments.allSatisfy { $0.sourceAttachmentID.hasPrefix(prefix) }
            && chat.draftAttachments.allSatisfy { $0.id.hasPrefix(prefix) }
            && chat.replyDraft == nil && chat.boardCardDraft == nil && chat.blueprintDraft == nil
            && chat.referenceSelections.isEmpty
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
        waitsOnBusyChat = false
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
            var into = self.target()
            let target: Target
            do {
                target = try await open(earlier, into)
            } catch Failure.noOngoingChat where tries[share.id, default: 0] + 1 >= Self.maximumTries {
                // Every try found no ongoing chat: a new chat rather than none.
                into = .newChat
                target = try await open(earlier, .newChat)
            }
            agentName = target.agentName
            let chat = target.chat
            // Its words, left in the box by a try the app didn't live through, are this share's.
            if earlier?.sessionID == target.destination.sessionID, PendingShare.hasWords(share.composerText),
               chat.orderedDraftAttachments.isEmpty, Self.boxHoldsOnly(share, chat) {
                chat.draft = ""
            }
            // The sender's own new chat holds nothing of anyone else's; the ongoing chat is the person's.
            let ownChat = into == .newChat
            if ownChat {
                guard Self.isBlank(chat) else { throw Failure.refused }
            } else if let why = Self.whyBusy(chat) {
                Self.log.notice("Ongoing chat busy: \(why, privacy: .public)")
                throw Failure.busy
            }
            do {
                // Refused when the person placed it, or a message took it, while the chat was made.
                try await center.place(share, at: target.destination, agentName: target.agentName, automatic: true)
            } catch {
                throw Failure.refused
            }
            let failuresBefore = Set(chat.draftAttachmentFailures.map(\.id))
            let placed = await chat.placeShare(share, from: inbox, tracker: center)
            guard placed == .placed, chat.draftAttachmentFailures.isEmpty else {
                takeBack(share, from: chat, ownChat: ownChat, failuresBefore: failuresBefore)
                throw Failure.refused
            }
            var sendEnded = false
            var typedMeanwhile = false
            Task { @MainActor in
                // In the same turn as Send takes the box: the share alone, or nothing goes (the person
                // typed in that chat while the share's files came in, or a turn just started there).
                guard Self.boxHoldsOnly(share, chat), !chat.isSending || chat.isMidSessionTurnLive else {
                    typedMeanwhile = true
                    sendEnded = true
                    return
                }
                // A working bot gets it after its turn, never as a steer into the work under way.
                if chat.isSending {
                    await chat.sendMidSession(using: .queued)
                } else {
                    await chat.send()
                }
                sendEnded = true
            }
            let limit = isActive ? settleLimit : min(settleLimit, .seconds(min(60, max(2, backgroundTimeLeft() - 5))))
            let deadline = ContinuousClock.now + limit
            while isListed(share), ContinuousClock.now < deadline {
                if sendEnded, !chat.holdsShare(share.id) || isInBox(share, of: chat) { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            target.flush()
            guard isListed(share) else {
                // Hermes has it.
                told.remove(share.id)
                lastFailure[share.id] = nil
                busySince[share.id] = nil
                return
            }
            if typedMeanwhile {
                takeBack(share, from: chat, ownChat: ownChat, failuresBefore: failuresBefore)
                throw Failure.busy
            }
            // Still waiting for a connection that didn't come: back in the box, then out of it. Only
            // when every waiting message is this share's: in the ongoing chat the person may have
            // sent one too, and it stays where it is.
            let staged = chat.stagedSends
            let waitedForConnection = !staged.isEmpty && staged.allSatisfy { send in
                chat.shareLedger.message(row: send.id)?.shares.contains { $0.id == share.id } == true
            }
            if waitedForConnection { chat.returnStagedSendsToBox() }
            if isInBox(share, of: chat), sendEnded || waitedForConnection {
                takeBack(share, from: chat, ownChat: ownChat, failuresBefore: failuresBefore)
                throw waitedForConnection ? Failure.unreachable : Failure.refused
            }
            // Out of the chat and still saved: refused for good unless it may have arrived, which the
            // center has put in the list, saying so.
            if !chat.holdsShare(share.id), placement(of: share)?.recovery != .maybeSent {
                center.release(share.id, resumesReview: false)
                throw Failure.refused
            }
            // On its way: the chat settles it by itself.
        } catch {
            let failure = error as? Failure ?? .unreachable
            Self.log.notice("Share not sent: \(String(describing: failure), privacy: .public)")
            if failure == .busy {
                // Not a try: the person is using that chat, or it is about to answer.
                let since = busySince[share.id] ?? .now
                busySince[share.id] = since
                if ContinuousClock.now - since >= busyLimit {
                    center.giveUp(share.id)
                } else {
                    waitsOnBusyChat = true
                }
                if !isActive, told.insert(share.id).inserted { await tellNotSent(agentName) }
                return
            }
            busySince[share.id] = nil
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

    /// A share that stays in a message box nobody looks at would never be offered again: its own
    /// words and files come out, and it is free for the next try or for the person. Only what the
    /// share put there: in the ongoing chat the person may have typed meanwhile, and that stays.
    private func takeBack(_ share: PendingShare, from chat: ChatModel, ownChat: Bool, failuresBefore: Set<String>) {
        // The sender's own new chat holds no one else's shares.
        if ownChat { chat.retireShares() }
        let words = share.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty {
            if chat.draft.trimmingCharacters(in: .whitespacesAndNewlines) == words {
                chat.draft = ""
            } else if let range = chat.draft.range(of: words, options: .backwards) {
                var draft = chat.draft
                draft.removeSubrange(range)
                chat.draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        for attachment in chat.orderedDraftAttachments
        where attachment.sourceAttachmentID.hasPrefix("attachment_share_\(share.id)_") {
            chat.removeDraftAttachment(id: attachment.sourceAttachmentID)
        }
        chat.draftAttachmentFailures.removeAll { failure in
            !failuresBefore.contains(failure.id) && share.files.contains { $0.name == failure.name }
        }
        // The box holds nothing of it now: the ledger lets it go (and no other share).
        if !ownChat { chat.reviewSharesInBox() }
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
    /// The computer answered without an ongoing chat: it refused, can't, or answered something else.
    /// A lost connection is not this: the share then waits like any other.
    static func gaveNone(_ error: WorkspaceClientError) -> Bool {
        switch error {
        case .rejected, .invalidRequest, .invalidResponse, .outcomeUnknown, .unavailable, .conflict,
             .capacityExceeded: true
        case .ownerChanged, .authenticationRequired, .transportUnavailable: false
        }
    }

    /// The live path: the computer in use, as Shortcuts reach it, and its default bot. `botChat`
    /// gives the bot's ongoing chat, made when it has none (`WorkspaceConnectionStore.openCanonicalSession`).
    static func live(_ workspace: @escaping @MainActor () async throws -> BighelpShortcutWorkspace,
                     scope: @escaping @MainActor () -> String?,
                     botChat: @escaping @MainActor (_ agentID: String) async throws -> String) -> Open {
        { earlier, into in
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
            let target = { (opened: (sessionID: String, chat: ChatModel)) in
                Target(chat: opened.chat,
                       destination: PendingShareDestination(scope: scope, agentID: agent.id, sessionID: opened.sessionID),
                       agentName: agent.name, flush: { connected.featureStore.flushChatPersistence() })
            }
            // A chat this computer has, opened the way a tap opens it, then ready for a message. Only a
            // chat made just now comes connected; one that isn't on screen waited for a connection
            // nothing started, and every try ran out of time.
            let open = { (id: String) async throws -> (sessionID: String, chat: ChatModel) in
                let chat = try BighelpShortcutWorkspace.chatModel(sessionID: id, in: connected.featureStore)
                connected.featureStore.openDetachedChat(id: id)
                try await BighelpShortcutService.awaitTransportReady(chat)
                // Its newest page, so whether its bot is working is known (`whyBusy` waits otherwise).
                let read = ContinuousClock.now + .seconds(15)
                while chat.isHydratingHistory, ContinuousClock.now < read { try await Task.sleep(for: .milliseconds(100)) }
                return (id, chat)
            }
            if into == .botChat {
                // The one the app has saved, as a tap on the bot opens it; else the computer's, which
                // makes one when the bot has none.
                let saved = connected.catalog.records.first { $0.isBotChat && $0.agentIDs == [agent.id] }?.id
                var id = saved
                if id == nil {
                    do {
                        id = try await botChat(agent.id)
                    } catch let error as WorkspaceClientError where gaveNone(error) {
                        // Some computers can't give a bot its ongoing chat, and a busy one says so the
                        // same way: tried again, and the last try goes to a new chat.
                        log.notice("No ongoing chat to give: \(String(describing: error), privacy: .public)")
                        throw Failure.noOngoingChat
                    } catch {
                        throw Failure.unreachable
                    }
                }
                if let id {
                    // Never another chat in its place: `readyChat` makes one for a chat it doesn't know.
                    guard let record = connected.catalog.session(id: id), record.kind == .direct,
                          record.agentIDs == [agent.id] else {
                        log.notice("Ongoing chat not in the chat list")
                        throw Failure.unreachable
                    }
                    do {
                        return target(try await open(id))
                    } catch {
                        log.notice("Ongoing chat didn't connect: \(String(describing: error), privacy: .public)")
                        throw Failure.unreachable
                    }
                }
            }
            // Never the bot's ongoing chat: an earlier try in that mode put it there.
            let reused = earlier.flatMap { $0.scope == scope && $0.agentID == agent.id ? $0.sessionID : nil }
                .flatMap { id in connected.catalog.session(id: id).flatMap { $0.isBotChat ? nil : id } }
            do {
                // The earlier try's chat, unless it was used since (the person found it, or its bot
                // wrote): then a new one.
                if let reused {
                    let earlierChat = try await open(reused)
                    if isBlank(earlierChat.chat) { return target(earlierChat) }
                }
                return target(try await connected.readyChat(agentID: agent.id, reusing: nil))
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
