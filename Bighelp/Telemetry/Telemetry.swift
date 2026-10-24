import Foundation

/// Where telemetry may run at all. Tests, UI tests and demo mode never send, and
/// neither does a build from Xcode unless the launch argument asks for it.
enum TelemetryEnvironment {
    /// Opt in for a debug build (`-bighelp-telemetry`).
    static let debugOptIn = "-bighelp-telemetry"
    private static let neverSending: Set<String> = [
        "-use-demo-fixtures", "-disable-demo-delays", "-force-signed-out-onboarding", "-native-workspace-acceptance",
    ]

    /// XCTest is loaded into this process.
    static var xctestIsLoaded: Bool { NSClassFromString("XCTestCase") != nil }

    static func allowsSending(arguments: [String] = ProcessInfo.processInfo.arguments,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              isDebugBuild: Bool = TelemetryContext.isDebugBuild,
                              xctestIsLoaded: Bool = TelemetryEnvironment.xctestIsLoaded) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil || environment["BIGHELP_UI_TEST_RUN_ID"] != nil
            || xctestIsLoaded { return false }
        if !neverSending.isDisjoint(with: arguments) { return false }
        if isDebugBuild { return arguments.contains(debugOptIn) }
        return true
    }
}

/// Whether the person has telemetry on (Settings › Device access › Usage and
/// diagnostics). On unless they turned it off.
struct TelemetryPreference: @unchecked Sendable {
    static let key = "bighelp.privacy.telemetry-enabled"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// The app's one door to telemetry. Everything here is cheap, never blocks and does
/// nothing when telemetry is off or isn't allowed (tests, demo).
enum Telemetry {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TelemetryClient?
        private var seen: [Int] = []

        var client: TelemetryClient? { lock.withLock { value } }
        func set(_ client: TelemetryClient?) { lock.withLock { value = client } }

        /// True the first time a key shows up; keys are kept as hashes, bounded, in memory only.
        func isFirst(_ key: String) -> Bool {
            lock.withLock {
                let hash = key.hashValue
                if seen.contains(hash) { return false }
                seen.append(hash)
                if seen.count > 512 { seen.removeFirst(128) }
                return true
            }
        }
    }

    private static let box = Box()

    static var client: TelemetryClient? { box.client }
    static var isActive: Bool { box.client != nil }

    /// Makes the client when this run may send. Call once, early.
    @MainActor
    @discardableResult
    static func bootstrap(preference: TelemetryPreference = TelemetryPreference(),
                          arguments: [String] = ProcessInfo.processInfo.arguments,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          isDebugBuild: Bool = TelemetryContext.isDebugBuild) -> TelemetryClient? {
        guard TelemetryEnvironment.allowsSending(arguments: arguments, environment: environment,
                                                 isDebugBuild: isDebugBuild) else {
            box.set(nil)
            return nil
        }
        let client = TelemetryClient(
            transport: URLSessionTelemetryTransport(), identity: KeychainTelemetryIdentityStore(),
            disk: FileTelemetryDiskStore.standard, context: TelemetryContext.current(),
            isEnabled: preference.isEnabled)
        box.set(client)
        Task { await client.start() }
        return client
    }

    /// For tests: use this client instead of making one.
    static func install(_ client: TelemetryClient?) { box.set(client) }

    static func record(_ event: TelemetryEvent) {
        guard let client = box.client else { return }
        let date = Date()
        Task { await client.record(event, at: date) }
    }

    /// For an event that already happened (a MetricKit report, a push the extension saw).
    static func record(_ event: TelemetryEvent, at date: Date) {
        guard let client = box.client else { return }
        Task { await client.record(event, at: date) }
    }

    static func featureUsed(_ feature: TelemetryFeature) {
        record(.featureUsed(feature))
    }

    /// Counts a feature once per `key` per run (a card drawn again after a scroll is the same card).
    /// The key is only compared in memory; it is never sent or saved.
    static func featureUsedOnce(_ feature: TelemetryFeature, key: String) {
        guard box.client != nil, box.isFirst(feature.rawValue + ":" + key) else { return }
        featureUsed(feature)
    }

    static func flushForBackground() async {
        await box.client?.flushForBackground()
    }
}
