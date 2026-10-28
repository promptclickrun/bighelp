import SwiftUI

/// What a bot's Advanced Options page needs from the shell (`makeAdvancedOptions(for:)`).
@MainActor
struct AdvancedOptionsContext {
    let store: AdvancedOptionsStore
    /// The app's own settings: Send while it works is Settings › Chat's choice, shown here too.
    let settings: SettingsStore
    /// Whether a Nerd Mode page can open for this bot now. Read as the page draws, so a row
    /// shows up once the computer can open it.
    let offers: @MainActor (AdvancedPage) -> Bool
    let page: @MainActor (AdvancedPage) -> AnyView
}

/// Advanced Options in a sheet of its own, from a bot's profile.
@MainActor
struct AdvancedOptionsSheet: View {
    let context: AdvancedOptionsContext
    let botName: String
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            AdvancedOptionsPage(context: context, botName: botName)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done"), action: onClose)
                            .accessibilityIdentifier("advanced.done")
                    }
                }
        }
    }
}

/// One bot's advanced settings, grouped and in a few words each, then every Nerd Mode page for
/// it, with the expert ones last. A small (i) beside a setting says what each choice does.
/// Pushed from Bots mode's Settings too, so it brings its own page destinations.
@MainActor
struct AdvancedOptionsPage: View {
    let context: AdvancedOptionsContext
    let botName: String

    @State private var editing: AdvancedOption?
    @BighelpThemeReader private var theme

    private var store: AdvancedOptionsStore { context.store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                content
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.top, BighelpTokens.space8)
            .padding(.bottom, BighelpTokens.space32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(theme.canvas.ignoresSafeArea())
        .bighelpSwitches()
        .navigationTitle(String(localized: "Advanced Options"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: AdvancedPage.self) { context.page($0) }
        .task { await store.refresh() }
        .bighelpSheet(item: $editing) { option in
            AdvancedTextEditor(option: option, store: store)
                .bighelpSheetSize(.standard)
        }
        .alert(store.pendingChoice?.choice.confirmation?.title ?? "",
               isPresented: Binding(get: { store.pendingChoice != nil },
                                    set: { if !$0 { store.cancelPendingChoice() } }),
               presenting: store.pendingChoice) { pending in
            Button(pending.choice.confirmation?.action ?? pending.choice.title, role: .destructive) {
                Task { await store.confirm(pending) }
            }
            .accessibilityIdentifier("advanced.confirm")
            Button(String(localized: "Cancel"), role: .cancel) { store.cancelPendingChoice() }
        } message: { pending in
            Text(pending.choice.confirmation?.message ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advanced.options")
    }

    @ViewBuilder
    private var content: some View {
        switch store.load {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 160)
                .accessibilityIdentifier("advanced.loading")
        case .unavailable:
            VStack(spacing: BighelpTokens.space12) {
                Text(String(localized: "Couldn't reach your computer."))
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                Button(String(localized: "Try Again")) { Task { await store.refresh() } }
                    .buttonStyle(SimpleBotsPrimaryButtonStyle())
                    .accessibilityIdentifier("advanced.retry")
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        case .loaded:
            Text(String(localized: "Changes to \(botName) save right away."))
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, BighelpTokens.space20)
            if let message = store.message {
                banner(message)
            }
            ForEach(store.groups) { group in
                AdvancedGroupCard(group: group, context: context, editing: $editing)
            }
        }
    }

    private func banner(_ message: AdvancedOptionsStore.Message) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space12) {
            Text(message.text)
                .font(.bighelp(.subheadline))
                .foregroundStyle(message.isProblem ? theme.danger : theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !message.isProblem {
                Button(String(localized: "Check Again")) { Task { await store.refresh() } }
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.information)
                    .bighelpPlainButtonStyle()
                    .disabled(store.isSaving)
            }
        }
        .padding(.horizontal, BighelpTokens.space20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advanced.message")
    }
}

/// A group's quiet label and its card; rows hidden for now (a page the computer can't open
/// yet, a setting that doesn't apply) are left out, and an empty group isn't shown.
private struct AdvancedGroupCard: View {
    let group: AdvancedGroup
    let context: AdvancedOptionsContext
    @Binding var editing: AdvancedOption?

    var body: some View {
        let rows = group.rows.filter(isShown)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                SimpleBotsSectionLabel(title: group.title)
                SimpleBotsCard {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { SimpleBotsDivider() }
                        rowView(row)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("advanced.group.\(group.id)")
        }
    }

