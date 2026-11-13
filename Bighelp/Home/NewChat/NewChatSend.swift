import Foundation

/// What New chat's Send does, and the line beside it that says so. `NewChatSendRelay` runs it: a
/// chat is the blank chat's own send, a group is left for the shell (`createGroupChat(with:peers:)`),
/// a coding session goes through `CodeHomeStore.send`, and staged jobs through
/// `CodeHomeStore.sendAll(including:)`.
enum NewChatSend: Equatable, Sendable {
    case chat
    case group
    case coding
    /// Jobs are staged for the project: Send starts them all, with the box's text as the last one.
    case staged

    /// Nil while nobody is picked (Send says so and sends nothing) or past a group's size.
    static func decide(recipients: Int, hasProject: Bool, stagedJobs: Int) -> NewChatSend? {
        switch recipients {
        case 1 where hasProject: stagedJobs > 0 ? NewChatSend.staged : NewChatSend.coding
        case 1: .chat
        case 2...BotModeRoom.maximumMembers: .group
        default: nil
        }
    }

    /// `stagedJobs` is the project's in `CodeHomeStore.projectStaged`, read there, never copied.
    @MainActor
    static func decide(_ session: NewChatSession, stagedJobs: Int) -> NewChatSend? {
        decide(recipients: session.recipients.count, hasProject: session.project != nil, stagedJobs: stagedJobs)
    }

    /// The line by Send: "New chat with Mina", "Group chat · 3 bots", "Coding session in bighelp".
    /// `jobs` counts what Send all starts: the staged jobs and the box's text, if any.
    static func contextLine(_ send: NewChatSend, names: [String], projectName: String?, jobs: Int = 1) -> String {
        switch send {
        case .chat:
            return String(localized: "New chat with \(names.first ?? "")")
        case .group:
            return String(localized: "Group chat · \(names.count) bots")
        case .coding, .staged:
            let project = projectName ?? ""
            return send == .coding || jobs <= 1
                ? String(localized: "Coding session in \(project)")
                : String(localized: "\(jobs) coding sessions in \(project)")
        }
    }

    @MainActor
    static func contextLine(_ session: NewChatSession, stagedJobs: Int, hasText: Bool) -> String? {
        guard let send = decide(session, stagedJobs: stagedJobs) else { return nil }
        return contextLine(send, names: session.recipients.map(\.name), projectName: session.project?.name,
                           jobs: stagedJobs + (hasText ? 1 : 0))
    }

    // MARK: What Send does with the box as it stands

    /// Why Send sent nothing, or what it waits for: one short line under the To row
    /// (`NewChatSession.note`). The box stays as it was.
    enum Note: Equatable, Sendable {
        /// Nobody is in the To row.
        case nobody
        /// A group chat's first message goes as text, and the box holds attachments or references.
        case groupTextOnly
        /// The same for a coding session's first message.
        case codingTextOnly
        /// Another bot was picked while the box holds attachments or references. They belong to the
        /// chat they were added in, so the pick waits until they're out of the box.
        case pickKeepsAttachments
        /// The chat or the group chat for this pick is being made.
        case starting
        /// The computer in use can't start the coding session now: its project is gone or it isn't
        /// connected.
        case codingUnavailable

        var message: String {
            switch self {
            case .nobody: String(localized: "Pick who gets this")
            case .groupTextOnly: String(localized: "Group chats start with text only")
            case .codingTextOnly: String(localized: "Coding sessions start with text only")
            case .pickKeepsAttachments: String(localized: "Remove attachments to pick another bot")
            case .starting: String(localized: "Starting the chat…")
            case .codingUnavailable: String(localized: "Coding sessions can’t start right now")
            }
        }
    }

    /// One press of Send. It sends everything in the box, or nothing: a step that can't carry what
    /// the box holds is refused with a note, never run without it.
    enum Step: Equatable, Sendable {
        /// The chat's own send: the blank chat is the picked bot's.
        case sendHere
        /// The blank chat isn't the picked bot's yet: it becomes so, and the text goes with it.
        case followPick
        case startGroup
        case startCoding
        case startStaged
        case refuse(Note)
    }

    /// `isPickedBotsChat`: the blank chat under the To row is the one picked bot's, on the computer
    /// in use. `holdsAttachments`: the box holds attachments or references, which only that chat's
    /// own send can carry. `isStartingGroup`: an earlier Send's group chat is still being made.
    static func step(_ send: NewChatSend?, isPickedBotsChat: Bool, holdsAttachments: Bool,
                     isStartingGroup: Bool) -> Step {
        guard let send else { return .refuse(.nobody) }
        switch send {
        case .chat:
            if isPickedBotsChat { return .sendHere }
            return holdsAttachments ? .refuse(.pickKeepsAttachments) : .followPick
        case .group:
            if isStartingGroup { return .refuse(.starting) }
            return holdsAttachments ? .refuse(.groupTextOnly) : .startGroup
        case .coding:
            return holdsAttachments ? .refuse(.codingTextOnly) : .startCoding
        case .staged:
            return holdsAttachments ? .refuse(.codingTextOnly) : .startStaged
        }
    }
}
