import SwiftUI

/// New Section, or a section's Edit Members: its name, and every bot and group chat to pick, by
/// computer with every computer shown. A bot is in one section at a time, so picking one from another
/// section moves it here.
struct SimpleBotsSectionMembersSheet: View {
    let model: SimpleBotsSectionsModel
    /// Nil makes a new one.
    let section: FleetSection?
    @State private var name: String
    @State private var picked: Set<String>
    @State private var isSaving = false
    @FocusState private var isNameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    init(model: SimpleBotsSectionsModel, section: FleetSection?, picked: Set<String> = []) {
        self.model = model
        self.section = section
        _name = State(initialValue: section?.name ?? "")
        _picked = State(initialValue: section.map { model.editor.memberIDs(of: $0.id) } ?? picked)
    }

    private struct Computer: Identifiable {
        let id: String
        let title: String?
        let items: [SimpleBotsItem]
    }

    /// One list, or one per computer (the gateway in use first) with every computer shown.
    private var computers: [Computer] {
        guard let hostNames = model.hostNames else {
            return [Computer(id: "all", title: nil, items: model.candidates)]
        }
        var order: [UUID] = []
        var items: [UUID: [SimpleBotsItem]] = [:]
        var unknown: [SimpleBotsItem] = []
        for item in model.candidates {
            guard let host = item.hostID else { unknown.append(item); continue }
            if items[host] == nil { order.append(host) }
            items[host, default: []].append(item)
        }
        return order.map { host in
            Computer(id: host.uuidString, title: hostNames[host].map { String(localized: "On \($0)") },
                     items: items[host] ?? [])
        } + (unknown.isEmpty ? [] : [Computer(id: "other", title: nil, items: unknown)])
    }

    private var cleanName: String? { FleetSection.cleanName(name) }

