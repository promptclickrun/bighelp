import SwiftUI

/// Settings › Companion pet. Each agent's pet is its own avatar, so this page holds only whether
/// pets show, their size and whether they explore.
struct CompanionSettingsView: View {
    @Bindable var store: CompanionStore

    var body: some View {
        Form {
            Section {
                Toggle("Show pet companion", isOn: $store.isEnabled)
                    .tint(theme.action)
                    .accessibilityHint("Shows each bot's avatar as a pet in its chats.")
                    .accessibilityIdentifier("companion.enabled")
            } footer: {
                Text("Each bot's pet is its own avatar. Pets never send messages or do anything.")
            }

            Section {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    HStack {
                        Text("Pet size")
                        Spacer(minLength: BighelpTokens.space8)
                        Text(sizePercentage)
                            .foregroundStyle(theme.secondaryText)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $store.sizeScale,
                        in: CompanionStore.minimumSizeScale...CompanionStore.maximumSizeScale,
                        step: 0.05
                    )
                    .accessibilityLabel("Pet size")
                    .accessibilityValue(sizePercentage)
                    .accessibilityIdentifier("companion.size")
                }

                Toggle("Adventurous Pet", isOn: $store.isAdventurous)
                    .tint(theme.action)
                    .accessibilityHint("Lets the pet explore the message box while Bighelp is open.")
                    .accessibilityIdentifier("companion.adventurous")
            } footer: {
                Text("Adventurous Pet explores the message box. It stays put with Reduce Motion.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Pet Companion")
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.action)
        .accessibilityIdentifier("companion.settings")
    }

    private var sizePercentage: String {
        "\(Int((store.sizeScale * 100).rounded()))%"
    }

    @BighelpThemeReader private var theme
}
