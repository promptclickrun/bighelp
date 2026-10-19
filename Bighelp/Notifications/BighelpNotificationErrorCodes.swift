import Foundation
import os

/// Every way notification setup can stop, with a short code people can send us
/// (docs/NOTIFICATION_ERROR_CODES.md). A code never changes meaning once shipped:
/// add a new one instead. Hundreds say where it stopped:
/// 1 bighelp's notification service, 2 this device, 3 the computer,
/// 4 notification permissions (grants), 5 turning off and Set Up Again, 9 other.
/// Network problems name the service they couldn't reach, whatever step it was;
/// the step is in the copied details.
enum BighelpNotificationErrorCode: String, CaseIterable, Codable, Sendable {
    // MARK: 1 bighelp's notification service
    case offline = "NS-101"
    case serviceUnreachable = "NS-102"
    case serviceTimedOut = "NS-103"
    case serviceInsecure = "NS-104"
    case serviceAnswerUnreadable = "NS-105"
    case serviceProblem = "NS-106"
    case serviceBusy = "NS-107"
    case networkProblem = "NS-108"
    case serviceRequestRefused = "NS-109"
    case serviceRefusedUnknown = "NS-110"
    case signUpKeyConflict = "NS-111"
    case signUpRepeated = "NS-112"
    case signUpClockWrong = "NS-113"
    case signUpRateLimited = "NS-114"
    case signUpUnavailable = "NS-115"
    case signUpKeyRejected = "NS-116"
    case signInRejected = "NS-117"
    case signUpEnded = "NS-118"
    case signatureRejected = "NS-119"
    case requestRepeated = "NS-120"
    case oldSignUpNotRemoved = "NS-121"
    case pushCleanupUnavailable = "NS-122"

    // MARK: 2 this device
    case permissionOff = "NS-201"
    case permissionRequestFailed = "NS-202"
    case apnsRegistrationFailed = "NS-203"
    case apnsTimedOut = "NS-204"
    case apnsTokenMissing = "NS-205"
    case pushRegistrationFailed = "NS-206"
    case pushSubscriptionUnconfirmed = "NS-207"
    case alertChoicesNotMoved = "NS-208"
    case pushRegistrationUnfinished = "NS-209"
    case pushSignInLost = "NS-210"
    case pushServiceUnreachable = "NS-211"
    case pushSignInRefused = "NS-212"
    case pushServiceAnswerUnreadable = "NS-213"
    case pushServiceNotStarted = "NS-214"
    case pushKeyMissing = "NS-215"
    case pushAddressInvalid = "NS-216"
    case pushEnvironmentChanged = "NS-217"
    case pushEnvironmentUnknown = "NS-218"
    case demoMode = "NS-219"
    case providerNotReady = "NS-220"
    case pushSubscriberUnknown = "NS-221"
    case pushSubscriberUnverified = "NS-222"
    case noPushCredential = "NS-223"
    case pushDeviceUnmatched = "NS-224"
    case pushDeviceDisabled = "NS-225"
    case pushDeviceInactive = "NS-226"
    case pushWrongEnvironment = "NS-227"
    case pushTopicsIncomplete = "NS-228"
    case pushSubscriptionMismatch = "NS-229"
    case pushCheckFailed = "NS-230"
    case pushServiceOutOfReach = "NS-231"
    case pushServiceDataUnreadable = "NS-232"
    case pushRecordsMismatch = "NS-233"
    case pushRegistrationsAmbiguous = "NS-234"
    case pushServiceNotConfigured = "NS-235"
    case keychainUnavailable = "NS-240"
    case savedSetupDamaged = "NS-241"
    case saveFailed = "NS-242"
    case loadFailed = "NS-243"

    // MARK: 3 the computer
    case computerNotConnected = "NS-301"
    case computerConnectionFailed = "NS-302"
    case computerTimedOut = "NS-303"
    case computerInsecure = "NS-304"
    case computerAnswerUnreadable = "NS-305"
    case hermesProblem = "NS-306"
    case computerBusy = "NS-307"
    case computerSignInRefused = "NS-308"
    case notificationRoutesMissing = "NS-309"
    case computerSignInChanged = "NS-310"
    case pluginRefusedUnknown = "NS-311"
    case pluginRequestRefused = "NS-312"
    case pluginReleaseUnavailable = "NS-320"
    case duplicatePlugins = "NS-321"
    case earlierInstallUnfinished = "NS-322"
    case pluginInstallUnsupported = "NS-323"
    case pluginInstallNotAllowed = "NS-324"
    case pluginRejected = "NS-325"
    case pluginChangeRefused = "NS-326"
    case pluginInstallMayBeRunning = "NS-327"
    case pluginInstallUnconfirmed = "NS-328"
    case pluginNotTurnedOn = "NS-329"
    case restartHermes = "NS-330"
    case pluginTooOld = "NS-331"
    case computerCannotReachService = "NS-340"
    case computerRedirected = "NS-341"
    case computerServiceAnswerUnreadable = "NS-342"
    case serviceRefusedComputer = "NS-343"
    case grantKeyMismatchOnComputer = "NS-344"
    case grantUnreadableOnComputer = "NS-345"
    case grantExpiredOnComputer = "NS-346"
    case enrollmentLimit = "NS-347"
    case enrollmentConflict = "NS-348"
    case privateStorageRequired = "NS-349"
    case platformUnsupported = "NS-350"
    case computerKeyDamaged = "NS-351"
    case enrollmentInactive = "NS-352"
    case enrollmentChanged = "NS-353"
    case recipientKeyRefused = "NS-354"
    case chatScopeRefused = "NS-355"
    case chatAlertsRefused = "NS-356"
    case claimMismatch = "NS-360"
    case enrollmentChangedDuringCheck = "NS-361"
    case recipientKeyUnconfirmed = "NS-362"
    case chatAlertsUnconfirmed = "NS-363"

    // MARK: 4 notification permissions (grants)
    case grantRetryConflict = "NS-401"
    case grantLimit = "NS-402"
    case grantUnknown = "NS-403"
    case grantChanged = "NS-404"
    case grantSenderConflict = "NS-405"
    case grantClockWrong = "NS-406"
    case grantInactive = "NS-407"
    case oldSignUpKind = "NS-408"
    case oldAccountRetired = "NS-409"
    case computerKeyChanged = "NS-420"
    case oldGrantNotRemoved = "NS-421"
    case manyOldGrants = "NS-422"
    case manyMatchingGrants = "NS-423"
    case grantDiffersFromSaved = "NS-424"
    case savedGrantRequestDamaged = "NS-425"
    case newGrantDiffers = "NS-426"
    case grantFailedChecks = "NS-427"
    case grantBelongsToOtherComputer = "NS-428"
    case earlierRemovalPending = "NS-429"

