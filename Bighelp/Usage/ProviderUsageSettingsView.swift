import SwiftUI

/// Usage › Limits › Choose: which of the computer's plans and balances Usage
/// shows. All of them until you hide one; saved on this device.
struct ProviderUsageSettingsView: View {
    let store: ProviderUsageStore?
    @AppStorage(ProviderUsagePreferences.hiddenKey) private var hiddenRaw = ""
    @BighelpThemeReader private var theme

    private var hidden: Set<String> { ProviderUsagePreferences.hidden(hiddenRaw) }

    var body: some View {
        Form {
            Section {
                if let providers = store?.report?.providers, !providers.isEmpty {
                    ForEach(providers) { provider in
                        Toggle(isOn: shown(provider.id)) {
                            HStack(spacing: BighelpTokens.space12) {
                                AIProviderMarkView(providerID: ProviderUsagePresentation.logoProviderID(provider.id),
                                                   providerName: provider.name, context: .chatQuickChoice, size: 26)
                                    .frame(width: 34, height: 34)
                                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(theme.isDarkPalette ? Color(white: 0.16) : .white))
                                Text(provider.name)
                            }
                        }
                        .accessibilityIdentifier("usage.limits.choice.\(provider.id)")
                    }
                } else {
                    Text(emptyText)
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("usage.limits.choice.empty")
                }
            } footer: {
                Text("The plans and providers set up on your computer. New ones show until you turn them off.")
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
    }

    private var emptyText: String {
        switch store?.state {
        case .needsPluginUpdate?: "Update the bighelp plugin on your computer to see its plans."
        case .unavailable(let message)?: message
        case .loaded?: "No AI plans found on your computer."
        default: "Looking for plans on your computer…"
        }
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
