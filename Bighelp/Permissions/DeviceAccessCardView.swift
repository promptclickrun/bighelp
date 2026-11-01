import SwiftUI

/// One Device access card inline in the chat: the tool the agent asked for, what it gets, and Turn on
/// or Not now. It looks and acts like the connector cards; the switch it turns on is the one in
/// Settings › Device access.
@MainActor
struct DeviceAccessInlineCard: View {
    let store: DeviceAccessCardStore
    let card: DeviceAccessCardStore.Card

    @State private var shortcutName = ""

    private var kind: DeviceToolCapability { card.capability }
    private var step: DeviceAccessCardStore.Step { store.step(card) }

    var body: some View {
        BighelpCard {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                HStack(spacing: BighelpTokens.space12) {
                    DeviceToolIcon(kind: kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step == .healthSharing ? HealthSharingNote.title : "Turn on \(kind.title)?")
                            .bighelpFont(.sectionTitle)
                            .foregroundStyle(theme.primaryText)
                        Text("Your agent asked to use it.")
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                if step == .healthSharing {
                    Text(HealthSharingNote.body)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("device-access.card.health-sharing")
                } else {
                    Text(kind.cardLine)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    extra
                }
                if let message = store.message {
                    Text(message)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.warning)
                }
                buttons
                Text(footnote)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if shortcutName.isEmpty { shortcutName = card.shortcutName ?? "" } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("device-access.card.\(kind.rawValue)")
    }

    @ViewBuilder
    private var extra: some View {
        switch kind {
        case .geofences:
            Text("This needs Location set to Always, so bighelp hears about a place even while it's closed. iOS asks next.")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .shortcuts:
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                TextField("Shortcut name", text: $shortcutName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, BighelpTokens.space12)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .background(theme.incomingMessageBackground, in: .rect(cornerRadius: BighelpTokens.radius12))
                    .accessibilityIdentifier("device-access.card.shortcut-name")
                Text("Type it the way it shows in Shortcuts. iOS doesn't let apps see your list.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: BighelpTokens.space8) {
            Button(role: .cancel) {
                store.notNow(card)
            } label: {
                Text("Not now").frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            }
            .buttonStyle(.bordered)
            .tint(theme.action)
            .disabled(step == .turningOn)
            .accessibilityIdentifier("device-access.card.not-now")
            if step == .turningOn {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                    .accessibilityLabel(BighelpPlatform.isMac ? "Waiting for macOS" : "Waiting for iOS")
            } else {
                Button {
                    let name = shortcutName
                    Task {
                        if step == .healthSharing { await store.agreeToHealthSharing(card) }
                        else { await store.turnOn(card, shortcutName: name) }
                    }
                } label: {
                    Text(step == .healthSharing ? "Continue" : "Turn on")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                }
                .bighelpProminentButtonStyle()
                .tint(theme.action)
                .accessibilityIdentifier("device-access.card.turn-on")
            }
        }
    }

    private var footnote: String {
        let minutes = max(1, Int((card.deadline.timeIntervalSinceNow / 60).rounded()))
        return "This turns on \(kind.title) in Settings › Device access, where you can turn it off at any time. "
            + "Your agent waits up to \(minutes) minute\(minutes == 1 ? "" : "s")."
    }

    @BighelpThemeReader private var theme
}

/// A Device access tool's icon on a soft tile; Apple Health's heart is Health's pink.
struct DeviceToolIcon: View {
    let kind: DeviceToolCapability
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(kind == .health ? Color.pink : theme.action)
            .frame(width: size, height: size)
            .background((kind == .health ? Color.pink : theme.action).opacity(0.14),
                        in: .rect(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }

    @BighelpThemeReader private var theme
}

/// What the person reads once before Apple Health's switch first turns on (App Review 5.1.2(i) and
/// 5.1.3): where the data goes and that it can be turned off.
enum HealthSharingNote {
    static let title = String(localized: "Share Health data with your agent?")
    static let body = String(localized: "Health data you share goes to your Hermes computer and the AI provider on it, so your agent can answer you. It is not used for advertising. You can turn it off at any time in Settings › Device access. Next, iOS asks which kinds of Health data to share.")
}

/// Settings › Device access's sheet for the same note.
@MainActor
struct HealthSharingSheet: View {
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    DeviceToolIcon(kind: .health, size: 56)
                    Text(HealthSharingNote.title)
                        .bighelpFont(.sectionTitle)
                        .foregroundStyle(theme.primaryText)
                    Text(HealthSharingNote.body)
                        .bighelpFont(.body)
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(DeviceToolCapability.health.detail)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        dismiss()
                        onContinue()
                    } label: {
                        Text("Continue")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                    }
                    .bighelpProminentButtonStyle()
                    .tint(theme.action)
                    .accessibilityIdentifier("device-access.health-sharing.continue")
                }
                .padding(BighelpTokens.space20)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Apple Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                        .accessibilityIdentifier("device-access.health-sharing.not-now")
                }
            }
        }
        .accessibilityIdentifier("device-access.health-sharing")
        .bighelpSheetSize(.standard)
    }

    @BighelpThemeReader private var theme
}
