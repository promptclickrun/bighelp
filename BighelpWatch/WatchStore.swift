import AVFoundation
import Foundation
import Observation

/// Everything the Watch shows, fetched from bighelp on the iPhone.
@MainActor
@Observable
final class WatchStore {
    private(set) var home: WatchHome?
    private(set) var isLoadingHome = false
    private(set) var homeProblem: String?
    private(set) var chats: [String: WatchChat] = [:]
    private(set) var chatProblems: [String: String] = [:]
    private(set) var boards: [WatchBoardKind: [WatchBoardItem]] = [:]
    private(set) var boardProblems: [WatchBoardKind: String] = [:]
    /// Messages sent from the Watch that the chat doesn't show yet.
    private(set) var pending: [String: [WatchMessage]] = [:]
    /// Chats waiting on a reply to something sent from the Watch.
    private(set) var awaitingReply: [String: Awaited] = [:]

    struct Awaited: Equatable {
        let text: String
        let since: Date
    }
    /// The agent the Watch talks to; the iPhone's home agent unless changed here.
    var chosenAgentID: String? {
        didSet { UserDefaults.standard.set(chosenAgentID, forKey: Keys.agent) }
    }
    /// Read replies aloud. On by default: the Watch is for talking.
    var readsRepliesAloud: Bool {
        didSet { UserDefaults.standard.set(readsRepliesAloud, forKey: Keys.readAloud) }
    }
    /// The chat on screen, so only its reply is read aloud.
    var visibleChatID: String?

    private let phone: any WatchPhoneTalking
    private let speech = AVSpeechSynthesizer()
    private var boardAgentID: String?

    private enum Keys {
        static let agent = "bighelp.watch.agent"
        static let readAloud = "bighelp.watch.read-aloud"
    }

    init(phone: any WatchPhoneTalking) {
        self.phone = phone
        chosenAgentID = UserDefaults.standard.string(forKey: Keys.agent)
        readsRepliesAloud = UserDefaults.standard.object(forKey: Keys.readAloud) as? Bool ?? true
        phone.onPush = { [weak self] push in
            guard let self else { return }
            switch push {
            case .replyReady(let id): Task { await self.loadChat(id) }
            }
        }
    }

    // MARK: Home

    var agent: WatchAgent? {
        guard let home else { return nil }
        let id = chosenAgentID ?? home.homeAgentID
        return home.agents.first { $0.id == id } ?? home.agents.first { $0.id == home.homeAgentID } ?? home.agents.first
    }

    func refreshHome() async {
        guard !isLoadingHome else { return }
        isLoadingHome = true
        defer { isLoadingHome = false }
        switch await phone.ask(.home) {
        case .home(let fresh):
            if let home, home.hostKey != fresh.hostKey {
                // Another computer: nothing from the old one stays.
                chats = [:]; pending = [:]; awaitingReply = [:]; boards = [:]; chosenAgentID = nil
            }
            home = fresh
            homeProblem = switch fresh.status {
            case .ready: nil
            case .noHost: "Set up Bighelp on your iPhone first."
            case .unreachable: "Your computer isn't answering. Check that it's on and online."
            }
        case .failed(let message):
            homeProblem = message
        default:
            homeProblem = "Update Bighelp on your iPhone and Watch."
        }
    }

    // MARK: Chats

    func loadChat(_ id: String) async {
        switch await phone.ask(.chat(sessionID: id)) {
        case .chat(let chat):
            accept(chat)
            chatProblems[id] = nil
        case .failed(let message):
            chatProblems[id] = message
        default:
            break
        }
    }

    /// The chat as the Watch shows it: the host's messages plus what's still on its way.
    func messages(in id: String) -> [WatchMessage] {
        (chats[id]?.messages ?? []) + (pending[id] ?? [])
    }

    func isWorking(_ id: String) -> Bool {
        chats[id]?.isWorking == true || awaitingReply[id] != nil
    }