    // MARK: 5 turning off, and Set Up Again
    case turnOffServiceUnreachable = "NS-501"
    case turnOffUnconfirmed = "NS-502"
    case turnOffRefused = "NS-503"
    case turnOffPhoneDataFailed = "NS-504"
    case turnOffInterrupted = "NS-505"
    case setUpAgainComputerKeptCopy = "NS-510"
    case setUpAgainServiceKeptGrant = "NS-511"
    case setUpAgainCouldNotListGrants = "NS-512"
    case setUpAgainCouldNotClearPhone = "NS-513"

    // MARK: 9 other
    case interrupted = "NS-901"
    case alreadyRunning = "NS-902"
    case appProblem = "NS-903"
    case unexpected = "NS-999"

    private static let turnOff = "Turn off notifications at the bottom of Settings › Notifications, then turn them on again."
    private static let setUpAgain = "Use Set Up Again."
    private static let updateApp = "Update bighelp."
    private static let sendUs = "If it still happens, send us this code and its details."
    /// The system this device runs, which registers it for notifications.
    private static var system: String {
        #if targetEnvironment(macCatalyst)
        "macOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        "iOS"
        #endif
    }

    /// Where notification and clock settings live on this device.
    private static var settingsApp: String {
        #if targetEnvironment(macCatalyst)
        "System Settings"
        #elseif os(visionOS)
        "Settings"
        #else
        "iOS Settings"
        #endif
    }

