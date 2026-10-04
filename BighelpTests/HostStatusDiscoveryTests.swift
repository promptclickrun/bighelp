import Foundation
import Testing
@testable import Bighelp

/// The first thing bighelp asks a new address is Hermes' public `/api/status`.
/// Behind a Cloudflare Tunnel, an answer from something other than Hermes'
/// status (issue #132) showed only "unsupported or invalid response".
/// All values here are made up.
@MainActor
struct HostStatusDiscoveryTests {
    /// Hermes 0.21.5's `/api/status` on a loopback bind (no sign-in) with its
    /// gateway stopped, so the gateway fields are null.
    nonisolated static let stoppedGatewayStatus = """
    {"version":"0.21.5","release_date":"2026.9.24","config_version":31,"latest_config_version":31,
    "can_update_hermes":true,"gateway_running":false,"gateway_state":null,"gateway_platforms":{},
    "gateway_exit_reason":null,"gateway_updated_at":null,"gateway_heartbeat_stale_s":null,
    "gateway_shared_with":null,"active_agents":0,"gateway_busy":false,"gateway_drainable":false,
    "restart_drain_timeout":180,"active_sessions":0,"auth_required":false,"auth_providers":[],
    "auth_flows":[],"nous_session_valid":"unknown","install_id":"00000000-0000-4000-8000-000000000001",
    "components":{"gateway":{"status":"degraded","state":"stopped"},"dashboard":{"status":"ok"},
    "storage":{"status":"ok"},"platforms":{"status":"ok","configured":0,"connected":0}},
    "overall":"degraded","memory":{"pressure":"unknown"},"disk":{"pressure":"unknown"},
    "profiles":["default"],"parked_profiles":[],"gateway_mode":"single","multiplex_standalone_reason":null,
    "hermes_home":"/home/example/.hermes","config_path":"/home/example/.hermes/config.yaml",
    "env_path":"/home/example/.hermes/.env","gateway_pid":null,"gateway_health_url":null,"gateways":[]}
    """

    /// What Hermes answers when the Host header isn't its own bound name. A
    /// Cloudflare Tunnel passes the public name on unless told otherwise.
    nonisolated static let hostRefusal = """
    {"detail":"Invalid Host header. Dashboard requests must use the bound hostname or the configured public hostname."}
    """

    private func endpoint(_ port: UInt16) throws -> DirectHermesEndpoint {
        try DirectHermesEndpoint(address: "http://127.0.0.1:\(port)", allowPrivateHTTP: true)
    }

    private func discoveryError(_ reply: ScriptedHermes.Reply) async throws -> DirectHermesError? {
        let host = try ScriptedHermes { _ in reply }
        let endpoint = try endpoint(try await host.start())
        defer { #expect(host.paths == ["/api/status"]) }
        do {
            _ = try await HostAuthenticationDiscovery.discover(endpoint: endpoint)
            return nil
        } catch let error as DirectHermesError {
            return error
        }
    }

    @Test func aStockStatusWithTheGatewayStoppedIsRead() async throws {
        let host = try ScriptedHermes { _ in .json(Self.stoppedGatewayStatus) }
        let discovery = try await HostAuthenticationDiscovery.discover(endpoint: endpoint(try await host.start()))
        #expect(!discovery.requiresAuthentication)
        #expect(HostAuthenticationDiscovery.preferredMethod(for: discovery) == .dashboard)
        #expect(host.paths == ["/api/status"])
    }

    @Test func aNullListOfSignInFlowsMeansNone() async throws {
        let status = Self.stoppedGatewayStatus.replacingOccurrences(of: #""auth_flows":[]"#, with: #""auth_flows":null"#)
        let host = try ScriptedHermes { _ in .json(status) }
        let discovery = try await HostAuthenticationDiscovery.discover(endpoint: endpoint(try await host.start()))
        #expect(!discovery.requiresAuthentication && !discovery.nativePKCE)
    }

    @Test func hermesTurningAwayThePublicNameSaysHowToFixIt() async throws {
        let error = try await discoveryError(.raw(400, type: "application/json", body: Self.hostRefusal))
        #expect(error == .hostNameRefused)
        let message = DirectHermesConversationClient.safeMessage(DirectHermesError.hostNameRefused)
        #expect(message.contains("dashboard.public_url"))
        #expect(!message.contains("Invalid Host header"), "Never show what the host sent")
    }

    @Test func otherBadRequestsStayInvalid() async throws {
        let error = try await discoveryError(.raw(400, type: "application/json", body: #"{"detail":"fixture"}"#))
        #expect(error == .invalidResponse)
    }

    @Test func aWebPageThroughCloudflareIsNotCalledAnInvalidResponse() async throws {
        let page = "<!doctype html><html><head><title>Sign in</title></head><body>fixture</body></html>"
        let cloudflare = try await discoveryError(.raw(200, type: "text/html; charset=UTF-8",
                                                       headers: ["CF-RAY": "8a1b2c3d4e5f6a7b-DFW", "Server": "cloudflare"],
                                                       body: page))
        #expect(cloudflare == .webPageInsteadOfHermes(throughCloudflare: true))
        #expect(cloudflare?.localizedDescription.contains("Cloudflare") == true)

        let elsewhere = try await discoveryError(.html(page))
        #expect(elsewhere == .webPageInsteadOfHermes(throughCloudflare: false))
        #expect(elsewhere?.localizedDescription.contains("Cloudflare") == false)
    }
}