    private func isShown(_ row: AdvancedRow) -> Bool {
        switch row {
        case .option(let option): context.store.isShown(option)
        case .sendWhileWorking: true
        case .page(let page): context.offers(page)
        }
    }

    @ViewBuilder
    private func rowView(_ row: AdvancedRow) -> some View {
        switch row {
        case .option(let option):
            AdvancedOptionRow(option: option, store: context.store, editing: $editing)
        case .sendWhileWorking:
            AdvancedSendWhileWorkingRow(settings: context.settings)
        case .page(let page):
            NavigationLink(value: page) {
                SimpleBotsRow(title: page.title, value: page.isWholeComputer ? String(localized: "All bots") : nil)
            }
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier("advanced.page.\(page.rawValue)")
        }
    }
}

/// One setting on the computer: its name and tip, and a switch or a menu at the end.
private struct AdvancedOptionRow: View {
    let option: AdvancedOption
    let store: AdvancedOptionsStore
    @Binding var editing: AdvancedOption?

    @BighelpThemeReader private var theme

    var body: some View {
        switch option.kind {
        case .toggle:
            VStack(alignment: .leading, spacing: 0) {
                AdvancedSettingRow(title: option.title, tip: AdvancedTip(option), identifier: option.id) {
                    Toggle(option.title, isOn: Binding(
                        get: { store.isOn(option) },
                        set: { on in Task { await store.setOn(option, on) } }))
                        .labelsHidden()
                        .tint(SimpleBotColor.green.color)
                        .disabled(store.isSaving)
                        .accessibilityIdentifier("advanced.option.\(option.id)")
                }
                if case .whileOn(let note) = option.visibility {
                    Text(note)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, BighelpTokens.space20)
                        .padding(.bottom, BighelpTokens.space12)
                }
            }
        case .choice(let choices, _):
            AdvancedSettingRow(title: option.title, tip: AdvancedTip(option), identifier: option.id) {
                AdvancedMenu(title: option.title, value: store.valueText(for: option),
                             identifier: "advanced.option.\(option.id)") {
                    let selected = store.selectedChoice(for: option)
                    ForEach(choices) { choice in
                        AdvancedMenuItem(title: choice.title, isSelected: choice.id == selected?.id) {
                            Task { await store.choose(choice, for: option) }
                        }
                    }
                }
                .disabled(store.isSaving)
            }
        case .duration(let choices):
            AdvancedSettingRow(title: option.title, tip: AdvancedTip(option), identifier: option.id) {
                AdvancedMenu(title: option.title, value: store.valueText(for: option),
                             identifier: "advanced.option.\(option.id)") {
                    let current = store.seconds(for: option)
                    ForEach(Self.waits(choices, current: current), id: \.self) { seconds in
                        AdvancedMenuItem(title: AdvancedValue.duration(seconds), isSelected: seconds == current) {
                            Task { await store.setSeconds(option, seconds) }
                        }
                    }
                }
                .disabled(store.isSaving)
            }
        case .text:
            Button { editing = option } label: {
                SimpleBotsRow(title: option.title, value: store.valueText(for: option))
            }
            .bighelpPlainButtonStyle()
            .disabled(store.isSaving)
            .accessibilityIdentifier("advanced.option.\(option.id)")
        }
    }

    /// A wait the computer has that isn't in the list stays pickable, first.
    private static func waits(_ choices: [Int], current: Int?) -> [Int] {
        guard let current, !choices.contains(current) else { return choices }
        return [current] + choices
    }
}

/// Settings › Chat's own choice for a message sent while an agent works: the app does this,
/// not the bot's config, so it's the same for every bot.
private struct AdvancedSendWhileWorkingRow: View {
    let settings: SettingsStore

    var body: some View {
        AdvancedSettingRow(
            title: String(localized: "Send while it works"),
            tip: AdvancedTip(
                detail: String(localized: "What happens when you send a message while your bot is working. It's the same for every bot on this device."),
                choices: MidSessionChatBehavior.allCases.map { AdvancedTip.Line(title: $0.title, detail: Self.detail($0)) }),
            identifier: "send-while-working"
        ) {
            AdvancedMenu(title: String(localized: "Send while it works"), value: settings.midSessionChatBehavior.title,
                         identifier: "advanced.send-while-working") {
                ForEach(MidSessionChatBehavior.allCases) { behavior in
                    AdvancedMenuItem(title: behavior.title, isSelected: behavior == settings.midSessionChatBehavior) {
                        settings.midSessionChatBehavior = behavior
                    }
                }
            }
        }
    }

