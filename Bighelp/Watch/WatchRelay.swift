#if os(iOS) && !targetEnvironment(macCatalyst) // A Mac pairs with no Watch.
import CryptoKit
import Foundation
import UIKit
import UserNotifications
import WatchConnectivity

/// The iPhone side of the Watch app. The Watch asks; this answers through the
/// same live host connection Shortcuts use, so it works with bighelp closed
/// (WatchConnectivity wakes the app in the background).
@MainActor
final class WatchRelay: NSObject {
    typealias WorkspaceProvider = @MainActor () async throws -> BighelpShortcutWorkspace
    typealias BoardProvider = @MainActor () -> (any AgentBoardClient)?

    private let session: WCSession?
    private let workspace: WorkspaceProvider
    private let boards: BoardProvider
    private let hasHost: @MainActor () -> Bool
    private let hostKey: @MainActor () -> String
    /// Messages already sent, so a repeat from the Watch isn't sent twice.
    private var sentSessions: [UUID: String] = [:]
    private var sentOrder: [UUID] = []

    init(
        session: WCSession? = WCSession.isSupported() ? .default : nil,
        workspace: @escaping WorkspaceProvider,
        boards: @escaping BoardProvider,
        hasHost: @escaping @MainActor () -> Bool,
        hostKey: @escaping @MainActor () -> String
    ) {
        self.session = session
        self.workspace = workspace
        self.boards = boards
        self.hasHost = hasHost
        self.hostKey = hostKey
        super.init()
    }

    func activate() {
        session?.delegate = self
        session?.activate()
    }

    func handle(_ request: WatchRequest) async -> WatchReply {
        do {
            switch request {
            case .home: return .home(await home())
            case .chat(let id): return .chat(try await chat(id))
            case .send(let outgoing): return .sent(sessionID: try await send(outgoing))
            case .board(let agentID, let kind): return .board(try await board(agentID: agentID, kind: kind))
            case .decide(let id, let decision): try await decide(id, decision); return .done
            case .answer(let id, let text): try await answer(id, text); return .done
            case .open(let link): try await open(link); return .done
            }
        } catch let error as WatchRelayError {
            return .failed(error.message)
        } catch {
            return .failed(WatchRelayError.unreachable.message)
        }
    }

    // MARK: Requests

    private func connected() async throws -> BighelpShortcutWorkspace {
        guard hasHost() else { throw WatchRelayError.noHost }
        do { return try await workspace() } catch { throw WatchRelayError.unreachable }
    }

