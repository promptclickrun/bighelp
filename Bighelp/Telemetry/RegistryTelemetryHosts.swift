import Foundation
import Observation

/// How the app reaches its connected hosts for the telemetry switch. The computer in use
/// is live already; another one is visited only if it's connected right now, and its
/// connection is left as it was (`RegistryFleetReader.withWorkspace` lets go of a connection
/// it made, and this never makes one).
@MainActor
enum RegistryTelemetryHosts {
    static func visitor(registry: BighelpHostRegistry, connections: WorkspaceConnectionStore) -> TelemetryHostVisitor {
        { body in
            if let endpoint = await selected(connections) { await body(endpoint) }
            let reader = RegistryFleetReader(registry: registry)
            for host in registry.hosts where host.id != registry.selectedHostID {
                guard registry.workspace(for: host).isConnected else { continue }
                try? await reader.withWorkspace(host.id) { workspace, owner, _, _ in
                    _ = try? await workspace.perform(.nativeContext, payload: [:], owner: owner)
                    let endpoint = WorkspaceTelemetryHostEndpoint(
                        workspace: workspace, owner: owner, features: { [weak workspace] in
                            workspace?.nativeContext?.features ?? []
                        })
                    await body(endpoint)
                }
            }
        }
    }

    /// The computer in use, with its plugin's features read.
    static func selected(_ connections: WorkspaceConnectionStore) async -> WorkspaceTelemetryHostEndpoint? {
        guard let workspace = connections.workspace, let owner = connections.owner else { return nil }
        if workspace.nativeContext == nil { _ = try? await workspace.perform(.nativeContext, payload: [:], owner: owner) }
        return WorkspaceTelemetryHostEndpoint(workspace: workspace, owner: owner, features: { [weak workspace] in
            workspace?.nativeContext?.features ?? []
        })
    }
}

/// Demo mode has no host. This stands in for one that lists `native-host-telemetry-v1`, so the
/// switch can be tried, and UI tests can check what a host would be told, with nothing leaving
/// the app.
@MainActor
@Observable
final class DemoTelemetryHosts {
    static let shared = DemoTelemetryHosts()
    /// What the stand-in host was told, in order.
    private(set) var told: [Bool] = []
    /// "false,true": for the UI test, which can't read the app's memory.
    var toldDescription: String { told.map { $0 ? "true" : "false" }.joined(separator: ",") }

    private final class Endpoint: TelemetryHostEndpoint {
        unowned let owner: DemoTelemetryHosts
        init(owner: DemoTelemetryHosts) { self.owner = owner }
        var supportsTelemetrySwitch: Bool { true }
        func setTelemetry(enabled: Bool) async throws { owner.told.append(enabled) }
    }

    var visitor: TelemetryHostVisitor {
        { [self] body in await body(Endpoint(owner: self)) }
    }
}
