import Foundation
import Testing
@testable import Bighelp

@MainActor
struct PermissionCenterTests {
    @Test func locationDisclosureNamesEveryAppleServiceThatReceivesTheCoordinate() {
        let disclosure = PermissionKind.locationWhenInUse.purpose

        #expect(disclosure.contains("Apple Weather"))
        #expect(disclosure.contains("Apple location services"))
        #expect(!disclosure.contains("only"))
    }

    @Test func refreshReadsEveryStatusWithoutRequestingPermission() async {
        let recorder = PermissionClientRecorder()
        let center = PermissionCenter(
            clients: recorder.clients,
            isForeground: { true },
            openSystemSettings: { }
        )

        await center.refresh()

        #expect(recorder.statusKinds == Set(PermissionKind.allCases))
        #expect(recorder.requestKinds.isEmpty)
    }

    @Test func requestsRequireExplicitForegroundActionAndUndeterminedStatus() async {
        let recorder = PermissionClientRecorder()
        var isForeground = false
        let center = PermissionCenter(
            clients: recorder.clients,
            isForeground: { isForeground },
            openSystemSettings: { }
        )
        await center.refresh()

        #expect(await center.request(.notification) == false)
        isForeground = true
        #expect(await center.request(.notification))
        #expect(await center.request(.notification) == false)
        #expect(recorder.requestKinds == [.notification])
    }

    @Test func contextualAccessRefreshesGlobalStatusBeforeRequesting() async {
        let recorder = PermissionClientRecorder()
        recorder.statuses[.camera] = .init(authorization: .denied)
        let center = PermissionCenter(
            clients: recorder.clients,
            isForeground: { true },
            openSystemSettings: { }
        )

        #expect(await center.authorizeContextualAccess(.camera) == false)
        #expect(recorder.requestKinds.isEmpty)

        recorder.statuses[.microphone] = .init(authorization: .notDetermined)
        #expect(await center.authorizeContextualAccess(.microphone))
        #expect(recorder.requestKinds == [.microphone])
    }

    @Test func exposesNotificationAuthorizationAndGranularPresentationSettings() async {
        let recorder = PermissionClientRecorder()
        recorder.statuses[.notification] = PermissionStatus(
            authorization: .provisional,
            notification: NotificationPermissionDetails(
                alert: .enabled,
                sound: .disabled,
                badge: .notSupported
            )
        )
        let center = PermissionCenter(
            clients: recorder.clients,
            isForeground: { true },
            openSystemSettings: { }
        )

        await center.refresh()

        #expect(center.status(for: .notification).authorization == .provisional)
        #expect(center.status(for: .notification).notification?.alert == .enabled)
        #expect(center.status(for: .notification).notification?.sound == .disabled)
        #expect(center.status(for: .notification).notification?.badge == .notSupported)
        #expect(PermissionAuthorizationState.ephemeral.statusTitle == "Ephemeral")
        #expect(PermissionAuthorizationState.denied.statusTitle == "Denied")
        #expect(PermissionAuthorizationState.restricted.statusTitle == "Restricted")
        #expect(PermissionAuthorizationState.authorized.statusTitle == "Allowed")
    }

    @Test func exposesGlobalLocationAvailabilityAndReducedAccuracy() async {
        let recorder = PermissionClientRecorder()
        recorder.statuses[.locationWhenInUse] = PermissionStatus(
            authorization: .authorized,
            location: LocationPermissionDetails(
                servicesEnabled: true,
                accuracy: .reduced
            )
        )
        let center = PermissionCenter(
            clients: recorder.clients,
            isForeground: { true },
            openSystemSettings: { }
        )

        await center.refresh()

        let status = center.status(for: .locationWhenInUse)
        #expect(status.authorization == .authorized)
        #expect(status.location?.servicesEnabled == true)
        #expect(status.location?.accuracy == .reduced)
        #expect(recorder.locationAcquisitionCount == 0)

        recorder.statuses[.locationWhenInUse] = PermissionStatus(
            authorization: .restricted,
            location: LocationPermissionDetails(
                servicesEnabled: false,
                accuracy: .unknown
            )
        )
        await center.refresh()
        #expect(center.recoveryAction(for: .locationWhenInUse) == .openSystemSettings)
    }

    @Test func allowsOnlyOneRequestInFlight() async {
        let recorder = PermissionClientRecorder()
        let deferred = DeferredPermissionStatus()
        recorder.requests[.notification] = { await deferred.value() }
        let center = PermissionCenter(
            clients: recorder.clients,
            isForeground: { true },
            openSystemSettings: { }
        )
        await center.refresh()

        let first = Task { await center.request(.notification) }
        while center.requestInFlight == nil { await Task.yield() }
        #expect(await center.request(.locationWhenInUse) == false)
        deferred.resume(.init(authorization: .authorized))

        #expect(await first.value)
        #expect(recorder.requestKinds == [.notification])
        #expect(center.requestInFlight == nil)
    }

    @Test func ignoresStaleAsyncRefreshCompletion() async {
        let recorder = PermissionClientRecorder()
        let first = DeferredPermissionStatus()
        recorder.statusSequences[.notification] = [
            { await first.value() },
            { PermissionStatus(authorization: .denied) },
        ]
        let center = PermissionCenter(
            clients: recorder.clients,
            isForeground: { true },
            openSystemSettings: { }
        )

        let staleRefresh = Task { await center.refresh() }
        while recorder.statusCallCount[.notification, default: 0] == 0 { await Task.yield() }
        await center.refresh()
        first.resume(.init(authorization: .authorized))
        await staleRefresh.value

        #expect(center.status(for: .notification).authorization == .denied)
    }

