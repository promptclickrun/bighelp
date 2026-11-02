import SwiftUI

@MainActor
struct PermissionsSettingsView: View {
    let center: PermissionCenter

    var body: some View {
        Form {
            HostPluginFeatureSection(feature: .deviceAccess)
            if let status = center.nativeDeviceToolStatus {
                Section { Text(status).bighelpFont(.metadata).foregroundStyle(.secondary) }
            }

            Section {
                ForEach(DeviceToolCapability.allCases.filter { $0.sharesPersonalData && $0.isOfferedOnThisPlatform }) { kind in
                    DeviceToolPermissionRow(permissions: center.deviceTools, kind: kind)
                }
            } header: {
                Text("Shared with your host")
            } footer: {
                Text(center.deviceTools.scope == nil
                     ? "Each switch is for this device and stays on until you turn it off. Connect a host so its agents can use them."
                     : "Each switch is for this device and stays on until you turn it off. Any agent on your host can use it while you have its chat open, also for a short time after you leave bighelp. Requested data goes to that host and its AI provider.")
            }
            .listRowBackground(theme.surface)

            Section {
                AgentAppearancePermissionRow(permissions: center.deviceTools)
                AgentNavigationPermissionRow(permissions: center.deviceTools)
            } footer: {
                Text("Works only while you have the agent’s chat open. One switch for every host.")
                    .bighelpFont(.metadata)
            }
            .listRowBackground(theme.surface)

            Section {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(center: center, kind: kind)
                }
            } header: {
                Text("On this device")
            } footer: {
                Text(BighelpPlatform.isMac
                     ? "bighelp asks macOS only after you choose Allow. Denied access must be changed in System Settings."
                     : "bighelp asks iOS only after you choose Allow. Denied access must be changed in iOS Settings.")
                    .bighelpFont(.metadata)
            }
            .listRowBackground(theme.surface)

            Section {
                LabeledContent("Photos you attach", value: "Picker Only")
                    .accessibilityLabel("Photos you attach")
                    .accessibilityValue("Attaching uses the iOS photo picker and needs no library access.")
            } header: {
                Text("Attaching photos")
            } footer: {
                Text("Photos you attach in chat use Apple’s private picker. Your agent reaches your library only when Photos is on above.")
                    .bighelpFont(.metadata)
            }
            .listRowBackground(theme.surface)

            TelemetrySettingsSection()
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .driveScrolls()
        .navigationTitle("Device access")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.permissions")
        .task {
            // Device tools first: their switches depend on it; system rows can follow.
            await center.deviceTools.refresh()
            await center.refresh()
        }
    }

    @BighelpThemeReader private var theme
}

@MainActor
private struct DeviceToolPermissionRow: View {
    let permissions: DeviceToolPermissions
    let kind: DeviceToolCapability
    @Environment(\.openURL) private var openURL
    /// Apple Health's sharing note, shown once before its switch first turns on.
    @State private var showsHealthSharing = false
    @State private var turnsOnAfterSharing = false

    private var title: String { kind.title }
    private var detail: String { kind.detail }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Toggle(isOn: Binding(
                get: { permissions.isEnabled(kind) },
                set: { enabled in
                    if enabled, kind == .health, !permissions.healthSharingAgreed { showsHealthSharing = true }
                    else if enabled { Task { await permissions.setEnabled(true, for: kind) } }
                    else { permissions.disable(kind) }
                }
            )) {
                HStack(alignment: .top, spacing: BighelpTokens.space12) {
                    DeviceToolIcon(kind: kind, size: 28)
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text(title).bighelpFont(.body, weight: .semibold)
                        Text(detail).bighelpFont(.metadata).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .disabled(!permissions.isEnabled(kind) && (permissions.requestInFlight != nil
                || permissions.status(for: kind) == .unavailable))
            .accessibilityIdentifier("permissions.device-tools.\(kind.rawValue)")

            if permissions.requestInFlight == kind {
                ProgressView(BighelpPlatform.isMac ? "Waiting for macOS…" : "Waiting for iOS…").bighelpFont(.metadata)
            } else if permissions.status(for: kind) == .denied {
                Button(BighelpPlatform.isMac ? "Allow access in System Settings" : "Allow access in iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .accessibilityIdentifier("permissions.device-tools.\(kind.rawValue).settings")
            } else if kind == .health, permissions.isEnabled(kind) {
                Text("Health decides which kinds of data bighelp can read; change them in the Health app under Sharing. An empty answer can mean no data or no access.")
                    .bighelpFont(.metadata).foregroundStyle(.secondary)
            } else if kind == .location, permissions.isEnabled(kind) {
                Text("Only while bighelp is open. \(BighelpPlatform.isMac ? "macOS" : "iOS") asks before sharing your exact spot; if you keep it approximate, your agent gets a rough area.")
                    .bighelpFont(.metadata).foregroundStyle(.secondary)
            } else if permissions.scope != nil, permissions.status(for: kind) == .unavailable {
                Text("Unavailable on this device.").bighelpFont(.metadata).foregroundStyle(.secondary)
            }
            DeviceToolPermissionExtras(kind: kind, permissions: permissions)
        }
        .padding(.vertical, BighelpTokens.space4)
        // iOS shows Health's own sheet next, once this one has gone.
        .bighelpSheet(isPresented: $showsHealthSharing, onDismiss: {
            guard turnsOnAfterSharing else { return }
            turnsOnAfterSharing = false
            Task { await permissions.setEnabled(true, for: .health) }
        }) {
            HealthSharingSheet {
                permissions.agreeToHealthSharing()
                turnsOnAfterSharing = true
            }
        }
    }
}

/// On until the person turns it off: it shares nothing and Appearance undoes any change.
@MainActor
private struct AgentAppearancePermissionRow: View {
    let permissions: DeviceToolPermissions

