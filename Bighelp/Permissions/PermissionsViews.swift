import SwiftUI

@MainActor
struct PermissionsSettingsView: View {
    let center: PermissionCenter
    /// The page's one info sheet: whichever row's info button was tapped last.
    @State private var about: DeviceAccessAbout?

    var body: some View {
        Form {
            HostPluginFeatureSection(feature: .deviceAccess, lead: center.deviceTools.scope == nil
                ? Text("On until you turn it off. Connect a computer so its bots can use these.")
                : Text("On until you turn it off. What a bot reads goes to your computer and its AI providers."))
            if let status = center.nativeDeviceToolStatus {
                Section { Text(status).bighelpFont(.metadata).foregroundStyle(.secondary) }
            }

            toolSection(.yourData, header: "Your data",
                        footer: "Bots can change and delete events, reminders and contacts without asking each time.")
            toolSection(.whereYouAre, header: "Where you are")
            toolSection(.onThisDevice, header: "On this device")

            Section {
                AgentAppearancePermissionRow(permissions: center.deviceTools) { about = $0 }
                AgentNavigationPermissionRow(permissions: center.deviceTools) { about = $0 }
            } header: {
                Text("Bighelp itself")
            } footer: {
                Text("Only while that bot’s chat is open.")
                    .bighelpFont(.metadata)
            }
            .listRowBackground(theme.surface)

            Section {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(center: center, kind: kind) { about = $0 }
                }
            } header: {
                Text(BighelpPlatform.isMac ? "macOS permissions" : "iOS permissions")
            } footer: {
                Text(BighelpPlatform.isMac
                     ? "Bighelp asks macOS only after you choose Allow."
                     : "Bighelp asks iOS only after you choose Allow.")
                    .bighelpFont(.metadata)
            }
            .listRowBackground(theme.surface)
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .driveScrolls()
        .bighelpSheet(item: $about) { DeviceAccessAboutSheet(about: $0) }
        .navigationTitle("Device access")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.permissions")
        .task {
            // Device tools first: their switches depend on it; system rows can follow.
            await center.deviceTools.refresh()
            await center.refresh()
        }
    }

    /// One group of switches that share the person's data; left out where this platform offers none of them.
    @ViewBuilder
    private func toolSection(_ section: DeviceToolCapability.AccessSection, header: LocalizedStringKey,
                             footer: LocalizedStringKey? = nil) -> some View {
        let kinds = DeviceToolCapability.allCases.filter {
            $0.accessSection == section && $0.sharesPersonalData && $0.isOfferedOnThisPlatform
        }
        if !kinds.isEmpty {
            Section {
                ForEach(kinds) { kind in
                    DeviceToolPermissionRow(permissions: center.deviceTools, kind: kind) { about = $0 }
                }
            } header: {
                Text(header)
            } footer: {
                if let footer { Text(footer).bighelpFont(.metadata) }
            }
            .listRowBackground(theme.surface)
        }
    }

    @BighelpThemeReader private var theme
}

/// What one Device access row's info button opens: the row's name and its longer description.
struct DeviceAccessAbout: Identifiable {
    let id: String
    let title: String
    let detail: String
    /// A second paragraph: when a bot can use what the row shares.
    var note: String? = nil
}

/// The trailing info button on a Device access row.
@MainActor
private struct DeviceAccessAboutButton: View {
    let name: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.bighelp(.body))
                .foregroundStyle(theme.action)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(Rectangle())
        }
        .bighelpPointerButtonStyle(.borderless)
        .bighelpIconLabel(String(localized: "About \(name)"))
        .accessibilityIdentifier(identifier)
    }

    @BighelpThemeReader private var theme
}

