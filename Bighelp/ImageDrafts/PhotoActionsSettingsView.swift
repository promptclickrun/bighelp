import SwiftUI

extension ImageDraftPreset: Identifiable {
    var id: String { rawValue }

    /// "Business cards → Contacts", the section caption.
    var settingsTitle: String {
        switch self {
        case .businessCard: String(localized: "Business cards → Contacts")
        case .eventPoster: String(localized: "Event posters → Calendar")
        }
    }

    var offerTitle: String {
        switch self {
        case .businessCard: String(localized: "Offer when I send a card")
        case .eventPoster: String(localized: "Offer when I send a poster")
        }
    }

    var readingTitle: String {
        switch self {
        case .businessCard: String(localized: "How to read business cards")
        case .eventPoster: String(localized: "How to read event posters")
        }
    }

    /// Made-up values the preview fills the messages with.
    var sample: (name: String, destination: String, fields: String) {
        switch self {
        case .businessCard: ("Riley Moss", "iCloud", String(localized: "last name"))
        case .eventPoster: ("Night Market", "Home", String(localized: "end time"))
        }
    }
}

extension ImageActionMessageKey: Identifiable {
    var id: String { rawValue }

    var settingsTitle: String {
        switch self {
        case .review: String(localized: "Before you review")
        case .missingFields: String(localized: "Something is missing")
        case .saved: String(localized: "Saved")
        case .failed: String(localized: "Didn't save")
        case .outcomeUnknown: String(localized: "Not sure it saved")
        }
    }
}

extension ImageActionTemplateError {
    func message(for key: ImageActionMessageKey?) -> String {
        switch self {
        case .empty: return String(localized: "Write something, or use the default.")
        case .tooLong: return String(localized: "That's too long.")
        case .notPlainText: return String(localized: "Use plain text only.")
        case .unbalanced: return String(localized: "Each {{ needs a matching }} around one lowercase word.")
        case .unknownPlaceholder(let name):
            let allowed = key.map { $0.placeholders.sorted().map { "{{\($0)}}" }.joined(separator: ", ") } ?? ""
            return allowed.isEmpty
                ? String(localized: "{{\(name)}} can't be used in this message.")
                : String(localized: "{{\(name)}} can't be used here. You can use \(allowed).")
        }
    }
}

/// An agent's Photo actions: for business cards and event posters, whether it offers, how it reads
/// them, what it asks when a picture is unclear, and what the review says. Save, Discard and the
/// warnings belong to the app, so nothing here can hide them.
@MainActor
struct PhotoActionsSettingsView: View {
    let agentID: String
    let agentName: String

    @State private var store = PhotoActionsSettingsStore.shared
    @State private var notice: String?
    @State private var previewing: ImageDraftPreset?
    @State private var resetting: ImageDraftPreset?
    @BighelpThemeReader private var theme

    private var entry: PhotoActionsSettingsStore.Entry { store.entry(agentID) }
    private var settings: ImageActionsSettings { entry.page.settings }
    private var defaults: ImageActionsDefaults { entry.page.defaults }
    private var canEdit: Bool { entry.load == .loaded && !store.saving.contains(agentID) }

