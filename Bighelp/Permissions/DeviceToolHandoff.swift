import Foundation
import Observation
import SwiftUI
import UIKit

/// A phone tool call that has to leave bighelp for a moment and come back with its answer
/// (`shortcuts.run` opens Shortcuts, which runs the shortcut and opens bighelp again).
///
/// Staying in the background past its grace normally retires every phone-tool call and stops the
/// phone's channel (`RootShellView`, `runNativeDeviceTools`, the coordinator's `available()`). While a
/// handoff is active, bighelp counts as open for the phone tools: the call, the channel and its grants stay.
/// Everything else still cancels the call as before: the switch turning off, a host or chat change,
/// signing out, and the person locking the phone (protected data).
///
/// A handoff ends on the callback, a cancel, the deadline, iOS taking its background time back, or
/// the call being retired. After a callback it keeps counting as open for a few seconds more, because
/// bighelp's scene is still `.inactive` for a moment after Shortcuts opens it, and the call checks
/// that it may deliver its answer (`authorize`) straight after.
@MainActor
@Observable
final class DeviceToolHandoff {
    /// The one handoff the app uses. Tests make their own.
    static let shared = DeviceToolHandoff()

    /// The agent's tool call waits 60 seconds at most.
    static let deadline: Duration = .seconds(60)
    /// How long bighelp keeps counting as open after a callback.
    static let returnGrace: Duration = .seconds(5)
    /// A longer value from Shortcuts is cut here; the tool caps what it hands the agent far lower.
    static let maximumValueLength = 20_000
    /// A callback bigger than this is ignored whole.
    static let maximumCallbackLength = 2_000_000

    /// The part of a callback URL that says how the other app ended.
    enum CallbackKind: String, Sendable { case success, cancel, error }

    /// What came back, with the URL's query values decoded and bounded. Never logged.
    struct Callback: Equatable, Sendable {
        let kind: CallbackKind
        let parameters: [String: String]
    }

    enum Outcome: Equatable, Sendable {
        case callback(Callback)
        /// No callback by the deadline, or iOS took the background time back first.
        case timedOut
        /// The call was cancelled, or `isStillWanted` said no (switch off, host or chat changed).
        case retired
        /// The other app could not be opened. Nothing ran.
        case notOpened
        /// Another handoff is already out.
        case busy
    }

    /// True while a handoff is out, and for the return grace after its callback. Observed, so views and
    /// `nativeDeviceToolTrigger` follow it.
    private(set) var isActive = false

