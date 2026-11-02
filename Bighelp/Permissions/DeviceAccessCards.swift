import Foundation
import Observation

/// How the person answered a Device access card, and what the agent's call hears.
enum DeviceAccessAnswer: Equatable, Sendable {
    case turnedOn, notNow, denied, timedOut, cancelled

    /// The refusal the agent reads; nil when the call goes on.
    var refusalCode: String? {
        switch self {
        case .turnedOn: nil
        case .notNow: "permission_declined"
        case .denied: "permission_denied"
        case .timedOut: "permission_timeout"
        case .cancelled: "request_cancelled"
        }
    }
}

/// The Device access cards of the chats on screen, drawn inline in each chat like the connector cards.
/// When an agent calls a tool whose switch is off, its call waits here for the person: "Turn on" flips
/// the same switch Settings › Device access has (and iOS asks), then the call goes on; "Not now", an iOS
/// no or no answer before the call's time runs out refuses it. A refused tool isn't asked for again in
/// that chat, and an answered card leaves the chat.
@MainActor
@Observable
final class DeviceAccessCardStore {
    /// The store the chats draw and the phone's channel asks through.
    static let shared = DeviceAccessCardStore()

    struct Card: Identifiable, Equatable, Sendable {
        /// The call's request ID.
        let id: String
        let conversationID: String
        let capability: DeviceToolCapability
        /// For a shortcut the agent wants to run: its name, filled in on the card.
        let shortcutName: String?
        /// When the card gives up, a little before the call's own time runs out.
        let deadline: Date
    }

    enum Step: Equatable, Sendable {
        /// Turn on and Not now.
        case asking
        /// Apple Health's one-time note about where the data goes, before iOS asks.
        case healthSharing
        /// Waiting for iOS.
        case turningOn
    }

    private struct Key: Hashable {
        let conversationID: String
        let capability: DeviceToolCapability
    }

    private(set) var cards: [Card] = []
    private(set) var steps: [String: Step] = [:]
    /// Why the last Turn on didn't start, for the card to say.
    private(set) var message: String?

    /// The phone's switches, set when the app is put together.
    @ObservationIgnored var permissions: DeviceToolPermissions?
    /// The shortcut names a Shortcuts card adds to.
    @ObservationIgnored var shortcuts: () -> ShortcutNameStore = { ShortcutNameStore.current }
    @ObservationIgnored private var waiting: [String: CheckedContinuation<DeviceAccessAnswer, Never>] = [:]
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    /// Each chat's refused tools and how; bounded, oldest first.
    @ObservationIgnored private var refused: [Key: DeviceAccessAnswer] = [:]
    @ObservationIgnored private var refusedOrder: [Key] = []
    private static let maximumRefusals = 256

    init(permissions: DeviceToolPermissions? = nil) {
        self.permissions = permissions
    }

    /// One chat's waiting cards, oldest first.
    func cards(in conversationID: String) -> [Card] {
        cards.filter { $0.conversationID == conversationID }
    }

    func step(_ card: Card) -> Step { steps[card.id] ?? .asking }

