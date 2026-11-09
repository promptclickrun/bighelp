import SwiftUI
import UIKit

/// Who is working and on what, for the island.
struct AgentIslandActivity: Equatable {
    let agentID: String
    let name: String
    let imageURL: URL?
    let kind: AgentActivityKind
}

private struct AgentActivityInIslandKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The Dynamic Island shows what the agent is doing, so headers leave out
    /// their own activity badge and label.
    var agentActivityInIsland: Bool {
        get { self[AgentActivityInIslandKey.self] }
        set { self[AgentActivityInIslandKey.self] = newValue }
    }
}

/// Where the app may widen the hardware island into a stage of its own.
enum AgentIslandAvailability {
    /// Only on a phone laid out the ordinary way, where the island is across the top edge.
    ///
    /// The Duo's cameras and status sit in a column on its trailing edge, so the top of the
    /// screen has no island to cover. Drawing one there also reserved space at the top, which
    /// moved every screen and — because the app reads its posture from the measured size — came
    /// back round as a posture change: the stage shook the whole UI open. `BighelpStripTabs`
    /// carries the agent on those screens instead.
    static func isShown(isPhone: Bool, posture: BighelpScreenPosture) -> Bool {
        isPhone && posture == .standard
    }
}

enum DynamicIslandGeometry {
    /// The hardware island's frame in window points, when this phone has one.
    @MainActor
    static func frame(in window: UIWindow?) -> CGRect? {
        guard UIDevice.current.userInterfaceIdiom == .phone, let window,
              window.windowScene?.interfaceOrientation.isPortrait != false else { return nil }
        // No island of our own on the iPhone Duo: its camera and status sit in a column on the
        // trailing edge, so there is nothing across the top to cover. Reserving top space there
        // moved every screen — and because the posture this app lays itself out by comes from
        // the measured size, the reservation fed back into the posture: the whole UI shook while
        // the stage was open. The strip carries the agent instead (see `BighelpStripTabs`).
        // A window that hasn't settled reports neither size class: wait for it rather than guess.
        guard let horizontal = Self.sizeClass(window.traitCollection.horizontalSizeClass),
              let vertical = Self.sizeClass(window.traitCollection.verticalSizeClass) else { return nil }
        let posture = BighelpScreenPosture.classify(isPhone: true, horizontal: horizontal, vertical: vertical,
                                                    size: window.bounds.size)
        guard AgentIslandAvailability.isShown(isPhone: true, posture: posture) else { return nil }
        let top = window.safeAreaInsets.top
        // Notch phones report 44–50 pt; island phones 54 pt and up.
        guard top >= 54 else { return nil }
        let width: CGFloat = 125
        let height: CGFloat = 37
        let y: CGFloat = top >= 62 ? 14 : 11
        return CGRect(x: (window.bounds.width - width) / 2, y: y, width: width, height: height)
    }

    /// UIKit's size classes, as the posture's own answer takes them: `UserInterfaceSizeClass` is
    /// layout's, and a window that hasn't settled yet reports neither.
    private static func sizeClass(_ sizeClass: UIUserInterfaceSizeClass) -> UserInterfaceSizeClass? {
        switch sizeClass {
        case .compact: .compact
        case .regular: .regular
        default: nil
        }
    }
}

/// While the app is open, iOS hides the app's own Live Activity. This widens
/// the Dynamic Island into a small pill while the agent works, with the avatar
/// acting out the work inside it (code, files, the web flying across). Tap for
/// the big stage with its name and what it's doing; touch and hold to open
/// the chat.
struct AgentActivityIsland: View {
    let activity: AgentIslandActivity?
    let island: CGRect
    let containerWidth: CGFloat
    @Binding var isCompact: Bool
    let onOpen: () -> Void

    @State private var isGrown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let stageHeight: CGFloat = 66

