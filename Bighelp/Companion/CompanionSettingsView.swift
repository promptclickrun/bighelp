import SwiftUI
import UIKit

struct CompanionAgentOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ profile: AgentProfile) {
        id = profile.id
        name = profile.name
    }
}

struct CompanionSettingsView: View {
    @Bindable var store: CompanionStore
    let agents: [CompanionAgentOption]
    let agentScope: String


    init(store: CompanionStore, agents: [AgentProfile], agentScope: String = "") {
        self.store = store
        self.agents = agents.map(CompanionAgentOption.init)
        self.agentScope = agentScope
    }

    init(store: CompanionStore, agents: [CompanionAgentOption], agentScope: String = "") {
        self.store = store
        self.agents = agents
        self.agentScope = agentScope
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show pet companion", isOn: $store.isEnabled)
                    .tint(theme.action)
                    .accessibilityHint("Shows the selected companion throughout bighelp. Your choices remain saved when this is off.")
                    .accessibilityIdentifier("companion.enabled")
            } footer: {
                Text("Companions are optional and do not send messages or perform actions.")
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

                    Button("Reset Size") {
                        store.sizeScale = CompanionStore.defaultSizeScale
                    }
                    .disabled(store.sizeScale == CompanionStore.defaultSizeScale)
                    .accessibilityHint("Returns the pet to its default size.")
                    .accessibilityIdentifier("companion.size.reset")
                }