    /// What happened and what to try, in plain words. Never tells someone to try again
    /// when that can't help (`canRetry`).
    var message: String {
        switch self {
        case .offline: "This device is offline. Connect to Wi-Fi or mobile data, then try again."
        case .serviceUnreachable:
            "bighelp can't reach its notification service from this device. Check that this device is online and that no VPN or DNS filter blocks it, then try again."
        case .serviceTimedOut: "bighelp's notification service took too long to answer. Wait a minute, then try again."
        case .serviceInsecure:
            "This device couldn't make a secure connection to bighelp's notification service. Check the device's date and time, and turn off any VPN or filter that inspects web traffic. Then try again."
        case .serviceAnswerUnreadable:
            "bighelp's notification service sent an answer bighelp can't read. If this Wi-Fi has a sign-in page, sign in with Safari first, or use another network. Then try again."
        case .serviceProblem: "bighelp's notification service has a problem right now. Try again later."
        case .serviceBusy: "bighelp's notification service is busy. Wait a few minutes, then try again."
        case .networkProblem: "A network problem stopped setup. Check this device's connection, then try again."
        case .serviceRequestRefused:
            "bighelp's notification service doesn't accept a request from this version of bighelp. \(Self.updateApp) \(Self.sendUs)"
        case .serviceRefusedUnknown:
            "bighelp's notification service turned down a step for a reason this version of bighelp doesn't know. \(Self.updateApp) \(Self.sendUs)"
        case .signUpKeyConflict:
            "bighelp's notification service already has a different key for this device. \(Self.turnOff)"
        case .signUpRepeated: "bighelp's notification service got the same sign-up twice. Try again."
        case .signUpClockWrong, .grantClockWrong:
            "This device's clock is wrong. In \(Self.settingsApp), go to General › Date & Time and turn on Set Automatically. Then try again."
        case .signUpRateLimited: "This network made too many notification sign-ups in the last hour. Wait one hour, then try again."
        case .signUpUnavailable: "bighelp's notification service can't take new sign-ups right now. Try again later."
        case .signUpKeyRejected:
            "bighelp's notification service didn't accept this device's new key. \(Self.updateApp) \(Self.sendUs)"
        case .signInRejected:
            "bighelp's notification service didn't accept this device's sign-in. Usually this device's clock is wrong: in \(Self.settingsApp), go to General › Date & Time and turn on Set Automatically. Then try again."
        case .signUpEnded: "bighelp's notification service ended this device's notification sign-up. \(Self.turnOff)"
        case .signatureRejected: "bighelp's notification service didn't accept this device's notification key. \(Self.turnOff)"
        case .requestRepeated: "bighelp's notification service got the same request twice. Try again."
        case .oldSignUpNotRemoved:
            "bighelp's notification service didn't confirm that it removed this device's old sign-up. Try again later."
        case .pushCleanupUnavailable:
            "bighelp's notification service couldn't finish removing this device from the push service. Try again later."

        case .permissionOff:
            "Notifications for bighelp are off. In \(Self.settingsApp), go to Notifications › bighelp and turn on Allow Notifications. Then try again."
        case .permissionRequestFailed: "\(Self.system) didn't answer when bighelp asked to send notifications. Try again."
        case .apnsRegistrationFailed:
            "\(Self.system) couldn't register this device for notifications. Check that the device is online and signed in to your Apple Account, then try again. Restarting the device can help."
        case .apnsTimedOut: "\(Self.system) took too long to register this device for notifications. Check the device's connection, then try again."
        case .apnsTokenMissing: "\(Self.system) didn't give bighelp this device's notification address. Try again."
        case .pushRegistrationFailed: "The push service couldn't register this device. Wait a minute, then try again."
        case .pushSubscriptionUnconfirmed: "The push service didn't confirm this device's registration. Try again."
        case .alertChoicesNotMoved: "bighelp couldn't move your saved alert choices to the push service. Try again."
        case .pushRegistrationUnfinished: "This device's registration didn't finish before bighelp checked it. Try again."
        case .pushSignInLost: "This device's sign-in with the push service stopped during setup. Try again."
        case .pushServiceUnreachable:
            "bighelp can't reach the push service from this device. Check that this device is online and that no VPN or DNS filter blocks it, then try again."
        case .pushSignInRefused: "The push service didn't accept this device's sign-in. Wait a minute, then try again."
        case .pushServiceAnswerUnreadable: "The push service sent an answer bighelp can't read. Try again later."
        case .pushServiceNotStarted: "The push service didn't start in bighelp. Quit bighelp and open it again."
        case .pushKeyMissing, .pushAddressInvalid:
            "This copy of bighelp can't use notifications. Install bighelp from the App Store or TestFlight."
        case .pushEnvironmentChanged: "bighelp changed how it gets notifications. Quit bighelp and open it again."
        case .pushEnvironmentUnknown:
            "bighelp doesn't know which push service to use. Quit bighelp and open it again. \(Self.sendUs)"
        case .demoMode: "Notifications don't work in demo mode."
        case .providerNotReady: "bighelp's notification service isn't ready to send notifications right now. Try again later."
        case .pushSubscriberUnknown: "The push service doesn't know this device yet. Wait a minute, then try again."
        case .pushSubscriberUnverified: "The push service hasn't confirmed this device's sign-in yet. Wait a minute, then try again."
        case .noPushCredential:
            "bighelp's notification service can't send to this kind of bighelp build right now. Try again later. \(Self.sendUs)"
        case .pushDeviceUnmatched: "The push service has a different notification address for this device. Try again."
        case .pushDeviceDisabled:
            "The push service has notifications turned off for this device. Check that notifications for bighelp are on in \(Self.settingsApp), then try again."
        case .pushDeviceInactive: "The push service marked this device as inactive. Try again."
        case .pushWrongEnvironment:
            "The push service has this device registered for another kind of bighelp build (TestFlight or App Store). Try again."
        case .pushTopicsIncomplete: "The push service doesn't have every alert type for this device yet. Wait a minute, then try again."
        case .pushSubscriptionMismatch: "The push service confirmed a different registration for this device. Try again."
        case .pushCheckFailed: "The push service's check of this device didn't pass. Wait a minute, then try again."
        case .pushServiceOutOfReach: "bighelp's notification service can't reach the push service right now. Try again later."
        case .pushServiceDataUnreadable:
            "bighelp's notification service got an answer from the push service that it can't use. Try again later."
        case .pushRecordsMismatch: "The push service's records for this device don't match. Try again."
        case .pushRegistrationsAmbiguous: "The push service has more than one registration for this device. \(Self.turnOff)"
        case .pushServiceNotConfigured:
            "bighelp's notification service isn't set up to use the push service right now. Try again later. \(Self.sendUs)"
        case .keychainUnavailable: "bighelp couldn't open this device's keychain. Unlock the device, then try again."
        case .savedSetupDamaged: "bighelp's saved notification setup on this device is damaged. \(Self.turnOff)"
        case .saveFailed: "bighelp couldn't save notification setup on this device. Check that the device has free space, then try again."
        case .loadFailed: "bighelp couldn't load notification setup on this device. Quit bighelp and open it again."

        case .computerNotConnected:
            "bighelp can't reach this computer. Check that the computer is on and Hermes is running, then try again."
        case .computerConnectionFailed:
            "bighelp lost the connection to this computer. Check the computer's address, your VPN or Tailscale, and that Hermes is running. Then try again."
        case .computerTimedOut: "This computer took too long to answer. Try again."
        case .computerInsecure: "bighelp couldn't check this computer's secure connection. Check the computer's HTTPS certificate, then try again."
        case .computerAnswerUnreadable:
            "This computer sent an answer bighelp can't read. Update the bighelp plugin on the computer, then try again."
        case .hermesProblem: "Hermes on this computer had a problem. Look in Hermes' logs, then try again."
        case .computerBusy: "This computer is getting too many requests. Wait a minute, then try again."
        case .computerSignInRefused: "This computer didn't accept bighelp's sign-in. Sign in to this computer again, then try again."
        case .notificationRoutesMissing:
            "This computer doesn't have the notification part of the bighelp plugin. Update the plugin and restart Hermes, then try again."
        case .computerSignInChanged: "This computer's sign-in changed. Sign in to this computer again, then try again."
        case .pluginRefusedUnknown:
            "The bighelp plugin on this computer turned down a step. Update the plugin, then try again. \(Self.sendUs)"
        case .pluginRequestRefused:
            "The bighelp plugin on this computer doesn't accept a request from this version of bighelp. Update bighelp and the plugin. \(Self.sendUs)"
        case .pluginReleaseUnavailable:
            "bighelp couldn't reach GitHub to get the newest bighelp plugin. Check this device's internet connection, then try again."
        case .duplicatePlugins: "This computer has more than one bighelp plugin. Remove the extra one in Hermes, then try again."
        case .earlierInstallUnfinished:
            "An earlier plugin install on this computer didn't finish. Use Set Up Again in Settings › Notifications."
        case .pluginInstallUnsupported:
            "This version of Hermes can't install plugins for bighelp. Update Hermes, or install the bighelp plugin on the computer. Then try again."
        case .pluginInstallNotAllowed:
            "This computer doesn't let bighelp install plugins. Allow it in Hermes, or install the bighelp plugin on the computer. Then try again."
        case .pluginRejected: "Hermes on this computer refused the bighelp plugin. Look in Hermes for the reason, then try again."
        case .pluginChangeRefused: "Hermes on this computer refused to change its plugins. Look in Hermes for the reason, then try again."
        case .pluginInstallMayBeRunning: "The plugin install may still be running on this computer. Wait a minute, then try again."
        case .pluginInstallUnconfirmed:
            "This computer didn't confirm the plugin install. Try again. If it still happens, use Set Up Again."
        case .pluginNotTurnedOn: "The bighelp plugin didn't turn on. Turn it on in Hermes, then try again."
        case .restartHermes:
            "Restart Hermes on this computer (the hermes serve process, not only the messaging gateway), then try again."
        case .pluginTooOld: "The bighelp plugin on this computer is too old for notifications. Update the plugin, then try again."
        case .computerCannotReachService:
            "This computer can't reach bighelp's notification service. Check the computer's internet connection and that no firewall blocks it, then try again."
        case .computerRedirected:
            "This computer's network sent its connection to bighelp's notification service somewhere else. Check the computer's proxy settings, then try again."
        case .computerServiceAnswerUnreadable:
            "This computer got an answer from bighelp's notification service that it can't read. Check the computer's network and proxy, then try again."
        case .serviceRefusedComputer: "bighelp's notification service turned down this computer's request. \(Self.setUpAgain)"
        case .grantKeyMismatchOnComputer: "This device's notification permission doesn't match this computer's key. \(Self.setUpAgain)"
        case .grantUnreadableOnComputer: "This computer got a notification permission it can't read. Try again later."
        case .grantExpiredOnComputer:
            "This computer says the notification permission ran out. Check that the computer's clock is right, then use Set Up Again."
        case .enrollmentLimit: "This computer already sends notifications to the most devices it can. Send us this code and its details."
        case .enrollmentConflict: "This computer has a different copy of this device's notification permission. \(Self.setUpAgain)"
        case .privateStorageRequired:
            "The bighelp plugin can't keep its notification files private on this computer. Check the permissions of Hermes' home folder, then try again."
        case .platformUnsupported:
            "Hermes on this computer runs on a system that bighelp notifications don't support yet. Send us this code and its details."
        case .computerKeyDamaged: "The bighelp plugin's notification key on this computer is damaged. Send us this code and its details."
        case .enrollmentInactive: "This computer doesn't have this device's notification permission anymore. \(Self.setUpAgain)"
        case .enrollmentChanged: "This computer's copy of this device's notification permission changed. \(Self.setUpAgain)"
        case .recipientKeyRefused: "This computer didn't accept this device's alert key. \(Self.updateApp) \(Self.sendUs)"
        case .chatScopeRefused: "This computer refused alerts for the open chat's agent. \(Self.setUpAgain)"
        case .chatAlertsRefused: "This computer couldn't turn on alerts for the open chat. Try again."
        case .claimMismatch: "This computer confirmed a different notification permission. \(Self.setUpAgain)"
        case .enrollmentChangedDuringCheck: "This computer's notification setup changed while bighelp checked it. Try again."
        case .recipientKeyUnconfirmed: "This computer didn't confirm this device's alert key. Try again."
        case .chatAlertsUnconfirmed: "This computer didn't confirm alerts for the open chat. Try again."

        case .grantRetryConflict:
            "bighelp's notification service has an earlier try with different details for this computer. \(Self.setUpAgain)"
        case .grantLimit:
            "This device has too many notification permissions, or two of them conflict. \(Self.setUpAgain) \(Self.sendUs)"
        case .grantUnknown: "bighelp's notification service doesn't know this computer's notification permission. \(Self.setUpAgain)"
        case .grantChanged: "The notification permission changed while bighelp updated it. Try again."
        case .grantSenderConflict:
            "Another notification permission already uses this computer's key with bighelp's notification service. \(Self.setUpAgain)"
        case .grantInactive: "This computer's notification permission isn't active anymore. \(Self.setUpAgain)"
        case .oldSignUpKind: "This device's notification sign-up is from an older version of bighelp. \(Self.turnOff)"
        case .oldAccountRetired: "This device's notification sign-up uses a kind of sign-in that bighelp retired. \(Self.turnOff)"
        case .computerKeyChanged: "This computer's notification key changed since this device was set up. \(Self.setUpAgain)"
        case .oldGrantNotRemoved:
            "bighelp's notification service didn't confirm that it removed an old notification permission. Try again."
        case .manyOldGrants: "This computer has more than one old notification permission. \(Self.setUpAgain)"
        case .manyMatchingGrants: "This computer has more than one notification permission for this device. \(Self.setUpAgain)"
        case .grantDiffersFromSaved: "The notification permission doesn't match the one saved on this device. \(Self.setUpAgain)"
        case .savedGrantRequestDamaged:
            "The notification permission request saved on this device is damaged or out of date. \(Self.setUpAgain)"
        case .newGrantDiffers: "The new notification permission doesn't match what bighelp asked for. \(Self.setUpAgain)"
        case .grantFailedChecks: "The notification permission didn't pass bighelp's checks. \(Self.setUpAgain)"
        case .grantBelongsToOtherComputer:
            "This notification permission belongs to another computer on this device. \(Self.setUpAgain)"
        case .earlierRemovalPending: "An earlier change to notifications isn't finished. Wait a minute, then try again."

        case .turnOffServiceUnreachable:
            "Notifications aren't fully off yet, because bighelp can't reach its notification service. Check this device's connection, then try again."
        case .turnOffUnconfirmed:
            "Notifications aren't fully off yet, because bighelp's notification service didn't confirm. Try again later."
        case .turnOffRefused:
            "Notifications aren't fully off yet, because bighelp's notification service turned down the request. Try again. \(Self.sendUs)"
        case .turnOffPhoneDataFailed:
            "Notifications aren't fully off yet, because bighelp couldn't delete their data on this device. Unlock the device, then try again."
        case .turnOffInterrupted: "Turning off notifications stopped before it finished. Try again."
        case .setUpAgainComputerKeptCopy:
            "Set Up Again couldn't reach this computer to delete its old copy. bighelp tries again later. The old copy can't send anything."
        case .setUpAgainServiceKeptGrant:
            "Set Up Again couldn't remove the old notification permission from bighelp's notification service. bighelp tries again later."
        case .setUpAgainCouldNotListGrants:
            "Set Up Again couldn't check bighelp's notification service for old notification permissions. The next setup replaces them."
        case .setUpAgainCouldNotClearPhone: "Set Up Again couldn't clear this computer's old setup on this device. The next setup replaces it."

        case .interrupted: "Setup stopped because something changed while it ran. Try again."
        case .alreadyRunning: "Setup is already running for this computer. Wait for it to finish."
        case .appProblem: "bighelp hit a problem of its own. \(Self.updateApp) \(Self.sendUs)"
        case .unexpected: "Something unexpected stopped setup. Try again. \(Self.sendUs)"
        }
    }

