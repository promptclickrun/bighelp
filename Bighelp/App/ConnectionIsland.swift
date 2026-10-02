import SwiftUI
import UIKit

/// What the connection pill shows.
enum ConnectionIslandPhase: Equatable, Sendable {
    case hidden, connecting, reconnecting, connected, disconnected, noInternet

    var isWaiting: Bool { self != .hidden && self != .connected }
}

enum ConnectionIslandRules {
    /// A connection quicker than this shows nothing.
    static let showDelay: Duration = .milliseconds(700)
    /// How long "Connected!" stays before the pill goes away.
    static let connectedHold: Duration = .seconds(1.6)

    /// How long a shown status stays by itself. Only "Connected!" goes: the pill is
    /// the one place that says the connection is down, so that stays until it's back.
    static func hideDelay(after phase: ConnectionIslandPhase) -> Duration? {
        phase == .connected ? connectedHold : nil
    }

    /// What to show next, and how long to wait first (nil: now). `isRecovering`:
    /// the pill has shown the connection was down.
    static func next(from phase: ConnectionIslandPhase, state: WorkspaceConnectionState,
                     hasConnected: Bool, hasNetwork: Bool, isActive: Bool,
                     isRecovering: Bool) -> (phase: ConnectionIslandPhase, after: Duration?) {
        guard isActive else { return (.hidden, nil) }
        switch state {
        case .connected:
            return (phase.isWaiting || isRecovering || phase == .connected ? .connected : .hidden, nil)
        case .reconnecting, .disconnected:
            guard !isRecovering || phase.isWaiting else { return (phase, nil) }
            let target: ConnectionIslandPhase = switch state {
            case .reconnecting: hasConnected ? .reconnecting : .connecting
            default: hasNetwork ? .disconnected : .noInternet
            }
            return (target, phase.isWaiting ? nil : showDelay)
        }
    }
}

/// bighelp closes the host connection soon after you leave and reconnects when
/// you're back. This shows what's happening just under the Dynamic Island,
/// without closing or covering what you had open. (iOS hides an app's own Live
/// Activity while the app is open, so it's drawn here.)
@MainActor
@Observable
final class ConnectionIslandModel {
    private(set) var phase: ConnectionIslandPhase = .hidden
    /// The hardware island in window points, on phones that have one.
    var islandFrame: CGRect?
    @ObservationIgnored private var isRecovering = false
    @ObservationIgnored private var showing: Task<Void, Never>?
    @ObservationIgnored private var hiding: Task<Void, Never>?
    @ObservationIgnored private var isHeldForTesting = false

    /// `hasConnected`: the keeper's word on whether this computer answered yet,
    /// so the island and the chat agree on "Connecting" or "Reconnecting".
    func update(state: WorkspaceConnectionState, hasConnected: Bool, hasNetwork: Bool, isActive: Bool) {
        guard !isHeldForTesting else { return }
        if !isActive { isRecovering = false }
        let next = ConnectionIslandRules.next(from: phase, state: state, hasConnected: hasConnected,
                                              hasNetwork: hasNetwork, isActive: isActive,
                                              isRecovering: isRecovering)
        // A delayed "Reconnecting…" for a blip that's already over.
        showing?.cancel()
        showing = nil
        guard next.phase != phase else { return }
        guard let delay = next.after else { return show(next.phase) }
        showing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.show(next.phase)
        }
    }

    private func show(_ next: ConnectionIslandPhase) {
        hiding?.cancel()
        hiding = nil
        guard next != phase else { return }
        phase = next
        guard next != .hidden else { return }
        UIAccessibility.post(notification: .announcement, argument: next.spokenStatus)
        isRecovering = next != .connected
        if let delay = ConnectionIslandRules.hideDelay(after: next) { hide(after: delay) }
    }

    private func hide(after delay: Duration) {
        let shown = phase
        hiding = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self?.phase == shown else { return }
            self?.phase = .hidden
        }
    }
}

extension ConnectionIslandPhase {
    var spokenStatus: String {
        switch self {
        case .connecting: "Connecting to your computer"
        case .reconnecting: "Reconnecting to your computer"
        case .connected, .hidden: "Connected"
        case .disconnected: "Not connected to your computer"
        case .noInternet: "No internet connection"
        }
    }
}

/// A small Liquid Glass pill right under the Dynamic Island (under the status
/// bar where there isn't one): the shared connection indicator, then its words.
struct ConnectionIslandPill: View {
    let model: ConnectionIslandModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if let status = HostConnectionStatus(island: model.phase) {
                    label(status)
                        .padding(.top, model.islandFrame.map { $0.maxY + 6 }
                                 ?? proxy.safeAreaInsets.top + BighelpTokens.space4)
                        .transition(reduceMotion ? .opacity
                                    : .scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: model.phase)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func label(_ status: HostConnectionStatus) -> some View {
        HStack(spacing: 7) {
            BighelpConnectionIndicator(phase: status.phase)
            Text(status.label)
                .foregroundStyle(.primary)
                .contentTransition(.opacity)
        }
        .font(.bighelp(.footnote).weight(.semibold))
        .lineLimit(1)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .bighelpNavigationGlass(in: Capsule())
        .accessibilityIdentifier("connection.island")
    }
}

extension ConnectionIslandModel {
    static let shared = ConnectionIslandModel()

