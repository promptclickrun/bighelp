import SwiftUI

/// Goals › Edit categories: the computer's own goal categories, for every bot on it. A row opens
/// its name and emoji; a swipe, the row's menu or the editor deletes it. Each change goes to the
/// computer first (`AgentBoardStore.changeGoalCategories`) and shows once it took it; a refusal
/// stays on the page in plain words. Other is listed, and never changes.
struct GoalCategoriesSheet: View {
    let context: AgentBoardContext

    /// What the editor is open on: a category, or a new one.
    struct Draft: Identifiable, Hashable {
        /// Nil for a new category.
        var categoryID: String?
        var name = ""
        var icon = ""

        var id: String { categoryID ?? "new" }
    }

    private struct Request: Equatable {
        let change: GoalCategoryChange
        let attempt = UUID()
    }

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Draft?
    @State private var deleting: GoalCategoryInfo?
    @State private var request: Request?
    @State private var failure: String?

    var body: some View {
        let categories = context.store.goalCategories
        NavigationStack {
            List {
                Section {
                    // One change at a time: a second one would cancel the first while the computer works on it.
                    ForEach(categories) { row($0).disabled(request != nil) }
                } footer: {
                    if let failure, draft == nil {
                        Text(failure)
                            .foregroundStyle(theme.danger)
                            .accessibilityIdentifier("board.goals.categories.error")
                    } else {
                        Text("Every bot on this computer uses these. When you delete a category, its goals move to Other.")
                    }
                }
                .listRowBackground(theme.surface)
                if categories.count < GoalCategoryInfo.maximumCount {
                    Section {
                        Button {
                            failure = nil
                            draft = Draft()
                        } label: {
                            Label("Add category", systemImage: "plus")
                                .font(.bighelp(.body).weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .bighelpPlainButtonStyle()
                        .foregroundStyle(theme.action)
                        .disabled(request != nil)
                        .accessibilityIdentifier("board.goals.categories.add")
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("board.goals.categories.done")
                }
            }
            .navigationDestination(item: $draft) { draft in
                GoalCategoryEditor(draft: draft, isBusy: request != nil, failure: failure) { change in
                    request = Request(change: change)
                }
            }
        }
        .confirmationDialog(deleting.map { String(localized: "Delete \($0.name)?") } ?? "",
                            isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
                            titleVisibility: .visible, presenting: deleting) { category in
            Button("Delete category", role: .destructive) { request = Request(change: .delete(id: category.id)) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its goals move to Other.")
        }
        // A refusal belongs to the page that asked: leaving the editor leaves it behind.
        .onChange(of: draft) { old, new in
            if old != nil, new == nil, request == nil { failure = nil }
        }
        .task(id: request) {
            guard let request else { return }
            let refusal = await context.store.changeGoalCategories(request.change)
            guard !Task.isCancelled, self.request == request else { return }
            failure = refusal
            self.request = nil
            // The editor closes on a change the computer took; a refusal stays there to fix.
            if failure == nil { draft = nil }
        }
        .bighelpSheetSize(.standard)
        .accessibilityIdentifier("board.goals.categories")
    }

    @ViewBuilder
    private func row(_ category: GoalCategoryInfo) -> some View {
        let label = HStack(spacing: BighelpTokens.space12) {
            BoardIconTile(icon: category.icon, fallback: category.systemImage, color: .goal(category), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.bighelp(.body).weight(.medium))
                    .foregroundStyle(theme.primaryText)
                if category.isOther {
                    Text("For goals in no category")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            if !category.isOther {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .contentShape(.rect)
        if category.isOther {
            label
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("board.goals.categories.row.\(category.id)")
        } else {
            Button {
                failure = nil
                draft = Draft(categoryID: category.id, name: category.name, icon: category.icon)
            } label: {
                label
            }
            .bighelpPlainButtonStyle()
            .accessibilityHint("Changes its name and emoji")
            .accessibilityIdentifier("board.goals.categories.row.\(category.id)")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = category }
            }
            // The Mac has no swipe: a right-click offers the same.
            .contextMenu {
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = category }
            }
        }
    }

    @BighelpThemeReader private var theme
}

/// One category's name and emoji. Save sends the change; the sheet closes this page once the
/// computer took it.
private struct GoalCategoryEditor: View {
    let draft: GoalCategoriesSheet.Draft
    let isBusy: Bool
    let failure: String?
    let onChange: (GoalCategoryChange) -> Void

    @State private var name = ""
    @State private var icon = ""
    @State private var confirmsDelete = false
    @FocusState private var nameIsFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !isBusy && !trimmedName.isEmpty && (draft.categoryID == nil || trimmedName != draft.name || icon != draft.icon)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Name").bighelpFieldHint(theme))
                    .focused($nameIsFocused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { save() } }
                    .onChange(of: name) { _, value in
                        if value.count > GoalCategoryInfo.maximumNameLength {
                            name = String(value.prefix(GoalCategoryInfo.maximumNameLength))
                        }
                    }
                    .accessibilityIdentifier("board.goals.categories.name")
                TextField("Emoji", text: $icon, prompt: Text("Emoji (optional)").bighelpFieldHint(theme))
                    .onChange(of: icon) { _, value in
                        let kept = Self.emoji(in: value)
                        if kept != value { icon = kept }
                    }
                    .accessibilityIdentifier("board.goals.categories.icon")
            } footer: {
                if let failure {
                    Text(failure)
                        .foregroundStyle(theme.danger)
                        .accessibilityIdentifier("board.goals.categories.error")
                } else if draft.categoryID != nil {
                    Text("A new name keeps its goals.")
                }
            }
            .listRowBackground(theme.surface)
            if draft.categoryID != nil {
                Section {
                    Button("Delete category", role: .destructive) { confirmsDelete = true }
                        .disabled(isBusy)
                        .accessibilityIdentifier("board.goals.categories.delete")
                }
                .listRowBackground(theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle(draft.categoryID == nil ? "New category" : "Edit category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("board.goals.categories.save")
            }
        }
        .confirmationDialog(String(localized: "Delete \(draft.name)?"), isPresented: $confirmsDelete,
                            titleVisibility: .visible) {
            Button("Delete category", role: .destructive) {
                if let id = draft.categoryID { onChange(.delete(id: id)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its goals move to Other.")
        }
        .onAppear {
            name = draft.name
            icon = draft.icon
            if draft.categoryID == nil { nameIsFocused = true }
        }
    }

    private func save() {
        if let id = draft.categoryID {
            onChange(.update(id: id, name: trimmedName, icon: icon))
        } else {
            onChange(.add(name: trimmedName, icon: icon))
        }
    }

    /// The last emoji typed, or nothing: the computer takes one emoji and no letters.
    static func emoji(in text: String) -> String {
        guard let last = text.last(where: { character in
            // A keycap ("1️⃣") starts with a digit, which the computer refuses.
            guard let scalar = character.unicodeScalars.first, !scalar.isASCII else { return false }
            return scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && character.unicodeScalars.count > 1)
        }) else { return "" }
        return String(last)
    }

    @BighelpThemeReader private var theme
}