    /// Whether the next step is trying again, now, later or after the fix the message names.
    /// False when the way forward is something else: Set Up Again, turning notifications
    /// off and on, updating bighelp, or sending us the code.
    var canRetry: Bool {
        switch self {
        case .serviceRequestRefused, .serviceRefusedUnknown, .signUpKeyConflict, .signUpKeyRejected, .signUpEnded,
             .signatureRejected,
             .pushServiceNotStarted, .pushKeyMissing, .pushAddressInvalid, .pushEnvironmentChanged, .pushEnvironmentUnknown,
             .demoMode, .pushRegistrationsAmbiguous, .savedSetupDamaged, .loadFailed,
             .pluginRequestRefused, .earlierInstallUnfinished, .serviceRefusedComputer, .grantKeyMismatchOnComputer,
             .grantExpiredOnComputer, .enrollmentLimit, .enrollmentConflict, .platformUnsupported, .computerKeyDamaged,
             .enrollmentInactive, .enrollmentChanged, .recipientKeyRefused, .chatScopeRefused, .claimMismatch,
             .grantRetryConflict, .grantLimit, .grantUnknown, .grantSenderConflict, .grantInactive, .oldSignUpKind,
             .oldAccountRetired, .computerKeyChanged, .manyOldGrants, .manyMatchingGrants, .grantDiffersFromSaved,
             .savedGrantRequestDamaged, .newGrantDiffers, .grantFailedChecks, .grantBelongsToOtherComputer,
             .setUpAgainComputerKeptCopy, .setUpAgainServiceKeptGrant, .setUpAgainCouldNotListGrants,
             .setUpAgainCouldNotClearPhone, .appProblem:
            false
        default:
            true
        }
    }

}

/// Where setup was when it stopped.
enum BighelpNotificationSetupStep: String, Codable, Sendable, CaseIterable {
    case pluginCheck, pluginRelease, pluginInstall, pluginEnable
    case serviceSignUp, pushSignIn, permission, pushRegistration, pushCheck
    case computerCheck, serviceGrant, computerEnroll
    case contextCheck, savingSetup, loadingSetup, startingSetup
    case turnOff, setUpAgain

