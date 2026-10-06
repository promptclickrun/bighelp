import SwiftUI

@MainActor
struct PersonalitiesView: View {
    @Bindable var store: PersonalityStore
    @State private var editor: PersonalityEditorPresentation?
    @State private var pendingDelete: PersonalityDefinition?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch store.loadState {
            case .idle, .loading:
                BighelpThinkingOrb(
                    scenario: .searching,
                    visibleLabel: "Loading personalities…"
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed where store.catalog == nil:
                ContentUnavailableView {
                    Label("Personalities unavailable", systemImage: "theatermasks")
                } description: {
                    Text(store.errorMessage ?? "Hermes could not load its personality catalog.")
                } actions: {
                    Button("Try Again") { Task { await store.load() } }
                        .bighelpProminentButtonStyle()
                }
            case .loaded, .failed:
                catalogList
            }
        }
        .navigationTitle("Personalities")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BighelpHeaderActionButton(
                    systemImage: "chevron.left",
                    accessibilityLabel: "Back to Settings",
                    action: { dismiss() }
                )
                #if targetEnvironment(macCatalyst)
                .keyboardShortcut(.cancelAction)
                #endif
                .accessibilityIdentifier("personalities.back")
            }
            ToolbarItem(placement: .primaryAction) {
                BighelpHeaderActionButton(
                    systemImage: "plus",
                    accessibilityLabel: "New Personality",
                    isEnabled: !store.isSaving && store.catalog != nil,
                    action: { editor = .new }
                )
                .accessibilityIdentifier("personalities.add")
            }
        }
        .bighelpSheet(item: $editor) { presentation in
            NavigationStack {
                PersonalityEditorView(store: store, presentation: presentation)
            }
            .bighelpSheetSize(.standard)
        }
        .confirmationDialog(
            pendingDelete?.deleteLabel ?? "Delete Personality",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let personality = pendingDelete {
                Button(personality.deleteLabel, role: .destructive) {
                    pendingDelete = nil
                    Task { await store.delete(name: personality.name) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let personality = pendingDelete {
                Text(
                    personality.isBuiltIn
                        ? "Your changes will be removed and Hermes’ built-in version will return."
                        : "This removes \(personality.name) from Hermes. Existing session history is unchanged."
                )
            }
        }
        .task {
            if store.loadState == .idle { await store.load() }
        }
        .refreshable { await store.load() }
        .background(theme.canvas.ignoresSafeArea())
    }

    private var catalogList: some View {
        List {
            Section {
                Button {
                    Task { await store.activate(name: nil) }
                } label: {
                    personalityChoice(
                        title: "No overlay",
                        detail: "Use the agent’s base behavior",
                        isSelected: store.catalog?.activeName.isEmpty == true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("personalities.none")
            } header: {
                Text("Active Personality")
            }

            personalitySection(
                title: "Built-in",
                values: store.personalities.filter(\.isBuiltIn)
            )
            personalitySection(
                title: "Your Personalities",
                values: store.personalities.filter { !$0.isBuiltIn }
            )

            if let error = store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.danger)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if store.isSaving {
                BighelpThinkingOrb(scenario: .working, scale: .inline)
                    .padding(BighelpTokens.space16)
                    .background(.regularMaterial, in: .circle)
            }
        }
    }

    @ViewBuilder
    private func personalitySection(
        title: String,
        values: [PersonalityDefinition]
    ) -> some View {
        if !values.isEmpty {
            Section(title) {
                ForEach(values) { personality in
                    personalityRow(personality)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task { await store.activate(name: personality.name) }
                            } label: {
                                Label("Use", systemImage: "checkmark")
                            }
                            .tint(theme.success)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if personality.canDelete {
                                Button(role: .destructive) {
                                    pendingDelete = personality
                                } label: {
                                    Label(personality.deleteLabel, systemImage: "trash")
                                }
                            }
                        }
                }
            }
        }
    }

    private func personalityRow(_ personality: PersonalityDefinition) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Button {
                editor = .edit(personality)
            } label: {
                personalityChoice(
                    title: personality.name.capitalized,
                    detail: personality.description.isEmpty
                        ? personality.systemPrompt
                        : personality.description,
                    isSelected: store.catalog?.activeName == personality.name
                )
            }
            .buttonStyle(.plain)
            // Keep editing as the row's established direct action. The adjacent
            // menu retains explicit use/edit/delete targets.
            .accessibilityIdentifier("personalities.\(personality.name)")

            Menu {
                ForEach(personality.availableActions, id: \.self) { action in
                    personalityActionButton(action, for: personality)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.bighelp(.title3))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Actions for \(personality.name)")
            .accessibilityIdentifier("personalities.\(personality.name).actions")
        }
    }

    @ViewBuilder
    private func personalityActionButton(
        _ action: PersonalityAction,
        for personality: PersonalityDefinition
    ) -> some View {
        switch action {
        case .use:
            Button {
                Task { await store.activate(name: personality.name) }
            } label: {
                Label("Use Personality", systemImage: "checkmark.circle")
            }
            .accessibilityIdentifier("personalities.\(personality.name).use")
        case .edit:
            Button {
                editor = .edit(personality)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .accessibilityIdentifier("personalities.\(personality.name).edit-action")
        case .delete:
            Button(role: .destructive) {
                pendingDelete = personality
            } label: {
                Label(personality.deleteLabel, systemImage: "trash")
            }
            .accessibilityIdentifier("personalities.\(personality.name).delete")
        }
    }

    private func personalityChoice(
        title: String,
        detail: String,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            Image(systemName: "theatermasks.fill")
                .foregroundStyle(isSelected ? theme.action : theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(theme.raisedSurface, in: .circle)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(title)
                    .bighelpFont(.body, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text(detail)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: BighelpTokens.space8)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
                    .accessibilityLabel("Active")
            } else {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.caption).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: BighelpTokens.hitTarget)
    }

    @BighelpThemeReader private var theme
}