    private func home() async -> WatchHome {
        guard hasHost() else { return .unavailable(.noHost) }
        guard let workspace = try? await workspace() else { return .unavailable(.unreachable) }
        try? await workspace.catalog.load()
        await workspace.featureStore.dashboardModel.refreshAfterExternalChange()
        let agents = workspace.agents.profiles
        let names = Dictionary(agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let summaries = workspace.catalog.recentSummaries(includeCronSessions: false)
        return WatchHome(
            status: .ready,
            hostKey: hostKey(),
            agents: agents.prefix(WatchLimits.agents).map {
                WatchAgent(id: $0.id, name: WatchWire.bounded($0.name, bytes: WatchLimits.name),
                           role: WatchWire.bounded($0.role, bytes: WatchLimits.name))
            },
            homeAgentID: workspace.agents.resolvedAgent(explicitID: nil)?.id,
            needs: WatchRelayProjection.needs(
                workspace.featureStore.dashboardModel.snapshot?.attentionItems ?? [], agentNames: names),
            chats: WatchRelayProjection.chats(summaries, agentNames: names) { id in
                workspace.featureStore.preparedChatModel(id: id)?.isSending == true
            },
            generatedAt: .now
        )
    }

    private func chat(_ id: String) async throws -> WatchChat {
        let workspace = try await connected()
        let names = Dictionary(workspace.agents.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // A turn in progress lives in the chat model; otherwise the host's
        // saved history is the truth.
        if let model = workspace.featureStore.preparedChatModel(id: id), model.isSending,
           let record = workspace.catalog.session(id: id) {
            return WatchRelayProjection.chat(record, items: model.items, isWorking: true,
                                             activityEvents: model.activityLedger.allEvents, agentNames: names)
        }
        guard let record = try? await workspace.catalog.hydrateSession(id: id) else { throw WatchRelayError.chatGone }
        return WatchRelayProjection.chat(record, items: record.items, isWorking: record.isActive,
                                         activityEvents: record.activityEvents, agentNames: names)
    }

    private func send(_ outgoing: WatchOutgoing) async throws -> String {
        if let sessionID = sentSessions[outgoing.id] { return sessionID }
        let text = outgoing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WatchRelayError.empty }
        let workspace = try await connected()
        var agentID = outgoing.agentID
        if let sessionID = outgoing.sessionID {
            // Never let a message meant for a chat start a new one.
            var record = workspace.catalog.session(id: sessionID)
            if record == nil { record = try? await workspace.catalog.hydrateSession(id: sessionID) }
            guard let record else { throw WatchRelayError.chatGone }
            agentID = record.agentIDs.first
        }
        guard let agent = workspace.agents.resolvedAgent(explicitID: agentID) else { throw WatchRelayError.agentGone }
        let (sessionID, chat) = try await BighelpShortcutService.holdingHostConnection(named: "bighelp Watch") {
            try await workspace.readyChat(agentID: agent.id, reusing: outgoing.sessionID)
        }
        remember(outgoing.id, sessionID: sessionID)
        Telemetry.featureUsed(.watchChat)

        // The phone's own draft for this chat comes back after the Watch's message.
        let phoneDraft = chat.draft
        let known = Set(chat.items.map(\.id))
        chat.draft = text
        Task { @MainActor [weak self] in
            await BighelpShortcutService.holdingHostConnection(named: "bighelp Watch reply") {
                await chat.send()
            }
            workspace.featureStore.flushChatPersistence()
            self?.push(.replyReady(sessionID: sessionID))
        }
        // Answer once the message is really in the chat (or clearly wasn't).
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if chat.failureMessage != nil { break }
            if chat.items.contains(where: { !known.contains($0.id) && $0.role == .human }) { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        if chat.draft.isEmpty || chat.draft == text { chat.draft = phoneDraft }
        guard chat.failureMessage == nil,
              chat.items.contains(where: { !known.contains($0.id) && $0.role == .human }) else {
            forget(outgoing.id)
            throw WatchRelayError.notSent
        }
        return sessionID
    }

    private func board(agentID: String, kind: WatchBoardKind) async throws -> [WatchBoardItem] {
        _ = try await connected()
        guard let client = boards() else { throw WatchRelayError.boardUnavailable }
        let items = try await BighelpShortcutService.holdingHostConnection(named: "bighelp Watch board") {
            try await client.items(agentID: agentID)
        }
        return WatchRelayProjection.board(items, kind: kind)
    }

    private func decide(_ needID: String, _ choice: WatchDecision) async throws {
        let workspace = try await connected()
        let dashboard = workspace.featureStore.dashboardModel
        await dashboard.refreshAfterExternalChange()
        guard let item = dashboard.snapshot?.attentionItems.first(where: { $0.id == needID }),
              case .approval(let summary) = item.interaction, !summary.isExpired(at: .now) else {
            throw WatchRelayError.needGone
        }
        guard let decision = ApprovalDecision(rawValue: choice.rawValue),
              summary.allowedDecisions.contains(decision) else { throw WatchRelayError.needGone }
        await BighelpShortcutService.holdingHostConnection(named: "bighelp Watch approval") {
            await dashboard.respondToApproval(itemID: needID, decision: decision)
        }
        guard dashboard.snapshot?.attentionItems.contains(where: { $0.id == needID }) != true else {
            throw WatchRelayError.notConfirmed
        }
    }

    private func answer(_ needID: String, _ text: String) async throws {
        let workspace = try await connected()
        let dashboard = workspace.featureStore.dashboardModel
        await dashboard.refreshAfterExternalChange()
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = dashboard.snapshot?.attentionItems.first(where: { $0.id == needID }),
              case .clarification(let request) = item.interaction,
              WatchRelayProjection.isSimple(request), !request.isExpired(at: .now) else {
            throw WatchRelayError.needGone
        }
        guard !answer.isEmpty, request.allowsCustomResponse || request.choices.contains(answer) else {
            throw WatchRelayError.empty
        }
        await BighelpShortcutService.holdingHostConnection(named: "bighelp Watch answer") {
            await dashboard.respondToClarification(itemID: needID, response: answer)
        }
        guard dashboard.snapshot?.attentionItems.contains(where: { $0.id == needID }) != true else {
            throw WatchRelayError.notConfirmed
        }
    }

    /// Opens bighelp's own links only. With the app in front it goes straight
    /// there; otherwise a notification on the phone opens it with one tap.
    private func open(_ link: WatchPhoneLink) async throws {
        guard let url = WatchRelayProjection.openableURL(link.url) else { throw WatchRelayError.cantOpen }
        if UIApplication.shared.applicationState == .active {
            await UIApplication.shared.open(url)
            return
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            throw WatchRelayError.notificationsOff
        }
        let content = UNMutableNotificationContent()
        content.title = "Open on iPhone"
        content.body = link.title.isEmpty ? "Tap to open it in bighelp." : link.title
        content.userInfo = [WatchOpenRequest.urlKey: url.absoluteString]
        content.interruptionLevel = .active
        try await center.add(UNNotificationRequest(identifier: "bighelp.watch.open", content: content, trigger: nil))
    }

    // MARK: Delivery

    private func push(_ push: WatchPush) {
        guard let session, session.activationState == .activated,
              let payload = try? WatchWire.encode(push, key: WatchWire.pushKey) else { return }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in session.transferUserInfo(payload) }
        } else {
            session.transferUserInfo(payload)
        }
    }

