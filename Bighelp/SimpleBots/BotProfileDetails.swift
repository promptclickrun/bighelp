import SwiftUI

/// One of a bot's words the page edits in place: what Agent Studio's Identity section edited.
enum BotProfileAboutField: String, CaseIterable, Identifiable, Sendable {
    case name, role, summary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .role: String(localized: "Role")
        case .summary: String(localized: "Summary")
        }
    }

    var prompt: String {
        switch self {
        case .name: String(localized: "Give your bot a name")
        case .role: String(localized: "e.g. Travel planner")
        case .summary: String(localized: "One line about what it does")
        }
    }

    var draftKey: WritableKeyPath<AgentDraft, String> {
        switch self {
        case .name: \.name
        case .role: \.role
        case .summary: \.summary
        }
    }

    /// The editor model's field, for its validation message.
    var editorField: AgentEditorModel.Field {
        switch self {
        case .name: .name
        case .role: .role
        case .summary: .summary
        }
    }

    func value(in profile: AgentProfile) -> String {
        switch self {
        case .name: profile.name
        case .role: profile.role
        case .summary: profile.summary
        }
    }
}

/// A row in Info's About group: its title, its second line and whether a tap edits it.
struct BotProfileAboutRow: Identifiable, Equatable, Sendable {
    enum Kind: Hashable, Sendable { case field(BotProfileAboutField), handle }

    let kind: Kind
    let title: String
    /// The value, or why the computer won't take an edit.
    let detail: String
    let isEditable: Bool

    var id: Kind { kind }

    var identifier: String {
        switch kind {
        case .field(let field): "simple-bots.profile.about.\(field.rawValue)"
        case .handle: "simple-bots.profile.about.handle"
        }
    }
}

enum BotProfileAbout {
    /// Name, Role, Summary and Handle. A field the computer won't let the app change shows the
    /// reason as its second line; the handle is only ever read (Hermes suggests it from the name).
    static func rows(name: String, role: String, summary: String, handle: String,
                     canEdit: Bool, unavailableReason: String?) -> [BotProfileAboutRow] {
        let reason = unavailableReason ?? String(localized: "This computer doesn't let the app change this bot.")
        let values: [BotProfileAboutField: String] = [.name: name, .role: role, .summary: summary]
        let fields = BotProfileAboutField.allCases.map { field in
            let value = values[field, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            return BotProfileAboutRow(
                kind: .field(field), title: field.title,
                detail: canEdit ? (value.isEmpty ? String(localized: "Not set") : value) : reason,
                isEditable: canEdit)
        }
        return fields + [BotProfileAboutRow(kind: .handle, title: String(localized: "Handle"),
                                            detail: "@\(handle)", isEditable: false)]
    }
}

/// One About field, edited on its own and saved through the same `AgentEditorModel` path (and
/// validation, and errors) as the editor it replaces.
@MainActor
struct BotProfileFieldEditor: View {
    let field: BotProfileAboutField
    let model: AgentEditorModel

    @State private var text: String
    @State private var isSaving = false
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    init(field: BotProfileAboutField, model: AgentEditorModel) {
        self.field = field
        self.model = model
        _text = State(initialValue: model.draft[keyPath: field.draftKey])
    }

    private var original: String { model.editedProfile.map(field.value(in:)) ?? model.draft[keyPath: field.draftKey] }

    /// This field's message first; another field's (the model checks them all) or the save's after it.
    private var errorMessage: String? {
        model.fieldErrors[field.editorField]
            ?? BotProfileAboutField.allCases.lazy.compactMap { model.fieldErrors[$0.editorField] }.first
            ?? model.fieldErrors[.instructions] ?? model.saveError
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                TextField(field.title, text: $text, prompt: Text(field.prompt).bighelpFieldHint(theme),
                          axis: field == .summary ? .vertical : .horizontal)
                    .lineLimit(field == .summary ? 1...4 : 1...1)
                    .font(.bighelp(.body))
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { if field != .summary { save() } }
                    .padding(.horizontal, BighelpTokens.space16)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .padding(.vertical, BighelpTokens.space4)
                    .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20, style: .continuous))
                    .accessibilityLabel(field.title)
                    .accessibilityIdentifier("simple-bots.profile.about.editor.\(field.rawValue)")
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("simple-bots.profile.about.editor.error")
                }
                Spacer(minLength: 0)
            }
            .padding(BighelpTokens.space16)
            .background(theme.canvas.ignoresSafeArea())
            .disabled(isSaving)
            // A swipe down never throws away an unsaved change.
            .interactiveDismissDisabled(isSaving || text != original)
            .navigationTitle(field.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("simple-bots.profile.about.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || text == original || model.hasUnconfirmedSave)
                        .accessibilityIdentifier("simple-bots.profile.about.editor.save")
                }
            }
            .onAppear { isFocused = true }
        }
    }

    private func save() {
        guard !isSaving, text != original else { return }
        isSaving = true
        model.draft[keyPath: field.draftKey] = text
        Task { @MainActor in
            defer { isSaving = false }
            // The model keeps its own message for each failure; the sheet stays open to show it.
            guard (try? await model.save()) != nil else { return }
            dismiss()
        }
    }
}

/// What the bot asked permission for and what the person decided, newest first: the old
/// profile sheet's Approvals tab, as a page of its own.
@MainActor
struct BotApprovalsPage: View {
    let store: AgentBoardStore
    let botName: String
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                content
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space16)
            // As wide as the bot page it opens from.
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Approvals")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-bots.profile.approvals.page")
    }

    @ViewBuilder
    private var content: some View {
        if !store.approvals.isEmpty {
            SimpleBotsCard {
                ForEach(Array(store.approvals.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { SimpleBotsDivider() }
                    row(entry)
                }
            }
        } else {
            switch store.logState {
            case .failed(let message):
                SimpleBotsMessageCard(systemImage: "exclamationmark.triangle", title: message)
            case .unavailable:
                SimpleBotsMessageCard(systemImage: "wifi.slash", title: String(localized: "Your computer isn't connected"))
            case .loaded:
                SimpleBotsMessageCard(systemImage: "checkmark.shield",
                                      title: String(localized: "No approvals yet"),
                                      detail: String(localized: "What \(botName) asks to do shows up here."))
            case .idle, .loading:
                // Still, never a spinner that loops.
                SimpleBotsMessageCard(systemImage: "checkmark.shield", title: String(localized: "Loading…"))
            }
        }
    }

    private func row(_ entry: AgentApprovalEntry) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: entry.wasAllowed ? "checkmark.shield" : "xmark.shield")
                .font(.bighelp(.body, weight: .semibold))
                .foregroundStyle(entry.wasAllowed ? theme.secondaryText : theme.danger)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.description.isEmpty ? entry.command : entry.description)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.sessionTitle.isEmpty {
                    Text(entry.sessionTitle)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                }
                Text("\(entry.decisionLabel) · \(entry.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.vertical, BighelpTokens.space12)
        .accessibilityElement(children: .combine)
    }
}

/// The page while its bot's computer isn't the one in use yet: still, with Back, and nothing read
/// from the computer in use, so a bot there with the same ID never shows in its place.
@MainActor
struct BotProfileOpeningView: View {
    /// Nil when the computer has no name to show.
    let computerName: String?

    var body: some View {
        VStack {
            SimpleBotsMessageCard(systemImage: "desktopcomputer",
                                  title: computerName.map { String(localized: "Opening \($0)…") }
                                    ?? String(localized: "Opening…"))
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.top, BighelpTokens.space24)
                .frame(maxWidth: 720)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-bots.profile.opening")
    }
}
