import SwiftUI

/// A new card: what needs doing, who does it, and whether it starts now.
struct KanbanNewTaskSheet: View {
    @Bindable var model: KanbanBoardModel
    @State private var lane: KanbanLane
    @State private var title = ""
    @State private var details = ""
    @State private var assignee: String?
    @State private var priority = KanbanPriority.normal
    @State private var isSaving = false
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: KanbanBoardModel, lane: KanbanLane) {
        self.model = model
        _lane = State(initialValue: lane == .ready ? .ready : .later)
        if case .agent(let id) = model.agentFilter { _assignee = State(initialValue: id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space24) {
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        TextField("What needs doing?", text: $title, axis: .vertical)
                            .font(.bighelp(.title3).weight(.semibold))
                            .lineLimit(1...4)
                            .focused($titleFocused)
                            .accessibilityIdentifier("kanban.new.title")
                        TextField("Add details for the bot (optional)", text: $details, axis: .vertical)
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1...8)
                            .accessibilityIdentifier("kanban.new.details")
                    }
                    .padding(BighelpTokens.space16)
                    .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16, style: .continuous))

                    field("Who does it") { agentPicker }
                    field("When") {
                        Picker("When", selection: $lane) {
                            Text("Later").tag(KanbanLane.later)
                            Text("Start now").tag(KanbanLane.ready)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("kanban.new.when")
                        Text(lane == .ready
                             ? "Goes to Ready. A bot picks it up next and works on it with AI."
                             : model.autoPlan == true
                                ? "Goes to Later. Auto plan is on, so Hermes may split it into smaller tasks."
                                : "Goes to Later. Nothing runs until you move it to Ready.")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                    }
                    field("Priority") {
                        Picker("Priority", selection: $priority) {
                            ForEach(KanbanPriority.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(BighelpTokens.space20)
            }
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("New card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                        .accessibilityIdentifier("kanban.new.add")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { titleFocused = true }
    }

    private var agentPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space12) {
                agentOption(id: nil, name: "Anyone") {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 26))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 44, height: 44)
                }
                ForEach(model.assignableAgents) { agent in
                    agentOption(id: agent.id, name: agent.name) {
                        AvatarView(stableID: agent.id, displayName: agent.name, imageURL: agent.imageURL, size: 44)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func agentOption<Face: View>(id: String?, name: String, @ViewBuilder face: () -> Face) -> some View {
        let selected = assignee == id
        return Button { assignee = id } label: {
            VStack(spacing: 6) {
                face()
                    .padding(3)
                    .overlay { Circle().strokeBorder(selected ? theme.action : .clear, lineWidth: 2.5) }
                Text(name.split(separator: " ").first.map(String.init) ?? name)
                    .font(.bighelp(.caption).weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: 64)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("kanban.new.agent.\(id ?? "anyone")")
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text(title.uppercased())
                .font(.bighelp(.caption).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(theme.secondaryText)
            content()
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await model.create(title: title, details: details, lane: lane, assignee: assignee, priority: priority) {
            dismiss()
        }
    }

    @BighelpThemeReader private var theme
}