    var title: String {
        switch self {
        case .pluginCheck: "Checking the plugin on the computer"
        case .pluginRelease: "Finding the newest plugin"
        case .pluginInstall: "Installing the plugin"
        case .pluginEnable: "Turning on the plugin"
        case .serviceSignUp: "Signing up with the notification service"
        case .pushSignIn: "Signing in to the push service"
        case .permission: "Asking iOS for permission"
        case .pushRegistration: "Registering this device for push"
        case .pushCheck: "Checking this device's push registration"
        case .computerCheck: "Checking notification support on the computer"
        case .serviceGrant: "Making the notification permission"
        case .computerEnroll: "Giving the permission to the computer"
        case .contextCheck: "Checking that nothing changed"
        case .savingSetup: "Saving setup on this device"
        case .loadingSetup: "Loading setup on this device"
        case .startingSetup: "Starting notification setup"
        case .turnOff: "Turning off notifications"
        case .setUpAgain: "Set Up Again"
        }
    }

    fileprivate enum Peer { case notificationService, computer, phone, github }

    fileprivate var peer: Peer {
        switch self {
        case .pluginCheck, .pluginInstall, .pluginEnable, .computerCheck, .computerEnroll: .computer
        case .pluginRelease: .github
        case .permission, .pushRegistration, .contextCheck, .savingSetup, .loadingSetup: .phone
        case .serviceSignUp, .pushSignIn, .pushCheck, .serviceGrant, .startingSetup, .turnOff, .setUpAgain: .notificationService
        }
    }
}

/// What went wrong underneath, kept only in words safe to log and copy: error types, numbers
/// and our own services' short error codes. Never an address, a name, a token or text a
/// computer or service wrote.
indirect enum BighelpNotificationErrorKind: Equatable, Sendable {
    case network(Int)
    case service(status: Int, code: String)
    case serviceAnswer
    case serviceConfiguration
    case computer(status: Int, code: String)
    case computerRestart
    case computerFeatureMissing
    case hermes(DirectHermesError)
    case provider(BighelpManagedNotificationSetupError)
    case cancelled
    case decoding
    case cocoa(Int)
    case savedKeyUnreadable
    /// The keychain said no (an OSStatus).
    case keychain(Int)
    /// A computer's alert-signing key didn't read.
    case senderKeyInvalid
    /// One of bighelp's own checks, by name.
    case check(String)
    /// An error type bighelp doesn't sort, by type name.
    case other(String)
    /// A failure from an earlier run, as it was saved.
    case saved(String)

    init(_ error: any Error) {
        switch error {
        case let failure as BighelpNotificationSetupFailure: self = failure.kind
        case let error as URLError: self = .network(error.errorCode)
        case let error as BighelpLinkAPIError:
            switch error {
            case .requestFailed(let status, let code): self = .service(status: status, code: Self.safe(code))
            case .invalidResponse: self = .serviceAnswer
            case .invalidConfiguration: self = .serviceConfiguration
            }
        case let error as DirectHostNotificationError:
            switch error {
            case .backendRestartRequired: self = .computerRestart
            case .featureUnavailable: self = .computerFeatureMissing
            case .rejected(let status, let code): self = .computer(status: status, code: Self.safe(code))
            }
        case let error as DirectHermesError: self = .hermes(error)
        case let error as BighelpManagedNotificationSetupError: self = .provider(error)
        case is CancellationError: self = .cancelled
        case is DecodingError: self = .decoding
        case is BighelpLinkCryptoError: self = .savedKeyUnreadable
        case let error as BighelpRelayTrustError:
            if case .keychain(let status) = error { self = .keychain(Int(status)) } else { self = .senderKeyInvalid }
        default:
            let bridged = error as NSError
            switch bridged.domain {
            case NSURLErrorDomain: self = .network(bridged.code)
            case NSCocoaErrorDomain: self = .cocoa(bridged.code)
            default: self = .other(String(describing: type(of: error)))
            }
        }
    }

    /// A server's error code as we copy it: our services' codes are short lowercase words.
    /// Anything else (an identifier, an address, free text) becomes "unrecognized".
    static func safe(_ code: String) -> String {
        let segments = code.split(separator: "_", omittingEmptySubsequences: false)
        guard !code.isEmpty, code.utf8.count <= 80, code.utf8.first.map({ (97...122).contains($0) }) == true,
              code.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
              segments.allSatisfy({ !$0.isEmpty && $0.count <= 24 && $0.filter(\.isNumber).count <= 4 }) else {
            return "unrecognized"
        }
        return code
    }

    var description: String {
        switch self {
        case .network(let code): "URLError \(code)"
        case .service(let status, let code): "Notification service HTTP \(status) \(code)"
        case .serviceAnswer: "Notification service answer unreadable"
        case .serviceConfiguration: "Notification service request invalid"
        case .computer(let status, let code): "Plugin HTTP \(status) \(code)"
        case .computerRestart: "Plugin notification routes missing (HTTP 404)"
        case .computerFeatureMissing: "Plugin feature missing"
        case .hermes(let error): "DirectHermesError.\(Self.name(error))"
        case .provider(let error):
            "Push \(error.stage.rawValue) \(error.code.map(Self.safe) ?? "none")"
                + (error.underlying.map { " (\($0.description))" } ?? "")
        case .cancelled: "CancellationError"
        case .decoding: "DecodingError"
        case .cocoa(let code): "CocoaError \(code)"
        case .savedKeyUnreadable: "Saved key unreadable"
        case .keychain(let status): "Keychain \(status)"
        case .senderKeyInvalid: "Computer alert key unreadable"
        case .check(let name): "Check \(name)"
        case .other(let type): type
        case .saved(let description): description
        }
    }

    /// The case alone: `rpcRejected` keeps Hermes' number, never its words.
    private static func name(_ error: DirectHermesError) -> String {
        switch error {
        case .rpcRejected(let code, _): "rpcRejected(\(code))"
        case .disconnected(let unknown): "disconnected(outcomeUnknown: \(unknown))"
        case .timedOut(let unknown): "timedOut(outcomeUnknown: \(unknown))"
        case .cancelled(let unknown): "cancelled(outcomeUnknown: \(unknown))"
        case .webPageInsteadOfHermes(let cloudflare): "webPageInsteadOfHermes(throughCloudflare: \(cloudflare))"
        default: String(describing: error)
        }
    }
}

/// A notification setup failure, named where it happened.
struct BighelpNotificationSetupFailure: Error, Equatable, Sendable {
    let code: BighelpNotificationErrorCode
    let step: BighelpNotificationSetupStep
    let kind: BighelpNotificationErrorKind
    /// Where setup stands after it: the same state the underlying error always left, so
    /// naming a failure never changes what setup does next.
    let state: HostNotificationState