private enum PersonalityEditorPresentation: Identifiable {
    case new
    case edit(PersonalityDefinition)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let value): "edit-\(value.name)"
        }
    }
}

@MainActor
private struct PersonalityEditorView: View {
    @Bindable var store: PersonalityStore
    let presentation: PersonalityEditorPresentation

    @State private var name: String
    @State private var description: String
    @State private var systemPrompt: String
    @State private var tone: String
    @State private var style: String
    @State private var validationMessage: String?
    @State private var expandsInstructions = false

    init(store: PersonalityStore, presentation: PersonalityEditorPresentation) {
        self.store = store
        self.presentation = presentation
        let personality: PersonalityDefinition? = switch presentation {
        case .new: nil
        case .edit(let value): value
        }
        _name = State(initialValue: personality?.name ?? "")
        _description = State(initialValue: personality?.description ?? "")
        _systemPrompt = State(initialValue: personality?.systemPrompt ?? "")
        _tone = State(initialValue: personality?.tone ?? "")
        _style = State(initialValue: personality?.style ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Short description", text: $description, axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("Identity")
            } footer: {
                Text("Names use lowercase letters, numbers, hyphens, or underscores.")
            }

            Section {
                TextField(
                    "How should this personality behave?",
                    text: $systemPrompt,
                    axis: .vertical
                )
                .lineLimit(6...16)
                .accessibilityIdentifier("personality.editor.instructions")
            } header: {
                HStack {
                    Text("Instructions")
                    Spacer()
                    FocusedTextEditorButton(title: "Instructions",
                                            identifier: "personality.editor.instructions.expand") {
                        expandsInstructions = true
                    }
                }
            }

            Section("Advanced") {
                TextField("Tone", text: $tone)
                TextField("Style", text: $style)
            }

            if let validationMessage {
                Section {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.danger)
                }
            }
        }
        .focusedTextEditor(
            isPresented: $expandsInstructions,
            title: "Instructions",
            text: $systemPrompt,
            placeholder: "How should this personality behave?",
            identifier: "personality.editor.instructions.expand",
            onSave: store.isSaving ? nil : { save() }
        )
        .navigationTitle(isNew ? "New Personality" : "Edit Personality")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    #if targetEnvironment(macCatalyst)
                    .keyboardShortcut(.cancelAction)
                    #endif
                    .bighelpToolbarText()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(store.isSaving)
            }
        }
        .background(theme.canvas.ignoresSafeArea())
    }

    private var isNew: Bool {
        if case .new = presentation { return true }
        return false
    }

    private var originalName: String? {
        guard case .edit(let value) = presentation else { return nil }
        return value.name
    }

    private func save() {
        do {
            let draft = try PersonalityDraft.validated(
                originalName: originalName,
                name: name,
                description: description,
                systemPrompt: systemPrompt,
                tone: tone,
                style: style
            )
            validationMessage = nil
            Task {
                await store.save(draft)
                if store.errorMessage == nil { dismiss() }
            }
        } catch {
            validationMessage = "Add a valid name and personality instructions before saving."
        }
    }

    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme
}
