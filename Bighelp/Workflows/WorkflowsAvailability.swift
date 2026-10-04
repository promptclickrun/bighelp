import Foundation
import Observation

/// Whether the connected computer's bighelp plugin has Workflows, for the ☰ menu.
/// Remembered per computer, so reconnecting (every return to the app) doesn't
/// hide it, and only a clear answer from the host changes it: a check that
/// fails while the connection settles leaves Workflows where it was.
@MainActor
@Observable
final class WorkflowsAvailability {
    private(set) var isAvailable: Bool?
    private(set) var host: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let retryDelays: [Duration]

    init(defaults: UserDefaults = .standard,
         retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30)]) {
        self.defaults = defaults
        self.retryDelays = retryDelays
    }

    /// Switches to a computer (nil: none). True when it's a different one;
    /// the last answer for it comes back at once.
    @discardableResult
    func use(host: String?) -> Bool {
        guard host != self.host else { return false }
        self.host = host
        isAvailable = host.flatMap { defaults.object(forKey: Self.key($0)) as? Bool }
        return true
    }

    /// Asks the host, trying again a few times if the question itself fails.
    func check(_ probe: @MainActor () async throws -> Bool) async {
        guard let host else { return }
        for delay in [Duration.zero] + retryDelays {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, self.host == host else { return }
            do {
                let answer = try await probe()
                guard self.host == host else { return }
                isAvailable = answer
                defaults.set(answer, forKey: Self.key(host))
                return
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    private static func key(_ host: String) -> String { "bighelp.workflows.available.\(host)" }
}
