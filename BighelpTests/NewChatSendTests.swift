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
}