    private func remember(_ id: UUID, sessionID: String) {
        sentSessions[id] = sessionID
        sentOrder.append(id)
        while sentOrder.count > 64 { sentSessions.removeValue(forKey: sentOrder.removeFirst()) }
    }

    private func forget(_ id: UUID) {
        sentSessions.removeValue(forKey: id)
        sentOrder.removeAll { $0 == id }
    }

    /// Encodes a reply, dropping the oldest parts until it fits in one message.
    nonisolated static func payload(for reply: WatchReply) -> [String: Any] {
        var reply = reply
        for _ in 0..<6 {
            if let payload = try? WatchWire.encode(reply, key: WatchWire.replyKey) { return payload }
            reply = reply.trimmed()
        }
        return (try? WatchWire.encode(WatchReply.failed(WatchRelayError.tooBig.message), key: WatchWire.replyKey)) ?? [:]
    }

    /// Stable per host, and says nothing about it.
    nonisolated static func hostKey(for hostID: UUID?) -> String {
        guard let hostID else { return "" }
        return SHA256.hash(data: Data(hostID.uuidString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Sendable wrapper for WatchConnectivity's reply block.
private struct WatchReplyHandler: @unchecked Sendable {
    let call: ([String: Any]) -> Void
}

extension WatchRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: (any Error)?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = WatchReplyHandler(call: replyHandler)
        // Decode here: WatchConnectivity calls in on its own queue.
        guard let request = try? WatchWire.decode(WatchRequest.self, key: WatchWire.requestKey, from: message) else {
            reply.call(WatchRelay.payload(for: .failed(WatchRelayError.update.message)))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return reply.call([:]) }
            let answer = await BighelpShortcutService.holdingHostConnection(named: "bighelp Watch") {
                await self.handle(request)
            }
            reply.call(WatchRelay.payload(for: answer))
        }
    }
}

extension WatchReply {
    /// Half as much, for a reply too big for one message.
    func trimmed() -> WatchReply {
        switch self {
        case .home(var home):
            home.chats = Array(home.chats.prefix(max(home.chats.count / 2, 1)))
            home.needs = Array(home.needs.prefix(max(home.needs.count / 2, 1)))
            return .home(home)
        case .chat(let chat):
            return .chat(WatchChat(sessionID: chat.sessionID, title: chat.title, agentName: chat.agentName,
                                   messages: Array(chat.messages.suffix(max(chat.messages.count / 2, 1))),
                                   isWorking: chat.isWorking, activity: chat.activity))
        case .board(let items):
            return .board(Array(items.prefix(max(items.count / 2, 1))))
        default:
            return self
        }
    }
}

enum WatchRelayError: Error, Equatable {
    case noHost, unreachable, chatGone, agentGone, needGone, notSent, notConfirmed, empty
    case boardUnavailable, cantOpen, notificationsOff, tooBig, update

    var message: String {
        switch self {
        case .noHost: "Set up bighelp on your iPhone first."
        case .unreachable: "Your computer isn't answering. Check that it's on and online."
        case .chatGone: "That chat isn't on your computer anymore."
        case .agentGone: "That agent isn't available anymore."
        case .needGone: "This was already answered or expired."
        case .notSent: "Your message didn't go through. Try again."
        case .notConfirmed: "Your answer wasn't confirmed. Check bighelp on your iPhone."
        case .empty: "Say or type something first."
        case .boardUnavailable: "Update the bighelp plugin on your computer to see this."
        case .cantOpen: "bighelp can't open that on your iPhone."
        case .notificationsOff: "Open bighelp on your iPhone. Turn on its notifications to open things from your Watch."
        case .tooBig: "That's too much to show on your Watch. Open it on your iPhone."
        case .update: "Update bighelp on your iPhone and Watch."
        }
    }
}

/// "Open on iPhone" notifications carry one of bighelp's own links.
enum WatchOpenRequest {
    static let urlKey = "bighelp_watch_open_url"

    /// The link in a tapped notification, if it's one of ours.
    static func url(in userInfo: [AnyHashable: Any]) -> URL? {
        (userInfo[urlKey] as? String).flatMap(WatchRelayProjection.openableURL)
    }
}
#endif