    @Test func foregroundRefreshDoesNotCancelAnInFlightPermissionRequest() async {
        let recorder = PermissionClientRecorder()
        let deferred = DeferredPermissionStatus()
        recorder.requests[.notification] = { await deferred.value() }
        let center = PermissionCenter(
            clients: recorder.clients,
            isForeground: { true },
            openSystemSettings: { }
        )
        await center.refresh()

        let request = Task { await center.request(.notification) }
        while center.requestInFlight == nil { await Task.yield() }
        recorder.statuses[.notification] = .init(authorization: .denied)
        await center.refresh()
        deferred.resume(.init(authorization: .authorized))

        #expect(await request.value)
        #expect(center.status(for: .notification).authorization == .authorized)
        #expect(center.requestInFlight == nil)
    }

    @Test func deniedAndRestrictedUseSettingsRecovery() async {
        let recorder = PermissionClientRecorder()
        var openedSettings = 0
        recorder.statuses[.camera] = .init(authorization: .denied)
        recorder.statuses[.microphone] = .init(authorization: .restricted)
        let center = PermissionCenter(
            clients: recorder.clients,
            isForeground: { true },
            openSystemSettings: { openedSettings += 1 }
        )
        await center.refresh()

        #expect(center.recoveryAction(for: .camera) == .openSystemSettings)
        #expect(center.recoveryAction(for: .microphone) == .openSystemSettings)
        center.performRecoveryAction(for: .camera)
        center.performRecoveryAction(for: .microphone)
        #expect(openedSettings == 2)
    }

    @Test func permissionRowsUseActionsInsteadOfWritableToggleSemantics() {
        let undetermined = PermissionRowPresentation(
            kind: .speech,
            status: .init(authorization: .notDetermined)
        )
        let denied = PermissionRowPresentation(
            kind: .camera,
            status: .init(authorization: .denied)
        )
        let authorized = PermissionRowPresentation(
            kind: .microphone,
            status: .init(authorization: .authorized)
        )

        #expect(undetermined.action == .request)
        #expect(denied.action == .openSystemSettings)
        #expect(authorized.action == .none)
        #expect(!undetermined.usesToggleSemantics)
        #expect(undetermined.accessibilityValue == "Not Requested")
        #expect(undetermined.actionTitle == "Allow Speech Recognition")

        let notification = PermissionRowPresentation(
            kind: .notification,
            status: PermissionStatus(
                authorization: .provisional,
                notification: NotificationPermissionDetails(
                    alert: .enabled,
                    sound: .disabled,
                    badge: .notSupported
                )
            )
        )
        #expect(notification.detailText == "Alerts On · Sounds Off · Badges Not Supported")

        for authorization in [
            PermissionAuthorizationState.notDetermined,
            .denied,
            .restricted,
        ] {
            let unavailableLocation = PermissionRowPresentation(
                kind: .locationWhenInUse,
                status: PermissionStatus(
                    authorization: authorization,
                    location: LocationPermissionDetails(
                        servicesEnabled: true,
                        accuracy: .full
                    )
                )
            )
            #expect(unavailableLocation.detailText == "Location Services On")
        }
    }

    @Test func contextualDeniedAndRestrictedPermissionsOfferSettingsRecovery() {
        let denied = ContextualPermissionRecoveryPresentation(
            kind: .microphone,
            status: .init(authorization: .denied)
        )
        let restricted = ContextualPermissionRecoveryPresentation(
            kind: .camera,
            status: .init(authorization: .restricted)
        )

        #expect(denied.message == "Microphone access is denied. You can allow it in iOS Settings.")
        #expect(denied.action == .openSystemSettings)
        #expect(restricted.message == "Camera access is restricted on this device.")
        #expect(restricted.action == .openSystemSettings)
    }
}

@MainActor
private final class PermissionClientRecorder {
    var statuses = Dictionary(
        uniqueKeysWithValues: PermissionKind.allCases.map {
            ($0, PermissionStatus(authorization: .notDetermined))
        }
    )
    var requests: [PermissionKind: @MainActor () async -> PermissionStatus] = [:]
    var statusSequences: [PermissionKind: [@MainActor () async -> PermissionStatus]] = [:]
    private(set) var statusKinds: Set<PermissionKind> = []
    private(set) var requestKinds: [PermissionKind] = []
    private(set) var statusCallCount: [PermissionKind: Int] = [:]
    private(set) var locationAcquisitionCount = 0

    var clients: [PermissionKind: PermissionClient] {
        Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { kind in
            (kind, PermissionClient(
                status: { [self] in
                    statusKinds.insert(kind)
                    statusCallCount[kind, default: 0] += 1
                    if var sequence = statusSequences[kind], !sequence.isEmpty {
                        let next = sequence.removeFirst()
                        statusSequences[kind] = sequence
                        return await next()
                    }
                    return statuses[kind]!
                },
                request: { [self] in
                    requestKinds.append(kind)
                    if let request = requests[kind] { return await request() }
                    let result = PermissionStatus(authorization: .authorized)
                    statuses[kind] = result
                    return result
                }
            ))
        })
    }
}

@MainActor
private final class DeferredPermissionStatus {
    private var continuation: CheckedContinuation<PermissionStatus, Never>?

    func value() async -> PermissionStatus {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ status: PermissionStatus) {
        continuation?.resume(returning: status)
        continuation = nil
    }
}
