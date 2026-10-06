import Foundation

#if DEBUG
/// Demo hosts for the all-hosts view. "Home Hermes" is the demo's own agents
/// (live, like a selected host); "Studio Mac" has made-up agents to list but
/// not open (with `-test-fleet-loading` it's still being read, for
/// screenshots); "Office Linux" can't be reached.
@MainActor
final class FleetFixtureReader: FleetHostReading {
    static let homeID = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000001")!
    static let studioID = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000002")!
    static let officeID = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000003")!

    var hosts: [FleetHost] {
        [(Self.homeID, "Home Hermes"), (Self.studioID, "Studio Mac"), (Self.officeID, "Office Linux")].map {
            FleetHost(id: $0.0, name: $0.1, isSelected: $0.0 == Self.homeID)
        }
    }

    func select(_ hostID: UUID) {}
    func maintenance() -> (any FleetMaintenanceConnecting)? { FleetMaintenanceFixture.demo() }
    func canOpen(_ hostID: UUID) -> Bool { hostID == Self.homeID }
    /// Demo hosts keep pins on screen only.
    func setPinned(_ pinned: Bool, hostID: UUID, profileID: String) -> Bool { true }

    /// Sections and hidden agents saved on the demo host, like a real one's
    /// profiles. None until the person files or hides one.
    private var placements: [String: AgentListPlacement] = [:]

    func setPlacement(_ placement: AgentListPlacement, hostID: UUID, profileID: String) async throws {
        guard hostID == Self.studioID else { throw WorkspaceClientError.unavailable(.unsupportedHost) }
        placements[profileID] = placement
    }

    /// Studio Mac's agents worked a little; Office Linux can't be reached.
    func usage(_ hostID: UUID, name: String, days: Int, refresh: Bool) async -> HostUsage {
        guard hostID == Self.studioID else {
            return HostUsage(id: hostID.uuidString, name: name, failure: "Couldn't reach this computer.")
        }
        let limits = try? await DemoProviderUsageClient().usage(agentID: "default", refresh: refresh)
        return HostUsage(id: hostID.uuidString, name: name, agents: [
            AgentUsage(id: "research", name: "Rio Tanaka", report: UsageFixtures.report(seed: 5, days: days)),
            AgentUsage(id: "reviewer", name: "Sage Ortiz", report: UsageFixtures.report(seed: 7, days: days)),
        ], limits: limits.map { report in
            .loaded(ProviderUsageReport(agentID: report.agentID, fetchedAt: report.fetchedAt, cached: report.cached,
                                        providers: report.providers.filter { ["claude", "openrouter"].contains($0.id) }))
        })
    }

    func read(_ hostID: UUID, avatars: FleetAvatarFolder) async throws -> FleetSnapshot {
        guard hostID == Self.studioID else { throw FleetReadError(message: "Couldn't reach this host.") }
        if ProcessInfo.processInfo.arguments.contains("-test-fleet-loading") {
            try await Task.sleep(for: .seconds(3_600))
        }
        let id = Self.studioID
        let now = Date()
        return FleetSnapshot(
            agents: [
                FleetAgent(hostID: id, profileID: "research", name: "Rio Tanaka", role: "Research agent",
                           isPinned: true, isDefault: true, placement: placements["research"]),
                FleetAgent(hostID: id, profileID: "reviewer", name: "Sage Ortiz", role: "Code reviewer",
                           isPinned: false, isDefault: false, activity: .working, placement: placements["reviewer"]),
            ],
            chats: [
                FleetChat(hostID: id, profileID: "research", storedSessionID: "studio-1", title: "Market scan",
                          preview: "Found three competitors worth a closer look.",
                          updatedAt: now.addingTimeInterval(-25 * 60), isActive: false),
                FleetChat(hostID: id, profileID: "reviewer", storedSessionID: "studio-2", title: "Pull request review",
                          preview: "Two small fixes before this can merge.",
                          updatedAt: now.addingTimeInterval(-2 * 60 * 60), isActive: true),
                FleetChat(hostID: id, profileID: "reviewer", storedSessionID: "studio-3", title: "Release checklist",
                          preview: "Brought in from Codex.", updatedAt: now.addingTimeInterval(-3 * 60 * 60),
                          isActive: false, origin: "codex-cli"),
            ],
            tasks: [
                FleetTask(hostID: id, jobID: "digest", profileID: "research", name: "Morning research digest",
                          schedule: "Every day at 8:00 AM",
                          nextRun: Calendar.current.date(bySettingHour: 8, minute: 0, second: 0,
                                                         of: now.addingTimeInterval(24 * 60 * 60)),
                          status: .active),
                FleetTask(hostID: id, jobID: "health", profileID: "reviewer", name: "Weekly code health",
                          schedule: "Mondays at 9:00 AM", nextRun: nil, status: .paused),
            ],
            groups: [
                FleetGroup(hostID: id, roomID: "studio-launch", name: "Launch crew",
                           memberNames: ["Rio Tanaka", "Sage Ortiz"], updatedAt: now.addingTimeInterval(-50 * 60),
                           isWorking: false, canRename: false, canDelete: false),
            ],
            refreshedAt: now,
            otherAppChats: [
                FleetOtherAppChat(hostID: id, item: HermesForeignSessionItem(
                    id: String(repeating: "e", count: 64), source: "codex", sourceLabel: "Codex CLI",
                    title: "Speed up the test suite", cwd: "~/Projects/site", modifiedAt: now.addingTimeInterval(-40 * 60),
                    turnCount: 9, excerpt: "Run the slow tests in parallel")),
                FleetOtherAppChat(hostID: id, item: HermesForeignSessionItem(
                    id: String(repeating: "f", count: 64), source: "claude", sourceLabel: "Claude Code",
                    title: "Draft the launch post", cwd: "~/Projects/blog", modifiedAt: now.addingTimeInterval(-5 * 60 * 60),
                    turnCount: 5, excerpt: "Three short paragraphs")),
            ]
        )
    }
}
#endif
