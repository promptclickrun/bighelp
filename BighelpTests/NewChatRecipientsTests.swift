import Foundation
import Testing
@testable import Bighelp

@MainActor
struct NewChatRecipientsTests {
    private let here = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    private let there = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!

    private func bot(_ id: String, on host: UUID? = nil) -> SimpleBotsBot {
        SimpleBotsBot(id: host.map { FleetID.make($0, id) } ?? id, profileID: id, hostID: host,
                      name: id.capitalized, role: "")
    }

    private var groups: NewChatGroupRules { NewChatGroupRules(hostInUse: here, canMakeGroups: true) }

    @Test func oneBotIsAChatAndTwoToSixAGroup() {
        let session = NewChatSession()
        #expect(session.kind == .nobody)
        #expect(session.toggle(bot("avery"), rules: groups))
        #expect(session.kind == .chat)
        for id in ["mina", "jordan", "sam", "kai", "rio"] {
            #expect(session.toggle(bot(id), rules: groups))
            #expect(session.kind == .group)
        }
        #expect(session.recipients.map(\.profileID) == ["avery", "mina", "jordan", "sam", "kai", "rio"])
        #expect(session.refusal == nil)
    }

    @Test func aSeventhBotIsRefused() {
        let six = ["a", "b", "c", "d", "e", "f"].map { bot($0) }
        let change = NewChatRecipients.toggling(bot("g"), in: six, rules: groups)
        #expect(change.picked == six)
        #expect(change.refusal == .full)
        #expect(!NewChatRecipients.canJoin(bot("g"), picked: six, rules: groups))
        // A picked bot can still be taken out.
        #expect(NewChatRecipients.toggling(six[2], in: six, rules: groups).picked.count == 5)
    }

    @Test func aSecondPickIsRefusedWhereGroupChatsCantBeMade() {
        let rules = NewChatGroupRules(hostInUse: here, canMakeGroups: false)
        let session = NewChatSession()
        #expect(session.toggle(bot("avery"), rules: rules))
        #expect(!session.toggle(bot("mina"), rules: rules))
        #expect(session.recipients.map(\.profileID) == ["avery"])
        #expect(session.refusal == .noGroups)
        #expect(session.refusal?.message == "Group chats need a newer Hermes on this computer.")
        // The next change clears the line.
        session.remove(bot("avery"))
        #expect(session.refusal == nil)
    }

    @Test func onlyBotsHermesSeatsCanJoinAGroupOnItsComputer() {
        let rules = NewChatGroupRules(hostInUse: here, canMakeGroups: true, seatableProfiles: ["avery", "mina"])
        #expect(NewChatRecipients.refusal(adding: bot("mina"), to: [bot("avery")], rules: rules) == nil)
        #expect(NewChatRecipients.refusal(adding: bot("jordan"), to: [bot("avery")], rules: rules)
            == .cannotSeat(names: ["Jordan"]))
        // A chat with one bot never needs a seat.
        #expect(NewChatRecipients.refusal(adding: bot("jordan"), to: [], rules: rules) == nil)
        // A first pick Hermes can't seat holds back the group it would start.
        #expect(NewChatRecipients.refusal(adding: bot("avery"), to: [bot("jordan")], rules: rules)
            == .cannotSeat(names: ["Jordan"]))
    }

    @Test func botsOnAnotherComputerJoinAsPeers() {
        let rules = NewChatGroupRules(hostInUse: here, canMakeGroups: true, seatableProfiles: ["avery"])
        let avery = bot("avery", on: here)
        let juno = bot("juno", on: there)
        // Hermes on this computer seats only its own bots; Juno joins through its own computer.
        #expect(NewChatRecipients.refusal(adding: juno, to: [avery], rules: rules) == nil)
        let split = NewChatRecipients.split([avery, juno], rules: rules)
        #expect(split.home == [avery])
        #expect(split.peers == [juno])
        let peers = NewChatRecipients.peerCandidates([avery, juno], rules: rules) { _ in "Studio" }
        #expect(peers == [HermesBotModePeerCandidate(hostID: there.uuidString, hostName: "Studio",
                                                     profileID: "juno", name: "Juno")])
    }

    @Test func aGroupStartedOnAnotherComputerIsCheckedThere() {
        // This computer can't make groups, but the group lives on the first bot's computer.
        let rules = NewChatGroupRules(hostInUse: here, canMakeGroups: false, seatableProfiles: [])
        let juno = bot("juno", on: there)
        #expect(NewChatRecipients.refusal(adding: bot("kai", on: there), to: [juno], rules: rules) == nil)
        #expect(NewChatRecipients.refusal(adding: bot("avery", on: here), to: [juno], rules: rules) == nil)
        // Started here, it is refused.
        #expect(NewChatRecipients.refusal(adding: juno, to: [bot("avery", on: here)], rules: rules) == .noGroups)
    }

    @Test func anotherBotOrASecondOneDropsTheProject() {
        let session = NewChatSession()
        let project = CodeProject(id: "p", name: "Sample", folder: "/tmp/sample")
        session.toggle(bot("avery"), rules: groups)
        session.project = project
        session.toggle(bot("mina"), rules: groups)
        #expect(session.project == nil)
        session.remove(bot("mina"))
        #expect(session.recipients.map(\.profileID) == ["avery"])
        session.project = project
        // A refused pick changes nobody, so the project stays.
        session.toggle(bot("mina"), rules: NewChatGroupRules(hostInUse: here, canMakeGroups: false))
        #expect(session.project == project)
        session.remove(bot("avery"))
        session.toggle(bot("mina"), rules: groups)
        #expect(session.project == nil)
    }

    @Test func listGroupsBotsByComputerInOrder() {
        let hosts = [FleetHost(id: here, name: "Home", isSelected: true),
                     FleetHost(id: there, name: "Studio", isSelected: false)]
        let bots = [bot("juno", on: there), bot("avery", on: here), bot("mina")]
        let sections = NewChatRecipients.sections(bots, hosts: hosts, rules: groups)
        #expect(sections.map(\.host?.name) == ["Home", "Studio"])
        // A bot with no computer is on the one in use.
        #expect(sections[0].bots.map(\.profileID) == ["avery", "mina"])
        #expect(sections[1].bots.map(\.profileID) == ["juno"])
        // One computer: one section, no header.
        #expect(NewChatRecipients.sections([bot("avery"), bot("mina")], hosts: [], rules: groups).count == 1)
    }

    @Test func searchMatchesNamesAndRoles() {
        let travel = SimpleBotsBot(id: "mina", profileID: "mina", name: "Mina", role: "Travel")
        #expect(NewChatRecipients.matches(travel, query: "trav"))
        #expect(NewChatRecipients.matches(travel, query: " "))
        #expect(!NewChatRecipients.matches(travel, query: "money"))
    }
}
