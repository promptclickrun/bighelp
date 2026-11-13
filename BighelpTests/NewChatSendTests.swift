import Foundation
import Testing
@testable import Bighelp

@MainActor
struct NewChatSendTests {
    @Test func sendFollowsWhoAndWhere() {
        #expect(NewChatSend.decide(recipients: 0, hasProject: false, stagedJobs: 0) == nil)
        #expect(NewChatSend.decide(recipients: 1, hasProject: false, stagedJobs: 0) == .chat)
        // Staged jobs belong to a project: without one, Send is the chat's own.
        #expect(NewChatSend.decide(recipients: 1, hasProject: false, stagedJobs: 2) == .chat)
        #expect(NewChatSend.decide(recipients: 1, hasProject: true, stagedJobs: 0) == .coding)
        #expect(NewChatSend.decide(recipients: 1, hasProject: true, stagedJobs: 2) == .staged)
        #expect(NewChatSend.decide(recipients: 2, hasProject: false, stagedJobs: 0) == .group)
        #expect(NewChatSend.decide(recipients: 6, hasProject: true, stagedJobs: 1) == .group)
        #expect(NewChatSend.decide(recipients: 7, hasProject: false, stagedJobs: 0) == nil)
    }

    @Test func contextLineSaysWhatSendDoes() {
        #expect(NewChatSend.contextLine(.chat, names: ["Mina"], projectName: nil) == "New chat with Mina")
        #expect(NewChatSend.contextLine(.group, names: ["Avery", "Mina", "Jordan"], projectName: nil)
            == "Group chat · 3 bots")
        #expect(NewChatSend.contextLine(.coding, names: ["Mina"], projectName: "sample-app")
            == "Coding session in sample-app")
        #expect(NewChatSend.contextLine(.staged, names: ["Mina"], projectName: "sample-app", jobs: 3)
            == "3 coding sessions in sample-app")
        #expect(NewChatSend.contextLine(.staged, names: ["Mina"], projectName: "sample-app", jobs: 1)
            == "Coding session in sample-app")
    }

    @Test func sessionLineCountsTheBoxAsAJob() {
        let session = NewChatSession()
        #expect(NewChatSend.contextLine(session, stagedJobs: 0, hasText: true) == nil)
        session.start(with: [SimpleBotsBot(id: "mina", profileID: "mina", name: "Mina", role: "")])
        #expect(NewChatSend.contextLine(session, stagedJobs: 0, hasText: true) == "New chat with Mina")
        session.project = CodeProject(id: "p", name: "sample-app", folder: "/tmp/sample-app")
        #expect(NewChatSend.decide(session, stagedJobs: 0) == .coding)
        #expect(NewChatSend.contextLine(session, stagedJobs: 2, hasText: true) == "3 coding sessions in sample-app")
        #expect(NewChatSend.contextLine(session, stagedJobs: 2, hasText: false) == "2 coding sessions in sample-app")
    }

    // MARK: Send sends everything in the box, or nothing

    private func bot(_ id: String, on hostID: UUID? = nil) -> SimpleBotsBot {
        SimpleBotsBot(id: id, profileID: id, hostID: hostID, name: id.capitalized, role: "")
    }

    private func relay(_ session: NewChatSession, _ model: ChatModel, hostInUse: UUID? = nil,
                       shown: @escaping @MainActor (String) -> Void = { _ in }) -> NewChatSendRelay {
        NewChatSendRelay(session: session, model: model, store: nil, hostInUse: { hostInUse }, showProject: shown)
    }

    @Test func aStepThatCannotCarryTheBoxIsRefusedNeverRunWithoutIt() {
        func step(_ send: NewChatSend?, own: Bool = false, files: Bool = false, starting: Bool = false) -> NewChatSend.Step {
            NewChatSend.step(send, isPickedBotsChat: own, holdsAttachments: files, isStartingGroup: starting)
        }
        #expect(step(nil) == .refuse(.nobody))
        #expect(step(.chat, own: true, files: true) == .sendHere, "The chat's own send carries attachments")
        #expect(step(.chat) == .followPick)
        #expect(step(.chat, files: true) == .refuse(.pickKeepsAttachments))
        #expect(step(.group) == .startGroup)
        #expect(step(.group, files: true) == .refuse(.groupTextOnly))
        #expect(step(.group, starting: true) == .refuse(.starting), "A second Send would make a second group chat")
        #expect(step(.coding) == .startCoding)
        #expect(step(.coding, files: true) == .refuse(.codingTextOnly))
        #expect(step(.staged) == .startStaged)
        #expect(step(.staged, files: true) == .refuse(.codingTextOnly))
    }

    /// The group chat is made by the shell, after Send returns, and making it can fail. The box
    /// keeps the text until the group chat has it.
    @Test func aGroupSendKeepsTheTextUntilTheGroupChatHasIt() {
        let session = NewChatSession()
        session.start(with: [bot("mina"), bot("otto")], conversationID: "blank")
        let model = ChatModel(conversationID: "blank", client: ConversationFixtureClient(), agentID: "mina",
                              initialItems: [])
        model.draft = "Plan the trip together"
        let send = relay(session, model)

        #expect(send.send(holdsReferences: false), "The message isn't this chat's to send")
        #expect(session.takeRequest() == .startGroup)
        #expect(session.isStartingGroup)
        #expect(model.draft == "Plan the trip together")

        // A second press while it is being made asks for nothing more.
        #expect(send.send(holdsReferences: false))
        #expect(session.takeRequest() == nil)
        #expect(session.note == .starting)

        // It couldn't be made: Send is free again and the text is still there.
        session.groupEnded()
        #expect(!session.isStartingGroup)
        #expect(session.note == nil)
        #expect(model.draft == "Plan the trip together")
        #expect(send.send(holdsReferences: false))
        #expect(session.takeRequest() == .startGroup)
    }

    @Test func aGroupSendWithReferencesAsksForNothingAndSaysWhy() {
        let session = NewChatSession()
        session.start(with: [bot("mina"), bot("otto")], conversationID: "blank")
        let model = ChatModel(conversationID: "blank", client: ConversationFixtureClient(), agentID: "mina",
                              initialItems: [])
        model.draft = "Use the trip notes"

        #expect(relay(session, model).send(holdsReferences: true))
        #expect(session.takeRequest() == nil)
        #expect(!session.isStartingGroup)
        #expect(session.note == .groupTextOnly)
        #expect(model.draft == "Use the trip notes")
    }

    /// A picture pasted or dropped into the box before the second bot was picked stays there: the
    /// group chat would have started without it.
    @Test func aGroupSendWithAnAttachmentAsksForNothingAndKeepsIt() throws {
        let session = NewChatSession()
        session.start(with: [bot("mina"), bot("otto")], conversationID: "blank")
        let model = ChatModel(conversationID: "blank", client: ConversationFixtureClient(), agentID: "mina",
                              initialItems: [])
        model.draft = "Where is this?"
        try model.addDraftAttachment(ChatAttachment(id: "attachment_image_new_chat_0001", fileName: "map.png",
                                                    mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47])))

        #expect(relay(session, model).send(holdsReferences: false))
        #expect(session.takeRequest() == nil)
        #expect(session.note == .groupTextOnly)
        #expect(model.draft == "Where is this?")
        #expect(model.orderedDraftAttachments.count == 1)
    }

    @Test func sendWithNobodyPickedSaysSoAndPutsTheCursorInTheToField() {
        let session = NewChatSession()
        session.start(conversationID: "blank")
        let model = ChatModel(conversationID: "blank", client: ConversationFixtureClient(), agentID: "mina",
                              initialItems: [])
        model.draft = "Hello"

        #expect(relay(session, model).send(holdsReferences: false))
        #expect(session.note == .nobody)
        #expect(session.fieldFocusRequests == 1)
        #expect(session.noteCount == 1)
        #expect(model.draft == "Hello")
        // Each press says it again, for VoiceOver.
        #expect(relay(session, model).send(holdsReferences: false))
        #expect(session.noteCount == 2)

        // A pick takes the line away.
        session.toggle(bot("mina"), rules: NewChatGroupRules())
        #expect(session.note == nil)
    }

    @Test func oneBotsOwnChatSendsHereAndAnotherBotsChatFollowsThePickFirst() {
        let studio = UUID()
        let session = NewChatSession()
        session.start(with: [bot("mina")], conversationID: "blank")
        let minas = ChatModel(conversationID: "blank", client: ConversationFixtureClient(), agentID: "mina",
                              initialItems: [])
        minas.draft = "Hello"
        #expect(!relay(session, minas).send(holdsReferences: true), "Its own send carries references too")
        #expect(session.takeRequest() == nil)

        // The blank chat is still the primary bot's: nothing is sent to the wrong bot.
        let primarys = ChatModel(conversationID: "blank", client: ConversationFixtureClient(), agentID: "otto",
                                 initialItems: [])
        primarys.draft = "Hello"
        #expect(relay(session, primarys).send(holdsReferences: false))
        #expect(session.takeRequest() == .followPick)
        #expect(primarys.draft == "Hello")

        // The same profile name on another computer isn't this chat's bot.
        session.start(with: [bot("mina", on: studio)], conversationID: "blank")
        #expect(relay(session, minas, hostInUse: UUID()).send(holdsReferences: false))
        #expect(session.takeRequest() == .followPick)
    }

    /// No coding store on the computer in use: nothing starts, the text stays and a line says so.
    @Test func aCodingSendThatCannotStartKeepsTheText() {
        let session = NewChatSession()
        session.start(with: [bot("mina")], conversationID: "blank")
        session.project = CodeProject(id: "p", name: "sample-app", folder: "/tmp/sample-app")
        let model = ChatModel(conversationID: "blank", client: ConversationFixtureClient(), agentID: "mina",
                              initialItems: [])
        model.draft = "Fix the widget tap"
        var shown: [String] = []

        #expect(relay(session, model, shown: { shown.append($0) }).send(holdsReferences: false))
        #expect(session.note == .codingUnavailable)
        #expect(model.draft == "Fix the widget tap")
        #expect(shown.isEmpty)
    }
}
