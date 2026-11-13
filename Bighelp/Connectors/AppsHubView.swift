import SwiftUI

/// Settings › Apps & skills: everything your bots can use, on one page. This device's access first
/// (the row Settings pushes, `deviceAccess`), then the apps (Hermes' own connectors on this computer and
/// Composio's, one sign-in for every computer), skills and plugins, messaging apps, the vault of logins
/// their browser can use, and (Advanced options) MCP servers and toolsets.
/// A bot's Connections shows the same page without `marketplace`: this device and the apps, which then
/// show once, since its Marketplace lists the rest.
@MainActor
struct AppsHubView<DeviceAccess: View>: View {
    let native: ConnectorAppsModel?
    let composio: ComposioAppsModel?
    /// Opens the vault over this page; nil hides it (no computer chosen).
    var onOpenVault: (() -> Void)?
    /// The last Open found the computer away.
    var vaultNeedsComputer = false
    /// Skills, plugins and messaging apps for the bot in use; nil leaves them out.
    var marketplace: (@MainActor () -> MarketplaceContext)?
    private let deviceAccess: DeviceAccess
    /// Made once, when the page first shows: its plugin model lives as long as the page.
    @State private var context: MarketplaceContext?

    init(native: ConnectorAppsModel?, composio: ComposioAppsModel?, onOpenVault: (() -> Void)? = nil,
         vaultNeedsComputer: Bool = false, marketplace: (@MainActor () -> MarketplaceContext)? = nil,
         @ViewBuilder deviceAccess: () -> DeviceAccess) {
        self.native = native
        self.composio = composio
        self.onOpenVault = onOpenVault
        self.vaultNeedsComputer = vaultNeedsComputer
        self.marketplace = marketplace
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

            ConnectedAppsSection(native: native, composio: composio)

            if let context {
                MarketplaceSections(context: context, part: .skillsAndPlugins)
                MarketplaceSections(context: context, part: .talkAnywhere)
            }

            if let onOpenVault {
                Section {
                    Button(action: onOpenVault) {
                        AppsHubRow(title: String(localized: "Credential vault"),
                                   value: vaultNeedsComputer ? String(localized: "Connect your computer first.") : nil,
                                   symbol: "lock.shield", showsChevron: true)
                            .bighelpSettingsLinkLabel()
                    }
                    .buttonStyle(.plain)
                    .bighelpSettingsLink()
                    .accessibilityIdentifier("settings.connections.vault")
                    .driveTarget("settings.connections.vault")
                } header: {
                    Text("Logins")
                }
                .listRowBackground(theme.surface)
            }

            if let context {
                MarketplaceSections(context: context, part: .advanced)
            }
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .navigationTitle(marketplace == nil ? String(localized: "Connections") : String(localized: "Apps & skills"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            composio?.account.reload()
            if context == nil { context = marketplace?() }
        }
        .task(id: context?.id) { await context?.plugins?.loadIfNeeded() }
        .accessibilityIdentifier("apps.hub")
        // An agent's drive points at the featured plugin, which can be below the fold.
        .driveScrolls()
    }

    @BighelpThemeReader private var theme
}

/// The apps bots can use: Hermes' own connectors on this computer and Composio's, one sign-in for
/// every computer. Apps & skills lists it, and a bot's Connections.
@MainActor
struct ConnectedAppsSection: View {
    let native: ConnectorAppsModel?
    let composio: ComposioAppsModel?

    var body: some View {
        Section {
            if let native {
                NavigationLink {
                    ConnectorAppsView(model: native)
                } label: {
                    AppsHubRow(title: String(localized: "Built-in apps"), value: Self.connectedLine(native),
                               symbol: "app.connected.to.app.below.fill")
                        .bighelpSettingsLinkLabel()
                }
                .bighelpSettingsLink()
                .accessibilityIdentifier("apps.native")
                .driveTarget("apps.native")
            }
            if let composio {
                NavigationLink {
                    ComposioAppsView(model: composio)
                } label: {
                    AppsHubRow(title: String(localized: "Composio"),
                               value: composio.account.isSignedIn ? String(localized: "Signed in")
                                   : String(localized: "Not signed in"),
                               symbol: "square.grid.3x3.fill")
                        .bighelpSettingsLinkLabel()
                }
                .bighelpSettingsLink()
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
            Text("Your bots can use connected apps in any chat.")
        }
        .listRowBackground(theme.surface)
    }

    /// "3 connected" once the page behind it has read them; nothing before.
    private static func connectedLine(_ model: ConnectorAppsModel) -> String? {
        let count = model.apps.filter(\.isConnected).count
        return count > 0 ? String(localized: "\(count) connected") : nil
    }

    @BighelpThemeReader private var theme
}

/// A row of Apps & skills: its icon, the thing, and its value under it.
struct AppsHubRow: View {
    let title: String
    var value: String?
    let symbol: String
    /// Buttons draw their own chevron; links get the List's, except on the Mac.
    var showsChevron = false

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bighelp(.body)).foregroundStyle(theme.primaryText)
                if let value, !value.isEmpty {
                    Text(value).font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText).lineLimit(2)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            if showsChevron || BighelpPlatform.drawsOwnLinkChevron {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, BighelpTokens.space8)
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
    }

    @BighelpThemeReader private var theme
}

/// Apps & skills' Device access row: the kinds of data a bot can ask this device for, as a small
/// grid of their icons, and how many of the switches behind it are on.
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
                if let count = Self.switchesOn(), count > 0 {
                    Text("\(count) on")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                }
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

    /// The data switches that are on, from where Device access saves them (`DeviceToolPermissions.grantsKey`).
    /// Nil before anything was saved.
    private static func switchesOn() -> Int? {
        guard let grants = UserDefaults.standard.stringArray(forKey: DeviceToolPermissions.grantsKey) else { return nil }
        return Set(grants.compactMap(DeviceToolCapability.init(rawValue:))
            .filter { $0.sharesPersonalData && $0.isOfferedOnThisPlatform }).count
    }

    private func icon(_ index: Int) -> some View {
        DeviceToolIcon(kind: Self.kinds[index], size: 20)
    }

    @BighelpThemeReader private var theme
}
