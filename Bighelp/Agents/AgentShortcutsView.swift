import AppIntents
import SwiftUI

struct AgentShortcutsView: View {
    let agent: AgentProfile

    @State private var isSiriTipVisible = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Set up in Shortcuts") {
                        instruction(
                            "Choose an action",
                            detail: "Add Send a chat with bighelp, or Start a bighelp voice chat.",
                            symbol: "plus.app"
                        )
                        instruction(
                            "Choose this bot",
                            detail: "Set Bot to \(agent.name). The selected computer must be connected when it runs.",
                            symbol: "person.crop.circle"
                        )
                        instruction(
                            "Review before running",
                            detail: "Chat sends your message. Voice chat opens bighelp and starts voice mode.",
                            symbol: "checkmark.bubble"
                        )
                }

                Section {
                    #if !targetEnvironment(macCatalyst)
                    SiriTipView(intent: SendLoopdyChatIntent(), isVisible: $isSiriTipVisible)
                    #endif

                    ShortcutsLink()
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .accessibilityIdentifier("agent.shortcuts.open")
                } header: {
                    Text("Open Shortcuts")
                } footer: {
                    Text("Opening Shortcuts does not send a message or create a shortcut.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Use with Siri")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .frame(minHeight: BighelpTokens.toolbarHitTarget)
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                }
            }
        }
        .accessibilityIdentifier("agent.shortcuts.screen")
    }

    private func instruction(_ title: String, detail: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                Text(detail)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(theme.action)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}
