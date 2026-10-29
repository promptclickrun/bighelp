import Foundation
import Observation
import CryptoKit

/// The order here is the order of Settings › Device access.
enum DeviceToolCapability: String, CaseIterable, Codable, Identifiable, Sendable {
    case calendar, reminders, contacts, photos, location, geofences, alarms, music, focus, shortcuts, appearance, navigation
    var id: String { rawValue }

    /// The plugin feature a host must list before the phone offers this tool.
    /// Older plugins reject an unknown name in the channel's `enabled` list.
    var pluginFeature: String? {
        switch self {
        case .calendar, .reminders: nil
        case .location: "native-device-location-v1"
        case .appearance: "native-device-appearance-v1"
        case .navigation: "native-device-navigation-v1"
        case .contacts: "native-device-contacts-v1"
        case .photos: "native-device-photos-v1"
        case .geofences: "native-device-geofences-v1"
        case .alarms: "native-device-alarms-v1"
        case .music: "native-device-music-v1"
        case .focus: "native-device-focus-v1"
        case .shortcuts: "native-device-shortcuts-v1"
        }
    }

    /// Everything but Appearance and Navigation shares the person's data or acts for them: each stays
    /// off for a host until they allow it and iOS agrees. Those two share nothing and are easy to undo
    /// (Appearance, Return to chat), so they're on for every host until the person turns them off.
    var sharesPersonalData: Bool { self != .appearance && self != .navigation }

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
        case .navigation: String(localized: "Show you around")
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
        case .navigation: String(localized: "Open the page or setting you ask about and point at it.")
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
    /// Where "Let agents show you around bighelp" is saved; missing means on.
    static let navigationAllowedKey = "bighelp.device-tools.navigation"
    /// Where the switches are saved: one list for this phone, for every computer and agent. A switch
    /// stays on until the person turns it off; iOS saying no only pauses its tool (`isUsable`).
    static let grantsKey = "bighelp.device-tools.grants"
    /// Before 2.6.15 each host had its own list (`DeviceToolScope.storageKey`). They're read once,
    /// when the phone's list doesn't exist yet, and an approval from any of them carries over.
    static let legacyGrantsPrefix = "loopdy.device-tools.v1."

    private(set) var scope: DeviceToolScope?
    private(set) var revision: UInt64 = 0
    private(set) var requestInFlight: DeviceToolCapability?
    private var enabled: Set<DeviceToolCapability> = []
    /// Settings › Device access › "Let agents change how bighelp looks". One switch for every host.
    private(set) var appearanceAllowed: Bool
    /// Settings › Device access › "Let agents show you around bighelp". One switch for every host.
    private(set) var navigationAllowed: Bool
    private var statuses: [DeviceToolCapability: DeviceToolSystemAccess] = [:]
    private let readStatus: (DeviceToolCapability) async -> DeviceToolSystemAccess
    private let requestAccess: (DeviceToolCapability) async -> DeviceToolSystemAccess
    private let isForeground: () -> Bool
    private let writeGrants: (String, [String]) -> Void
    private let saveAppearanceAllowed: (Bool) -> Void
    private let saveNavigationAllowed: (Bool) -> Void
    init(
        status: @escaping (DeviceToolCapability) async -> DeviceToolSystemAccess,
        request: @escaping (DeviceToolCapability) async -> DeviceToolSystemAccess,
        isForeground: @escaping () -> Bool,
        readGrants: @escaping (String) -> [String]?,
        writeGrants: @escaping (String, [String]) -> Void,
        legacyGrants: () -> [[String]] = { [] },
        appearanceAllowed: Bool = true,
        saveAppearanceAllowed: @escaping (Bool) -> Void = { _ in },
        navigationAllowed: Bool = true,
        saveNavigationAllowed: @escaping (Bool) -> Void = { _ in }
    ) {
        readStatus = status
        requestAccess = request
        self.isForeground = isForeground
        self.writeGrants = writeGrants
        self.appearanceAllowed = appearanceAllowed
        self.saveAppearanceAllowed = saveAppearanceAllowed
        self.navigationAllowed = navigationAllowed
        self.saveNavigationAllowed = saveNavigationAllowed
        let saved = readGrants(Self.grantsKey)
        let names = saved ?? legacyGrants().flatMap { $0 }
        enabled = Set(names.compactMap(DeviceToolCapability.init(rawValue:)).filter(\.sharesPersonalData))
        if saved == nil, !enabled.isEmpty { persist() }
    }

