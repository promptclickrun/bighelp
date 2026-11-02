@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech
import UIKit
import UserNotifications

enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case notification
    case camera
    case microphone
    case speech

    var id: Self { self }

    var title: String {
        switch self {
        case .notification: String(localized: "Notifications")
        case .camera: String(localized: "Camera")
        case .microphone: String(localized: "Microphone")
        case .speech: String(localized: "Speech Recognition")
        }
    }

    var systemImage: String {
        switch self {
        case .notification: "bell.badge"
        case .camera: "camera"
        case .microphone: "microphone"
        case .speech: "waveform"
        }
    }

    var purpose: String {
        switch self {
        case .notification:
            String(localized: "Receive proactive updates from your paired Hermes host.")
        case .camera:
            String(localized: "Scan pairing codes, use Reflective Vision, and attach photos you choose to chats.")
        case .microphone:
            String(localized: "Speak during a live voice conversation with your selected Hermes agent.")
        case .speech:
            String(localized: "Turn speech into words for live voice conversations.")
        }
    }
}

enum PermissionAuthorizationState: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
    case provisional
    case ephemeral

    var statusTitle: String {
        switch self {
        case .notDetermined: String(localized: "Not Requested")
        case .denied: String(localized: "Denied")
        case .restricted: String(localized: "Restricted")
        case .authorized: String(localized: "Allowed")
        case .provisional: String(localized: "Provisional")
        case .ephemeral: String(localized: "Ephemeral")
        }
    }

    var permitsNotificationRegistration: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied, .restricted: false
        }
    }
}

enum PermissionSettingState: Equatable, Sendable {
    case enabled
    case disabled
    case notSupported

    var title: String {
        switch self {
        case .enabled: String(localized: "On")
        case .disabled: String(localized: "Off")
        case .notSupported: String(localized: "Not Supported")
        }
    }
}

struct NotificationPermissionDetails: Equatable, Sendable {
    let alert: PermissionSettingState
    let sound: PermissionSettingState
    let badge: PermissionSettingState
}

struct PermissionStatus: Equatable, Sendable {
    let authorization: PermissionAuthorizationState
    let notification: NotificationPermissionDetails?

    init(
        authorization: PermissionAuthorizationState,
        notification: NotificationPermissionDetails? = nil
    ) {
        self.authorization = authorization
        self.notification = notification
    }
}

struct PermissionClient {
    let status: @MainActor () async -> PermissionStatus
    let request: @MainActor () async -> PermissionStatus
}

enum PermissionRecoveryAction: Equatable, Sendable {
    case none
    case openSystemSettings
}

@MainActor
@Observable
final class PermissionCenter {
    let deviceTools: DeviceToolPermissions
    var nativeDeviceID = UUID().uuidString.lowercased()
    var nativeDeviceToolStatus: String?
    @ObservationIgnored let nativeDeviceToolLifetime = NativeDeviceToolLifetime()
    @ObservationIgnored var nativeDeviceToolHandler: NativeDeviceToolSession.Handler?
    #if DEBUG
    /// Demo mode's stand-in for an agent's appearance call (`-test-agent-appearance`).
    @ObservationIgnored var demoAppearanceCall: DeviceAppearanceFixture?
    /// Demo mode's stand-in for an agent's call to a tool that's off (`-test-device-access-card`).
    @ObservationIgnored var demoAccessCall: DeviceAccessCardFixture?
    #endif
    private(set) var requestInFlight: PermissionKind?
    private(set) var statuses: [PermissionKind: PermissionStatus]

    private let clients: [PermissionKind: PermissionClient]
    private let isForeground: () -> Bool
    private let openSystemSettings: () -> Void
    private var refreshGenerations: [PermissionKind: Int] = [:]
    private var nextRequestOwnership = 0
    private var requestOwnership: Int?

    init(
        clients: [PermissionKind: PermissionClient],
        isForeground: @escaping () -> Bool,
        openSystemSettings: @escaping () -> Void,
        deviceTools: DeviceToolPermissions? = nil
    ) {
        self.clients = clients
        self.isForeground = isForeground
        self.openSystemSettings = openSystemSettings
        self.deviceTools = deviceTools ?? DeviceToolPermissions(
            status: { _ in .unavailable }, request: { _ in .unavailable },
            isForeground: { false }, readGrants: { _ in [] }, writeGrants: { _, _ in }
        )
        statuses = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map {
            ($0, PermissionStatus(authorization: .notDetermined))
        })
    }

    convenience init(deviceTools: DeviceToolPermissions? = nil) {
        self.init(
            clients: Self.liveClients(),
            isForeground: { UIApplication.shared.applicationState == .active },
            openSystemSettings: {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            },
            deviceTools: deviceTools
        )
    }

    func status(for kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? PermissionStatus(authorization: .notDetermined)
    }

    /// Reads only OS-authoritative state. It never invokes a permission request.
    func refresh() async {
        for kind in PermissionKind.allCases {
            await refresh(kind)
        }
    }

    func refresh(_ kind: PermissionKind) async {
        guard requestInFlight != kind else { return }
        guard let client = clients[kind] else { return }
        let generation = refreshGenerations[kind, default: 0] + 1
        refreshGenerations[kind] = generation
        let value = await client.status()
        guard refreshGenerations[kind] == generation, requestInFlight != kind else { return }
        statuses[kind] = value
    }

    /// Reconciles the global OS status, then requests access only when the
    /// explicit contextual action is still eligible to display a prompt.
    func authorizeContextualAccess(_ kind: PermissionKind) async -> Bool {
        await refresh(kind)
        switch status(for: kind).authorization {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            guard await request(kind) else { return false }
            switch status(for: kind).authorization {
            case .authorized, .provisional, .ephemeral: return true
            case .notDetermined, .denied, .restricted: return false
            }
        case .denied, .restricted:
            return false
        }
    }

    /// The only shared entry point that can display an iOS permission prompt.
    /// Callers must be handling an explicit user action while the app is active.
    @discardableResult
    func request(_ kind: PermissionKind) async -> Bool {
        guard isForeground(), requestInFlight == nil else { return false }
        guard status(for: kind).authorization == .notDetermined else { return false }
        guard let client = clients[kind] else { return false }

        nextRequestOwnership += 1
        let owner = nextRequestOwnership
        requestOwnership = owner
        requestInFlight = kind
        refreshGenerations[kind, default: 0] += 1
        defer {
            if requestOwnership == owner {
                requestOwnership = nil
                requestInFlight = nil
            }
        }

        let value = await client.request()
        guard requestOwnership == owner else { return false }
        refreshGenerations[kind, default: 0] += 1
        statuses[kind] = value
        return true
    }

    func recoveryAction(for kind: PermissionKind) -> PermissionRecoveryAction {
        let value = status(for: kind)
        return switch value.authorization {
        case .denied, .restricted: .openSystemSettings
        case .notDetermined, .authorized, .provisional, .ephemeral: .none
        }
    }

    func performRecoveryAction(for kind: PermissionKind) {
        guard recoveryAction(for: kind) == .openSystemSettings else { return }
        openSystemSettings()
    }
}

