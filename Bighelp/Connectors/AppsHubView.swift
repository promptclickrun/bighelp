import SwiftUI

/// Settings › Apps: the two ways agents reach your other apps. Native App Connections are
/// Hermes' own connectors on this computer; Composio Apps use your Composio account.
@MainActor
struct AppsHubView: View {
    let native: ConnectorAppsModel?
    @State var composio: ComposioAppsModel

    var body: some View {
        Form {
            Section {
                if let native {
                    NavigationLink {
                        ConnectorAppsView(model: native)
                    } label: {
                        row("Native App Connections", detail: "Built into Hermes on this computer",
                            symbol: "app.connected.to.app.below.fill", tint: Color(hex: "3A7BD5"))
                    }
                    .accessibilityIdentifier("apps.native")
                }
                NavigationLink {
                    ComposioAppsView(model: composio)
                } label: {
                    row("Composio Apps", detail: composio.account.isSignedIn
                            ? (composio.account.email.map { "Signed in as \($0)" } ?? "Signed in")
                            : "Sign in to connect hundreds of apps",
                        symbol: "square.grid.3x3.fill", tint: Color(hex: "7A5AF8"))
                }
                .accessibilityIdentifier("apps.composio")
            } footer: {
                Text("Your agents can use the apps you connect, in any chat.")
            }
        }
        .bighelpFormSurface()
        .navigationTitle("Apps")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { composio.account.reload() }
        .accessibilityIdentifier("apps.hub")
    }

    private func row(_ title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bighelp(.body))
                Text(detail).font(.bighelp(.footnote)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