    init(_ code: BighelpNotificationErrorCode, step: BighelpNotificationSetupStep,
         kind: BighelpNotificationErrorKind, state: HostNotificationState) {
        self.code = code; self.step = step; self.kind = kind; self.state = state
    }

    /// An error from `step`, sorted by what it is. A failure already named passes through.
    init(step: BighelpNotificationSetupStep, error: any Error) {
        if let named = error as? Self { self = named; return }
        let kind = BighelpNotificationErrorKind(error)
        self.init(BighelpNotificationErrorCode.sorting(kind, at: step), step: step, kind: kind,
                  state: Self.state(after: error))
    }

    /// One of bighelp's own checks failed where it used to throw `was`.
    init(_ code: BighelpNotificationErrorCode, step: BighelpNotificationSetupStep, check: String,
         was error: any Error) {
        self.init(code, step: step, kind: .check(check), state: Self.state(after: error))
    }

    var message: String { code.message }
    var canRetry: Bool { code.canRetry }

    /// A push service failure: its own (danger) tone in setup.
    var provider: BighelpManagedNotificationSetupError? {
        if case .provider(let error) = kind { return error }
        return nil
    }

    /// The state each kind of error has always left setup in.
    static func state(after error: any Error) -> HostNotificationState {
        if let named = error as? Self { return named.state }
        if error is BighelpManagedNotificationSetupError { return .prerequisitesRequired }
        if let linkError = error as? BighelpLinkAPIError, case let .requestFailed(_, code) = linkError,
           ["not_found", "device_credentials_missing", "notification_service_unavailable",
            "notification_mobile_required", "notification_recipient_unavailable",
            "notification_recipient_changed"].contains(code) {
            return .prerequisitesRequired
        }
        guard let error = error as? DirectHermesError else { return .outcomeUnknown }
        switch error {
        case .notConnected: return .notConnected
        case .identityChanged: return .signInChanged
        case .rpcRejected(code: -32601, _): return .unsupported
        case .rpcRejected(code: 403, _): return .permissionDenied
        case .rpcRejected(code: 5026, _): return .managementRejected
        default: return .outcomeUnknown
        }
    }

    private static let log = Logger(subsystem: "app.loopdy.mobile", category: "NotificationSetup")

    /// One line per failure: the code, the step and the kind, nothing that names a person,
    /// a computer or a sign-in.
    func log() {
        Self.log.error("Setup stopped: \(code.rawValue, privacy: .public) at \(step.rawValue, privacy: .public) (\(kind.description, privacy: .public))")
    }
}

extension BighelpNotificationErrorCode {
    /// The code for `kind` when it stops `step`.
    static func sorting(_ kind: BighelpNotificationErrorKind, at step: BighelpNotificationSetupStep) -> Self {
        if step == .pluginRelease { return kind == .cancelled ? .interrupted : .pluginReleaseUnavailable }
        if step == .turnOff { return turnOff(kind) }
        let computer = step.peer == .computer
        switch kind {
        case .network(let code): return computer ? computerNetwork(code) : serviceNetwork(code)
        case .service(let status, let code): return service(status: status, code: code)
        case .serviceAnswer: return .serviceAnswerUnreadable
        case .serviceConfiguration: return .appProblem
        case .computer(_, let code): return plugin(code)
        case .computerRestart: return .restartHermes
        case .computerFeatureMissing: return .pluginTooOld
        case .hermes(let error): return hermes(error, at: step)
        case .provider(let error): return provider(error, at: step)
        case .cancelled: return .interrupted
        case .decoding:
            return computer ? .computerAnswerUnreadable : step.peer == .phone ? .savedSetupDamaged : .serviceAnswerUnreadable
        case .cocoa(let code):
            if code == CocoaError.Code.fileReadNoPermission.rawValue { return .keychainUnavailable }
            return step == .loadingSetup ? .loadFailed : .saveFailed
        case .savedKeyUnreadable: return .savedSetupDamaged
        case .keychain: return .keychainUnavailable
        case .senderKeyInvalid: return .grantFailedChecks
        case .check, .other, .saved: return .unexpected
        }
    }

    private static func serviceNetwork(_ code: Int) -> Self {
        switch URLError.Code(rawValue: code) {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: .offline
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .resourceUnavailable:
            .serviceUnreachable
        case .timedOut: .serviceTimedOut
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            .serviceInsecure
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData,
             .httpTooManyRedirects, .redirectToNonExistentLocation, .zeroByteResource, .dataLengthExceedsMaximum:
            .serviceAnswerUnreadable
        case .cancelled: .interrupted
        case .badURL, .unsupportedURL: .appProblem
        default: .networkProblem
        }
    }

    private static func computerNetwork(_ code: Int) -> Self {
        switch serviceNetwork(code) {
        case .serviceTimedOut: .computerTimedOut
        case .serviceInsecure: .computerInsecure
        case .serviceAnswerUnreadable: .computerAnswerUnreadable
        case .interrupted: .interrupted
        case .appProblem: .appProblem
        default: .computerConnectionFailed
        }
    }

    /// Codes that only say the request itself was malformed: this version of bighelp sent
    /// something the notification service doesn't take. The exact code is in the details.
    static let serviceRequestCodes: Set<String> = [
        "notification_request_invalid", "notification_method_invalid", "notification_path_invalid",
        "notification_body_too_large", "notification_route_unknown", "not_found", "notification_bootstrap_invalid",
        "notification_key_invalid", "notification_proof_invalid", "notification_grant_invalid",
        "notification_device_readback_invalid", "notification_device_readback_required", "notification_test_invalid",
        "buzzkit_device_token_hash_invalid",
    ]