    #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
    /// "-test-connection-island reconnecting": holds one status on screen for screenshots.
    func showForTesting(_ arguments: [String]) {
        guard let index = arguments.firstIndex(of: "-test-connection-island"),
              arguments.indices.contains(index + 1) else { return }
        let phases: [String: ConnectionIslandPhase] = [
            "connecting": .connecting, "reconnecting": .reconnecting, "connected": .connected,
            "disconnected": .disconnected, "no-internet": .noInternet,
        ]
        guard let phase = phases[arguments[index + 1]] else { return }
        isHeldForTesting = true
        self.phase = phase
    }
    #endif
}

/// Follows the host connection directly rather than through view updates: the
/// root screen doesn't refresh while a chat is pushed over it.
@MainActor
final class ConnectionIslandFollower {
    static let shared = ConnectionIslandFollower()

    private let model = ConnectionIslandModel.shared
    private weak var keeper: WorkspaceConnectionKeeper?
    private var tracking = 0
    private var observers: [NSObjectProtocol] = []

    func follow(_ keeper: WorkspaceConnectionKeeper) {
        self.keeper = keeper
        if observers.isEmpty {
            let center = NotificationCenter.default
            for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { ConnectionIslandFollower.shared.evaluate() }
                })
            }
        }
        evaluate()
    }

    private func evaluate() {
        tracking &+= 1
        let current = tracking
        let (state, connected, network) = withObservationTracking {
            (keeper?.state ?? .connected, keeper?.hasConnected ?? false, keeper?.hasNetwork ?? true)
        } onChange: {
            // Only the latest registration re-arms, so observations never pile up.
            Task { @MainActor in
                guard ConnectionIslandFollower.shared.tracking == current else { return }
                ConnectionIslandFollower.shared.evaluate()
            }
        }
        model.update(state: state, hasConnected: connected, hasNetwork: network,
                     isActive: UIApplication.shared.applicationState == .active)
    }
}

/// Draws the pill above everything. On iPhone and iPad it has its own window,
/// so it shows over sheets and pop-ups too.
struct ConnectionIslandLayer: View {
    var body: some View {
        Group {
            #if os(iOS)
            ConnectionIslandWindowHost(model: .shared)
            #else
            ConnectionIslandPill(model: .shared)
            #endif
        }
        #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
        .task { ConnectionIslandModel.shared.showForTesting(ProcessInfo.processInfo.arguments) }
        #endif
    }
}

#if os(iOS)
/// The pill lives in its own window so it shows over sheets and pop-ups too.
/// The window never takes a touch, is only on screen while the pill is, and
/// takes its light or dark look from the app's window (Settings › Appearance).
private struct ConnectionIslandWindowHost: UIViewRepresentable {
    let model: ConnectionIslandModel

    func makeUIView(context: Context) -> HostView { HostView(model: model) }
    func updateUIView(_ view: HostView, context: Context) {}

    final class HostView: UIView {
        private let model: ConnectionIslandModel
        private var overlay: PassthroughWindow?
        private var hiding: Task<Void, Never>?

        init(model: ConnectionIslandModel) {
            self.model = model
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: HostView, _: UITraitCollection) in
                view.matchAppearance()
            }
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, let scene = window.windowScene else {
                overlay?.isHidden = true
                overlay = nil
                return
            }
            if overlay == nil {
                let overlay = PassthroughWindow(windowScene: scene)
                overlay.windowLevel = .normal + 1
                overlay.backgroundColor = .clear
                let host = IslandHostingController(rootView: ConnectionIslandPill(model: model))
                host.view.backgroundColor = .clear
                host.appWindow = window
                overlay.rootViewController = host
                overlay.isHidden = true
                self.overlay = overlay
                observePhase()
                phaseChanged()
            }
            matchAppearance()
            measureIsland()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            measureIsland()
        }

        /// System, Light or Dark, as the app itself shows right now.
        private func matchAppearance() {
            overlay?.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        }

        private func measureIsland() {
            let frame = DynamicIslandGeometry.frame(in: window)
            if model.islandFrame != frame { model.islandFrame = frame }
        }

        private func observePhase() {
            withObservationTracking { _ = model.phase } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.phaseChanged()
                    self?.observePhase()
                }
            }
        }

        private func phaseChanged() {
            hiding?.cancel()
            if model.phase != .hidden {
                matchAppearance()
                overlay?.isHidden = false
                return
            }
            // Let the pill shrink away before the window goes.
            hiding = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, self?.model.phase == .hidden else { return }
                self?.overlay?.isHidden = true
            }
        }
    }

    final class PassthroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }

    /// Leaves the status bar as the app has it: the pill sits below it.
    final class IslandHostingController: UIHostingController<ConnectionIslandPill> {
        weak var appWindow: UIWindow?

        private var appController: UIViewController? {
            var controller = appWindow?.rootViewController
            while let presented = controller?.presentedViewController { controller = presented }
            return controller
        }

        override var prefersStatusBarHidden: Bool { appController?.prefersStatusBarHidden ?? false }
        override var preferredStatusBarStyle: UIStatusBarStyle { appController?.preferredStatusBarStyle ?? .default }
    }
}
#endif
