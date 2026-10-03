import Foundation
import Testing
@testable import Bighelp

/// Reading one computer for the Usage page: stock Hermes routes for the
/// numbers, the plugin's activity only when it has it, and a missing part
/// hiding its row rather than the page.
@MainActor
struct HostUsageLoaderTests {
    private static let usage: [String: BighelpJSONValue] = [
        "daily": .array([.object([
            "day": .string("2026-10-03"), "input_tokens": .integer(100), "output_tokens": .integer(20),
            "estimated_cost": .number(0.5), "sessions": .integer(1),
        ])]),
        "by_model": .array([]), "totals": .object([:]), "period_days": .integer(30),
    ]

    @Test func stockRoutesSendOnlyWhatHermesTakes() throws {
        let route = try DirectHermesWorkspaceClient.route(
            .usageModels, payload: ["profile": .string("research"), "days": .integer(30)])
        guard case .http(let request) = route else {
            Issue.record("The models route is the dashboard's REST route")
            return
        }
        #expect(request.path == "/api/analytics/models" && request.method == .get)
        #expect(Set(request.query.map(\.name)) == ["profile", "days"])
        #expect(throws: WorkspaceClientError.self) {
            try DirectHermesWorkspaceClient.route(.usageModels, payload: ["profile": .string("x"), "sql": .string("1")])
        }
        #expect(DirectHermesNativePluginClient.supports(.usageActivity), "Hours come from the plugin's route")
        #expect(!DirectHermesNativePluginClient.supports(.usageModels))
    }

    @Test func anOlderPluginOrHermesHidesOnlyWhatItLacks() async throws {
        let performer = try UsageRoutes()
        performer.missing = [.usageActivity, .usageModels]
        let host = await HostUsageLoader.read(hostID: "home", hostName: "Home", agents: [("ada", "Ada")],
                                              workspace: performer, owner: performer.owner!, days: 30,
                                              limits: true, refresh: false)
        #expect(host.failure == nil)
        #expect(host.agents.first?.report.totals.estimatedCost == 0.5, "The days and totals still show")
        #expect(host.agents.first?.report.activity == nil, "No hours without the plugin")
        #expect(host.limits == .needsPluginUpdate)
        #expect(performer.calls.filter { $0 == .usageSummary } == [.usageSummary])
        #expect(performer.days == [30, 30, 30])
    }

    @Test func anAgentThatCantBeReadIsNamedAndTheRestStillShow() async throws {
        let performer = try UsageRoutes()
        performer.failingAgents = ["bo"]
        let host = await HostUsageLoader.read(hostID: "home", hostName: "Home", agents: [("ada", "Ada"), ("bo", "Bo")],
                                              workspace: performer, owner: performer.owner!, days: 7,
                                              limits: false, refresh: false)
        #expect(host.agents.map(\.name) == ["Ada"])
        #expect(host.unreadAgents == ["Bo"])
        #expect(host.limits == nil, "The computer in use reads its limits elsewhere")

        performer.failingAgents = ["ada", "bo"]
        let none = await HostUsageLoader.read(hostID: "home", hostName: "Home", agents: [("ada", "Ada"), ("bo", "Bo")],
                                              workspace: performer, owner: performer.owner!, days: 7,
                                              limits: false, refresh: false)
        #expect(none.agents.isEmpty)
        #expect(none.failure == "Couldn't reach this computer.")
    }
}

@MainActor
private final class UsageRoutes: WorkspaceOperationPerforming {
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [:]) }
    var missing: Set<WorkspaceOperation> = []
    var failingAgents: Set<String> = []
    private(set) var calls: [WorkspaceOperation] = []
    private(set) var days: [Int] = []

    init() throws {
        owner = WorkspaceOwner(authority: try .fixture(id: UUID().uuidString), authenticationGeneration: UUID(),
                               connectionGeneration: UUID())
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        calls.append(operation)
        if let days = payload["days"]?.integer { self.days.append(days) }
        if missing.contains(operation) || (operation == .usageList && missing.contains(.usageActivity)) {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        let agent = payload["profile"]?.string ?? payload["agentId"]?.string ?? ""
        if failingAgents.contains(agent) { throw DirectHermesError.disconnected(outcomeUnknown: false) }
        switch operation {
        case .usageSummary: return HostUsageLoaderTests.usageSample
        case .usageModels: return ["models": .array([])]
        case .usageActivity: return ["hours": .array(Array(repeating: .integer(0), count: 24))]
        case .usageList: return ["providers": .array([])]
        default: throw WorkspaceClientError.invalidRequest
        }
    }
}

extension HostUsageLoaderTests {
    static var usageSample: [String: BighelpJSONValue] { usage }
}