    /// The host the phone's channel and calls belong to. Switching retires work in flight; the
    /// switches stay, since they're the phone's.
    func bind(_ scope: DeviceToolScope?) {
        guard self.scope != scope else { return }
        revision &+= 1
        self.scope = scope
    }

    /// The person's switch: on until they turn it off.
    func isEnabled(_ kind: DeviceToolCapability) -> Bool {
        switch kind {
        case .appearance: appearanceAllowed
        case .navigation: navigationAllowed
        default: enabled.contains(kind)
        }
    }

    /// Whether an agent can use it now: the switch is on, a computer is connected, and iOS allows it.
    func isUsable(_ kind: DeviceToolCapability) -> Bool {
        scope != nil && isEnabled(kind) && (!kind.sharesPersonalData || status(for: kind) == .available)
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

    /// Like Appearance: no iOS permission, and the switch alone decides.
    func setNavigationAllowed(_ allowed: Bool) {
        guard allowed != navigationAllowed else { return }
        revision &+= 1
        navigationAllowed = allowed
        saveNavigationAllowed(allowed)
    }

    private func setAllowed(_ allowed: Bool, for kind: DeviceToolCapability) {
        if kind == .navigation { setNavigationAllowed(allowed) } else { setAppearanceAllowed(allowed) }
    }

    /// Retires in-flight work without changing the user's saved choices.
    func invalidateOperations() { revision &+= 1 }

    /// Refresh never prompts, never creates an app grant from an existing OS grant, and never turns a
    /// switch off: iOS saying no (Location Services off for a moment, access taken back in Settings)
    /// only pauses the tool until iOS allows it again. A change for a switch that's on retires work
    /// started under the old answer and reopens the phone's channel with or without the tool.
    func refresh() async {
        for kind in DeviceToolCapability.allCases where kind.sharesPersonalData {
            guard requestInFlight != kind else { continue }
            let owner = revision
            let value = await readStatus(kind)
            guard revision == owner, requestInFlight != kind else { continue }
            let previous = statuses[kind]
            statuses[kind] = value
            if isEnabled(kind), let previous, previous != value { revision &+= 1 }
        }
    }

    /// Synchronous revocation also invalidates operations awaiting OS callbacks.
    func disable(_ kind: DeviceToolCapability) {
        guard kind.sharesPersonalData else { setAllowed(false, for: kind); return }
        revision &+= 1
        choices &+= 1
        enabled.remove(kind)
        persist()
    }

    func setEnabled(_ enabled: Bool, for kind: DeviceToolCapability) async {
        guard enabled else { disable(kind); return }
        guard kind.sharesPersonalData else { setAllowed(true, for: kind); return }
        guard isForeground(), requestInFlight == nil, !isEnabled(kind) else { return }
        let choice = choices
        requestInFlight = kind
        defer { requestInFlight = nil }
        let value = await requestAccess(kind)
        // Only the person changing a switch meanwhile undoes it; the switch is the phone's, so a host
        // switch during the question doesn't.
        guard choices == choice else { return }
        statuses[kind] = value
        guard value == .available else { return }
        self.enabled.insert(kind)
        revision &+= 1
        choices &+= 1
        persist()
    }

    /// Counts the person's own switch changes, so a late iOS answer can't undo one.
    private var choices: UInt64 = 0

    private func persist() {
        writeGrants(Self.grantsKey, enabled.map(\.rawValue).sorted())
    }
}
