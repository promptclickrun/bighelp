import SwiftUI
import UIKit

/// The driving overlay (#662, option C, "Island and dock"): while an agent shows the person a place,
/// the bar grows out of the Dynamic Island with the agent, the steps and Return to chat; the chat
/// steps aside into a card at the bottom, still streaming, with its message box; between them the
/// app runs edge to edge. A dot presses each control and a still spotlight marks where it ends.
/// Nothing loops: every motion plays once, and Reduce Motion cross-fades instead.
struct DriveOverlayLayer: View {
    @Environment(\.appAppearance) private var appearance

    var body: some View {
        #if os(iOS)
        DriveOverlayWindowHost(appearance: appearance)
        #else
        DriveOverlayView(navigator: .shared, island: nil, topInset: 24, hitAreas: DriveOverlayHitAreas())
        #endif
    }
}

/// The bar's and the dock's frames: the only places the overlay's window takes a touch.
@MainActor
final class DriveOverlayHitAreas {
    var frames: [CGRect] = []
}

#if os(iOS)
/// Its own window, above sheets and the connection pill, so a drive into Settings or a deck
/// still shows the bar and the dock. Touches outside them reach the app.
private struct DriveOverlayWindowHost: UIViewRepresentable {
    let appearance: BighelpAppearanceContext

    func makeUIView(context: Context) -> HostView { HostView(appearance: appearance) }
    func updateUIView(_ view: HostView, context: Context) { view.update(appearance: appearance) }

    final class HostView: UIView {
        private var appearance: BighelpAppearanceContext
        private var overlay: PassthroughWindow?
        private var host: DriveHostingController?
        private let hitAreas = DriveOverlayHitAreas()
        private var hiding: Task<Void, Never>?
        private var observing = false

        init(appearance: BighelpAppearanceContext) {
            self.appearance = appearance
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: HostView, _: UITraitCollection) in
                view.overlay?.overrideUserInterfaceStyle = view.traitCollection.userInterfaceStyle
            }
        }

        required init?(coder: NSCoder) { nil }

        func update(appearance: BighelpAppearanceContext) {
            guard appearance != self.appearance else { return }
            self.appearance = appearance
            host?.rootView = rootView()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, let scene = window.windowScene else {
                overlay?.isHidden = true
                overlay = nil
                return
            }
            if overlay == nil {
                let overlay = PassthroughWindow(windowScene: scene)
                overlay.hitAreas = hitAreas
                overlay.windowLevel = .normal + 2
                overlay.backgroundColor = .clear
                let host = DriveHostingController(rootView: rootView())
                host.view.backgroundColor = .clear
                overlay.rootViewController = host
                overlay.isHidden = true
                self.overlay = overlay
                self.host = host
                if !observing {
                    observing = true
                    observePhase()
                }
                phaseChanged()
            }
            overlay?.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
            DriveNavigator.shared.scrollPage = { [weak window] scrolling in
                guard let window else { return false }
                let distance: CGFloat
                switch scrolling {
                case .page: distance = window.bounds.height * 0.5
                case .reveal(let frame):
                    // Low on the screen it would sit under the dock: bring it up to a little above the middle.
                    guard frame.midY > window.bounds.height * 0.6 else { return false }
                    distance = frame.midY - window.bounds.height * 0.42
                }
                // The page under the middle of the screen: the first scroll view that scrolls up and down.
                var view = window.hitTest(CGPoint(x: window.bounds.midX, y: window.bounds.midY), with: nil)
                while let current = view, !((current as? UIScrollView).map { $0.contentSize.height > $0.bounds.height } ?? false) {
                    view = current.superview
                }
                guard let scroll = view as? UIScrollView else { return false }
                let bottom = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
                let next = min(bottom, scroll.contentOffset.y + distance)
                guard next > scroll.contentOffset.y + 1 else { return false }
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next),
                                        animated: !UIAccessibility.isReduceMotionEnabled)
                return true
            }
            DriveNavigator.shared.capturePicture = { [weak window] in
                guard let window else { return nil }
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                return renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            }
        }

        private func rootView() -> AnyView {
            AnyView(DriveOverlayView(navigator: .shared, island: DynamicIslandGeometry.frame(in: window),
                                     topInset: window?.safeAreaInsets.top ?? 24, hitAreas: hitAreas)
                .environment(\.appAppearance, appearance))
        }

        private func observePhase() {
            withObservationTracking { _ = DriveNavigator.shared.phase } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.phaseChanged()
                    self?.observePhase()
                }
            }
        }

        private func phaseChanged() {
            hiding?.cancel()
            host?.setNeedsStatusBarAppearanceUpdate()
            if DriveNavigator.shared.phase != .idle {
                host?.rootView = rootView()
                overlay?.isHidden = false
                return
            }
            // Let the bar and the dock fade before the window goes.
            hiding = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, DriveNavigator.shared.phase == .idle else { return }
                self?.overlay?.isHidden = true
                self?.hitAreas.frames = []
            }
        }
    }

    /// The overlay's window is the top one while it shows, so it decides the status bar: hidden, since
    /// the bar fills the top of the screen and the time and battery would sit on its buttons.
    final class DriveHostingController: UIHostingController<AnyView> {
        override var prefersStatusBarHidden: Bool { DriveNavigator.shared.isShowing }
        override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    }

    final class PassthroughWindow: UIWindow {
        var hitAreas: DriveOverlayHitAreas?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard hitAreas?.frames.contains(where: { $0.contains(point) }) == true else { return nil }
            return super.hitTest(point, with: event)
        }
    }
}
#endif