    /// Shows a card in the chat and waits for the person. Returns at once when the switch is already on,
    /// or when this tool was already refused in this chat.
    func ask(_ capability: DeviceToolCapability, requestID: String, conversationID: String,
             shortcutName: String? = nil, until deadline: Date) async -> DeviceAccessAnswer {
        let key = Key(conversationID: conversationID, capability: capability)
        if let earlier = refused[key] { return earlier }
        guard let permissions else { return .cancelled }
        guard capability.sharesPersonalData, capability.isOfferedOnThisPlatform else { return .denied }
        if permissions.isEnabled(capability) { return .turnedOn }
        guard waiting[requestID] == nil, !Task.isCancelled, deadline > Date() else { return .cancelled }
        cards.append(Card(id: requestID, conversationID: conversationID, capability: capability,
                          shortcutName: shortcutName.flatMap { $0.isEmpty ? nil : $0 }, deadline: deadline))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting[requestID] = continuation
                timers[requestID] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                    guard !Task.isCancelled else { return }
                    self?.finish(requestID, .timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(requestID, .cancelled) }
        }
    }

    func notNow(_ card: Card) {
        finish(card.id, .notNow)
    }

    /// Turns on the tool's switch, the way Settings › Device access does, and lets the call go on.
    /// Apple Health first shows its sharing note, once. A Shortcuts card also adds the named shortcut.
    func turnOn(_ card: Card, shortcutName: String? = nil) async {
        guard let permissions, waiting[card.id] != nil, step(card) != .turningOn else { return }
        message = nil
        if card.capability == .health, !permissions.healthSharingAgreed {
            steps[card.id] = .healthSharing
            return
        }
        guard permissions.requestInFlight == nil else {
            message = String(localized: "Finish the other question first, then try again.")
            return
        }
        if card.capability == .shortcuts,
           let name = shortcutName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            switch shortcuts().add(name) {
            case .added, .duplicate: break
            case .full: message = String(localized: "You have 50 shortcuts. Remove one in Device access first."); return
            default: message = String(localized: "Type the shortcut's name the way it shows in Shortcuts."); return
            }
        }
        steps[card.id] = .turningOn
        // The card's channel already offers this tool, and the call that asked waits on it.
        await permissions.setEnabled(true, for: card.capability, reopensChannel: false)
        steps[card.id] = nil
        finish(card.id, permissions.isEnabled(card.capability) ? .turnedOn : .denied)
    }

    /// Apple Health's note: the person agreed, so iOS asks next.
    func agreeToHealthSharing(_ card: Card) async {
        guard waiting[card.id] != nil else { return }
        permissions?.agreeToHealthSharing()
        steps[card.id] = nil
        await turnOn(card)
    }

    private func finish(_ id: String, _ answer: DeviceAccessAnswer) {
        timers.removeValue(forKey: id)?.cancel()
        steps[id] = nil
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        if let card = cards.first(where: { $0.id == id }) {
            cards.removeAll { $0.id == id }
            // Other calls waiting for the same tool hear the same: everywhere once it's on, in this
            // chat when it's refused there. A cancelled call answers only for itself.
            var siblings: [Card] = []
            if answer == .turnedOn {
                siblings = cards.filter { $0.capability == card.capability }
            } else if [.notNow, .denied, .timedOut].contains(answer) {
                remember(Key(conversationID: card.conversationID, capability: card.capability), answer)
                siblings = cards.filter { $0.capability == card.capability && $0.conversationID == card.conversationID }
            }
            for sibling in siblings { finish(sibling.id, answer) }
        }
        if cards.isEmpty { message = nil }
        continuation.resume(returning: answer)
    }

    private func remember(_ key: Key, _ answer: DeviceAccessAnswer) {
        if refused.updateValue(answer, forKey: key) == nil { refusedOrder.append(key) }
        while refusedOrder.count > Self.maximumRefusals {
            refused.removeValue(forKey: refusedOrder.removeFirst())
        }
    }
}

/// Sends a call for a tool that's off through its chat's card before the real handler runs it.
@MainActor
enum DeviceAccessAsk {
    /// The card ends this long before the call's own time, so the host still takes the refusal.
    static let margin = 5

    static func asking(
        _ handle: @escaping NativeDeviceToolSession.Handler,
        cards: DeviceAccessCardStore,
        permissions: DeviceToolPermissions,
        conversationID: String,
        clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }
    ) -> NativeDeviceToolSession.Handler {
        { request, scope, isCurrent in
            guard let capability = DeviceToolCatalog.capability(for: request.operation),
                  capability.sharesPersonalData, !permissions.isEnabled(capability) else {
                return await handle(request, scope, isCurrent)
            }
            let answer = await cards.ask(
                capability, requestID: request.requestId, conversationID: conversationID,
                shortcutName: request.operation == "shortcuts.run" ? request.arguments["name"]?.string : nil,
                until: Date(timeIntervalSince1970: TimeInterval(request.expiresAt - margin)))
            guard let code = answer.refusalCode else { return await handle(request, scope, isCurrent) }
            return DeviceToolResult(request: request, status: "failed", code: code, sentAt: clock())
        }
    }

    /// The tools a chat's channel offers to ask for: off, shared with the host, and something this
    /// device has. Tools iOS can't give at all here are left out.
    static func askable(_ permissions: DeviceToolPermissions) -> Set<DeviceToolCapability> {
        Set(DeviceToolCapability.allCases.filter {
            $0.sharesPersonalData && $0.isOfferedOnThisPlatform && !permissions.isEnabled($0)
                && permissions.status(for: $0) != .unavailable
        })
    }
}