    var body: some View {
        Form {
            Section {
                status
            } header: {
                Text("Send \(agentName) a photo and ask, and it makes a contact or an event for you to check. Nothing is saved until you tap Save.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(ImageDraftPreset.allCases) { preset in
                presetSection(preset)
            }
            Section {
            } footer: {
                Text("Save, Discard and the warnings about missing details always show. Your text adds to them; it can't hide them.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Photo actions")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: agentID) { await store.refresh(agentID) }
        .bighelpSheet(item: $previewing) { preset in
            PhotoActionsPreview(preset: preset, effective: settings.effective(preset, defaults: defaults))
                .bighelpSheetSize(.standard)
        }
        .confirmationDialog("Reset to defaults?", isPresented: Binding(
            get: { resetting != nil }, set: { if !$0 { resetting = nil } }), titleVisibility: .visible,
            presenting: resetting) { preset in
            Button("Reset to defaults", role: .destructive) {
                change { settings, _ in settings.reset(preset) }
            }
            .accessibilityIdentifier("photo-actions.reset.confirm")
        } message: { preset in
            Text("\(preset.settingsTitle) goes back to bighelp's own text. Device access doesn't change.")
        }
        .alert("Photo actions", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
        } message: {
            Text(notice ?? "")
        }
        .accessibilityIdentifier("photo-actions.page")
    }

    @ViewBuilder
    private var status: some View {
        switch entry.load {
        case .needsPluginUpdate:
            Label("Update the bighelp plugin on this computer to use Photo actions.", systemImage: "arrow.down.circle")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.warning)
                .listRowBackground(theme.surface)
                .accessibilityIdentifier("photo-actions.needs-plugin-update")
        case .unavailable:
            Label("Can't reach the computer. These are the defaults until it answers.", systemImage: "wifi.exclamationmark")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .listRowBackground(theme.surface)
        case .idle, .loading, .loaded:
            EmptyView()
        }
    }

    private func presetSection(_ preset: ImageDraftPreset) -> some View {
        let effective = settings.effective(preset, defaults: defaults)
        let overrides = settings[preset]
        return Section {
            Toggle(preset.offerTitle, isOn: Binding(
                get: { effective.offer },
                set: { on in change { settings, defaults in settings.set(offer: on, for: preset, defaults: defaults) } }))
                .tint(theme.action)
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("photo-actions.\(preset.rawValue).offer")
            NavigationLink {
                PhotoActionsTextPage(agentID: agentID, preset: preset, kind: .instructions)
            } label: {
                textRow(String(localized: "How to read them"), preview: effective.instructions,
                        isEdited: overrides.instructions != nil)
            }
            .accessibilityIdentifier("photo-actions.\(preset.rawValue).instructions")
            NavigationLink {
                PhotoActionsTextPage(agentID: agentID, preset: preset, kind: .question)
            } label: {
                textRow(String(localized: "Question when unclear"), preview: effective.question,
                        isEdited: overrides.question != nil)
            }
            .accessibilityIdentifier("photo-actions.\(preset.rawValue).question")
            NavigationLink {
                PhotoActionsMessagesPage(agentID: agentID, preset: preset)
            } label: {
                HStack {
                    Text("Review messages").foregroundStyle(theme.primaryText)
                    if !overrides.messages.isEmpty { editedBadge }
                    Spacer()
                    if overrides.messages.isEmpty {
                        Text("Default").font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                    }
                }
                .frame(minHeight: BighelpTokens.hitTarget)
            }
            .accessibilityIdentifier("photo-actions.\(preset.rawValue).messages")
            Button("Preview") { previewing = preset }
                .foregroundStyle(theme.action)
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("photo-actions.\(preset.rawValue).preview")
            if !overrides.isEmpty {
                Button("Reset to defaults", role: .destructive) { resetting = preset }
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("photo-actions.\(preset.rawValue).reset")
            }
        } header: {
            AgentStudioCaption(preset.settingsTitle)
        }
        .disabled(!canEdit)
        .listRowBackground(theme.surface)
    }

    private func textRow(_ title: String, preview: String, isEdited: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(theme.primaryText)
                if isEdited { editedBadge }
            }
            Text(preview)
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
        }
        .padding(.vertical, BighelpTokens.space4)
        .frame(minHeight: BighelpTokens.hitTarget, alignment: .leading)
    }

    private var editedBadge: some View {
        Text("Edited")
            .font(.bighelp(.caption2, weight: .bold))
            .foregroundStyle(theme.action)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.action.opacity(0.12), in: .capsule)
    }

    private func change(_ edit: @escaping (inout ImageActionsSettings, ImageActionsDefaults) -> Void) {
        Task { @MainActor in
            do throws(PhotoActionsSaveError) {
                try await store.update(agentID, edit)
            } catch {
                notice = error.message
            }
        }
    }
}

/// One long text: how to read a kind of picture, or the question for an unclear one.
@MainActor
struct PhotoActionsTextPage: View {
    enum Kind { case instructions, question }

    let agentID: String
    let preset: ImageDraftPreset
    let kind: Kind

