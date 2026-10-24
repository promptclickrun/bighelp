import Foundation
import Observation

/// A host the telemetry switch can be sent to: the computer in use, or another one
/// that is connected right now.
@MainActor
protocol TelemetryHostEndpoint: AnyObject {
    /// The plugin's `/native/context` lists `native-host-telemetry-v1`.
    var supportsTelemetrySwitch: Bool { get }
    /// `PUT /api/plugins/loopdy/native/telemetry {"enabled": …}`.
    func setTelemetry(enabled: Bool) async throws
}

/// Calls `body` once for every connected host, however the app reaches them.
typealias TelemetryHostVisitor = @MainActor (_ body: @MainActor (any TelemetryHostEndpoint) async -> Void) async -> Void

/// A host over its plugin routes (`DirectHermesWorkspaceClient`).
@MainActor
final class WorkspaceTelemetryHostEndpoint: TelemetryHostEndpoint {
    static let feature = "native-host-telemetry-v1"
    private let workspace: any WorkspaceOperationPerforming
    private let owner: WorkspaceOwner
    private let features: @MainActor () -> Set<String>

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner,
         features: @escaping @MainActor () -> Set<String>) {
        self.workspace = workspace
        self.owner = owner
        self.features = features
    }

    var supportsTelemetrySwitch: Bool { features().contains(Self.feature) }

    func setTelemetry(enabled: Bool) async throws {
        let payload: [String: BighelpJSONValue] = ["enabled": .boolean(enabled)]
        do {
            _ = try await workspace.perform(.telemetrySet, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed (412): the next call loads it again. Once.
            _ = try await workspace.perform(.telemetrySet, payload: payload, owner: owner)
        }
    }
}

/// The Settings switch "Share usage and diagnostics", and what turning it off or on does.
///
/// - Off: the queue and the install ID are thrown away, nothing more is sent, and every connected
///   host that lists `native-host-telemetry-v1` is told `{"enabled": false}`. A host that connects
///   later while it's off is told then.
/// - On again: a new install ID, one `telemetry.toggled` event, and `{"enabled": true}` to each
///   connected host that lists the capability.
/// - `{"enabled": true}` goes out at no other time (contract §4). A host that wasn't connected when
///   it was turned back on keeps its own switch off until the next time.
@MainActor
@Observable
final class TelemetryController {
    static let shared = TelemetryController()

    private(set) var isEnabled: Bool
    /// Whether this run can send at all. False in tests and demo mode: the switch still works,
    /// it just has nothing to stop.
    var sendsTelemetry: Bool { Telemetry.isActive }

    @ObservationIgnored private let preference: TelemetryPreference
    @ObservationIgnored private let clientProvider: @MainActor () -> TelemetryClient?
    @ObservationIgnored private let receipts: BighelpDeliveryReceipts
    @ObservationIgnored private let markEnabled: @MainActor (Bool) -> Void
    /// Each switch change waits for the one before it, so quick changes can't run side by side.
    @ObservationIgnored private var changes: Task<Void, Never>?
    @ObservationIgnored var visitHosts: TelemetryHostVisitor
    /// The connection each host was last told on, so a refresh on the same connection doesn't ask again.
    @ObservationIgnored private var toldConnections: Set<UUID> = []

    init(preference: TelemetryPreference = TelemetryPreference(),
         client: @escaping @MainActor () -> TelemetryClient? = { Telemetry.client },
         receipts: BighelpDeliveryReceipts = .shared,
         markEnabled: @escaping @MainActor (Bool) -> Void = { Telemetry.markEnabled($0) },
         visitHosts: @escaping TelemetryHostVisitor = { _ in }) {
        self.preference = preference
        self.receipts = receipts
        self.markEnabled = markEnabled
        clientProvider = client
        self.visitHosts = visitHosts
        isEnabled = preference.isEnabled
        receipts.setRecording(isEnabled)
    }

    /// The person's choice takes effect at once (`isEnabled`, the saved preference and the no-op flag), and
    /// the work behind it runs in order: a quick off, on, off never overlaps itself. Each host is asked again
    /// whether the choice still stands just before it is told, so a host is never left on while the app is off.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        preference.isEnabled = enabled
        markEnabled(enabled)
        receipts.setRecording(enabled)
        toldConnections.removeAll()
        let previous = changes
        let work = Task { @MainActor in
            await previous?.value
            await apply(enabled)
        }
        changes = work
        await work.value
    }

    private func apply(_ enabled: Bool) async {
        // The client always follows every change in order (off clears the queue and the ID, even if it
        // is switched back on a moment later); only the "toggled" event and the hosts check the final choice.
        let client = clientProvider()
        await client?.setEnabled(enabled)
        if enabled, isEnabled { await client?.record(.toggled(enabled: true), at: Date()) }
        // Pushes counted while it was off are not sent later.
        if !enabled { await TelemetryLifecycle.drain(receipts, into: nil, now: Date()) }
        await visitHosts { host in
            guard host.supportsTelemetrySwitch, self.isEnabled == enabled else { return }
            try? await host.setTelemetry(enabled: enabled)
        }
    }

    /// A host just connected (or its plugin's context was read again). While telemetry is off it
    /// is told so; while it's on, nothing is sent.
    func hostConnected(_ host: any TelemetryHostEndpoint, connection: UUID) async {
        guard !isEnabled, host.supportsTelemetrySwitch, toldConnections.insert(connection).inserted else { return }
        do { try await host.setTelemetry(enabled: false) }
        catch { toldConnections.remove(connection) }
    }
}
