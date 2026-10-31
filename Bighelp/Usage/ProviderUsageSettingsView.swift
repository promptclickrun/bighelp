import SwiftUI

/// Usage › Limits › Choose: which of the computer's plans and balances Usage
/// shows, and the names you give them. All of them until you hide one; saved on this device.
struct ProviderUsageSettingsView: View {
    let store: ProviderUsageStore?
    /// The computer in use: names given here are for its plans.
    var gatewayID: String? = nil
    @AppStorage(ProviderUsagePreferences.hiddenKey) private var hiddenRaw = ""
    @AppStorage(BighelpPlanNames.key, store: BighelpPlanNames.defaults) private var namesRaw = ""
    @State private var namesWhenOpened: String?
    @BighelpThemeReader private var theme

    private var hidden: Set<String> { ProviderUsagePreferences.hidden(hiddenRaw) }

    var body: some View {
        Form {
            Section {
                if let providers = store?.report?.providers, !providers.isEmpty {
                    ForEach(providers) { provider in
                        HStack(spacing: BighelpTokens.space12) {
                            AIProviderMarkView(providerID: ProviderUsagePresentation.logoProviderID(provider.id),
                                               providerName: provider.name, context: .chatQuickChoice, size: 26)
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(theme.isDarkPalette ? Color(white: 0.16) : .white))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.plan.map { "\(provider.name) · \($0)" } ?? provider.name)
                                    .font(.bighelp(.caption))
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                                TextField("Name for \(provider.name)", text: name(provider),
                                          prompt: Text(provider.name).bighelpFieldHint(theme))
                                    .submitLabel(.done)
                                    .accessibilityIdentifier("usage.limits.name.\(provider.id)")
                            }
                            Toggle("Show \(provider.name)", isOn: shown(provider.id))
                                .labelsHidden()
                                .accessibilityIdentifier("usage.limits.choice.\(provider.id)")
                        }
                    }
                } else {
                    Text(emptyText)
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("usage.limits.choice.empty")
                }
            } footer: {
                Text("The plans and providers set up on your computer. New ones show until you turn them off. A name you give a plan shows in Usage and its widgets.")
            }
            .listRowBackground(theme.surface)

            if !hidden.isEmpty {
                Section {
                    Button("Show All") { hiddenRaw = "" }
                        .accessibilityIdentifier("usage.limits.show-all")
                }
                .listRowBackground(theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Show in Usage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { namesWhenOpened = namesRaw }
        .onDisappear { if namesRaw != namesWhenOpened { UsageWidgetPublisher.namesChanged() } }
    }

    private var emptyText: String {
        switch store?.state {
        case .needsPluginUpdate?: "Update the bighelp plugin on your computer to see its plans."
        case .unavailable(let message)?: message
        case .loaded?: "No AI plans found on your computer."
        default: "Looking for plans on your computer…"
        }
    }

    /// Saved as it's typed; a blank name goes back to the provider's.
    private func name(_ provider: ProviderUsage) -> Binding<String> {
        let key = ProviderUsagePreferences.key(for: provider.id)
        return Binding(
            get: { BighelpPlanNames.typed(of: key, gateway: gatewayID, in: namesRaw) },
            set: { namesRaw = BighelpPlanNames.setting($0, of: key, gateway: gatewayID, in: namesRaw) }
        )
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !ProviderUsagePreferences.isHidden(id, in: hidden) },
            set: { isShown in
                var next = hidden
                let key = ProviderUsagePreferences.key(for: id)
                if isShown { next.remove(key) } else { next.insert(key) }
                hiddenRaw = ProviderUsagePreferences.raw(next)
            }
        )
    }
}
