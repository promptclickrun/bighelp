import Foundation
import Testing
@testable import Bighelp

/// A scheduled task's alert used to name the run's own session, which no chat list shows. Hosts
/// that know where the job was made (bighelp plugin `scheduled_links.py`) name that chat
/// (`scheduled.chat.<session>`) or the job itself (`scheduled.job.<job>`) instead; a tap opens it.
@MainActor
struct ScheduledAlertLinkTests {
    private func reference(_ profile: String, _ coordinate: String) -> String {
        ManagedNotificationValidation.sessionReference(profile: profile, session: coordinate)
    }

    private let chat = SessionRecord(id: "native-session-v1:trip", kind: .direct, agentIDs: ["juniper"], title: "Trip",
                                     remoteStoredID: "20261020_090000_ab12cd")
    private let other = SessionRecord(id: "native-session-v1:garden", kind: .direct, agentIDs: ["juniper"], title: "Garden",
                                      remoteStoredID: "20261019_080000_ffffff")
    private let otherAgent = SessionRecord(id: "native-session-v1:atlas", kind: .direct, agentIDs: ["atlas"], title: "Same id",
                                           remoteStoredID: "20261020_090000_ab12cd")
    private let run = SessionRecord(id: "native-session-v1:run", kind: .direct, agentIDs: ["juniper"], title: "Morning weather",
                                    remoteStoredID: "cron_a1b2c3d4e5f6_20261021_070000", remoteSource: "cron")
    private let tasks: [ScheduledTask] = [
        .fixture(id: "a1b2c3d4e5f6", agentID: "juniper", name: "Morning weather"),
        .fixture(id: "a1b2c3d4e5f6", agentID: "atlas", name: "Same id, another agent"),
        .fixture(id: "0f0f0f0f0f0f", agentID: "juniper", name: "Weekly review"),
    ]

    @Test func theAlertOpensTheChatTheJobWasMadeIn() {
        let records = [other, otherAgent, chat, run]
        let link = reference("juniper", "scheduled.chat.20261020_090000_ab12cd")
        #expect(BighelpScheduledAlertLinks.place(reference: link, profileID: "juniper", records: records,
                                                 tasks: tasks, isScheduledRun: true) == .chat(chat))
        // Another agent's chat with the same stored ID is never opened for it.
        #expect(BighelpScheduledAlertLinks.place(reference: link, profileID: "atlas", records: records,
                                                 tasks: tasks, isScheduledRun: true) == .tasks(agentID: "atlas"))
    }

    @Test func aScheduledLinkIsNeverTakenForAReplyInThatChat() {
        let link = reference("juniper", "scheduled.chat.20261020_090000_ab12cd")
        // The chat-on-screen check, the clearing on open and the newer-reply rule all read the plain reference.
        #expect(SessionRecord.matching(reference: link, profileID: "juniper", in: [chat]) == nil)
        #expect(link != reference("juniper", "20261020_090000_ab12cd"))
    }

    @Test func withoutTheChatTheAlertOpensTheJob() {
        let link = reference("juniper", "scheduled.job.a1b2c3d4e5f6")
        #expect(BighelpScheduledAlertLinks.place(reference: link, profileID: "juniper", records: [chat],
                                                 tasks: tasks, isScheduledRun: true) == .task(tasks[0]))
        #expect(BighelpScheduledAlertLinks.place(reference: link, profileID: "atlas", records: [],
                                                 tasks: tasks, isScheduledRun: true) == .tasks(agentID: "atlas"))
    }

    @Test func aJobThatIsGoneOpensTheAgentsScheduledTasks() {
        let link = reference("juniper", "scheduled.job.deadbeef0000")
        #expect(BighelpScheduledAlertLinks.place(reference: link, profileID: "juniper", records: [chat],
                                                 tasks: tasks, isScheduledRun: true) == .tasks(agentID: "juniper"))
        // Tasks that couldn't load yet: no answer, so the caller can load them and ask again.
        #expect(BighelpScheduledAlertLinks.place(reference: link, profileID: "juniper", records: [chat],
                                                 tasks: nil, isScheduledRun: true) == nil)
    }

    /// An older plugin names the run itself; the run's own session still opens as before.
    @Test func anOlderPluginsRunReferenceOpensTheRunAsBefore() {
        let link = reference("juniper", "cron_a1b2c3d4e5f6_20261021_070000")
        #expect(BighelpScheduledAlertLinks.place(reference: link, profileID: "juniper", records: [chat, run],
                                                 tasks: tasks, isScheduledRun: true) == .chat(run))
    }

    @Test func otherAlertsKeepTheirOwnRules() {
        let link = reference("juniper", "scheduled.job.a1b2c3d4e5f6")
        #expect(BighelpScheduledAlertLinks.place(reference: link, profileID: "juniper", records: [chat],
                                                 tasks: tasks, isScheduledRun: false) == nil)
        #expect(BighelpScheduledAlertLinks.place(reference: reference("juniper", "20261020_090000_ab12cd"),
                                                 profileID: "juniper", records: [chat], tasks: nil,
                                                 isScheduledRun: false) == .chat(chat))
        #expect(BighelpScheduledAlertLinks.isScheduledRun("scheduled.completed"))
        #expect(BighelpScheduledAlertLinks.isScheduledRun("scheduled.failed"))
        #expect(!BighelpScheduledAlertLinks.isScheduledRun("session.completed"))
        #expect(!BighelpScheduledAlertLinks.isScheduledRun(nil))
    }

    /// Two jobs made in one chat share its link, so one task's alert never removes another's.
    @Test func scheduledAlertsStayInNotificationCenter() {
        let link = reference("juniper", "scheduled.chat.20261020_090000_ab12cd")
        let delivered = [BighelpNotificationGrouping.Delivered(identifier: "earlier", chat: link, eventType: "scheduled.completed")]
        #expect(BighelpNotificationGrouping.superseded(by: "scheduled.completed", chat: link, among: delivered,
                                                       except: "newer").isEmpty)
        #expect(BighelpNotificationGrouping.superseded(by: "session.completed", chat: link, among: delivered,
                                                       except: "newer").isEmpty)
    }

    @Test func hostsSayWhetherTheyNameTheJobsChat() throws {
        func capabilities(_ preferences: String) throws -> BighelpManagedCapabilities {
            try JSONDecoder().decode(BighelpManagedCapabilities.self, from: Data("""
            {"version":1,"hostKeyId":"k","hostPublicKey":"p","managedEnrollmentSupported":true,
             "producerCapabilities":{"sessionCompletion":true,"sessionFailure":true,"richLiveActivity":true,
             "nativeApproval":true,"nativeClarification":true},\(preferences)}
            """.utf8))
        }
        #expect(try capabilities(#""preferences":{"peerChats":true,"workflows":true,"scheduledLinks":true}"#)
            .supportsScheduledAlertLinks)
        #expect(try !capabilities(#""preferences":{"peerChats":true,"workflows":true}"#).supportsScheduledAlertLinks)
        #expect(try !capabilities(#""preferences":null"#).supportsScheduledAlertLinks)
    }
}
