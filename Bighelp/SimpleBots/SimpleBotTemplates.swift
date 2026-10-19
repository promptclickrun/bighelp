import SwiftUI

/// New Bot's starting point: bighelp's everyday helper, or a template attached with the
/// Templates button. The template fills the role, vibe and instructions; the person gives the name
/// and the look.
@MainActor
enum SimpleBotCreation {
    static var everydayHelper: AgentSoulTemplate? { AgentSoulTemplate.bundled.first { $0.id == "anchor" } }

    /// Attaches a template. One with fill-in fields asks for them first (the editor's form), with the
    /// name typed so far already in it; it's attached once that form is done.
    static func attach(_ template: AgentSoulTemplate, to model: AgentEditorModel, name: String) {
        // What `prepare` filled in for an earlier try counts as empty, so the template's values go in.
        if let helper = everydayHelper {
            if model.draft.role == helper.profile { model.draft.role = "" }
            if model.draft.summary == helper.about { model.draft.summary = "" }
            if model.draft.instructions == helper.soul { model.draft.instructions = "" }
        }
        model.draft.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.startFrom(template)
    }

    /// Takes the template off: what it filled in goes.
    static func detach(_ model: AgentEditorModel) {
        model.showStartChoice(.scratch)
    }

    /// The attached template's ID, once it has filled the bot in.
    static func attachedID(_ model: AgentEditorModel) -> String? {
        guard let applied = model.appliedTemplateID, applied.hasPrefix("builtin:") else { return nil }
        return String(applied.dropFirst("builtin:".count))
    }

    /// Right before Create: the name goes into the template's instructions, and whatever a bot
    /// needs that the template left empty comes from the everyday helper.
    static func prepare(_ model: AgentEditorModel, name: String) {
        let helper = everydayHelper
        model.draft.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachedID(model) != nil {
            model.nameDidChange()
        } else {
            model.draft.instructions = helper?.soul
                ?? "You are {{agent_name}}, a friendly helper. Keep answers short and clear, and ask before doing anything that can't be undone."
        }
        if model.draft.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.draft.role = helper?.profile ?? "Everyday helper"
        }
        if model.draft.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.draft.summary = helper?.about ?? "Warm, direct, adaptable."
        }
    }
}

/// New Bot's Templates button, top right.
struct SimpleBotTemplatesButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Templates", systemImage: "square.grid.2x2")
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, BighelpTokens.space16)
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(Capsule())
                .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityHint("Start from a template. It fills in the role, vibe and instructions.")
        .accessibilityIdentifier("simple-bots.create.templates")
    }
}

/// The attached template, under the Templates button: its name, and an x to take it off.
struct SimpleBotTemplateChip: View {
    let template: AgentSoulTemplate
    let onRemove: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space4) {
            Label {
                Text(verbatim: template.title).lineLimit(1)
            } icon: {
                Image(systemName: template.systemImage)
            }
            .font(.bighelp(.subheadline, weight: .semibold))
            .foregroundStyle(theme.primaryText)
            .padding(.leading, BighelpTokens.space16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Template: \(template.title)")
            .accessibilityIdentifier("simple-bots.create.template")
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.tertiaryText)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove template")
            .accessibilityIdentifier("simple-bots.create.template.remove")
        }
        .background(theme.surface, in: Capsule())
    }
}

/// Share on a bot's profile: name it, Save, and it's one of My Templates on the person's computer.
@MainActor
struct SimpleBotSaveTemplateSheet: View {
    let profile: AgentProfile
    var store: MyTemplatesStore = .shared
    let onSaved: (AgentSoulTemplate) -> Void

    @State private var name: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    init(profile: AgentProfile, store: MyTemplatesStore = .shared, onSaved: @escaping (AgentSoulTemplate) -> Void) {
        self.profile = profile
        self.store = store
        self.onSaved = onSaved
        _name = State(initialValue: String(profile.name.prefix(MyTemplatesWire.maximumNameLength)))
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var needsPluginUpdate: Bool { store.load == .needsPluginUpdate }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BighelpTokens.space12) {
                SimpleBotsCircleButton(systemImage: "xmark", label: "Close", identifier: "simple-bots.template.close") {
                    dismiss()
                }
                Text("Save as Template")
                    .font(.bighelp(.title3, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space16)

            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    Text("Saves \(profile.name)'s role, vibe and instructions on your computer. Pick it from Templates when you make a new bot. Its picture isn't saved.")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Template name", text: $name)
                        .font(.bighelp(.title3, weight: .medium))
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .onSubmit { Task { await save() } }
                        .onChange(of: name) { _, value in
                            if value.count > MyTemplatesWire.maximumNameLength {
                                name = String(value.prefix(MyTemplatesWire.maximumNameLength))
                            }
                        }
                        .padding(.horizontal, BighelpTokens.space16)
                        .frame(minHeight: 56)
                        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20, style: .continuous))
                        .accessibilityIdentifier("simple-bots.template.name")
                    if let message = errorMessage ?? (needsPluginUpdate ? MyTemplatesSaveError.needsPluginUpdate.message : nil) {
                        Text(message)
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("simple-bots.template.error")
                    }
                }
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.vertical, BighelpTokens.space20)
            }

            Button {
                Task { await save() }
            } label: {
                if isSaving { ProgressView().tint(theme.actionForeground) } else { Text("Save") }
            }
            .buttonStyle(SimpleBotsPrimaryButtonStyle())
            .disabled(trimmedName.isEmpty || isSaving || needsPluginUpdate)
            .padding(.horizontal, BighelpTokens.space32)
            .padding(.bottom, BighelpTokens.space12)
            .accessibilityIdentifier("simple-bots.template.save")
        }
        .background(theme.canvas.ignoresSafeArea())
        .interactiveDismissDisabled(isSaving)
        .task {
            isNameFocused = true
            await store.refresh()
        }
    }

    private func save() async {
        guard !trimmedName.isEmpty, !isSaving, !needsPluginUpdate else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let template = try await store.save(name: trimmedName, from: profile)
            onSaved(template)
            dismiss()
        } catch {
            errorMessage = MyTemplatesSaveError(error).message
        }
    }
}