    /// The choices' names are the ones Send's hold menu uses; their tips in plainer words.
    private static func detail(_ behavior: MidSessionChatBehavior) -> String {
        switch behavior {
        case .steer: String(localized: "Your bot reads it at once and changes course.")
        case .queued: String(localized: "Your bot finishes first, then reads it.")
        case .interruptAndSend: String(localized: "Your bot stops and starts on your message.")
        }
    }
}

/// A setting's row: the name with its tip button, then the control at the end. With the
/// largest text the control goes under the name, so neither is cut.
private struct AdvancedSettingRow<Control: View>: View {
    let title: String
    let tip: AdvancedTip
    let identifier: String
    @ViewBuilder let control: Control

    @Environment(\.dynamicTypeSize) private var typeSize
    @BighelpThemeReader private var theme

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: BighelpTokens.space8))
        layout {
            HStack(spacing: 0) {
                Text(title)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                AdvancedTipButton(title: title, tip: tip, identifier: identifier)
            }
            if !stacked { Spacer(minLength: BighelpTokens.space8) }
            control
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.vertical, BighelpTokens.space4)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// A menu at a row's end: the current value and the up-down chevrons, like a picker.
private struct AdvancedMenu<Items: View>: View {
    let title: String
    let value: String
    let identifier: String
    @ViewBuilder let items: Items

    @BighelpThemeReader private var theme

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: BighelpTokens.space4) {
                Text(value)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.bighelp(.footnote, weight: .semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .fixedSize()
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier)
    }
}

private struct AdvancedMenuItem: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// What a setting's tip says: the setting in one line, then each choice in one line.
private struct AdvancedTip {
    struct Line: Identifiable {
        let title: String
        let detail: String
        var id: String { title }
    }

    let detail: String
    var choices: [Line] = []

    init(detail: String, choices: [Line] = []) {
        self.detail = detail
        self.choices = choices
    }

    init(_ option: AdvancedOption) {
        if case .choice(let choices, _) = option.kind {
            self.init(detail: option.detail, choices: choices.map { Line(title: $0.title, detail: $0.detail) })
        } else {
            self.init(detail: option.detail)
        }
    }
}

/// The small (i) after a setting's name; a tap opens its tip.
private struct AdvancedTipButton: View {
    let title: String
    let tip: AdvancedTip
    let identifier: String

    @State private var isShowing = false
    @BighelpThemeReader private var theme

    var body: some View {
        Button { isShowing = true } label: {
            Image(systemName: "info.circle")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.tertiaryText)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityLabel(String(localized: "About \(title)"))
        .accessibilityIdentifier("advanced.help.\(identifier)")
        .popover(isPresented: $isShowing) {
            AdvancedTipView(tip: tip)
                .presentationCompactAdaptation(.popover)
                .bighelpPopoverDismissal(isPresented: $isShowing)
        }
    }
}

private struct AdvancedTipView: View {
    let tip: AdvancedTip
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Text(tip.detail)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(tip.choices) { choice in
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .font(.bighelp(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    Text(choice.detail)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(BighelpTokens.space20)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advanced.help.popover")
    }
}

/// Free text for a setting (the rules for Smart), saved when you tap Save.
private struct AdvancedTextEditor: View {
    let option: AdvancedOption
    let store: AdvancedOptionsStore

    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    init(option: AdvancedOption, store: AdvancedOptionsStore) {
        self.option = option
        self.store = store
        _text = State(initialValue: store.text(for: option))
    }

    private var placeholder: String {
        if case .text(let placeholder) = option.kind { return placeholder }
        return ""
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Text(option.detail)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(.bighelp(.body))
                    .scrollContentBackground(.hidden)
                    .padding(BighelpTokens.space12)
                    .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .font(.bighelp(.body))
                                .foregroundStyle(theme.tertiaryText)
                                .padding(BighelpTokens.space12)
                                .padding(.top, BighelpTokens.space8)
                                .padding(.leading, BighelpTokens.space4)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(option.title)
                    .accessibilityIdentifier("advanced.text-editor")
                if let message = store.message, message.isProblem {
                    Text(message.text)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.danger)
                }
            }
            .padding(BighelpTokens.space16)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(option.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        Task {
                            await store.setText(option, text)
                            if store.message?.isProblem != true { dismiss() }
                        }
                    }
                    .disabled(store.isSaving)
                    .accessibilityIdentifier("advanced.text-editor.save")
                }
            }
        }
    }
}