@MainActor
private struct DeviceAccessAboutSheet: View {
    let about: DeviceAccessAbout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    Text(about.detail)
                        .bighelpFont(.body)
                        .foregroundStyle(theme.primaryText)
                    if let note = about.note {
                        Text(note)
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(BighelpTokens.space20)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(about.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .bighelpDefaultAction()
                        .accessibilityIdentifier("permissions.about.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("permissions.about")
        .bighelpSheetSize(.compact)
    }

    @BighelpThemeReader private var theme
}

@MainActor
private struct DeviceToolPermissionRow: View {
    let permissions: DeviceToolPermissions
    let kind: DeviceToolCapability
    let onAbout: (DeviceAccessAbout) -> Void
    @Environment(\.openURL) private var openURL
    /// Apple Health's sharing note, shown once before its switch first turns on.
    @State private var showsHealthSharing = false
    @State private var turnsOnAfterSharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space8) {
                Toggle(isOn: Binding(
                    get: { permissions.isEnabled(kind) },
                    set: { enabled in
                        if enabled, kind == .health, !permissions.healthSharingAgreed { showsHealthSharing = true }
                        else if enabled { Task { await permissions.setEnabled(true, for: kind) } }
                        else { permissions.disable(kind) }
                    }
                )) {
                    HStack(spacing: BighelpTokens.space12) {
                        DeviceToolIcon(kind: kind, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title).bighelpFont(.body, weight: .semibold)
                            if let hint = kind.hint {
                                Text(hint).bighelpFont(.metadata).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .disabled(!permissions.isEnabled(kind) && (permissions.requestInFlight != nil
                    || permissions.status(for: kind) == .unavailable))
                .accessibilityHint(Text(kind.detail))
                .accessibilityIdentifier("permissions.device-tools.\(kind.rawValue)")

                DeviceAccessAboutButton(name: kind.title, identifier: "permissions.device-tools.\(kind.rawValue).about") {
                    // The page's opening line says where the data goes; when a bot can read it is here.
                    onAbout(DeviceAccessAbout(
                        id: "device-tools.\(kind.rawValue)", title: kind.title, detail: kind.detail,
                        note: String(localized: "Any bot on your computer can use this while its chat is open, and for a short time after you leave Bighelp.")))
                }
            }

            if permissions.requestInFlight == kind {
                ProgressView(BighelpPlatform.isMac ? "Waiting for macOS…" : "Waiting for iOS…").bighelpFont(.metadata)
            } else if permissions.status(for: kind) == .denied {
                Button(BighelpPlatform.isMac ? "Allow access in System Settings" : "Allow access in iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .accessibilityIdentifier("permissions.device-tools.\(kind.rawValue).settings")
            } else if kind == .health, permissions.isEnabled(kind) {
                Text("Choose which kinds Bighelp can read in the Health app under Sharing; an empty answer can mean no data or no access.")
                    .bighelpFont(.metadata).foregroundStyle(.secondary)
            } else if kind == .location, permissions.isEnabled(kind) {
                Text("Only while Bighelp is open, and only a rough area if you keep your location approximate.")
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
    let onAbout: (DeviceAccessAbout) -> Void

    private var title: String { String(localized: "Change how Bighelp looks") }
    private var detail: String {
        String(localized: "When you ask, your bot can switch light or dark mode and change your chat color. You can change it back in Appearance.")
    }

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            Toggle(isOn: Binding(
                get: { permissions.appearanceAllowed },
                set: { permissions.setAppearanceAllowed($0) }
            )) {
                Text(title).bighelpFont(.body, weight: .semibold)
            }
            .accessibilityHint(Text(detail))
            .accessibilityIdentifier("permissions.device-tools.appearance")
            .driveTarget("permissions.device-tools.appearance")

            DeviceAccessAboutButton(name: title, identifier: "permissions.device-tools.appearance.about") {
                onAbout(DeviceAccessAbout(id: "device-tools.appearance", title: title, detail: detail))
            }
        }
        .padding(.vertical, BighelpTokens.space4)
    }
}

/// On until the person turns it off: it shares nothing, never changes a setting, and Return to chat
/// puts everything back.
@MainActor
private struct AgentNavigationPermissionRow: View {
    let permissions: DeviceToolPermissions
    let onAbout: (DeviceAccessAbout) -> Void

    private var title: String { String(localized: "Show you around") }
    private var detail: String {
        String(localized: "When you ask where something is, your bot can open that page or setting and point at it. It never changes anything for you.")
    }

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            Toggle(isOn: Binding(
                get: { permissions.navigationAllowed },
                set: { permissions.setNavigationAllowed($0) }
            )) {
                Text(title).bighelpFont(.body, weight: .semibold)
            }
            .accessibilityHint(Text(detail))
            .accessibilityIdentifier("permissions.device-tools.navigation")
            .driveTarget("permissions.device-tools.navigation")

            DeviceAccessAboutButton(name: title, identifier: "permissions.device-tools.navigation.about") {
                onAbout(DeviceAccessAbout(id: "device-tools.navigation", title: title, detail: detail))
            }
        }
        .padding(.vertical, BighelpTokens.space4)
    }
}

@MainActor
struct PermissionRow: View {
    let center: PermissionCenter
    let kind: PermissionKind
    /// Device access puts `purpose` behind an info button that opens its sheet; without one
    /// (Settings › Notifications) the purpose shows under the title.
    var onAbout: ((DeviceAccessAbout) -> Void)? = nil

    var body: some View {
        let status = center.status(for: kind)
        let presentation = PermissionRowPresentation(kind: kind, status: status)
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(alignment: onAbout == nil ? .top : .center, spacing: BighelpTokens.space12) {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(theme.action)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .bighelpFont(.body, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                    if onAbout == nil {
                        Text(kind.purpose)
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: BighelpTokens.space8)
                Text(status.authorization.statusTitle)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(status.authorization == .denied ? theme.warning : theme.secondaryText)
                if let onAbout {
                    DeviceAccessAboutButton(name: kind.title, identifier: "permissions.\(kind.rawValue).about") {
                        onAbout(DeviceAccessAbout(id: "permission.\(kind.rawValue)", title: kind.title, detail: kind.purpose))
                    }
                }
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