    var body: some View {
        ZStack(alignment: .top) {
            if let activity {
                panel(activity)
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .scale(scale: 0.4, anchor: .top).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, island.minY)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8), value: activity == nil)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82), value: isCompact)
        .animation(reduceMotion ? nil : .snappy, value: activity?.kind)
    }

    private var expandedSize: CGSize {
        CGSize(width: min(containerWidth - 20, 420), height: island.height + Self.stageHeight + 8)
    }

    /// Wide enough that the work can fly across on both sides of the camera.
    private var compactSize: CGSize {
        CGSize(width: min(island.width + 150, containerWidth - 20), height: island.height)
    }

    private func panel(_ activity: AgentIslandActivity) -> some View {
        let size = !isGrown ? island.size : (isCompact ? compactSize : expandedSize)
        let expanded = isGrown && !isCompact
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: expanded ? 38 : island.height / 2, style: .continuous)
                .fill(.black)
            if isGrown {
                if expanded {
                    VStack(spacing: 0) {
                        topRow(activity)
                        IslandStage(activity: activity)
                            .frame(height: Self.stageHeight)
                            .padding(.horizontal, 14)
                    }
                    .transition(.opacity)
                } else {
                    compactStage(activity)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(.rect)
        .onTapGesture { isCompact.toggle() }
        .onLongPressGesture(minimumDuration: 0.4) { onOpen() }
        .onAppear {
            guard !isGrown else { return }
            if reduceMotion { isGrown = true } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { isGrown = true }
            }
        }
        .onDisappear { isGrown = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(activity.name), \(activity.kind.label)")
        .accessibilityHint("Double-tap to make it smaller or bigger. Touch and hold to open the chat.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("agent.island")
    }

    /// Beside the camera: who is working, and on what.
    private func topRow(_ activity: AgentIslandActivity) -> some View {
        HStack(spacing: 0) {
            Text(activity.name)
                .font(.bighelp(.subheadline).weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: island.width + 8)
            HStack(spacing: 5) {
                Image(systemName: activity.kind.systemImage)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && activity.kind.isWorking)
                    .contentTransition(.symbolEffect(.replace))
                Text(activity.kind.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.bighelp(.footnote).weight(.semibold))
            .foregroundStyle(activity.kind.pose.tint)
            // A new kind of work slides in rather than cross-fading over the old.
            .id(activity.kind)
            .transition(.push(from: .bottom))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .clipped()
        }
        .padding(.horizontal, 22)
        .frame(height: island.height)
    }

    /// The big stage's scene, shrunk to the pill's height.
    private func compactStage(_ activity: AgentIslandActivity) -> some View {
        let scale = island.height / Self.stageHeight
        let width = compactSize.width - 2 * Self.compactInset
        return IslandStage(activity: activity)
            .frame(width: width / scale, height: Self.stageHeight)
            .scaleEffect(scale)
            .frame(width: width, height: island.height)
            .clipShape(Capsule())
    }

    static let compactInset: CGFloat = 8
}

/// Shared by the app scene (which draws the island above every screen) and
/// the root shell (which knows who is working).
@MainActor
@Observable
final class AgentIslandModel {
    var activity: AgentIslandActivity?
    var isAvailable = false
    /// The small pill unless someone taps for the big stage.
    var isCompact = true
    /// How far the big island reaches below the safe area; the app moves down
    /// by this much so the island never covers its buttons.
    var contentInset: CGFloat = 0
    @ObservationIgnored var onOpen: @MainActor () -> Void = {}

    /// The island covers the clock and signal while it shows, as the system
    /// island does, so nothing overlaps.
    var hidesStatusBar: Bool { isAvailable && activity != nil }
}

/// Places the island over the hardware one, above every screen.
struct AgentActivityIslandLayer: View {
    let model: AgentIslandModel
    @State private var island: CGRect?
    @State private var safeTop: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let activity = scenePhase == .active ? model.activity : nil
        let inset = island.map {
            activity == nil || model.isCompact ? 0
                : max(0, $0.maxY + AgentActivityIsland.stageHeight + 8 + 8 - safeTop)
        } ?? 0
        GeometryReader { proxy in
            if let island {
                AgentActivityIsland(activity: activity, island: island, containerWidth: proxy.size.width,
                                    isCompact: Binding(get: { model.isCompact }, set: { model.isCompact = $0 }),
                                    onOpen: { model.onOpen() })
            }
        }
        .background(IslandWindowReader(extraTopInset: inset) { frame, top in
            island = frame
            safeTop = top
            model.isAvailable = frame != nil
        })
        .onChange(of: inset, initial: true) { _, value in model.contentInset = value }
        .ignoresSafeArea()
        // Only the island itself takes touches; everything else passes through.
        .allowsHitTesting(activity != nil)
    }
}

/// Recomputes who is working in its own small body, so a streaming reply
/// refreshes this view rather than the whole shell.
struct AgentIslandPublisher: View {
    let model: AgentIslandModel
    let compute: @MainActor () -> AgentIslandActivity?

    var body: some View {
        let activity = compute()
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: activity, initial: true) { _, value in model.activity = value }
    }
}

private struct IslandWindowReader: UIViewRepresentable {
    /// Pushes the whole app (navigation bars included) below the big island.
    let extraTopInset: CGFloat
    let onChange: (CGRect?, CGFloat) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.apply(extraTopInset: extraTopInset, animated: !context.transaction.disablesAnimations)
    }

    final class ReaderView: UIView {
        var onChange: ((CGRect?, CGFloat) -> Void)?
        private var last: CGRect?
        private var lastTop: CGFloat = -1

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

        func apply(extraTopInset: CGFloat, animated: Bool) {
            guard let root = window?.rootViewController, root.additionalSafeAreaInsets.top != extraTopInset else {
                return
            }
            let change = {
                root.additionalSafeAreaInsets.top = extraTopInset
                root.view.layoutIfNeeded()
            }
            if animated, !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.85,
                               initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState],
                               animations: change)
            } else {
                change()
            }
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            // Leaving the window: give its safe area back.
            if newWindow == nil { window?.rootViewController?.additionalSafeAreaInsets.top = 0 }
            super.willMove(toWindow: newWindow)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            let frame = DynamicIslandGeometry.frame(in: window)
            let top = window?.safeAreaInsets.top ?? 0
            guard frame != last || top != lastTop else { return }
            last = frame
            lastTop = top
            let callback = onChange
            DispatchQueue.main.async { callback?(frame, top) }
        }
    }
}
