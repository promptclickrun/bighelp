import Foundation
import Security

// The computer's own desktop (macOS, Linux or Windows), not an agent's: the plugin bridges the
// computer's own VNC server (macOS Screen Sharing, a Linux or Windows VNC server) to the app
// (`native-computer-screen-v1`), and the Computer tab opens it in the same viewer as an agent's
// screen. Two sign-ins guard it: the computer's (the app's connection) and the VNC password the
// person set on the computer, which stays on this phone.

/// Whether the computer's screen sharing answers, and which system it runs.
struct ComputerScreenStatus: Equatable, Sendable {
    enum OS: String, Sendable { case macos, linux, windows, other }

    var available: Bool
    var os: OS

    init(available: Bool, os: OS) {
        self.available = available
        self.os = os
    }

    init?(_ object: [String: BighelpJSONValue]) {
        guard let available = object["available"]?.boolean else { return nil }
        self.init(available: available, os: object["os"]?.string.flatMap(OS.init(rawValue:)) ?? .other)
    }

    /// How to turn the computer's screen sharing on, in plain words.
    var setupSteps: String {
        switch os {
        case .macos:
            String(localized: "On the Mac, open System Settings › General › Sharing and turn on Screen Sharing. Then tap ⓘ, turn on “VNC viewers may control screen with password” and set a password.")
        case .linux:
            String(localized: "On the computer, turn on its remote desktop with VNC and a password, or run a VNC server such as x11vnc on port 5900.")
        case .windows:
            String(localized: "On the PC, install a VNC server such as TightVNC, set a password and keep it on port 5900.")
        case .other:
            String(localized: "On the computer, turn on a VNC server with a password, on port 5900.")
        }
    }
}

/// A screen service for the computer itself. Nobody else drives it, so control is the person's
/// to take and give back here, with no lease on the computer.
@MainActor
protocol ComputerScreenProviding: BotScreenService {
    func computerStatus() async throws -> ComputerScreenStatus
    /// The VNC password this phone keeps for the computer.
    var passwords: ComputerScreenPasswords { get }
}

extension BotScreenService {
    var computer: (any ComputerScreenProviding)? { nil }
}

/// The plugin's `computer-screen/*` on the connected computer.
@MainActor
final class LiveComputerScreenService: ComputerScreenProviding {
    static let feature = "native-computer-screen-v1"
    static let streamPath = "/api/plugins/loopdy/native/computer-screen/ws"
    static let profileKey = "computer"

    let passwords: ComputerScreenPasswords
    private let signIn: WorkspaceSignIn
    private let connection: @MainActor () -> LiveBotScreenService.Connection?
    private var lease = BotScreenLease.agent

    init(signIn: WorkspaceSignIn, hostID: UUID, connection: @escaping @MainActor () -> LiveBotScreenService.Connection?) {
        self.signIn = signIn
        self.connection = connection
        passwords = ComputerScreenPasswords(account: hostID.uuidString)
    }

    func computerStatus() async throws -> ComputerScreenStatus {
        guard let status = ComputerScreenStatus(try await perform(.computerScreenStatus)) else {
            throw WorkspaceClientError.invalidResponse
        }
        return status
    }

    private var current: BotScreenStatus {
        BotScreenStatus(running: true, lease: lease, profileKey: Self.profileKey)
    }

    func status(agentID: String) async throws -> BotScreenStatus { current }
    func start(agentID: String) async throws -> BotScreenStatus { current }
    func stop(agentID: String) async throws -> BotScreenStatus { current }
    func thumbnail(agentID: String) async throws -> BotScreenThumbnail { .none }

    func observe(agentID: String, viewerID: String?) async throws -> BotScreenObservation {
        let result = try await perform(.computerScreenObserve)
        guard let ticket = result["ticket"]?.string, !ticket.isEmpty, ticket.utf8.count <= 1_024,
              (result["path"]?.string ?? Self.streamPath) == Self.streamPath else {
            throw WorkspaceClientError.invalidResponse
        }
        return BotScreenObservation(ticket: ticket, path: Self.streamPath, viewerID: viewerID ?? UUID().uuidString,
                                    status: current)
    }

    func takeControl(agentID: String, viewerID: String) async throws -> BotScreenLease {
        lease = BotScreenLease(holder: .human, viewerHash: BotScreenLease.hash(viewerID: viewerID), epoch: lease.epoch + 1)
        return lease
    }

    func handBack(agentID: String, viewerID: String) async throws -> BotScreenLease {
        lease = BotScreenLease(holder: .agent, viewerHash: nil, epoch: lease.epoch + 1)
        return lease
    }

    func openStream(_ observation: BotScreenObservation) async throws -> any RFBTransport {
        guard let current = connection(), current.owner.signIn == signIn else { throw WorkspaceClientError.ownerChanged }
        return try current.streams.open(observation)
    }

    func events() -> AsyncStream<BotScreenEvent> { AsyncStream { $0.finish() } }

    private func perform(_ operation: WorkspaceOperation) async throws -> [String: BighelpJSONValue] {
        guard let current = connection(), current.owner.signIn == signIn else { throw WorkspaceClientError.ownerChanged }
        return try await current.workspace.perform(operation, payload: [:], owner: current.owner)
    }
}

/// The computer's VNC password, in this phone's Keychain, one per computer. Never sent anywhere:
/// it only answers the VNC server's challenge.
struct ComputerScreenPasswords: Sendable {
    static let service = "BighelpComputerScreen"
    let account: String

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ password: String) {
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    func remove() { SecItemDelete(baseQuery as CFDictionary) }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }
}

/// Demo mode's computer: the demo desktop, available, with no password.
@MainActor
final class DemoComputerScreenService: ComputerScreenProviding {
    static let shared = DemoComputerScreenService()
    let passwords = ComputerScreenPasswords(account: "demo-computer")
    private var lease = BotScreenLease.agent
    private let desktop = DemoBotScreenService.shared

    private var current: BotScreenStatus {
        BotScreenStatus(running: true, size: DemoBotDesktop.size, lease: lease, profileKey: LiveComputerScreenService.profileKey)
    }

    func computerStatus() async throws -> ComputerScreenStatus { ComputerScreenStatus(available: true, os: .macos) }
    func status(agentID: String) async throws -> BotScreenStatus { current }
    func start(agentID: String) async throws -> BotScreenStatus { current }
    func stop(agentID: String) async throws -> BotScreenStatus { current }
    func thumbnail(agentID: String) async throws -> BotScreenThumbnail { .none }

    func observe(agentID: String, viewerID: String?) async throws -> BotScreenObservation {
        BotScreenObservation(ticket: "demo-computer", viewerID: viewerID ?? "demo-computer-viewer", status: current)
    }

    func takeControl(agentID: String, viewerID: String) async throws -> BotScreenLease {
        lease = BotScreenLease(holder: .human, viewerHash: BotScreenLease.hash(viewerID: viewerID), epoch: lease.epoch + 1)
        return lease
    }

    func handBack(agentID: String, viewerID: String) async throws -> BotScreenLease {
        lease = BotScreenLease(holder: .agent, viewerHash: nil, epoch: lease.epoch + 1)
        return lease
    }

    func openStream(_ observation: BotScreenObservation) async throws -> any RFBTransport {
        try await desktop.openStream(observation)
    }

    func events() -> AsyncStream<BotScreenEvent> { AsyncStream { $0.finish() } }
}