    /// The notification service's own codes, each with its own app code.
    static let serviceCodes: [String: Self] = [
        "notification_bootstrap_conflict": .signUpKeyConflict,
        "notification_bootstrap_replayed": .signUpRepeated,
        "notification_bootstrap_stale": .signUpClockWrong,
        "notification_bootstrap_rate_limited": .signUpRateLimited,
        "notification_bootstrap_rate_unavailable": .signUpUnavailable,
        "notification_bootstrap_proof_invalid": .signUpKeyRejected,
        "notification_credentials_invalid": .signInRejected,
        "notification_credentials_revoked": .signUpEnded,
        "notification_signature_invalid": .signatureRejected,
        "notification_nonce_replayed": .requestRepeated,
        "notification_revocation_unconfirmed": .oldSignUpNotRemoved,
        "notification_cleanup_unavailable": .pushCleanupUnavailable,
        "buzzkit_transport_unavailable": .pushServiceOutOfReach,
        "buzzkit_response_invalid": .pushServiceDataUnreadable,
        "buzzkit_response_too_large": .pushServiceDataUnreadable,
        "buzzkit_subscriber_invalid": .pushServiceDataUnreadable,
        "buzzkit_topic_invalid": .pushServiceDataUnreadable,
        "buzzkit_readback_mismatch": .pushRecordsMismatch,
        "buzzkit_device_subscription_ambiguous": .pushRegistrationsAmbiguous,
        "buzzkit_identity_generation_unconfigured": .pushServiceNotConfigured,
        "buzzkit_tenant_invalid": .pushServiceNotConfigured,
        "buzzkit_api_url_invalid": .pushServiceNotConfigured,
        "notification_idempotency_conflict": .grantRetryConflict,
        "notification_grant_limit_or_conflict": .grantLimit,
        "notification_grant_unknown": .grantUnknown,
        "notification_revision_stale": .grantChanged,
        "notification_sender_grant_conflict": .grantSenderConflict,
        "notification_grant_expiry_invalid": .grantClockWrong,
        "notification_grant_inactive": .grantInactive,
        "notification_mobile_required": .oldSignUpKind,
        "notification_account_scope_retired": .oldAccountRetired,
    ]

    private static func service(status: Int, code: String) -> Self {
        if let known = serviceCodes[code] { return known }
        if serviceRequestCodes.contains(code) { return .serviceRequestRefused }
        if status >= 500 { return .serviceProblem }
        if status == 429 { return .serviceBusy }
        return .serviceRefusedUnknown
    }

    /// The plugin's own codes (`ManagedNotificationError` in bighelp-plugin).
    static let pluginCodes: [String: Self] = [
        "notification_service_unavailable": .computerCannotReachService,
        "notification_redirect_rejected": .computerRedirected,
        "notification_response_invalid": .computerServiceAnswerUnreadable,
        "notification_response_too_large": .computerServiceAnswerUnreadable,
        "notification_remote_rejected": .serviceRefusedComputer,
        "notification_grant_identity_mismatch": .grantKeyMismatchOnComputer,
        "notification_grant_invalid": .grantUnreadableOnComputer,
        "notification_grant_expired": .grantExpiredOnComputer,
        "notification_enrollment_limit": .enrollmentLimit,
        "notification_enrollment_conflict": .enrollmentConflict,
        "notification_private_storage_required": .privateStorageRequired,
        "notification_platform_unavailable": .platformUnsupported,
        "notification_identity_invalid": .computerKeyDamaged,
        "notification_enrollment_inactive": .enrollmentInactive,
        "notification_enrollment_changed": .enrollmentChanged,
        "notification_recipient_key_invalid": .recipientKeyRefused,
        "notification_scope_forbidden": .chatScopeRefused,
        "notification_session_unknown": .chatAlertsRefused,
        "notification_session_unavailable": .chatAlertsRefused,
        "notification_session_forbidden": .chatAlertsRefused,
        "notification_session_limit": .chatAlertsRefused,
        "notification_session_not_subscribed": .chatAlertsRefused,
        "notification_coordinate_invalid": .pluginRequestRefused,
        "notification_path_invalid": .pluginRequestRefused,
        "notification_preferences_invalid": .pluginRequestRefused,
    ]

    private static func plugin(_ code: String) -> Self { pluginCodes[code] ?? .pluginRefusedUnknown }

    private static func hermes(_ error: DirectHermesError, at step: BighelpNotificationSetupStep) -> Self {
        let computer = step.peer == .computer || step.peer == .github
        switch error {
        case .notConnected: return .computerNotConnected
        case .connectionFailed, .disconnected, .redirectRefused, .hostNameRefused, .webPageInsteadOfHermes,
             .invalidEndpoint, .plaintextNotAllowed:
            return computer ? .computerConnectionFailed : .serviceUnreachable
        case .timedOut: return computer ? .computerTimedOut : .serviceTimedOut
        case .tlsRequired: return computer ? .computerInsecure : .serviceInsecure
        case .invalidResponse, .messageTooLarge:
            return computer ? .computerAnswerUnreadable : step.peer == .phone ? .appProblem : .serviceAnswerUnreadable
        case .serverUnavailable: return computer ? .hermesProblem : .serviceProblem
        case .rateLimited: return computer ? .computerBusy : .serviceBusy
        case .unsupportedAuthentication: return computer ? .notificationRoutesMissing : .appProblem
        case .invalidCredentials, .authenticationRequired, .authModeChanged, .ambiguousPasswordProvider,
             .invalidAccessCredentials, .cloudflareAccessDenied, .nativeTokenExchangeUncertain,
             .browserAuthenticationUnavailable:
            return computer ? .computerSignInRefused : .appProblem
        case .identityChanged: return .computerSignInChanged
        case .secureStorageUnavailable: return .keychainUnavailable
        case .savedConnectionInvalid: return .savedSetupDamaged
        case .secureStorageChanged, .cancelled: return .interrupted
        case .tooManyRequests: return .alreadyRunning
        case .rpcRejected(code: -32601, _): return .pluginInstallUnsupported
        case .rpcRejected(code: 403, _): return .pluginInstallNotAllowed
        case .rpcRejected(code: 5026, _): return .pluginRejected
        case .rpcRejected: return .pluginChangeRefused
        case .activeSessionLimit: return .unexpected
        }
    }