private extension PermissionCenter {
    static func liveClients() -> [PermissionKind: PermissionClient] {
        [
            .notification: PermissionClient(
                status: { await notificationStatus() },
                request: {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                        options: [.alert, .badge, .sound]
                    )
                    return await notificationStatus()
                }
            ),
            .camera: PermissionClient(
                status: { captureStatus(for: .video) },
                request: {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                    return captureStatus(for: .video)
                }
            ),
            .microphone: PermissionClient(
                status: { microphoneStatus() },
                request: {
                    // The system answers on its own queue. A Sendable callback keeps it
                    // off the main actor; an inherited MainActor callback traps there
                    // (the crash when allowing the microphone).
                    _ = await withCheckedContinuation { continuation in
                        AVAudioApplication.requestRecordPermission { @Sendable granted in
                            continuation.resume(returning: granted)
                        }
                    }
                    return microphoneStatus()
                }
            ),
            .speech: PermissionClient(
                status: { speechStatus() },
                request: {
                    // Same for speech recognition: its answer arrives on a background queue.
                    _ = await withCheckedContinuation { continuation in
                        SFSpeechRecognizer.requestAuthorization { @Sendable status in
                            continuation.resume(returning: status)
                        }
                    }
                    return speechStatus()
                }
            ),
        ]
    }

    static func notificationStatus() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorization: PermissionAuthorizationState = switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .restricted
        }
        return PermissionStatus(
            authorization: authorization,
            notification: NotificationPermissionDetails(
                alert: permissionSetting(settings.alertSetting),
                sound: permissionSetting(settings.soundSetting),
                badge: permissionSetting(settings.badgeSetting)
            )
        )
    }

    static func permissionSetting(
        _ setting: UNNotificationSetting
    ) -> PermissionSettingState {
        switch setting {
        case .enabled: .enabled
        case .disabled: .disabled
        case .notSupported: .notSupported
        @unknown default: .notSupported
        }
    }

    static func captureStatus(for mediaType: AVMediaType) -> PermissionStatus {
        let authorization: PermissionAuthorizationState = switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .restricted
        }
        return PermissionStatus(authorization: authorization)
    }

    static func microphoneStatus() -> PermissionStatus {
        let authorization: PermissionAuthorizationState = switch AVAudioApplication.shared.recordPermission {
        case .undetermined: .notDetermined
        case .denied: .denied
        case .granted: .authorized
        @unknown default: .restricted
        }
        return PermissionStatus(authorization: authorization)
    }

    static func speechStatus() -> PermissionStatus {
        let authorization: PermissionAuthorizationState = switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .restricted
        }
        return PermissionStatus(authorization: authorization)
    }
}

enum PermissionRowAction: Equatable, Sendable {
    case none
    case request
    case openSystemSettings
}

struct PermissionRowPresentation: Equatable, Sendable {
    let kind: PermissionKind
    let status: PermissionStatus

    var action: PermissionRowAction {
        switch status.authorization {
        case .notDetermined: .request
        case .denied, .restricted: .openSystemSettings
        case .authorized, .provisional, .ephemeral: .none
        }
    }

    let usesToggleSemantics = false
    var accessibilityValue: String { status.authorization.statusTitle }

    var actionTitle: String? {
        switch action {
        case .request: String(localized: "Allow \(kind.title)")
        case .openSystemSettings: String(localized: "Open System Settings")
        case .none: nil
        }
    }

    var detailText: String? {
        if let notification = status.notification {
            let alerts = notification.alert.title, sounds = notification.sound.title
            let badges = notification.badge.title
            return String(localized: "Alerts \(alerts) · Sounds \(sounds) · Badges \(badges)")
        }
        return nil
    }
}

struct ContextualPermissionRecoveryPresentation: Equatable, Sendable {
    let kind: PermissionKind
    let status: PermissionStatus

    var message: String? {
        switch status.authorization {
        case .denied:
            "\(kind.title) access is denied. You can allow it in \(BighelpPlatform.isMac ? "System Settings" : "iOS Settings")."
        case .restricted:
            "\(kind.title) access is restricted on this device."
        case .notDetermined, .authorized, .provisional, .ephemeral:
            nil
        }
    }

    var action: PermissionRecoveryAction {
        switch status.authorization {
        case .denied, .restricted: .openSystemSettings
        case .notDetermined, .authorized, .provisional, .ephemeral: .none
        }
    }
}