    @State private var store = PhotoActionsSettingsStore.shared
    @State private var text = ""
    @State private var loaded = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    private var entry: PhotoActionsSettingsStore.Entry { store.entry(agentID) }
    private var defaultText: String {
        let defaults = entry.page.defaults[preset]
        return kind == .instructions ? defaults.instructions : defaults.question
    }
    private var savedText: String {
        let effective = entry.page.settings.effective(preset, defaults: entry.page.defaults)
        return kind == .instructions ? effective.instructions : effective.question
    }
    private var maximum: Int {
        kind == .instructions ? ImageActionsSettings.maximumInstructions : ImageActionsSettings.maximumQuestion
    }
    private var problem: String? {
        do throws(ImageActionTemplateError) {
            if kind == .instructions { try ImageActionsSettings.checkInstructions(text) }
            else { try ImageActionsSettings.checkQuestion(text) }
            return nil
        } catch {
            return error.message(for: nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            TextEditor(text: $text)
                .font(.bighelp(.body))
                .scrollContentBackground(.hidden)
                .padding(BighelpTokens.space12)
                .frame(minHeight: kind == .instructions ? 220 : 100)
                .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16, style: .continuous))
                .accessibilityIdentifier("photo-actions.text.editor")
            HStack {
                Text("\(ImageDraftText.length(text)) of \(maximum)")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                if text != defaultText {
                    Button("Use the default") { text = defaultText }
                        .font(.bighelp(.footnote, weight: .semibold))
                        .foregroundStyle(theme.action)
                        .accessibilityIdentifier("photo-actions.text.default")
                }
            }
            if let problem = problem ?? errorMessage {
                Text(problem).font(.bighelp(.footnote)).foregroundStyle(theme.danger)
            }
            Text(kind == .instructions
                 ? "The agent reads this whenever you send a picture of this kind. Text inside a picture never counts as instructions."
                 : "The agent asks this when it can't tell what you want from a picture, instead of guessing.")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(BighelpTokens.space16)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle(kind == .instructions ? preset.readingTitle : String(localized: "Question when unclear"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .fontWeight(.semibold)
                    .disabled(text == savedText || problem != nil || store.saving.contains(agentID))
                    .accessibilityIdentifier("photo-actions.text.save")
            }
        }
        .onAppear {
            guard !loaded else { return }
            text = savedText
            loaded = true
        }
    }

    private func save() {
        let value = text
        let preset = preset
        let kind = kind
        Task { @MainActor in
            do throws(PhotoActionsSaveError) {
                try await store.update(agentID) { settings, defaults in
                    if kind == .instructions { settings.set(instructions: value, for: preset, defaults: defaults) }
                    else { settings.set(question: value, for: preset, defaults: defaults) }
                }
                dismiss()
            } catch {
                errorMessage = error.message
            }
        }
    }
}

/// The five review messages for one kind of picture, with the placeholders each may use.
@MainActor
struct PhotoActionsMessagesPage: View {
    let agentID: String
    let preset: ImageDraftPreset

    @State private var store = PhotoActionsSettingsStore.shared
    @State private var texts: [ImageActionMessageKey: String] = [:]
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var previewing = false
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    private var entry: PhotoActionsSettingsStore.Entry { store.entry(agentID) }
    private var saved: ImageDraftMessages { entry.page.settings.effective(preset, defaults: entry.page.defaults).messages }
    private var defaults: ImageDraftMessages { entry.page.defaults[preset].messages }

    private var draftMessages: ImageDraftMessages {
        var messages = saved
        for key in ImageActionMessageKey.allCases { if let text = texts[key] { messages.set(text, for: key) } }
        return messages
    }

    private func problem(_ key: ImageActionMessageKey) -> String? {
        do throws(ImageActionTemplateError) {
            try ImageActionTemplate.validate(texts[key] ?? saved[key], for: key)
            return nil
        } catch {
            return error.message(for: key)
        }
    }

    private var hasChanges: Bool { draftMessages != saved }
    /// The saved settings with the messages as typed, unsaved.
    private var previewEffective: ImageActionsEffectivePreset {
        var effective = entry.page.settings.effective(preset, defaults: entry.page.defaults)
        effective.messages = draftMessages
        return effective
    }
    private var isValid: Bool { ImageActionMessageKey.allCases.allSatisfy { problem($0) == nil } }

