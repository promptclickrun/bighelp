import SwiftUI

/// Settings › Connections: everything your agents can use, on one page. This device's access first
/// (the row Settings pushes, `deviceAccess`), then the apps (Hermes' own connectors on this computer and
/// Composio's, one sign-in for every computer), then the vault of logins their browser can use.
@MainActor
struct AppsHubView<DeviceAccess: View>: View {
    let native: ConnectorAppsModel?
    let composio: ComposioAppsModel?
    /// Opens the vault over this page; nil hides it (no computer chosen).
    var onOpenVault: (() -> Void)?
    /// The last Open found the computer away.
    var vaultNeedsComputer = false
    private let deviceAccess: DeviceAccess

    init(native: ConnectorAppsModel?, composio: ComposioAppsModel?, onOpenVault: (() -> Void)? = nil,
         vaultNeedsComputer: Bool = false, @ViewBuilder deviceAccess: () -> DeviceAccess) {
        self.native = native
        self.composio = composio
        self.onOpenVault = onOpenVault
        self.vaultNeedsComputer = vaultNeedsComputer
        self.deviceAccess = deviceAccess()
    }

    var body: some View {
        Form {
            Section {
                deviceAccess
            } header: {
                Text("This device")
            }
            .listRowBackground(theme.surface)

            Section {
                if let native {
                    NavigationLink {
                        ConnectorAppsView(model: native)
                    } label: {
                        row("Native App Connections", detail: "Built into Hermes on this computer",
                            symbol: "app.connected.to.app.below.fill")
                    }
                    .accessibilityIdentifier("apps.native")
                    .driveTarget("apps.native")
                }
                if let composio {
                    NavigationLink {
                        ComposioAppsView(model: composio)
                    } label: {
                        row("Composio Apps", detail: composio.account.isSignedIn
                                ? (composio.account.email.map { "Signed in as \($0)" } ?? "Signed in")
                                : "Sign in to connect hundreds of apps",
                            symbol: "square.grid.3x3.fill")
                    }
                    .accessibilityIdentifier("apps.composio")
                    .driveTarget("apps.composio")
                }
                if native == nil, composio == nil {
                    Text("Connect to your computer to add apps.")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("Your agents can use the apps you connect, in any chat.")
            }
            .listRowBackground(theme.surface)

            if let onOpenVault {
                Section {
                    Button(action: onOpenVault) {
                        HStack(spacing: BighelpTokens.space12) {
                            row(String(localized: "Secure credential vault"),
                                detail: vaultNeedsComputer ? String(localized: "Connect to your computer to open it.")
                                    : String(localized: "Logins and cards your agents can use on websites"),
                                symbol: "lock.shield")
                            Spacer(minLength: BighelpTokens.space8)
                            Image(systemName: "chevron.right")
                                .font(.bighelp(.footnote).weight(.semibold))
                                .foregroundStyle(theme.tertiaryText)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.connections.vault")
                    .driveTarget("settings.connections.vault")
                } header: {
                    Text("Logins")
                }
                .listRowBackground(theme.surface)
            }
        }
        .bighelpFormSurface()
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { composio?.account.reload() }
        .accessibilityIdentifier("apps.hub")
    }

    private func row(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bighelp(.body)).foregroundStyle(theme.primaryText)
                Text(detail).font(.bighelp(.footnote)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    @BighelpThemeReader private var theme
}

/// Connections' This device row: the kinds of data an agent can ask this device for, as a small
/// grid of their icons, and what the page behind it lets agents do.
struct DeviceAccessRowLabel: View {
    private static let kinds: [DeviceToolCapability] = [.calendar, .health, .location, .contacts]

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow { icon(0); icon(1) }
                GridRow { icon(2); icon(3) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Device access")
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                Text("Let agents use this device's health, calendar, reminders, contacts and location.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: BighelpTokens.space8)
            if BighelpPlatform.drawsOwnLinkChevron {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, BighelpTokens.space8)
        .padding(.horizontal, BighelpMenuRowLayout.labelInset)
        .contentShape(.rect)
    }

    private func icon(_ index: Int) -> some View {
        DeviceToolIcon(kind: Self.kinds[index], size: 20)
    }

    @BighelpThemeReader private var theme
}
