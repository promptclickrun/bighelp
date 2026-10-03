import Foundation
import Observation
import CryptoKit

enum DeviceToolCapability: String, CaseIterable, Codable, Identifiable, Sendable {
    case health, calendar, reminders, location
    var id: String { rawValue }

    /// The plugin feature a host must list before the phone offers this tool.
    /// Older plugins reject an unknown name in the channel's `enabled` list.
    var pluginFeature: String? {
        self == .location ? "native-device-location-v1" : nil
    }
}

struct DeviceToolScope: Codable, Hashable, Sendable {
    let deviceID: String
    let authorizationEpoch: Int
    let hostID: String

    var storageKey: String {
        let data = Data("\(deviceID.utf8.count):\(deviceID):\(authorizationEpoch):\(hostID)".utf8)
        return "loopdy.device-tools.v1." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum DeviceToolSystemAccess: Equatable, Sendable {
    case notRequested, available, managedByHealth, denied, unavailable
}

@MainActor @Observable
final class DeviceToolPermissions {
    private(set) var scope: DeviceToolScope?
    private(set) var revision: UInt64 = 0
    private(set) var requestInFlight: DeviceToolCapability?
    private var enabled: Set<DeviceToolCapability> = []
    private var statuses: [DeviceToolCapability: DeviceToolSystemAccess] = [:]
    private let readStatus: (DeviceToolCapability) async -> DeviceToolSystemAccess
    private let requestAccess: (DeviceToolCapability) async -> DeviceToolSystemAccess
    private let isForeground: () -> Bool
    private let readGrants: (String) -> [String]
    private let writeGrants: (String, [String]) -> Void
    init(
        status: @escaping (DeviceToolCapability) async -> DeviceToolSystemAccess,
        request: @escaping (DeviceToolCapability) async -> DeviceToolSystemAccess,
        isForeground: @escaping () -> Bool,
        readGrants: @escaping (String) -> [String],
        writeGrants: @escaping (String, [String]) -> Void
    ) {
        readStatus = status
        requestAccess = request
        self.isForeground = isForeground
        self.readGrants = readGrants
        self.writeGrants = writeGrants
    }

    func bind(_ scope: DeviceToolScope?) {
        guard self.scope != scope else { return }
        revision &+= 1
        self.scope = scope
        enabled = Set(scope.map { readGrants($0.storageKey).compactMap(DeviceToolCapability.init(rawValue:)) } ?? [])
    }

    func isEnabled(_ kind: DeviceToolCapability) -> Bool { scope != nil && enabled.contains(kind) }
    func status(for kind: DeviceToolCapability) -> DeviceToolSystemAccess { statuses[kind] ?? .notRequested }

    /// Retires in-flight work without changing the user's saved choices.
    func invalidateOperations() { revision &+= 1 }

    /// Refresh never prompts or creates an app grant from an existing OS grant.
    func refresh() async {
        for kind in DeviceToolCapability.allCases {
            guard requestInFlight != kind else { continue }
            let owner = revision
            let value = await readStatus(kind)
            guard revision == owner, requestInFlight != kind else { continue }
            statuses[kind] = value
            if isEnabled(kind), value == .denied || value == .unavailable { disable(kind) }
        }
    }

    /// Synchronous revocation also invalidates operations awaiting OS callbacks.
    func disable(_ kind: DeviceToolCapability) {
        revision &+= 1
        enabled.remove(kind)
        persist()
    }

    func setEnabled(_ enabled: Bool, for kind: DeviceToolCapability) async {
        guard enabled else { disable(kind); return }
        guard let scope, isForeground(), requestInFlight == nil, !isEnabled(kind) else { return }
        let owner = revision
        requestInFlight = kind
        defer { requestInFlight = nil }
        let value = await requestAccess(kind)
        guard self.scope == scope, revision == owner else { return }
        statuses[kind] = value
        guard value == .available || (kind == .health && value == .managedByHealth) else { return }
        self.enabled.insert(kind)
        revision &+= 1
        persist()
    }

    private func persist() {
        guard let scope else { return }
        writeGrants(scope.storageKey, enabled.map(\.rawValue).sorted())
    }
}