    var body: some View {
        Form {
            ForEach(ImageActionMessageKey.allCases) { key in
                Section {
                    TextField(key.settingsTitle, text: binding(key), axis: .vertical)
                        .font(.bighelp(.body))
                        .lineLimit(1...5)
                        .bighelpMacField()
                        .accessibilityIdentifier("photo-actions.message.\(key.rawValue)")
                    if !key.placeholders.isEmpty {
                        HStack(spacing: BighelpTokens.space8) {
                            ForEach(key.placeholders.sorted(), id: \.self) { name in
                                Button {
                                    texts[key] = (texts[key] ?? saved[key]) + "{{\(name)}}"
                                } label: {
                                    Label(name, systemImage: "plus")
                                        .font(.bighelp(.footnote, weight: .semibold))
                                        .foregroundStyle(theme.action)
                                        .padding(.horizontal, BighelpTokens.space8)
                                        .padding(.vertical, BighelpTokens.space4)
                                        .background(theme.action.opacity(0.12), in: .capsule)
                                }
                                .bighelpPlainButtonStyle()
                                .accessibilityLabel(Text("Insert \(name)"))
                            }
                        }
                    }
                    if let problem = problem(key) {
                        Text(problem).font(.bighelp(.footnote)).foregroundStyle(theme.danger)
                    }
                } header: {
                    AgentStudioCaption(key.settingsTitle)
                }
                .listRowBackground(theme.surface)
            }
            Section {
                Button("Preview") { previewing = true }
                    .foregroundStyle(theme.action)
                if draftMessages != defaults {
                    Button("Use the defaults") {
                        for key in ImageActionMessageKey.allCases { texts[key] = defaults[key] }
                    }
                    .foregroundStyle(theme.action)
                    .accessibilityIdentifier("photo-actions.messages.default")
                }
            } footer: {
                if let errorMessage {
                    Text(errorMessage).font(.bighelp(.footnote)).foregroundStyle(theme.danger)
                }
            }
            .listRowBackground(theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Review messages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .fontWeight(.semibold)
                    .disabled(!hasChanges || !isValid || store.saving.contains(agentID))
                    .accessibilityIdentifier("photo-actions.messages.save")
            }
        }
        .bighelpSheet(isPresented: $previewing) {
            PhotoActionsPreview(preset: preset, effective: previewEffective)
                .bighelpSheetSize(.standard)
        }
    }

    private func binding(_ key: ImageActionMessageKey) -> Binding<String> {
        Binding(get: { texts[key] ?? saved[key] }, set: { texts[key] = $0 })
    }

    private func save() {
        let messages = draftMessages
        let preset = preset
        Task { @MainActor in
            do throws(PhotoActionsSaveError) {
                try await store.update(agentID) { settings, defaults in
                    for key in ImageActionMessageKey.allCases {
                        settings.set(message: messages[key], key, for: preset, defaults: defaults)
                    }
                }
                dismiss()
            } catch {
                errorMessage = error.message
            }
        }
    }
}

/// How the review and the chat read with these messages and a made-up picture. The warning box is
/// drawn exactly as the review draws it, to show that it stays whatever the messages say.
@MainActor
struct PhotoActionsPreview: View {
    let preset: ImageDraftPreset
    let effective: ImageActionsEffectivePreset

    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    var body: some View {
        let sample = preset.sample
        let values = ["destination": sample.destination, "name": sample.name, "fields": sample.fields,
                      "reason": ImageDraftFailureReason.permissionDenied.message]
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    caption("In the review")
                    ImageDraftReviewNote(text: ImageActionTemplate.render(effective.messages.review, values: values))
                    ImageDraftCheckBox(lines: [String(localized: "Last name: missing")],
                                       note: ImageActionTemplate.render(effective.messages.missingFields, values: values))
                    Text("bighelp always shows this box and Save and Discard.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                    caption("In the chat")
                    previewLine(ImageActionTemplate.render(effective.messages.saved, values: values),
                                systemImage: "checkmark.circle.fill", color: theme.success)
                    previewLine(ImageActionTemplate.render(effective.messages.failed, values: values),
                                systemImage: "xmark.circle.fill", color: theme.danger)
                    previewLine(ImageActionTemplate.render(effective.messages.outcomeUnknown, values: values),
                                systemImage: "questionmark.circle.fill", color: theme.warning)
                }
                .padding(BighelpTokens.space16)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(theme.action)
                        .bighelpDefaultAction()
                }
            }
        }
        .accessibilityIdentifier("photo-actions.preview")
    }

    private func caption(_ text: String) -> some View {
        AgentStudioCaption(text)
    }

    private func previewLine(_ text: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(text).foregroundStyle(theme.primaryText)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .font(.bighelp(.subheadline))
        .padding(BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius12, style: .continuous))
    }
}
