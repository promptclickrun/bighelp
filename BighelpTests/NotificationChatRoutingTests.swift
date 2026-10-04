import Foundation
import Testing
@testable import Bighelp

/// A tapped alert opens its chat from what's already on the phone: the alert names the chat by a
/// reference (a digest of agent and session), which matches a chat in the saved list without
/// asking the host first.
@MainActor
struct NotificationChatRoutingTests {
    private let grant = "11111111-1111-4111-8111-111111111111"

    private func payload(reference: String?) -> [AnyHashable: Any] {
        var loopdy: [String: Any] = ["version": 2, "eventId": grant + ":" + String(repeating: "a", count: 64),
                                     "eventType": "session.completed", "grantId": grant,
                                     "agent": ["id": "juniper"]]
        loopdy["sessionReference"] = reference
        return ["aps": ["alert": ["title": "Juniper", "body": "Done"]], "loopdy": loopdy]
    }

    @Test func anAlertCarriesItsChatReference() throws {
        let reference = ManagedNotificationValidation.sessionReference(profile: "juniper", session: "20261003_101500_ab12cd")
        let open = try #require(BighelpProactiveNotificationOpen(userInfo: payload(reference: reference)))
        #expect(open.sessionReference == reference)
        #expect(open.agentID == "juniper")
        #expect(BighelpProactiveNotificationOpen(userInfo: payload(reference: "not a reference"))?.sessionReference == nil)
        #expect(BighelpProactiveNotificationOpen(userInfo: payload(reference: nil))?.sessionReference == nil)
    }

    @Test func theReferenceFindsTheSavedChat() {
        let mine = SessionRecord(id: "native-session-v1:a", kind: .direct, agentIDs: ["juniper"], title: "Trip",
                                 remoteStoredID: "20261003_101500_ab12cd")
        let other = SessionRecord(id: "native-session-v1:b", kind: .direct, agentIDs: ["juniper"], title: "Other",
                                  remoteStoredID: "20261002_090000_ffffff")
        let otherAgent = SessionRecord(id: "native-session-v1:c", kind: .direct, agentIDs: ["atlas"], title: "Same id",
                                       remoteStoredID: "20261003_101500_ab12cd")
        let reference = ManagedNotificationValidation.sessionReference(profile: "juniper", session: "20261003_101500_ab12cd")
        #expect(SessionRecord.matching(reference: reference, profileID: "juniper", in: [other, otherAgent, mine])?.id
                == "native-session-v1:a")
        #expect(SessionRecord.matching(reference: reference, profileID: "atlas", in: [mine]) == nil)
    }
}