/// The overlay itself, in window coordinates (the same as `DriveTargets`).
struct DriveOverlayView: View {
    let navigator: DriveNavigator
    /// The hardware island's frame, when the phone has one.
    let island: CGRect?
    /// The app window's top safe area: where the bar sits without an island.
    let topInset: CGFloat
    let hitAreas: DriveOverlayHitAreas

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme
    /// The chat has stepped aside into the dock.
    @State private var docked = false
    @State private var barFrame: CGRect = .zero
    @State private var dockFrame: CGRect = .zero
    @State private var size: CGSize = .zero

    private var calm: Bool { reduceMotion || navigator.reducesMotion }
    private var showing: Bool { navigator.phase == .driving || navigator.phase == .arrived }

    var body: some View {
        ZStack {
            // Window coordinates: the spotlight, the dot and the chat's picture go where the app's
            // controls are.
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    DriveSpotlight(navigator: navigator, theme: theme)
                    DriveTouchDot(navigator: navigator, theme: theme)
                    chatPicture(in: CGRect(origin: .zero, size: proxy.size))
                }
            }
            .ignoresSafeArea()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            // The bar from the top edge; the dock above the home indicator and the keyboard.
            VStack(spacing: 0) {
                DriveIslandBar(navigator: navigator, island: island, topInset: topInset, width: size.width,
                               expanded: docked && showing) { barFrame = $0; publishHitAreas() }
                Spacer(minLength: 0)
                DriveDock(navigator: navigator, theme: theme)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .opacity(docked && showing ? 1 : 0)
                    .offset(y: docked && showing || calm ? 0 : 24)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dockFrame = $0; publishHitAreas() }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .onChange(of: navigator.phase, initial: true) { _, phase in
            withAnimation(calm ? .easeInOut(duration: 0.25) : .spring(response: 0.6, dampingFraction: 0.86)) {
                docked = phase == .driving || phase == .arrived
            }
            publishHitAreas()
            if phase == .driving { announce() }
        }
        .onChange(of: navigator.serial) { _, _ in announce() }
    }

    /// The chat as it was, shrinking into the dock as the drive starts and growing back on Return.
    @ViewBuilder
    private func chatPicture(in bounds: CGRect) -> some View {
        if let picture = navigator.chatPicture, !calm {
            let target = dockFrame == .zero ? bounds : dockFrame
            let frame = docked ? target : bounds
            Image(uiImage: picture)
                .resizable()
                .scaledToFill()
                .frame(width: frame.width, height: frame.height, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: docked ? 30 : 0, style: .continuous))
                .position(x: frame.midX, y: frame.midY)
                .opacity(docked ? 0 : 1)
                .animation(docked ? .easeIn(duration: 0.35).delay(0.2) : .easeOut(duration: 0.2), value: docked)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func publishHitAreas() {
        hitAreas.frames = showing ? [barFrame, dockFrame].filter { !$0.isEmpty } : []
    }

    private func announce() {
        guard navigator.phase == .driving, let agent = navigator.agent else { return }
        UIAccessibility.post(notification: .announcement,
                             argument: String(localized: "\(agent.name) is showing you \(navigator.placeTitle)"))
    }
}

