import Foundation

/// What New chat's Send leaves for the shell on screen: the steps that need the shell's stores
/// (`NewChatSession.ask`, handed over by `NewChatToRow`).
enum NewChatRequest: Equatable, Sendable {
    /// The blank chat isn't the picked bot's yet: make it so. The box's text goes with it.
    case followPick
    /// Make the group chat and send it the box's text.
    case startGroup
}

/// New chat's Send, outside any view. The message box keeps `ChatNewChatSlot.sendOverride` for as
/// long as the chat is open, so it must hold no view: this holds the To row's session, the chat and
/// the computer's coding store, and closures over stores only. It decides (`NewChatSend.step`),
/// does what those can do by themselves (a coding session, a note under the To row), and asks the
/// shell for the rest. The box keeps its text until whoever takes the message has it.
@MainActor
struct NewChatSendRelay {
    let session: NewChatSession
    /// New chat's blank chat, whose message box this Send belongs to.
    let model: ChatModel
    /// The computer in use's coding store, where it has one.
    let store: CodeHomeStore?
    /// The computer in use while every computer's bots can be picked; a bot that names another
    /// computer isn't this chat's.
    let hostInUse: @MainActor () -> UUID?
    /// A coding session started: its project's page on Work.
    let showProject: @MainActor (_ projectID: String) -> Void

    /// True when the message went elsewhere or can't go yet; false sends it in this chat, as any
    /// chat does. `holdsReferences`: the box's own answer, which the chat's copy can trail by a key.
    func send(holdsReferences: Bool) -> Bool {
        let kind = NewChatSend.decide(session, stagedJobs: store?.projectStaged.count ?? 0)
        let isPickedBotsChat = session.recipients.first.map { bot in
            (bot.hostID == nil || bot.hostID == hostInUse()) && model.memberIDs == [bot.profileID]
        } ?? false
        switch NewChatSend.step(kind, isPickedBotsChat: isPickedBotsChat,
                                holdsAttachments: holdsReferences || model.holdsAttachmentsOrReferences,
                                isStartingGroup: session.isStartingGroup) {
        case .sendHere:
            session.show(nil)
            return false
        case .followPick:
            session.ask(.followPick)
        case .startGroup:
            session.ask(.startGroup)
        case .startCoding:
            guard let store, let project = session.project, store.send(model.draft) else {
                session.show(.codingUnavailable)
                return true
            }
            finishCoding(project)
        case .startStaged:
            guard let store, let project = session.project, store.sendAll(including: model.draft) != nil else {
                session.show(.codingUnavailable)
                return true
            }
            finishCoding(project)
        case .refuse(.nobody):
            session.askWho()
        case .refuse(let note):
            session.show(note)
        }
        return true
    }

    /// The store has the message: only now does the box let it go.
    private func finishCoding(_ project: CodeProject) {
        model.draft = ""
        session.show(nil)
        showProject(project.id)
    }
}

/// What a change of the To row asks of the blank chat under it. The To row and that chat must
/// agree: one picked bot means the chat is that bot's.
enum NewChatPick: Equatable, Sendable {
    /// Not exactly one bot, or the blank chat is that bot's already.
    case keep
    /// The bot is on the computer in use: its chat takes the blank chat's place.
    case start(profileID: String)
    /// The bot is on another computer, which becomes the one in use first.
    case switchComputer(UUID, profileID: String)

    /// `blankMembers`: who the blank chat is with now, nil when there is none. `hasFleet`: other
    /// computers can be switched to; without it every bot is on the computer in use.
    static func decide(recipients: [SimpleBotsBot], blankMembers: [String]?, hasFleet: Bool,
                       hostInUse: UUID?) -> NewChatPick {
        guard recipients.count == 1, let bot = recipients.first else { return .keep }
        if hasFleet, let hostID = bot.hostID, hostID != hostInUse {
            return .switchComputer(hostID, profileID: bot.profileID)
        }
        return blankMembers == [bot.profileID] ? .keep : .start(profileID: bot.profileID)
    }
}

/// One chat starts at a time (`RootShellView.runNewChatStart`). A pick made while one starts used to
/// be dropped, which left the To row on one bot and the chat under it another's. It waits here
/// instead: when the start ends the To row is read again, so the latest pick gets the chat.
struct NewChatPickGate: Equatable, Sendable {
    private(set) var isWaiting = false

    /// A pick came while a chat was starting.
    mutating func hold() {
        isWaiting = true
    }

    /// The start ended. True when a pick waited: read the To row again now.
    mutating func release() -> Bool {
        defer { isWaiting = false }
        return isWaiting
    }
}
