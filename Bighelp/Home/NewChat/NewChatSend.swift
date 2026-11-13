import Foundation

/// What New chat's Send does, and the line beside it that says so. The shell runs it: a chat is the
/// blank chat's own send, a group goes through `createGroupChat(with:peers:)`, a coding session
/// through `CodeHomeStore.send`, and staged jobs through `CodeHomeStore.sendAll(including:)`.
enum NewChatSend: Equatable, Sendable {
    case chat
    case group
    case coding
    /// Jobs are staged for the project: Send starts them all, with the box's text as the last one.
    case staged

    /// Nil while nobody is picked (Send stays off) or past a group's size.
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
}
