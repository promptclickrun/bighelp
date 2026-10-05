import Foundation
import Observation

/// What a computer's bighelp plugin says about Workflows in `/native/context`.
enum WorkflowsSupport: Equatable, Sendable {
    /// `native-workflows-v1`; editing the flow needs `native-workflows-edit-v1` too.
    case available(canEdit: Bool)
    /// The plugin has Workflows, but this computer can't run them (a fixed code under `unavailable`).
    case unavailable(code: String)
    /// The plugin predates Workflows.
    case missing

    static let feature = "native-workflows-v1"
    static let editFeature = "native-workflows-edit-v1"
    /// The codes a plugin may give under `unavailable`; any other one is shown as "can't run right now".
    static let unavailableCodes: Set<String> = ["not_posix", "profile_helpers_missing", "chat_runner_missing",
                                                "store_unavailable"]

    init(context: WorkflowJSON) {
        let features = Set(WorkflowDecode.strings(context["features"], max: 400))
        if features.contains(Self.feature) {
            self = .available(canEdit: features.contains(Self.editFeature))
        } else if let code = Self.unavailableCode(context["unavailable"]) {
            self = .unavailable(code: code)
        } else {
            self = .missing
        }
    }

    /// `{"native-workflows-v1": "not_posix"}`, `{"native-workflows-v1": {"code": …}}`
    /// or `[{"feature": "native-workflows-v1", "code": …}]`.
    private static func unavailableCode(_ value: BighelpJSONValue?) -> String? {
        let entry: BighelpJSONValue?
        if let object = value?.object {
            entry = object[feature]
        } else {
            entry = WorkflowDecode.objects(value, max: 100).first {
                WorkflowDecode.string($0["feature"] ?? $0["capability"], max: 128) == feature
            }.map(BighelpJSONValue.object)
        }
        guard let entry else { return nil }
        let code = entry.string ?? WorkflowDecode.string(entry.object?["code"] ?? entry.object?["reason"], max: 64)
        guard let code, !code.isEmpty, code.utf8.count <= 64 else { return "unknown" }
        return code
    }

    /// ☰ shows Workflows for a computer that has them or says why it can't run them.
    var showsMenuRow: Bool { self != .missing }
    var canEdit: Bool { self == .available(canEdit: true) }

    var stored: String {
        switch self {
        case .available(let canEdit): canEdit ? "edit" : "read"
        case .unavailable(let code): "unavailable:\(code)"
        case .missing: "missing"
        }
    }

    init?(stored: String) {
        switch stored {
        case "edit": self = .available(canEdit: true)
        case "read": self = .available(canEdit: false)
        case "missing": self = .missing
        case _ where stored.hasPrefix("unavailable:"): self = .unavailable(code: String(stored.dropFirst(12)))
        default: return nil
        }
    }
}

/// Whether the connected computer's bighelp plugin has Workflows, for the ☰ menu.
/// Remembered per computer, so reconnecting (every return to the app) doesn't
/// hide it, and only a clear answer from the host changes it: a check that
/// fails while the connection settles leaves Workflows where it was.
@MainActor
@Observable
final class WorkflowsAvailability {
    private(set) var support: WorkflowsSupport?
    private(set) var host: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let retryDelays: [Duration]

    init(defaults: UserDefaults = .standard,
         retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30)]) {
        self.defaults = defaults
        self.retryDelays = retryDelays
    }

    /// The ☰ row: shown for a computer that has Workflows or says why it can't run them.
    var isAvailable: Bool? { support.map(\.showsMenuRow) }

    /// Switches to a computer (nil: none). True when it's a different one;
    /// the last answer for it comes back at once.
    @discardableResult
    func use(host: String?) -> Bool {
        guard host != self.host else { return false }
        self.host = host
        support = host.flatMap { host in
            (defaults.string(forKey: Self.key(host))).flatMap(WorkflowsSupport.init(stored:))
                // Saved by an older version: it only knew "has Workflows".
                ?? (defaults.object(forKey: Self.oldKey(host)) as? Bool).map { $0 ? .available(canEdit: false) : .missing }
        }
        return true
    }

    /// Asks the host, trying again a few times if the question itself fails.
    func check(_ probe: @MainActor () async throws -> WorkflowsSupport) async {
        guard let host else { return }
        for delay in [Duration.zero] + retryDelays {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, self.host == host else { return }
            do {
                let answer = try await probe()
                guard self.host == host else { return }
                support = answer
                defaults.set(answer.stored, forKey: Self.key(host))
                return
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    private static func key(_ host: String) -> String { "bighelp.workflows.support.\(host)" }
    private static func oldKey(_ host: String) -> String { "bighelp.workflows.available.\(host)" }
}