    /// The push service's diagnostic codes (`BighelpBuzzKitRuntime`), each with its own app code.
    static let providerCodes: [String: Self] = [
        "notification_permission_required": .permissionOff,
        "identity_provider_permission_denied": .permissionOff,
        "permission_request_failed": .permissionRequestFailed,
        "apns_registration_failed": .apnsRegistrationFailed,
        "apns_token_wait_timed_out": .apnsTimedOut,
        "current_apns_token_readback_required": .apnsTokenMissing,
        "buzzkit_device_registration_failed": .pushRegistrationFailed,
        "buzzkit_subscription_registration_failed": .pushSubscriptionUnconfirmed,
        "buzzkit_preference_migration_failed": .alertChoicesNotMoved,
        "buzzkit_registration_required": .pushRegistrationUnfinished,
        "buzzkit_identity_required": .pushSignInLost,
        "identity_provider_unreachable": .pushServiceUnreachable,
        "identity_provider_rejected": .pushSignInRefused,
        "identity_provider_not_identified": .pushSignInRefused,
        "identity_provider_invalid_response": .pushServiceAnswerUnreadable,
        "identity_provider_not_configured": .pushServiceNotStarted,
        "buzzkit_client_key_missing": .pushKeyMissing,
        "buzzkit_api_url_invalid": .pushAddressInvalid,
        "buzzkit_push_environment_changed": .pushEnvironmentChanged,
        "buzzkit_push_environment_unavailable": .pushEnvironmentUnknown,
        "buzzkit_sdk_not_awaitable": .appProblem,
        "offline_fixture": .demoMode,
        "test_sdk_not_configured": .demoMode,
        "readiness_provider_not_configured": .providerNotReady,
        "readiness_subscriber_unidentified": .pushSubscriberUnknown,
        "readiness_subscriber_unverified": .pushSubscriberUnverified,
        "readiness_device_unmatched": .pushDeviceUnmatched,
        "readiness_device_push_disabled": .pushDeviceDisabled,
        "readiness_device_inactive": .pushDeviceInactive,
        "readiness_device_wrong_environment": .pushWrongEnvironment,
        "readiness_topics_incomplete": .pushTopicsIncomplete,
        "readiness_subscription_mismatch": .pushSubscriptionMismatch,
        "identity_invalid_response": .serviceAnswerUnreadable,
        "readiness_invalid_response": .serviceAnswerUnreadable,
        "identity_decode_failed": .serviceAnswerUnreadable,
        "readiness_decode_failed": .serviceAnswerUnreadable,
        "identity_invalid_configuration": .appProblem,
        "readiness_invalid_configuration": .appProblem,
        "identity_connection_failed": .serviceUnreachable,
        "identity_request_timed_out": .serviceTimedOut,
        "identity_auth_failed": .signInRejected,
        "identity_server_unavailable": .serviceProblem,
    ]

    private static func provider(_ error: BighelpManagedNotificationSetupError,
                                 at step: BighelpNotificationSetupStep) -> Self {
        // The real cause underneath (the network, the notification service's answer) names it
        // best. Registering talks to the push service, not bighelp's notification service.
        if let underlying = error.underlying {
            let pushService = error.stage == .deviceRegistration
            switch underlying {
            case .network(let code) where pushService:
                let named = serviceNetwork(code)
                return named == .offline || named == .interrupted ? named : .pushServiceUnreachable
            case .network, .service, .serviceAnswer, .cancelled, .provider:
                let named = sorting(underlying, at: .pushCheck)
                if named != .unexpected { return named }
            case .hermes where !pushService, .decoding where !pushService:
                let named = sorting(underlying, at: .pushCheck)
                if named != .unexpected, named != .appProblem { return named }
            default: break
            }
        }
        if let code = error.code {
            if let known = providerCodes[code] { return known }
            if code.hasPrefix("readiness_no_active_push_credential") { return .noPushCredential }
            if let known = serviceCodes[code] { return known }
            if code.hasPrefix("link_backend_") {
                let parts = code.dropFirst("link_backend_".count).split(separator: "_", maxSplits: 1)
                if parts.count == 2, let status = Int(parts[0]) { return service(status: status, code: String(parts[1])) }
            }
            if code.hasPrefix("identity_provider_") { return .pushSignInRefused }
        }
        return switch error.stage {
        case .providerBootstrap: .pushServiceNotStarted
        case .providerIdentity: .pushSignInRefused
        case .notificationPermission: .permissionOff
        case .deviceRegistration: .pushRegistrationFailed
        case .providerReadiness: .pushCheckFailed
        }
    }

    private static func turnOff(_ kind: BighelpNotificationErrorKind) -> Self {
        switch kind {
        case .network: return .turnOffServiceUnreachable
        case .hermes(let error):
            switch error {
            case .connectionFailed, .disconnected, .timedOut, .tlsRequired, .notConnected: return .turnOffServiceUnreachable
            case .secureStorageUnavailable, .savedConnectionInvalid: return .turnOffPhoneDataFailed
            case .secureStorageChanged, .cancelled: return .turnOffInterrupted
            case .serverUnavailable: return .turnOffUnconfirmed
            default: return .turnOffRefused
            }
        case .service(let status, let code):
            return status >= 500 || ["notification_revocation_unconfirmed", "notification_cleanup_unavailable"].contains(code)
                ? .turnOffUnconfirmed : .turnOffRefused
        case .serviceAnswer, .serviceConfiguration: return .turnOffRefused
        case .cocoa, .decoding, .savedKeyUnreadable, .keychain: return .turnOffPhoneDataFailed
        case .cancelled: return .turnOffInterrupted
        default: return .unexpected
        }
    }
}

/// The last setup failure on this device, for Settings › Notifications › Provider details and
/// for the setup screen after bighelp opens again. Kept only on this device.
struct BighelpNotificationLastFailure: Codable, Equatable, Sendable {
    let code: BighelpNotificationErrorCode
    let step: BighelpNotificationSetupStep
    /// The kind's privacy-safe description.
    let kind: String
    let hostID: UUID?
    /// The setup state it left, as saved with the host.
    let state: HostNotificationState
    let date: Date
    /// The build that saw it: after an update the same failure may not happen again.
    let build: String

    static let key = "bighelp.notifications.last-setup-failure"

    static func load(_ defaults: UserDefaults = .standard) -> Self? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    static func save(_ failure: BighelpNotificationSetupFailure, hostID: UUID?, now: Date = Date(),
                     defaults: UserDefaults = .standard) {
        let record = Self(code: failure.code, step: failure.step, kind: failure.kind.description, hostID: hostID,
                          state: failure.state.saved, date: now, build: BighelpNotificationFailureReport.build)
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: key) }
    }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    var failure: BighelpNotificationSetupFailure {
        BighelpNotificationSetupFailure(code, step: step, kind: .saved(kind), state: state)
    }
}

/// What "Copy Details" copies: only what helps us find the failure, never where or who.
enum BighelpNotificationFailureReport {
    static func text(code: BighelpNotificationErrorCode, step: BighelpNotificationSetupStep, kind: String,
                     app: String = appVersion, system: String = systemVersion) -> String {
        """
        bighelp notification setup
        Code: \(code.rawValue)
        Step: \(step.title) (\(step.rawValue))
        Error: \(kind)
        App: \(app)
        System: \(system)
        """
    }

    static func text(_ failure: BighelpNotificationSetupFailure) -> String {
        text(code: failure.code, step: failure.step, kind: failure.kind.description)
    }

    static func text(_ failure: BighelpNotificationLastFailure) -> String {
        text(code: failure.code, step: failure.step, kind: failure.kind)
    }

    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown" }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(visionOS)
        let name = "visionOS"
        #elseif targetEnvironment(macCatalyst)
        let name = "macOS"
        #else
        let name = "iOS"
        #endif
        return "\(name) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