/// The bar that grows out of the Dynamic Island. On a phone with an island it keeps the camera's
/// spot clear: the agent at the leading edge, the buttons at the trailing edge, the words below.
private struct DriveIslandBar: View {
    let navigator: DriveNavigator
    let island: CGRect?
    let topInset: CGFloat
    let width: CGFloat
    let expanded: Bool
    /// The bar's own frame, the only part of the top that takes a touch.
    let onFrame: (CGRect) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var barWidth: CGFloat { max(0, min(width - 16, 440)) }

    var body: some View {
        let collapsed = island ?? CGRect(x: (width - 126) / 2, y: topInset + 8, width: 126, height: 37)
        let height: CGFloat = island == nil ? 96 : 124
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: expanded ? 32 : collapsed.height / 2, style: .continuous)
                .fill(Color.black)
            content
                .opacity(expanded ? 1 : 0)
                .animation(reduceMotion ? nil : expanded ? .easeOut(duration: 0.25).delay(0.22) : .easeIn(duration: 0.1),
                           value: expanded)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
        .frame(width: expanded ? barWidth : collapsed.width, height: expanded ? height : collapsed.height)
        .opacity(expanded || island != nil ? 1 : 0)
        .padding(.top, expanded ? (island == nil ? topInset : 8) : collapsed.minY)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.55, dampingFraction: 0.78), value: expanded)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drive.bar")
    }

    private var arrived: Bool { navigator.phase == .arrived }

    private var title: some View {
        let name = navigator.agent?.name ?? String(localized: "Your agent")
        return Text(arrived ? String(localized: "\(name) brought you here") : String(localized: "\(name) is driving"))
            .font(.bighelp(.subheadline, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let island {
                // Beside the camera: the agent to its left, Stay here to its right. The rest goes below.
                HStack {
                    DriveAgentMark(agent: navigator.agent, size: 30)
                    Spacer(minLength: island.width + 16)
                    if arrived { stayButton }
                }
                .frame(height: island.height)
                .padding(.top, max(0, island.minY - 8))
                HStack(spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    returnButton
                }
                .padding(.top, 8)
            } else {
                HStack(spacing: 10) {
                    DriveAgentMark(agent: navigator.agent, size: 30)
                    title
                    Spacer(minLength: 8)
                    if arrived { stayButton }
                    returnButton
                }
                .frame(height: 36)
                .padding(.top, 12)
            }
            trail.padding(.top, 6)
        }
        .padding(.horizontal, 14)
    }

    private var stayButton: some View {
        Button { navigator.stay() } label: {
            Image(systemName: "xmark")
                .font(.bighelp(.footnote, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Stay here"))
        .accessibilityIdentifier("drive.stay")
    }

    private var returnButton: some View {
        Button { navigator.returnToChat() } label: {
            Text("Return to chat")
                .font(.bighelp(.footnote, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(Color.white))
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drive.return")
    }

    private var trail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(navigator.trail.enumerated()), id: \.offset) { index, label in
                    if index > 0 {
                        Text("›").foregroundStyle(Color.white.opacity(0.45)).accessibilityHidden(true)
                    }
                    Text(label)
                        .fontWeight(index < navigator.lit ? .semibold : .regular)
                        .foregroundStyle(index < navigator.lit ? Color.white : Color.white.opacity(0.55))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: navigator.lit)
                }
            }
            .font(.bighelp(.footnote))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(navigator.trail.prefix(max(navigator.lit, 1)).joined(separator: ", ")))
        .accessibilityIdentifier("drive.trail")
    }
}