    var body: some View {
        Toggle(isOn: Binding(
            get: { permissions.appearanceAllowed },
            set: { permissions.setAppearanceAllowed($0) }
        )) {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text("Let agents change how bighelp looks").bighelpFont(.body, weight: .semibold)
                Text("When you ask, your agent can switch light or dark mode and change your chat color. You can change it back in Appearance.")
                    .bighelpFont(.metadata).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("permissions.device-tools.appearance")
        .driveTarget("permissions.device-tools.appearance")
        .padding(.vertical, BighelpTokens.space4)
    }
}

/// On until the person turns it off: it shares nothing, never changes a setting, and Return to chat
/// puts everything back.
@MainActor
private struct AgentNavigationPermissionRow: View {
    let permissions: DeviceToolPermissions

    var body: some View {
        Toggle(isOn: Binding(
            get: { permissions.navigationAllowed },
            set: { permissions.setNavigationAllowed($0) }
        )) {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text("Let agents show you around bighelp").bighelpFont(.body, weight: .semibold)
                Text("When you ask where something is, your agent can open that page or setting and point at it. It never changes anything for you.")
                    .bighelpFont(.metadata).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("permissions.device-tools.navigation")
        .driveTarget("permissions.device-tools.navigation")
        .padding(.vertical, BighelpTokens.space4)
    }
}

@MainActor
struct PermissionRow: View {
    let center: PermissionCenter
    let kind: PermissionKind

    var body: some View {
        let status = center.status(for: kind)
        let presentation = PermissionRowPresentation(kind: kind, status: status)
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(theme.action)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .bighelpFont(.body, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                    Text(kind.purpose)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: BighelpTokens.space8)
                Text(status.authorization.statusTitle)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(status.authorization == .denied ? theme.warning : theme.secondaryText)
            }

            if let detail = presentation.detailText {
                Text(detail)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.tertiaryText)
            }

            switch presentation.action {
            case .request:
                Button(presentation.actionTitle ?? String(localized: "Allow")) {
                    Task { await center.request(kind) }
                }
                .disabled(center.requestInFlight != nil)
                .accessibilityIdentifier("permissions.\(kind.rawValue).allow")
            case .openSystemSettings:
                Button(presentation.actionTitle ?? String(localized: "Open System Settings")) {
                    center.performRecoveryAction(for: kind)
                }
                .accessibilityIdentifier("permissions.\(kind.rawValue).open-settings")
            case .none:
                EmptyView()
            }
        }
        .padding(.vertical, BighelpTokens.space4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityIdentifier("permissions.\(kind.rawValue).row")
    }

    @BighelpThemeReader private var theme
}

@MainActor
struct ContextualPermissionRecoveryView: View {
    let center: PermissionCenter
    let kind: PermissionKind

    var body: some View {
        let presentation = ContextualPermissionRecoveryPresentation(
            kind: kind,
            status: center.status(for: kind)
        )
        if let message = presentation.message {
            VStack(spacing: BighelpTokens.space16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(theme.warning)
                    .accessibilityHidden(true)
                Text(message)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if presentation.action == .openSystemSettings {
                    Button("Open System Settings") {
                        center.performRecoveryAction(for: kind)
                    }
                    .bighelpProminentButtonStyle()
                    .tint(theme.action)
                    .accessibilityIdentifier("permissions.\(kind.rawValue).contextual-open-settings")
                }
            }
            .padding(BighelpTokens.space20)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("permissions.\(kind.rawValue).contextual-recovery")
        }
    }

    @BighelpThemeReader private var theme
}
