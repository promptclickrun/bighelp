#if DEBUG
import Foundation

/// Deterministic records for exercising the real session surfaces without a host.
enum SessionOrganizationAcceptanceFixture {
    static var records: [SessionRecord] {
        [
            record("old-pin", title: "Pinned older", created: 10, pinned: true, active: true),
            record("new-pin", title: "Pinned newer", created: 20, pinned: true),
            record("old-active", title: "Active older", created: 30, active: true),
            record("new-active", title: "Active newer", created: 40, active: true),
            record("demo-finance", title: "Bighelp newer", created: 60, project: "demo-loopdy", name: "Bighelp"),
            record("loopdy-old", title: "Bighelp older", created: 50, project: "demo-loopdy", name: "Bighelp"),
            record("demo-travel", title: "Travel", created: 70, project: "demo-travel", name: "Travel Planning"),
        ]
    }

    private static func record(_ id: String, title: String, created: TimeInterval,
                               pinned: Bool = false, active: Bool = false,
                               project: String? = nil, name: String? = nil) -> SessionRecord {
        SessionRecord(id: id, kind: .direct, agentIDs: ["finance"], title: title,
                      workspaceID: project, workspaceName: name,
                      isActive: active, isPinned: pinned,
                      createdAt: Date(timeIntervalSince1970: 1_788_000_000 + created),
                      updatedAt: Date(timeIntervalSince1970: 1_788_001_000 - created),
                      hasAcceptedMessage: true)
    }
}
#endif
