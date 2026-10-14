import SwiftUI

/// An agent's screen, full screen: watch it live, take control for a login, a code or
/// a CAPTCHA, then hand it back. Dark whatever the app's look, like a video.
struct BotScreenViewer: View {
    let model: BotScreenViewerModel
    /// The agent's chats open in the app, for Stop task.
    let chats: [ChatModel]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nerdModeEnabled) private var nerdModeEnabled
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                BotScreenCanvas(model: model, label: "\(model.agentName)'s screen")
                overlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            controls
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .snappy(duration: BighelpTokens.stateDuration), value: model.isInControl)
        .task(id: model.attempt) { await model.run() }
        .onChange(of: scenePhase) { _, phase in
            // Back from the background: the link likely dropped while away.
            if phase == .active, case .ended = model.phase { model.retry() }
        }
        .onDisappear { model.close() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.viewer")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: BighelpTokens.space12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("screen.viewer.title")
                if let subtitle {
                    Text(subtitle)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if model.isInControl {
                roundButton("checkmark", label: "Hand back to \(model.agentName)", identifier: "screen.viewer.hand-back") {
                    Task { await model.handBack() }
                }
                .disabled(model.isChangingControl)
            } else {
                roundButton("xmark", label: "Close", identifier: "screen.viewer.close") {
                    model.close()
                    dismiss()
                }
                // Esc closes while watching; in control it belongs to the screen.
                .bighelpCancelAction()
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
    }

    private var title: String {
        switch model.control.holder {
        case .me: "You're in control"
        case .someoneElse: "Someone else is in control"
        case .agent, .meBeforeReconnect: "\(model.agentName) is in control"
        }
    }

    private var subtitle: String? {
        switch model.phase {
        case .connecting: model.hasPicture ? "Reconnecting…" : "Connecting…"
        case .ended: nil
        // The desktop's own name ("hermes:default") is a raw ID: Nerd Mode only.
        case .live: nerdModeEnabled ? model.desktopName : nil
        }
    }

    // MARK: Over the screen

    @ViewBuilder
    private var overlay: some View {
        if case .ended(let sentence) = model.phase {
            VStack(spacing: BighelpTokens.space12) {
                Text(sentence)
                    .font(.bighelp(.body))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button { model.retry() } label: {
                    Text("Try again")
                        .font(.bighelp(.body).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, BighelpTokens.space20)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .background(Capsule().fill(.white.opacity(0.16)))
                        .contentShape(Capsule())
                }
                .bighelpPlainButtonStyle()
                .accessibilityIdentifier("screen.viewer.retry")
            }
            .padding(BighelpTokens.space24)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.8)))
            .padding(BighelpTokens.space24)
        } else if !model.hasPicture {
            Text("Connecting to the screen…")
                .font(.bighelp(.subheadline))
                .foregroundStyle(.white.opacity(0.7))
                .allowsHitTesting(false)
        }
        if let notice = model.notice {
            VStack {
                Text(notice)
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, BighelpTokens.space16)
                    .padding(.vertical, BighelpTokens.space8)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .padding(.top, BighelpTokens.space12)
                Spacer()
            }
            .allowsHitTesting(false)
            .accessibilityIdentifier("screen.viewer.notice")
        }
    }

    // MARK: Controls

    private var controls: some View {
        let activity = BotScreenActivity(chats: chats)
        return HStack(spacing: BighelpTokens.space12) {
            if let chat = activity.chat {
                capsuleButton("Stop task", systemImage: "stop.fill", filled: false, identifier: "screen.viewer.stop-task") {
                    Task { await chat.stop() }
                }
            }
            if model.isInControl {
                Spacer(minLength: 0)
                #if !targetEnvironment(macCatalyst)
                // A Mac's own keyboard always types on the screen while in control.
                roundButton(model.showsKeyboard ? "keyboard.chevron.compact.down" : "keyboard",
                            label: model.showsKeyboard ? "Hide keyboard" : "Show keyboard",
                            identifier: "screen.viewer.keyboard", selected: model.showsKeyboard) {
                    model.showsKeyboard.toggle()
                }
                #endif
                roundButton(model.touchesDriveScreen ? "hand.point.up.left.fill" : "hand.draw",
                            label: model.touchesDriveScreen ? "Touches control the screen. Tap to move the view instead."
                                : "Touches move the view. Tap to control the screen instead.",
                            identifier: "screen.viewer.pointer-mode", selected: model.touchesDriveScreen) {
                    model.touchesDriveScreen.toggle()
                }
            } else {
                capsuleButton("Take control", systemImage: "hand.raised.fill", filled: true,
                              identifier: "screen.viewer.take-control") {
                    Task { await model.takeControl() }
                }
                .disabled(model.phase != .live || model.isChangingControl)
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.top, BighelpTokens.space12)
        .padding(.bottom, BighelpTokens.space8)
    }

    private func capsuleButton(_ title: String, systemImage: String, filled: Bool, identifier: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(filled ? theme.actionForeground : .white)
                .frame(maxWidth: .infinity, minHeight: max(50, BighelpTokens.hitTarget))
                .background(Capsule().fill(filled ? theme.action : .white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier(identifier)
    }

    private func roundButton(_ systemImage: String, label: String, identifier: String, selected: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.bighelp(.title3).weight(.semibold))
                .foregroundStyle(selected ? Color.black : .white)
                .frame(width: max(48, BighelpTokens.hitTarget), height: max(48, BighelpTokens.hitTarget))
                .background(Circle().fill(selected ? Color.white : .white.opacity(0.14)))
                .contentShape(Circle())
        }
        .bighelpPlainButtonStyle()
        .bighelpIconLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
