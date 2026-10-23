import Foundation
import Observation
import CryptoKit

/// The order here is the order of Settings › Device access.
enum DeviceToolCapability: String, CaseIterable, Codable, Identifiable, Sendable {
    case calendar, reminders, contacts, photos, location, geofences, alarms, music, focus, shortcuts, appearance
    var id: String { rawValue }

    /// The plugin feature a host must list before the phone offers this tool.
    /// Older plugins reject an unknown name in the channel's `enabled` list.
    var pluginFeature: String? {
        switch self {
        case .calendar, .reminders: nil
        case .location: "native-device-location-v1"
        case .appearance: "native-device-appearance-v1"
        case .contacts: "native-device-contacts-v1"
        case .photos: "native-device-photos-v1"
        case .geofences: "native-device-geofences-v1"
        case .alarms: "native-device-alarms-v1"
        case .music: "native-device-music-v1"
        case .focus: "native-device-focus-v1"
        case .shortcuts: "native-device-shortcuts-v1"
        }
    }

    /// Everything but Appearance shares the person's data or acts for them: each stays off for a
    /// host until they allow it and iOS agrees. Appearance shares nothing and is easy to undo, so
    /// it's on for every host until they turn it off.
    var sharesPersonalData: Bool { self != .appearance }

    /// False where Apple has no such feature, so Device access leaves the row out instead of
    /// showing a switch that can never turn on.
    var isOfferedOnThisPlatform: Bool {
        switch self {
        case .alarms:
            #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AlarmKit)
            if #available(iOS 26.0, *) { return true }
            #endif
            return false
        case .focus, .shortcuts:
            // visionOS has no Focus filters, and its Shortcuts can't call an app back.
            #if os(visionOS)
            return false
            #else
            return true
            #endif
        case .geofences, .music:
            // A Mac isn't launched for arrivals and stays put; its Music player and playlist
            // calls aren't available to Catalyst apps.
            #if os(visionOS) || targetEnvironment(macCatalyst)
            return false
            #else
            return true
            #endif
        default:
            return true
        }
    }

    var title: String {
        switch self {
        case .calendar: String(localized: "Calendar")
        case .reminders: String(localized: "Reminders")
        case .contacts: String(localized: "Contacts")
        case .photos: String(localized: "Photos")
        case .location: String(localized: "Location")
        case .geofences: String(localized: "Arriving and leaving")
        case .alarms: String(localized: "Alarms and timers")
        case .music: String(localized: "Music")
        case .focus: String(localized: "Focus")
        case .shortcuts: String(localized: "Shortcuts")
        case .appearance: String(localized: "Appearance")
        }
    }

    var detail: String {
        switch self {
        case .calendar: String(localized: "Read, create, update, and delete events directly after you enable access.")
        case .reminders: String(localized: "Read, create, update, and delete reminders directly after you enable access.")
        case .contacts: String(localized: "Look up, add, change, and delete people in your contacts.")
        case .photos: String(localized: "Find and look at your photos, save pictures your agent makes, and sort them into albums.")
        case .location: String(localized: "Share where you are when your agent asks, for things like finding places near you.")
        case .geofences: String(localized: "Your agent can watch places you name and hear from bighelp when you arrive or leave.")
        case .alarms: String(localized: "Set, change, and turn off alarms and timers that ring even on silent.")
        case .music: String(localized: "See what's playing, play and pause music, and make playlists in Apple Music.")
        case .focus: String(localized: "Tell your agent when a Focus is on, with the note you set for it.")
        case .shortcuts: String(localized: "Run the shortcuts you pick and give your agent what they return.")
        case .appearance: String(localized: "Switch light or dark mode and change your chat color when you ask.")
        }
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
    case notRequested, available, denied, unavailable
}

@MainActor @Observable
final class DeviceToolPermissions {
    /// Where "Let agents change how bighelp looks" is saved; missing means on.
    static let appearanceAllowedKey = "bighelp.device-tools.appearance"

    private(set) var scope: DeviceToolScope?
    private(set) var revision: UInt64 = 0
    private(set) var requestInFlight: DeviceToolCapability?
    private var enabled: Set<DeviceToolCapability> = []
    /// Settings › Device access › "Let agents change how bighelp looks". One switch for every host.
    private(set) var appearanceAllowed: Bool
    private var statuses: [DeviceToolCapability: DeviceToolSystemAccess] = [:]
    private let readStatus: (DeviceToolCapability) async -> DeviceToolSystemAccess
    private let requestAccess: (DeviceToolCapability) async -> DeviceToolSystemAccess
    private let isForeground: () -> Bool
    private let readGrants: (String) -> [String]
    private let writeGrants: (String, [String]) -> Void
    private let saveAppearanceAllowed: (Bool) -> Void
    init(
        status: @escaping (DeviceToolCapability) async -> DeviceToolSystemAccess,
        request: @escaping (DeviceToolCapability) async -> DeviceToolSystemAccess,
        isForeground: @escaping () -> Bool,
        readGrants: @escaping (String) -> [String],
        writeGrants: @escaping (String, [String]) -> Void,
        appearanceAllowed: Bool = true,
        saveAppearanceAllowed: @escaping (Bool) -> Void = { _ in }
    ) {
        readStatus = status
        requestAccess = request
        self.isForeground = isForeground
        self.readGrants = readGrants
        self.writeGrants = writeGrants
        self.appearanceAllowed = appearanceAllowed
        self.saveAppearanceAllowed = saveAppearanceAllowed
    }

    func bind(_ scope: DeviceToolScope?) {
        guard self.scope != scope else { return }
        revision &+= 1
        self.scope = scope
        enabled = Set(scope.map { readGrants($0.storageKey).compactMap(DeviceToolCapability.init(rawValue:)) } ?? [])
    }

    func isEnabled(_ kind: DeviceToolCapability) -> Bool {
        scope != nil && (kind.sharesPersonalData ? enabled.contains(kind) : appearanceAllowed)
    }

    func status(for kind: DeviceToolCapability) -> DeviceToolSystemAccess {
        kind.sharesPersonalData ? statuses[kind] ?? .notRequested : .available
    }

    /// No iOS permission: the switch alone decides. Changing it retires work in flight and
    /// reopens the phone's channel with or without the tool.
    func setAppearanceAllowed(_ allowed: Bool) {
        guard allowed != appearanceAllowed else { return }
        revision &+= 1
        appearanceAllowed = allowed
        saveAppearanceAllowed(allowed)
    }

    /// Retires in-flight work without changing the user's saved choices.
    func invalidateOperations() { revision &+= 1 }

    /// Refresh never prompts or creates an app grant from an existing OS grant.
    func refresh() async {
        for kind in DeviceToolCapability.allCases where kind.sharesPersonalData {
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
        guard kind.sharesPersonalData else { setAppearanceAllowed(false); return }
        revision &+= 1
        enabled.remove(kind)
        persist()
    }

    func setEnabled(_ enabled: Bool, for kind: DeviceToolCapability) async {
        guard enabled else { disable(kind); return }
        guard kind.sharesPersonalData else { setAppearanceAllowed(true); return }
        guard let scope, isForeground(), requestInFlight == nil, !isEnabled(kind) else { return }
        let owner = revision
        requestInFlight = kind
        defer { requestInFlight = nil }
        let value = await requestAccess(kind)
        guard self.scope == scope, revision == owner else { return }
        statuses[kind] = value
        guard value == .available else { return }
        self.enabled.insert(kind)
        revision &+= 1
        persist()
    }

    private func persist() {
        guard let scope else { return }
        writeGrants(scope.storageKey, enabled.map(\.rawValue).sorted())
    }
}
