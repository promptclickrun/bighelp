import Foundation
import Testing
@testable import Bighelp

/// What Hermes 0.21.5 actually sends for Settings › System and Fleet (made-up values). The
/// gateway's fields are null while it's stopped, and an update receipt's summary and commit IDs
/// can be empty; none of that may fail the page.
struct HostOperationsPayloadTests {
    private func json(_ text: String) throws -> BighelpJSONValue {
        try JSONDecoder().decode(BighelpJSONValue.self, from: Data(text.utf8))
    }

    @Test func overviewReadsAStoppedGateway() throws {
        let overview = try DirectHermesHostPayload.overview(try json("""
        {"version":"0.21.5","release_date":"2026.9.24","gateway_running":false,"gateway_state":null,
         "gateway_platforms":{},"gateway_shared_with":null,"active_agents":0,"gateway_busy":false,
         "gateway_drainable":false,"restart_drain_timeout":0.0,"active_sessions":0,
         "components":{"gateway":{"status":"degraded","state":"stopped"},"dashboard":{"status":"ok"},
                       "storage":{"status":"ok"},"platforms":{"status":"ok","configured":0}},
         "overall":"degraded","gateway_mode":"none","gateways":[]}
        """))
        #expect(overview.version == "0.21.5")
        #expect(overview.gatewayState == "stopped", "From the gateway component")
        #expect(overview.gatewaySharedWith.isEmpty)
        #expect(overview.components.map(\.id) == ["dashboard", "gateway", "platforms", "storage"])
    }

    @Test func overviewNeedsOnlyTheVersion() throws {
        let overview = try DirectHermesHostPayload.overview(try json(#"{"version":"0.21.2","gateway_running":true}"#))
        #expect(overview.gatewayState == "running")
        #expect(overview.gatewayMode == "none")
        #expect(overview.overall == "unknown")
        #expect(throws: (any Error).self) { try DirectHermesHostPayload.overview(try json(#"{"gateway_running":true}"#)) }
    }

    @Test func receiptWithoutSummaryOrCommitIDsStillReads() throws {
        let receipt = try DirectHermesHostPayload.updateReceipt(try json("""
        {"receipt":{"schema":1,"started_at":"2026-09-30T10:00:00+00:00","finished_at":"2026-09-30T10:04:00+00:00",
          "outcome":"partial","pre_update":{},"post_update":{},
          "steps":[{"name":"git pull","ok":true,"detail":"","at":"2026-09-30T10:01:00+00:00"},{"name":7}],
          "skips":[{"name":"web build","reason":"no node","at":"2026-09-30T10:02:00+00:00"}],
          "gateway_restart":{"incomplete":true,"phase_error":""},
          "fleet":[{"profile":"default","code_sha":"","code_version":"0.21.5","state":"current"},
                   {"profile":"work","code_sha":"abc1234","state":"stale"}]},
         "summary":null}
        """))
        #expect(receipt.summary.outcome == "partial", "Taken from the receipt")
        #expect(receipt.steps.map(\.name) == ["git pull"], "The odd row is left out")
        #expect(receipt.skips.count == 1)
        #expect(receipt.fleet.map(\.codeSHA) == [nil, "abc1234"])
        #expect(receipt.gatewayRestartIncomplete == true)
    }

    @Test func summaryWithEmptyCommitIDsReads() throws {
        let receipt = try DirectHermesHostPayload.updateReceipt(try json("""
        {"receipt":{"schema":1,"steps":[],"skips":[],"fleet":[]},
         "summary":{"outcome":"success","started_at":null,"finished_at":null,"pre_sha":"","post_sha":"0123abcd",
                    "post_version":"0.21.5","fleet_states":["current"]}}
        """))
        #expect(receipt.summary.outcome == "success")
        #expect(receipt.summary.preUpdateSHA == nil)
        #expect(receipt.summary.postUpdateSHA == "0123abcd")
    }
}
