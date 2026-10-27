import Foundation
import Observation

/// Bots mode: a bot's chat can take a few seconds to open when the computer has to find or
/// resume its Bot Chat and read its history first. After a short grace, so a quick open never
/// flashes it, the opening loader covers the wait until the chat can show its messages, or fails
/// with its own error. Cancel goes back to where the tap came from.
@MainActor @Observable
final class SimpleBotsChatOpening {
    struct Opening: Equatable, Identifiable {
        let id: UUID
        /// The bot whose chat opens; nil for a group chat.
        let agentID: String?
        var name: String?
        /// The chat that opened under the loader, once one has.
        var conversationID: String?
        /// The screens under the tap, for Cancel.
        let originPath: [AppRoute]
    }

    enum Readiness: Equatable {
        case waiting
        /// The chat is on screen and has its messages (or has none to wait for).
        case ready
        /// Nothing opens: an error shows instead.
        case failed
    }

    static let defaultGrace: Duration = .milliseconds(250)

    private(set) var current: Opening?
    private(set) var isShowing = false
    /// Set while Multi-gateway's loader hands over to this one, so the home never shows between them.
    @ObservationIgnored var showsNextAtOnce = false
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private let grace: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(grace: Duration = SimpleBotsChatOpening.defaultGrace,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.grace = grace
        self.sleep = sleep
    }

    /// A tap that opens a bot's chat. A second call for the same bot before its chat opens (the Bot Chat
    /// lookup falling back to the latest chat, say) keeps the one under way.
    @discardableResult
    func begin(agentID: String?, name: String?, originPath: [AppRoute], hasCachedContent: Bool = false) -> UUID {
        guard !hasCachedContent else {
            end()
            return UUID()
        }
        let atOnce = showsNextAtOnce
        if var opening = current, opening.conversationID == nil, opening.agentID == agentID {
            if let name { opening.name = name }
            current = opening
            if atOnce { show(opening.id) }
            return opening.id
        }
        end()
        let opening = Opening(id: UUID(), agentID: agentID, name: name, originPath: originPath)
        current = opening
        if atOnce {
            isShowing = true
        } else {
            let id = opening.id, grace = grace, sleep = sleep
            graceTask = Task { @MainActor [weak self] in
                do { try await sleep(grace) } catch { return }
                self?.show(id)
            }
        }
        return opening.id
    }

    /// The chat is on screen under the loader; it stays up until `update(_:)` says the chat is ready.
    func attach(_ id: UUID, conversationID: String) {
        guard current?.id == id else { return }
        current?.conversationID = conversationID
    }

    /// The grace is over and the chat isn't ready: show the loader.
    func show(_ id: UUID) {
        guard current?.id == id else { return }
        graceTask = nil
        isShowing = true
    }

    func update(_ readiness: Readiness) {
        guard current != nil, readiness != .waiting else { return }
        end()
    }

    /// The open finished without a chat on screen (nothing could be presented).
    func endIfNothingOpened(_ id: UUID) {
        guard let current, current.id == id, current.conversationID == nil else { return }
        end()
    }

    /// Cancel: what was opening, so the caller can stop it and go back.
    @discardableResult
    func cancel() -> Opening? {
        let opening = current
        end()
        return opening
    }

    func end() {
        graceTask?.cancel()
        graceTask = nil
        current = nil
        isShowing = false
    }
}

#if DEBUG
extension SimpleBotsChatOpening {
    /// "-test-simple-bots-open-delay-ms 2500": the demo's Bot Chat lookup takes as long as a slow
    /// computer's, so tests and screenshots see the opening loader.
    static func demoLookupDelay(arguments: [String] = ProcessInfo.processInfo.arguments) async throws {
        guard let index = arguments.firstIndex(of: "-test-simple-bots-open-delay-ms"),
              arguments.indices.contains(index + 1), let milliseconds = Int(arguments[index + 1]),
              (1...30_000).contains(milliseconds) else { return }
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}
#endif
