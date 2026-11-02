import Foundation
import Observation
import CryptoKit
import os

/// The order here is the order of Settings › Device access.
enum DeviceToolCapability: String, CaseIterable, Codable, Identifiable, Sendable {
    case health, calendar, reminders, contacts, photos, location, geofences, alarms, music, focus, shortcuts, appearance, navigation
    var id: String { rawValue }

    /// The plugin feature a host must list before the phone offers this tool.
    /// Older plugins reject an unknown name in the channel's `enabled` list.
    var pluginFeature: String? {
        switch self {
        // Every plugin with phone tools has Health: 2.3.0 took it out of the app only.
        case .health, .calendar, .reminders: nil
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
        case .health:
            return AppleDeviceToolService.isHealthDataAvailable
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
        case .health: String(localized: "Apple Health")
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
        // App Review 5.1.3(i): the exact kinds of Health data an agent can read.
        case .health: String(localized: "Read only. Your agent can read steps, distance, active and resting energy, flights climbed, exercise and stand time, sleep, heart rate, resting and walking heart rate, heart rate variability, blood oxygen, breathing rate, blood pressure, height, weight, body mass index, lean body mass, body fat, and workouts.")
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

    var systemImage: String {
        switch self {
        case .health: "heart.fill"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .photos: "photo.on.rectangle"
        case .location: "location.fill"
        case .geofences: "mappin.and.ellipse"
        case .alarms: "alarm"
        case .music: "music.note"
        case .focus: "moon.fill"
        case .shortcuts: "square.stack.3d.up.fill"
        case .appearance: "circle.lefthalf.filled"
        case .navigation: "hand.point.up.left"
        }
    }

    /// The connect card's one line about what the agent gets once the switch is on.
    var cardLine: String {
        switch self {
        case .health: String(localized: "Your agent can read your Health data, like sleep, steps, and heart rate. It never changes it.")
        case .calendar: String(localized: "Your agent can see, add, change, and delete events in your calendars.")
        case .reminders: String(localized: "Your agent can see, add, change, and delete your reminders.")
        case .contacts: String(localized: "Your agent can look up, add, change, and delete people in your contacts.")
        case .photos: String(localized: "Your agent can find and look at your photos, and save pictures it makes.")
        case .location: String(localized: "Your agent can see where you are when it asks, while bighelp is open.")
        case .geofences: String(localized: "Your agent hears from bighelp when you arrive at or leave places you name.")
        case .alarms: String(localized: "Your agent can set, change, and turn off alarms and timers.")
        case .music: String(localized: "Your agent can see what's playing, play and pause music, and make playlists.")
        case .focus: String(localized: "Your agent can see when a Focus is on, with the note you set for it.")
        case .shortcuts: String(localized: "Your agent can run the shortcut you name here and get what it returns.")
        case .appearance, .navigation: detail
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
    /// Where the person's yes to Apple Health's sharing note is saved: asked once, before the first grant.
    static let healthSharingKey = "bighelp.device-tools.health-sharing"
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
    /// The person read where Health data goes (their computer and its AI provider) and agreed, once.
    private(set) var healthSharingAgreed: Bool
    private var statuses: [DeviceToolCapability: DeviceToolSystemAccess] = [:]
    private let readStatus: (DeviceToolCapability) async -> DeviceToolSystemAccess
    private let requestAccess: (DeviceToolCapability) async -> DeviceToolSystemAccess
    private let isForeground: () -> Bool
    private let writeGrants: (String, [String]) -> Void
    private let saveAppearanceAllowed: (Bool) -> Void
    private let saveNavigationAllowed: (Bool) -> Void
    private let saveHealthSharingAgreed: (Bool) -> Void
    /// How long one iOS status read may take. The phone's channel opens after a refresh, so a framework
    /// that never answers (HealthKit's daemon stuck, say) must not hold up every other tool.
    private let statusDeadline: TimeInterval
    private static let log = Logger(subsystem: "app.loopdy.mobile", category: "DeviceTools")
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
        saveNavigationAllowed: @escaping (Bool) -> Void = { _ in },
        healthSharingAgreed: Bool = false,
        saveHealthSharingAgreed: @escaping (Bool) -> Void = { _ in },
        statusDeadline: TimeInterval = 3
    ) {
        readStatus = status
        requestAccess = request
        self.isForeground = isForeground
        self.writeGrants = writeGrants
        self.appearanceAllowed = appearanceAllowed
        self.saveAppearanceAllowed = saveAppearanceAllowed
        self.navigationAllowed = navigationAllowed
        self.saveNavigationAllowed = saveNavigationAllowed
        self.healthSharingAgreed = healthSharingAgreed
        self.saveHealthSharingAgreed = saveHealthSharingAgreed
        self.statusDeadline = statusDeadline
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

    /// The sharing note's Continue. Health's switch can't turn on before it.
    func agreeToHealthSharing() {
        guard !healthSharingAgreed else { return }
        healthSharingAgreed = true
        saveHealthSharingAgreed(true)
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
            let read = readStatus
            guard let value = try? await DeviceLocationDeadline.run(seconds: statusDeadline, { await read(kind) }) else {
                // No answer in time: keep what was known, and ask again at the next refresh.
                Self.log.notice("\(kind.rawValue, privacy: .public) status didn't answer in time")
                continue
            }
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

    /// Turning a switch on reopens the phone's channel, so the host hears the tool is on. A connect card
    /// passes `reopensChannel: false`: its channel already offers the tool, and the call that asked is
    /// still waiting on it for the answer.
    func setEnabled(_ enabled: Bool, for kind: DeviceToolCapability, reopensChannel: Bool = true) async {
        guard enabled else { disable(kind); return }
        guard kind.sharesPersonalData else { setAllowed(true, for: kind); return }
        guard isForeground(), requestInFlight == nil, !isEnabled(kind) else { return }
        guard kind != .health || healthSharingAgreed else { return }
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
        if reopensChannel { revision &+= 1 }
        choices &+= 1
        persist()
    }

    /// Counts the person's own switch changes, so a late iOS answer can't undo one.
    private var choices: UInt64 = 0

    private func persist() {
        writeGrants(Self.grantsKey, enabled.map(\.rawValue).sorted())
    }
}