    var body: some View {
        NavigationStack {
            List {
                Section("Name") {
                    TextField("Section name", text: $name)
                        .font(.bighelp(.body))
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .bighelpMacField()
                        .accessibilityIdentifier("simple-bots.section.name")
                        .listRowBackground(theme.surface)
                }
                let computers = computers
                ForEach(computers) { computer in
                    Section {
                        ForEach(computer.items) { row($0) }
                    } header: {
                        if let title = computer.title { Text(title) }
                    } footer: {
                        if computer.id == computers.last?.id {
                            Text("A bot is in one section at a time. Picking a bot from another section moves it here.")
                        }
                    }
                }
                if model.candidates.isEmpty {
                    Section {
                        Text("No bots or group chats to add yet.")
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(section == nil ? "New Section" : "Edit Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("simple-bots.section.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(section == nil ? "Create" : "Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(cleanName == nil || isSaving)
                        .bighelpDefaultAction()
                        .accessibilityIdentifier("simple-bots.section.save")
                }
            }
            .onAppear { if section == nil { isNameFocused = true } }
        }
        .accessibilityIdentifier("simple-bots.section.members")
    }

    private func row(_ item: SimpleBotsItem) -> some View {
        let isPicked = picked.contains(item.id)
        let note = note(for: item, isPicked: isPicked)
        return Button {
            if isPicked { picked.remove(item.id) } else { picked.insert(item.id) }
        } label: {
            HStack(spacing: BighelpTokens.space12) {
                face(item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                    if let note {
                        Text(note)
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer(minLength: BighelpTokens.space8)
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.bighelp(.title3))
                    .foregroundStyle(isPicked ? theme.action : theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .listRowBackground(theme.surface)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityValue(isPicked ? "Selected" : "Not selected")
        .accessibilityIdentifier("simple-bots.section.member.\(item.id)")
    }

    @ViewBuilder
    private func face(_ item: SimpleBotsItem) -> some View {
        switch item.kind {
        case .bot(let bot):
            SimpleBotFace(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL, size: 40)
                .companionScope(bot.faceScope)
        case .group(let group):
            SimpleBotsGroupFace(members: group.members, size: 40)
        }
    }

    /// "In Work" while it's in another section; "Moves from Work" once it's picked. A group chat says
    /// so, then that or who's in it.
    private func note(for item: SimpleBotsItem, isPicked: Bool) -> String? {
        let current = model.sectioning.section(of: item.kind)
        let elsewhere = current.flatMap { $0.id == section?.id ? nil : $0.name }
        let place: String? = elsewhere.map { isPicked ? String(localized: "Moves from \($0)") : String(localized: "In \($0)") }
        guard case .group(let group) = item.kind else { return place }
        let members = group.members.isEmpty ? nil : ListFormatter.localizedString(byJoining: group.members.map(\.name))
        return [String(localized: "Group chat"), place ?? members].compactMap { $0 }.joined(separator: " · ")
    }

    private func save() async {
        guard let clean = cleanName, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        if let section {
            if clean != section.name { await model.editor.rename(section.id, to: clean) }
            await model.editor.setMembers(of: section.id, to: picked)
        } else {
            await model.editor.create(named: clean, members: picked)
        }
        dismiss()
    }
}

/// Edit Sections: every section in its order, to rename, drag into place or delete, and New
/// Section. Nothing changes until Done; deleting asks first, and keeps every member.
struct SimpleBotsEditSectionsSheet: View {
    let model: SimpleBotsSectionsModel

    private struct Draft: Identifiable, Equatable {
        let id: String
        var name: String
        /// Made here; Done makes it.
        var isNew = false
    }

    @State private var drafts: [Draft]
    @State private var deleted: [Draft] = []
    @State private var deleting: Draft?
    @State private var isSaving = false
    @FocusState private var focused: String?
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    init(model: SimpleBotsSectionsModel) {
        self.model = model
        _drafts = State(initialValue: model.sections.map { Draft(id: $0.id, name: $0.name) })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Section name", text: $draft.name)
                                .font(.bighelp(.body))
                                .textInputAutocapitalization(.words)
                                .focused($focused, equals: draft.id)
                                .bighelpMacField()
                                .accessibilityIdentifier("simple-bots.sections.name.\(draft.name)")
                            Text(draft.isNew ? String(localized: "New section") : model.countText(of: draft.id))
                                .font(.bighelp(.subheadline))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .padding(.vertical, BighelpTokens.space4)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .listRowBackground(theme.surface)
                    }
                    .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        guard let index = offsets.first else { return }
                        if drafts[index].isNew { drafts.remove(at: index) } else { deleting = drafts[index] }
                    }
                    Button {
                        let draft = Draft(id: UUID().uuidString, name: "", isNew: true)
                        drafts.append(draft)
                        focused = draft.id
                    } label: {
                        Label("New Section", systemImage: "plus.circle.fill")
                            .font(.bighelp(.body))
                            .frame(minHeight: BighelpTokens.hitTarget, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .bighelpPlainButtonStyle()
                    .foregroundStyle(theme.primaryText)
                    .listRowBackground(theme.surface)
                    .disabled(drafts.count >= FleetSection.maximumCount)
                    .accessibilityIdentifier("simple-bots.sections.new")
                } footer: {
                    Text("Tap a name to rename it. Drag to change the order. Bots' sections show in Hermes Desktop too.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Edit Sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("simple-bots.sections.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(isSaving)
                        .bighelpDefaultAction()
                        .accessibilityIdentifier("simple-bots.sections.done")
                }
            }
            .alert(deleting.map { String(localized: "Delete “\($0.name)”?") } ?? "",
                   isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete Section", role: .destructive) {
                    if let draft = deleting {
                        drafts.removeAll { $0.id == draft.id }
                        deleted.append(draft)
                    }
                    deleting = nil
                }
                .accessibilityIdentifier("simple-bots.section.delete.confirm")
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                if let deleting { Text(model.deleteMessage(deleting.id)) }
            }
        }
        .accessibilityIdentifier("simple-bots.sections.edit")
    }

    /// Deletes, renames, makes the new ones, then puts them all in the order shown.
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let editor = model.editor
        for draft in deleted { await editor.delete(draft.id) }
        var order: [String] = []
        for draft in drafts {
            guard let clean = FleetSection.cleanName(draft.name) else {
                if !draft.isNew { order.append(draft.id) }
                continue
            }
            if draft.isNew {
                if let made = editor.fleet.createSection(named: clean) { order.append(made.id) }
            } else {
                if clean != editor.fleet.section(id: draft.id)?.name { await editor.rename(draft.id, to: clean) }
                order.append(draft.id)
            }
        }
        editor.fleet.orderSections(order)
        dismiss()
    }
}
