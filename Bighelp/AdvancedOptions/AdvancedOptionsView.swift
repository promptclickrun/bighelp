import SwiftUI

/// One bot's everyday settings, grouped and explained in a few words each. A small (i) beside
/// every setting opens a short note about what each choice does.
@MainActor
struct AdvancedOptionsView: View {
    @Bindable var store: AdvancedOptionsStore
    let botName: String
    var onOpenRawConfiguration: (() -> Void)?
    let onClose: () -> Void

    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space20) {
                    content
                }
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.vertical, BighelpTokens.space12)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(String(localized: "Advanced Options"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done"), action: onClose)
                        .accessibilityIdentifier("advanced.done")
                }
            }
            .task { await store.refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.load {
        case .idle, .loading:
            ProgressView(String(localized: "Loading…"))
                .frame(maxWidth: .infinity, minHeight: 160)
                .accessibilityIdentifier("advanced.loading")
        case .unavailable:
            unavailable
        case .loaded:
            Text(String(localized: "Changes for \(botName) save as soon as you make them."))
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let message = store.errorMessage {
                Text(message)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.danger)
                    .accessibilityIdentifier("advanced.error")
            }
            ForEach(store.groups) { group in
                AdvancedGroupSection(group: group, store: store)
            }
            if let onOpenRawConfiguration {
                expertLink(onOpenRawConfiguration)
            }
        }
    }

    private var unavailable: some View {
        VStack(spacing: BighelpTokens.space12) {
            Text(String(localized: "Couldn't reach this computer."))
                .font(.bighelp(.body))
                .foregroundStyle(theme.primaryText)
            Button(String(localized: "Try again")) { Task { await store.refresh() } }
                .buttonStyle(SimpleBotsPrimaryButtonStyle())
                .accessibilityIdentifier("advanced.retry")
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private func expertLink(_ action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            SimpleBotsSectionLabel(title: String(localized: "For experts"))
            SimpleBotsCard {
                Button(action: action) {
                    SimpleBotsRow(
                        title: String(localized: "Edit config.yaml"),
                        leading: Image(systemName: "doc.text")
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("advanced.raw-configuration")
            }
        }
    }
}

private struct AdvancedGroupSection: View {
    let group: AdvancedGroup
    @Bindable var store: AdvancedOptionsStore

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            SimpleBotsSectionLabel(title: group.title)
            SimpleBotsCard {
                ForEach(Array(group.options.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { SimpleBotsDivider() }
                    AdvancedOptionRow(option: option, store: store)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advanced.group.\(group.id)")
    }
}

private struct AdvancedOptionRow: View {
    let option: AdvancedOption
    @Bindable var store: AdvancedOptionsStore

    @State private var isShowingHelp = false
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(spacing: BighelpTokens.space8) {
                Text(option.title)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                helpButton
                Spacer(minLength: BighelpTokens.space8)
                if case .toggle = option.kind {
                    Toggle(option.title, isOn: toggleBinding)
                        .labelsHidden()
                        .disabled(store.isSaving)
                        .accessibilityIdentifier("advanced.option.\(option.id)")
                } else if case .choice(let choices) = option.kind, choices.count > 3 {
                    menu(choices)
                }
            }
            if case .choice(let choices) = option.kind {
                if choices.count <= 3 { segmented(choices) }
                if let custom = store.customDescription(for: option) {
                    Text(String(localized: "Custom: \(custom)"))
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.vertical, BighelpTokens.space12)
        .frame(minHeight: 56)
        .accessibilityElement(children: .contain)
    }

    private var helpButton: some View {
        Button {
            isShowingHelp = true
        } label: {
            Image(systemName: "info.circle")
                .font(.bighelp(.body))
                .foregroundStyle(theme.secondaryText)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "About \(option.title)"))
        .accessibilityIdentifier("advanced.help.\(option.id)")
        .popover(isPresented: $isShowingHelp) {
            AdvancedHelp(option: option)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { store.isOn(option) },
            set: { value in Task { await store.set(option, to: .boolean(value)) } }
        )
    }

    private func choiceBinding(_ choices: [AdvancedChoice]) -> Binding<String?> {
        Binding(
            get: { store.selectedChoice(for: option)?.id },
            set: { id in
                guard let choice = choices.first(where: { $0.id == id }) else { return }
                Task { await store.set(option, to: choice.value) }
            }
        )
    }

    private func segmented(_ choices: [AdvancedChoice]) -> some View {
        Picker(option.title, selection: choiceBinding(choices)) {
            ForEach(choices) { choice in
                Text(choice.title).tag(Optional(choice.id))
            }
        }
        .labelsHidden()
        .bighelpSegmentedPicker()
        .disabled(store.isSaving)
        .accessibilityIdentifier("advanced.option.\(option.id)")
    }

    private func menu(_ choices: [AdvancedChoice]) -> some View {
        let selected = store.selectedChoice(for: option)
        return Menu {
            ForEach(choices) { choice in
                Button {
                    Task { await store.set(option, to: choice.value) }
                } label: {
                    if choice.id == selected?.id {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                Text(selected?.title ?? String(localized: "Custom"))
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .disabled(store.isSaving)
        .accessibilityIdentifier("advanced.option.\(option.id)")
    }
}

/// The tappable note: what the setting does, and what each choice means.
private struct AdvancedHelp: View {
    let option: AdvancedOption
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Text(option.detail)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if case .choice(let choices) = option.kind {
                ForEach(choices) { choice in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.title)
                            .font(.bighelp(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                        Text(choice.detail)
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(BighelpTokens.space20)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.surface)
        .accessibilityIdentifier("advanced.help.popover")
    }
}