    /// Asks iOS for background time. Returns what ends it; the expiry runs if iOS takes the time back.
    typealias BackgroundTime = @MainActor (_ onExpire: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    /// Keeps the host socket open. Returns what lets go.
    typealias ConnectionHold = @MainActor () -> (@MainActor () -> Void)

    private struct Current {
        let id: UUID
        let tool: String
        var continuation: CheckedContinuation<Outcome, Never>?
        var tasks: [Task<Void, Never>] = []
        let endBackgroundTime: @MainActor () -> Void
        let releaseConnection: @MainActor () -> Void
    }

    @ObservationIgnored private var current: Current?
    @ObservationIgnored private var returnTask: Task<Void, Never>?
    @ObservationIgnored private let backgroundTime: BackgroundTime
    @ObservationIgnored private let holdConnection: ConnectionHold
    @ObservationIgnored private let graceDuration: Duration

    init(backgroundTime: @escaping BackgroundTime = DeviceToolHandoff.liveBackgroundTime,
         holdConnection: @escaping ConnectionHold = { BighelpShortcutService.holdHostConnection() },
         returnGrace: Duration = DeviceToolHandoff.returnGrace) {
        self.backgroundTime = backgroundTime
        self.holdConnection = holdConnection
        self.graceDuration = returnGrace
    }

    /// True from going to the background until the background grace ends (`BighelpBackgroundGrace`),
    /// unless bighelp comes back first. Observed, so the phone's channel follows it.
    private(set) var isInBackgroundGrace = false

    // MARK: Reading the app's state

    /// Whether bighelp counts as open for the phone tools' channel. Inactive is open: a notification
    /// pulled down, Control Center or a system question leave bighelp on screen. The background is
    /// open only for the grace after leaving, and through a handoff's trip to another app.
    func isOpen(_ phase: ScenePhase) -> Bool { isActive || isInBackgroundGrace || phase != .background }

    /// The same for the coordinator's `available()`, which reads the app's state.
    func isAppOpen(_ state: UIApplication.State) -> Bool { isActive || isInBackgroundGrace || state != .background }

    /// A quick trip away keeps the phone tools, like the host connection: until the grace ends.
    func holdBackgroundGrace() { isInBackgroundGrace = true }

    /// Back in bighelp, or the grace ran out.
    func releaseBackgroundGrace() { isInBackgroundGrace = false }

    // MARK: Running a handoff

    /// Starts a handoff for `runID`, calls `open` to leave for the other app, and waits for its
    /// callback. `isStillWanted` is checked about four times a second; when it turns false the
    /// handoff ends as `.retired`. Cancelling the calling task ends it the same way.
    func perform(
        tool: String, runID: UUID,
        timeout: Duration = DeviceToolHandoff.deadline,
        pollEvery: Duration = .milliseconds(250),
        isStillWanted: @escaping @MainActor () -> Bool,
        open: @escaping @MainActor () async -> Bool
    ) async -> Outcome {
        guard current == nil else { return .busy }
        guard !Task.isCancelled else { return .retired }
        returnTask?.cancel()
        returnTask = nil
        let endBackground = backgroundTime { [weak self] in
            // iOS wants its time back: the process is about to be frozen, so the wait ends here.
            self?.finish(runID, .timedOut)
        }
        current = Current(id: runID, tool: tool, endBackgroundTime: endBackground,
                          releaseConnection: holdConnection())
        isActive = true
        let deadline = ContinuousClock.now.advanced(by: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                // Same actor and no suspension since `current` was set: it is still this run.
                current?.continuation = continuation
                let watcher = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: pollEvery)
                        guard !Task.isCancelled, let self, self.current?.id == runID else { return }
                        if ContinuousClock.now >= deadline { self.finish(runID, .timedOut); return }
                        if !isStillWanted() { self.finish(runID, .retired); return }
                    }
                }
                let opener = Task { @MainActor [weak self] in
                    if await open() == false { self?.finish(runID, .notOpened) }
                }
                current?.tasks = [watcher, opener]
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(runID, .retired) }
        }
    }

    /// Ends the handoff for `id`. Anything for an unknown or finished run is ignored.
    private func finish(_ id: UUID, _ outcome: Outcome) {
        guard let run = current, run.id == id else { return }
        current = nil
        run.tasks.forEach { $0.cancel() }
        run.releaseConnection()
        run.endBackgroundTime()
        if case .callback = outcome {
            returnTask?.cancel()
            let grace = graceDuration
            returnTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled, let self, self.current == nil else { return }
                self.isActive = false
            }
        } else {
            isActive = false
        }
        run.continuation?.resume(returning: outcome)
    }

    /// Ends the return grace now. The call that got the callback uses it for its last checks; when
    /// one of them refuses (retired in the meantime), nothing is left to use it, so the app stops
    /// counting as open at once. A handoff still out is not touched.
    func endReturnGrace() {
        guard current == nil else { return }
        returnTask?.cancel()
        returnTask = nil
        isActive = false
    }

    // MARK: Callbacks

    /// The URL the other app opens for `tool` when it ends as `kind`. The run's UUID is in the path,
    /// before any query, so it is not touched when the other app appends its own parameters.
    static func callbackURL(tool: String, kind: CallbackKind, runID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = "loopdy"
        components.host = Self.callbackHost
        components.path = "/\(tool)/\(kind.rawValue)/\(runID.uuidString.lowercased())"
        return components.url
    }

    static let callbackHost = "device-tool"

    /// Takes a `loopdy://device-tool/…` URL. True for every URL of that shape, so the app never
    /// reads one as a screen to open; the callback reaches a handoff only if its run is still out,
    /// for the same tool.
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard Self.isCallback(url) else { return false }
        guard url.absoluteString.utf8.count <= Self.maximumCallbackLength,
              let parsed = Self.parse(url), let run = current,
              run.id == parsed.runID, run.tool == parsed.tool else { return true }
        finish(parsed.runID, .callback(parsed.callback))
        return true
    }

    static func isCallback(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "loopdy" || scheme == "app.loopdy.mobile") && url.host?.lowercased() == callbackHost
    }

    private struct Parsed {
        let tool: String
        let runID: UUID
        let callback: Callback
    }

    private static func parse(_ url: URL) -> Parsed? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == 3 else { return nil }
        // An app that appends `&result=…` to a URL with no `?` puts it on the last segment.
        var strayQuery: String?
        if let ampersand = segments[2].firstIndex(of: "&") {
            strayQuery = String(segments[2][segments[2].index(after: ampersand)...])
            segments[2] = String(segments[2][..<ampersand])
        }
        guard let kind = CallbackKind(rawValue: segments[1]),
              segments[2].utf8.count == 36, let runID = UUID(uuidString: segments[2]) else { return nil }
        var parameters: [String: String] = [:]
        for query in [components.percentEncodedQuery, strayQuery].compactMap({ $0 }) {
            for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = decode(String(parts[0]))
                guard !name.isEmpty, parameters[name] == nil else { continue }
                let value = parts.count > 1 ? decode(String(parts[1])) : ""
                parameters[name] = String(value.prefix(maximumValueLength))
            }
        }
        return Parsed(tool: segments[0], runID: runID, callback: Callback(kind: kind, parameters: parameters))
    }

    /// Percent-decoding that never fails: bytes that are not UTF-8 become replacement characters.
    /// A plus sign stays a plus sign; Shortcuts encodes spaces as %20.
    static func decode(_ encoded: String) -> String {
        var bytes: [UInt8] = []
        var iterator = encoded.utf8.makeIterator()
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        while let byte = iterator.next() {
            guard byte == 37 else { bytes.append(byte); continue }
            // Keep a stray % as it is rather than losing the rest.
            var rest = iterator
            if let high = rest.next().flatMap(hex), let low = rest.next().flatMap(hex) {
                bytes.append(high << 4 | low)
                iterator = rest
            } else {
                bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: iOS

    /// iOS gives a few seconds to a few tens of seconds in the background; the expiry fires if it
    /// takes them back before the callback. The Mac does not suspend the app, and it would not quit
    /// while a background task ran (as in `BighelpBackgroundGrace`).
    static let liveBackgroundTime: BackgroundTime = { onExpire in
        guard !BighelpPlatform.isMac else { return {} }
        let task = LiveBackgroundTask()
        task.identifier = UIApplication.shared.beginBackgroundTask(withName: "bighelp phone tool") {
            MainActor.assumeIsolated {
                // Give the time back first, so a late callback is not held up by it.
                task.end()
                onExpire()
            }
        }
        return { task.end() }
    }

    @MainActor
    private final class LiveBackgroundTask {
        var identifier: UIBackgroundTaskIdentifier = .invalid

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}
