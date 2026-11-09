import Foundation
import SwiftUI

/// The sheet's whole state: pick an agent, pick a chat (or a new one), say a line, send.
@MainActor
final class ShareModel: ObservableObject {
    enum Step: Equatable {
        case agents
        case chats
        case compose
    }

    @Published private(set) var step: Step = .agents
    @Published private(set) var agents: [ShareAgent] = []
    @Published private(set) var chats: [ShareChat] = []
    @Published private(set) var agent: ShareAgent?
    @Published private(set) var chat: ShareChat?
    @Published var text = ""
    @Published private(set) var busy = false
    @Published private(set) var loading = true
    @Published private(set) var sentChatID: String?
    @Published private(set) var failure: String?

    let input: ShareInput
    private let credential: ShareCredential?
    private var rpc: ShareRPC?

    init(input: ShareInput) {
        self.input = input
        credential = ShareCredential.load()
        agents = ShareCache.agents()
        if let last = ShareCache.lastAgent, let known = agents.first(where: { $0.id == last }) {
            agent = known
        }
    }

    var canSend: Bool {
        !busy && sentChatID == nil && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !input.isEmpty)
    }

    var subtitle: String {
        let parts = [input.link == nil ? nil : "a link",
                     input.attachments.isEmpty ? nil : "\(input.attachments.count) attached",
                     input.text.isEmpty ? nil : "text"].compactMap { $0 }
        return parts.isEmpty ? "" : parts.joined(separator: " · ")
    }

    // MARK: - Loading

    func start() async {
        guard credential != nil else {
            loading = false
            failure = "Open bighelp once to sign in, then share this again."
            return
        }
        loading = agents.isEmpty
        await refreshAgents()
        loading = false
    }

    private func refreshAgents() async {
        guard let credential else { return }
        let rpc = ShareRPC(credential: credential)
        self.rpc = rpc
        do {
            let result = try await rpc.call("profiles.list", ["include_sessions": false])
            let rows = (result["profiles"] as? [[String: Any]]) ?? []
            let agents = rows.compactMap { row -> ShareAgent? in
                guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                let name = (row["name"] as? String) ?? (row["title"] as? String) ?? id
                return ShareAgent(id: id, name: name)
            }
            if !agents.isEmpty {
                self.agents = agents
                ShareCache.store(agents: agents)
                if agent == nil { agent = agents.first }
            }
            failure = nil
        } catch {
            // The cached list is still worth showing; only say something when there is
            // nothing to show at all.
            if agents.isEmpty { failure = message(error) }
        }
    }

    func open(_ chosen: ShareAgent) async {
        agent = chosen
        chat = nil
        ShareCache.lastAgent = chosen.id
        chats = ShareCache.chats(for: chosen.id)
        step = .chats
        guard let credential else { return }
        let rpc = self.rpc ?? ShareRPC(credential: credential)
        self.rpc = rpc
        do {
            let result = try await rpc.call("session.list", ["profile": chosen.id, "limit": 20])
            let rows = (result["sessions"] as? [[String: Any]]) ?? []
            let chats = rows.compactMap { row -> ShareChat? in
                guard let id = (row["resolved_id"] as? String) ?? (row["id"] as? String), !id.isEmpty else { return nil }
                // The same rule the app applies (`DirectHermesSessionSummary.supportsNativeResume`):
                // a chat owned by another Hermes surface cannot be resumed here, and offering it
                // in the sheet would only get refused after the person had typed a line.
                guard Self.isResumable(source: row["source"] as? String ?? "", id: id) else { return nil }
                let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled chat"
                return ShareChat(id: id, title: title)
            }
            if !chats.isEmpty {
                self.chats = Array(chats.prefix(ShareCache.maximumChats))
                ShareCache.store(chats: self.chats, for: chosen.id)
            }
        } catch {
            if chats.isEmpty { failure = message(error) }
        }
    }

    /// `nil` starts a new chat rather than continuing one.
    func compose(into chosen: ShareChat?) {
        chat = chosen
        step = .compose
        failure = nil
    }

    func back() {
        switch step {
        case .compose: step = .chats
        case .chats: step = .agents
        case .agents: break
        }
    }

    // MARK: - Sending

    func send() async {
        guard let credential, let agent, canSend else { return }
        busy = true
        failure = nil
        let rpc = self.rpc ?? ShareRPC(credential: credential)
        self.rpc = rpc
        let sender = ShareSender(rpc: rpc)
        do {
            let id = try await sender.send(text: prompt, attachments: input.attachments,
                                           agent: agent.id, chatID: chat?.id)
            sentChatID = id
            // Keep the chat list honest for the next share.
            if chat == nil, let agent = self.agent {
                var updated = ShareCache.chats(for: agent.id)
                updated.insert(ShareChat(id: id, title: text.isEmpty ? "Shared to " + agent.name : String(text.prefix(60))), at: 0)
                ShareCache.store(chats: Array(updated.prefix(ShareCache.maximumChats)), for: agent.id)
            }
            rpc.disconnect()
            self.rpc = nil
        } catch {
            failure = message(error)
        }
        busy = false
    }

    private static func isResumable(source: String, id: String) -> Bool {
        if [ShareSender.sessionSource, "desktop", "tui", "cli"].contains(source) { return true }
        // Hermes rewrites a Bot Chat's stored source to "local"; only its own rows are ours.
        return source == "local" && id.hasPrefix("local-")
    }

    /// A link travels as the prompt's own first line, which is what the app's composer
    /// does when someone pastes a URL.
    private var prompt: String {
        var lines: [String] = []
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = input.link {
            lines.append(link)
            if !typed.isEmpty { lines.append(typed) }
        } else if !typed.isEmpty {
            lines.append(typed)
        }
        return lines.joined(separator: "\n")
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Couldn't send this share."
    }
}