    /// Sends to a chat, or starts one with the chosen agent. Returns the chat.
    @discardableResult
    func send(_ text: String, to sessionID: String?) async -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        stopSpeaking()
        let outgoing = WatchOutgoing(id: UUID(), sessionID: sessionID, agentID: sessionID == nil ? agent?.id : nil, text: text)
        let local = WatchMessage(id: "watch-\(outgoing.id.uuidString)", isYou: true, text: text, at: .now)
        let key = sessionID ?? "new"
        pending[key, default: []].append(local)
        defer { if sessionID == nil { pending["new"] = nil } }
        switch await phone.ask(.send(outgoing)) {
        case .sent(let id):
            if sessionID == nil { pending[id, default: []].append(local) }
            awaitingReply[id] = Awaited(text: text, since: .now)
            chatProblems[id] = nil
            Task { await loadChat(id) }
            return id
        case .failed(let message):
            pending[key]?.removeAll { $0.id == local.id }
            chatProblems[key] = message
            return nil
        default:
            pending[key]?.removeAll { $0.id == local.id }
            chatProblems[key] = "Your message didn't go through. Try again."
            return nil
        }
    }

    func problem(in id: String) -> String? { chatProblems[id] }

    private func accept(_ chat: WatchChat) {
        let id = chat.sessionID
        chats[id] = chat
        // Once the host has the message, the Watch's copy goes.
        let arrived = Set(chat.messages.filter(\.isYou).map(\.text))
        pending[id]?.removeAll { arrived.contains($0.text) }
        guard let awaited = awaitingReply[id] else { return }
        // Answered once the agent has spoken after the Watch's message and stopped working.
        let asked = chat.messages.lastIndex { $0.isYou && $0.text == awaited.text }
        let answer = asked.flatMap { index in chat.messages[(index + 1)...].last { !$0.isYou } }
        if let answer, !chat.isWorking {
            awaitingReply[id] = nil
            if readsRepliesAloud, visibleChatID == id { speak(answer.text) }
        } else if Date.now.timeIntervalSince(awaited.since) > 600 {
            awaitingReply[id] = nil
        }
    }

    // MARK: Needs

    /// Nil when it went through; otherwise what to tell the person.
    func decide(_ need: WatchNeed, _ decision: WatchDecision) async -> String? {
        await resolve(need, .decide(needID: need.id, decision: decision))
    }

    func answer(_ need: WatchNeed, _ text: String) async -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Say or type something first." }
        return await resolve(need, .answer(needID: need.id, text: text))
    }

    private func resolve(_ need: WatchNeed, _ request: WatchRequest) async -> String? {
        switch await phone.ask(request) {
        case .done:
            home?.needs.removeAll { $0.id == need.id }
            return nil
        case .failed(let message):
            return message
        default:
            return "That didn't go through. Try again on your iPhone."
        }
    }

    // MARK: Feed, Ideas and Goals

    func loadBoard(_ kind: WatchBoardKind) async {
        guard let agent else { return }
        if boardAgentID != agent.id { boards = [:]; boardProblems = [:]; boardAgentID = agent.id }
        switch await phone.ask(.board(agentID: agent.id, kind: kind)) {
        case .board(let items):
            boards[kind] = items
            boardProblems[kind] = nil
        case .failed(let message):
            boardProblems[kind] = message
        default:
            boardProblems[kind] = "Update Bighelp on your iPhone and Watch."
        }
    }

    // MARK: iPhone

    /// Nil when the iPhone has it; otherwise what to tell the person.
    func openOnPhone(_ link: WatchPhoneLink) async -> String? {
        switch await phone.ask(.open(link)) {
        case .done: nil
        case .failed(let message): message
        default: "Bighelp can't open that on your iPhone."
        }
    }

    // MARK: Speech

    func speak(_ text: String) {
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        speech.speak(utterance)
    }

    func stopSpeaking() {
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
    }
}