                Toggle("Adventurous Pet", isOn: $store.isAdventurous)
                    .tint(theme.action)
                    .accessibilityHint("Allows the pet to explore the chat composer and active rails while bighelp is visible.")
                    .accessibilityIdentifier("companion.adventurous")
            } header: {
                Text("Size and movement")
            } footer: {
                Text("Size applies everywhere. Adventurous movement is off by default and respects Reduce Motion.")
            }

            Section("App default") {
                NavigationLink {
                    CompanionCatalogPicker(title: "Character", appearance: store.defaultAppearance, isDefault: false) { entry in
                        guard let entry else { return }
                        var appearance = store.defaultAppearance
                        appearance.catalogAvatar = AvatarCatalogReference(entry)
                        appearance.topper = nil
                        store.defaultAppearance = appearance
                    }
                } label: {
                    LabeledContent("Character", value: store.defaultAppearance.displayName)
                }
                .accessibilityIdentifier("companion.default.character")

                Toggle("Match app theme", isOn: defaultMatchesThemeBinding)
                    .tint(theme.action)
                    .accessibilityHint("Uses the current theme accent color for this companion.")
                    .accessibilityIdentifier("companion.default.match-theme")

                ColorPicker(
                    "Custom color",
                    selection: defaultColorBinding,
                    supportsOpacity: false
                )
                .disabled(store.defaultAppearance.matchesTheme)
                .accessibilityHint("Selects the companion body color when Match app theme is off.")

                preview(appearance: store.defaultAppearance, label: "App default preview")
            }

            if agents.isEmpty {
                Section("Agent overrides") {
                    ContentUnavailableView(
                        "No agents",
                        systemImage: "person.2",
                        description: Text("Agent-specific companions will appear here after agents are available.")
                    )
                }
            } else {
                ForEach(agents) { agent in
                    agentSection(agent)
                }

                Section {
                    Button("Use app default for all agents", role: .destructive) {
                        store.clearAgentOverrides()
                    }
                    .disabled(store.agentOverrides.isEmpty)
                    .accessibilityHint("Removes every agent-specific companion choice without changing the app default.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Pet Companion")
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.action)
    }

    @ViewBuilder
    private func agentSection(_ agent: CompanionAgentOption) -> some View {
        let key = CompanionStore.agentKey(agentScope: agentScope, agentID: agent.id)
        let override = store.override(for: key)

        Section {
            NavigationLink {
                CompanionCatalogPicker(title: agent.name, appearance: store.appearance(for: key),
                                       defaultTitle: "Use app default", isDefault: override == nil) { entry in
                    guard let entry else {
                        store.setOverride(nil, for: key)
                        return
                    }
                    var appearance = store.override(for: key) ?? store.defaultAppearance
                    appearance.catalogAvatar = AvatarCatalogReference(entry)
                    appearance.topper = nil
                    store.setOverride(appearance, for: key)
                }
            } label: {
                LabeledContent("Companion", value: override?.displayName ?? "Use app default")
            }
            .accessibilityLabel("Companion for \(agent.name)")
            .accessibilityValue(override?.displayName ?? "Use app default")
            .accessibilityIdentifier("companion.agent.\(agent.id).character")

            if override != nil {
                Toggle("Match app theme", isOn: agentMatchesThemeBinding(key: key))
                    .tint(theme.action)
                    .accessibilityLabel("Match app theme for \(agent.name)")

                ColorPicker(
                    "Custom color",
                    selection: agentColorBinding(key: key),
                    supportsOpacity: false
                )
                .disabled(store.override(for: key)?.matchesTheme ?? true)
                .accessibilityLabel("Custom companion color for \(agent.name)")
            }

            preview(
                appearance: store.appearance(for: key),
                label: "\(agent.name) preview"
            )
        } header: {
            Text(agent.name)
        } footer: {
            if override == nil {
                Text("Uses the app default companion.")
            } else {
                Text("This choice applies only to \(agent.name) on this host and account.")
            }
        }
    }

    private func preview(appearance: CompanionAppearance, label: String) -> some View {
        let side = 104 * CGFloat(store.sizeScale)
        return HStack {
            Spacer(minLength: 0)
            CompanionAvatar(
                appearance: appearance,
                reaction: .idle,
                isAnimating: store.isEnabled
            )
            .frame(width: side, height: side)
            .accessibilityLabel(label)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 104 * CGFloat(CompanionStore.maximumSizeScale))
        .padding(.vertical, 4)
        .listRowBackground(theme.surface)
    }

    private var sizePercentage: String {
        "\(Int((store.sizeScale * 100).rounded()))%"
    }

    private var defaultMatchesThemeBinding: Binding<Bool> {
        Binding(
            get: { store.defaultAppearance.matchesTheme },
            set: { matchesTheme in
                var appearance = store.defaultAppearance
                appearance.matchesTheme = matchesTheme
                store.defaultAppearance = appearance
            }
        )
    }

    private var defaultColorBinding: Binding<Color> {
        colorBinding(
            get: { store.defaultAppearance.colorHex },
            set: { colorHex in
                var appearance = store.defaultAppearance
                appearance.colorHex = colorHex
                store.defaultAppearance = appearance
            }
        )
    }

    private func agentMatchesThemeBinding(key: String) -> Binding<Bool> {
        Binding(
            get: { store.override(for: key)?.matchesTheme ?? store.defaultAppearance.matchesTheme },
            set: { matchesTheme in
                var appearance = store.override(for: key) ?? store.defaultAppearance
                appearance.matchesTheme = matchesTheme
                store.setOverride(appearance, for: key)
            }
        )
    }

    private func agentColorBinding(key: String) -> Binding<Color> {
        colorBinding(
            get: { store.override(for: key)?.colorHex ?? store.defaultAppearance.colorHex },
            set: { colorHex in
                var appearance = store.override(for: key) ?? store.defaultAppearance
                appearance.colorHex = colorHex
                store.setOverride(appearance, for: key)
            }
        )
    }

    private func colorBinding(
        get: @escaping () -> String,
        set: @escaping (String) -> Void
    ) -> Binding<Color> {
        Binding(
            get: {
                let hex = CompanionAppearance.validatedColorHex(get())
                    ?? CompanionAppearance.fallbackColorHex
                return Color(hex: String(hex.dropFirst()))
            },
            set: { color in
                let uiColor = UIColor(color)
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: nil) else { return }
                set(String(
                    format: "#%02X%02X%02X",
                    Int(round(red * 255)),
                    Int(round(green * 255)),
                    Int(round(blue * 255))
                ))
            }
        )
    }

    @BighelpThemeReader private var theme
}