/// The chat while the agent drives: its newest words, still arriving, and its own message box.
private struct DriveDock: View {
    let navigator: DriveNavigator
    let theme: BighelpTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                DriveAgentMark(agent: navigator.agent, size: 26)
                VStack(alignment: .leading, spacing: 4) {
                    // Where the drive ended: the agent's note on what the person is looking at.
                    if let note = shownNote {
                        Text(note)
                            .font(.bighelp(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("drive.note")
                    }
                    if !answer.isEmpty {
                        Text(Self.inline(answer))
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(shownNote == nil ? theme.primaryText : theme.secondaryText)
                            .lineLimit(shownNote == nil ? 3 : 2)
                            .accessibilityIdentifier("drive.dock.latest")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let chat = navigator.chat {
                DriveDockComposer(chat: chat, agentName: navigator.agent?.name, theme: theme)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(theme.canvas)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(theme.separator, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drive.dock")
    }

    /// Bold, italics, code and links as the chat shows them; the rest as written.
    private static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    private var shownNote: String? { navigator.phase == .arrived ? navigator.note : nil }

    /// The agent's newest message, the one streaming now, without the blank lines between paragraphs.
    private var answer: String {
        guard let chat = navigator.chat else { return "" }
        for item in chat.items.reversed() where item.role == .assistant {
            if case .message(let text) = item.content, !text.isEmpty {
                return text.split(separator: "\n", omittingEmptySubsequences: true).joined(separator: "\n")
            }
        }
        return ""
    }
}

/// The chat's own draft and Send: a message sent here goes to the chat as it would from its box
/// (a running answer takes it as a steer).
private struct DriveDockComposer: View {
    @Bindable var chat: ChatModel
    let agentName: String?
    let theme: BighelpTheme

    /// A reply quote or references go out only through the chat's own box, which knows how to send
    /// them; here Send waits for Return to chat.
    private var sends: Bool { chat.canSend && chat.replyDraft == nil && chat.referenceSelections.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            TextField(agentName.map { String(localized: "Ask \($0)") } ?? String(localized: "Message"),
                      text: $chat.draft, axis: .vertical)
                .lineLimit(1...3)
                .font(.bighelp(.body))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().strokeBorder(theme.separator))
                .accessibilityIdentifier("drive.dock.field")
            Button { Task { await chat.send() } } label: {
                Image(systemName: "arrow.up")
                    .font(.bighelp(.body, weight: .bold))
                    .foregroundStyle(theme.actionForeground)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(theme.action))
                    .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!sends)
            .opacity(sends ? 1 : 0.4)
            .accessibilityLabel(Text("Send"))
            .accessibilityIdentifier("drive.dock.send")
        }
    }
}

/// The agent's touch: one still dot that moves to a control and presses it once.
private struct DriveTouchDot: View {
    let navigator: DriveNavigator
    let theme: BighelpTheme

    @State private var ripple = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let frame = navigator.touch.flatMap { DriveTargets.shared.frame($0) }
        ZStack {
            if let frame {
                Circle()
                    .strokeBorder(theme.action, lineWidth: 2)
                    .frame(width: 44, height: 44)
                    .scaleEffect(ripple ? 1.9 : 0.6)
                    .opacity(ripple ? 0 : 0.6)
                    .position(x: frame.midX, y: frame.midY)
                Circle()
                    .fill(theme.action.opacity(0.18))
                    .overlay(Circle().strokeBorder(theme.action, lineWidth: 2.5))
                    .frame(width: 44, height: 44)
                    .position(x: frame.midX, y: frame.midY)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: frame)
        .onChange(of: navigator.presses) { _, _ in
            ripple = false
            withAnimation(.easeOut(duration: 0.55)) { ripple = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where the drive ends: the rest of the screen dims a little, the place keeps its light, and the
/// agent's note sits beside it.
private struct DriveSpotlight: View {
    let navigator: DriveNavigator
    let theme: BighelpTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let frame = navigator.spotlight.flatMap { DriveTargets.shared.frame($0) }?.insetBy(dx: -6, dy: -6)
            ZStack(alignment: .topLeading) {
                if let frame {
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: proxy.size))
                        path.addRoundedRect(in: frame, cornerSize: CGSize(width: 16, height: 16))
                    }
                    .fill(Color.black.opacity(0.32), style: FillStyle(eoFill: true))
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(theme.action, lineWidth: 2)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: frame)
        }
        .allowsHitTesting(false)
    }
}

/// The agent's mark in the bar and the dock: its picture, else its first letter.
private struct DriveAgentMark: View {
    let agent: DriveAgent?
    let size: CGFloat

    var body: some View {
        Group {
            if let url = agent?.imageURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { initial }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initial: some View {
        Circle()
            .fill(Color(white: 0.32))
            .overlay(Text(String(agent?.name.first ?? "•")).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white))
    }
}
