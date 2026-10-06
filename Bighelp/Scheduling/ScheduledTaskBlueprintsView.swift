import Foundation
import SwiftUI

@MainActor
struct ScheduledTaskBlueprintsView: View {
    private struct Category: Identifiable {
        let name: String
        let items: [ScheduledTaskBlueprint]
        var id: String { name }
    }

    @State private var store: ScheduledTasksStore
    @State private var selectedBlueprint: ScheduledTaskBlueprint?
    @State private var searchQuery = ""
    @Environment(\.dismiss) private var dismiss
    let agents: AgentDirectoryStore

    init(store: ScheduledTasksStore, agents: AgentDirectoryStore) {
        _store = State(initialValue: store)
        self.agents = agents
    }

    var body: some View {
        Group {
            switch store.blueprintsLoadState {
            case .idle, .loading where store.blueprints.isEmpty:
                ProgressView("Loading task ideas")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("scheduled-task.blueprints.loading")
            case .failed(let message) where store.blueprints.isEmpty:
                ContentUnavailableView {
                    Label("Ideas unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await store.loadBlueprints() } }
                }
                .accessibilityIdentifier("scheduled-task.blueprints.error")
            default:
                blueprintList
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Task ideas")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, prompt: "Search ideas")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .bighelpToolbarText()
            }
        }
        .task {
            if store.blueprintsLoadState == .idle { await store.loadBlueprints() }
        }
        .refreshable { await store.loadBlueprints() }
        .bighelpSheet(item: $selectedBlueprint) { blueprint in
            NavigationStack {
                ScheduledTaskBlueprintPreviewView(store: store, agents: agents, blueprint: blueprint)
            }
            .bighelpSheetSize(.standard)
        }
        .accessibilityIdentifier("scheduled-task.blueprints.screen")
    }

    private var blueprintList: some View {
        List {
            if case .failed(let message) = store.blueprintsLoadState {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.danger)
                    Button("Retry") { Task { await store.loadBlueprints() } }
                }
            }
            ForEach(groupedCategories) { category in
                Section {
                    ForEach(category.items) { blueprint in
                        Button { selectedBlueprint = blueprint } label: {
                            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(blueprint.title)
                                        .font(.bighelp(.callout).weight(.semibold))
                                        .foregroundStyle(theme.primaryText)
                                }
                                Text(blueprint.summary)
                                    .font(.bighelp(.subheadline))
                                    .foregroundStyle(theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                Label(blueprint.scheduleDescription, systemImage: "calendar")
                                    .font(.bighelp(.footnote))
                                    .foregroundStyle(theme.action)
                            }
                            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                            .padding(.vertical, BighelpTokens.space4)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(blueprint.title). \(blueprint.summary). \(blueprint.scheduleDescription)")
                        .accessibilityHint("Preview and schedule this automation")
                        .accessibilityIdentifier("scheduled-task.blueprint.\(blueprint.key)")
                    }
                } header: {
                    ScheduledTaskSectionCaption(title: category.name)
                }
                .listRowBackground(theme.surface)
            }
            if store.blueprints.isEmpty || groupedCategories.isEmpty {
                ContentUnavailableView(
                    store.blueprints.isEmpty ? "No ideas yet" : "No matching ideas",
                    systemImage: store.blueprints.isEmpty ? "square.grid.2x2" : "magnifyingglass",
                    description: Text(store.blueprints.isEmpty
                        ? "This Hermes host did not return any task ideas."
                        : "Try another title, category, summary, or schedule."))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var groupedCategories: [Category] {
        Dictionary(grouping: filteredBlueprints, by: { $0.category })
            .map { Category(name: $0.key, items: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredBlueprints: [ScheduledTaskBlueprint] {
        let terms = searchQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return store.blueprints }
        return store.blueprints.filter { blueprint in
            let fields = [blueprint.title, blueprint.category, blueprint.summary, blueprint.scheduleDescription]
            return terms.allSatisfy { term in
                fields.contains { $0.localizedStandardContains(term) }
            }
        }
    }

    @BighelpThemeReader private var theme
}

@MainActor
private struct ScheduledTaskBlueprintPreviewView: View {
    @State private var store: ScheduledTasksStore
    @State private var selectedAgentID: String
    @State private var values: [String: String]
    @State private var showsConfirmation = false
    @State private var creationTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    let agents: AgentDirectoryStore
    let blueprint: ScheduledTaskBlueprint

    init(store: ScheduledTasksStore, agents: AgentDirectoryStore, blueprint: ScheduledTaskBlueprint) {
        _store = State(initialValue: store)
        self.agents = agents
        self.blueprint = blueprint
        _selectedAgentID = State(initialValue: agents.resolvedAgent(explicitID: nil)?.id ?? agents.profiles.first?.id ?? "")
        _values = State(initialValue: blueprint.initialValues())
    }

    var body: some View {
        Form {
            Section {
                Text(blueprint.summary)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Label(blueprint.scheduleDescription, systemImage: "calendar")
                    .bighelpFont(.label)
                    .foregroundStyle(theme.primaryText)
            } header: {
                Text("Overview")
            }

            Section("Which agent?") {
                if agents.profiles.isEmpty {
                    Text("No available agents")
                        .foregroundStyle(theme.danger)
                } else {
                    Picker("Owner", selection: $selectedAgentID) {
                        ForEach(agents.profiles) { agent in Text(agent.name).tag(agent.id) }
                    }
                    .accessibilityIdentifier("scheduled-task.blueprint.agent")
                }
            }

            Section("Setup") {
                ForEach(blueprint.fields) { field in
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        Text(field.label + (field.isOptional ? " (Optional)" : ""))
                            .font(.bighelp(.subheadline).weight(.semibold))
                        fieldControl(field)
                        if !field.help.isEmpty {
                            Text(field.help)
                                .font(.bighelp(.footnote))
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, BighelpTokens.space4)
                }
            }

            if let message = localValidationMessage ?? store.blueprintErrorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("scheduled-task.blueprint.error")
                    if store.isInstantiatingBlueprint {
                        Button("Cancel scheduling", role: .destructive) {
                            creationTask?.cancel()
                        }
                        .accessibilityIdentifier("scheduled-task.blueprint.cancel-request")
                    }
                }
            } else if store.isInstantiatingBlueprint {
                Section {
                    ProgressView("Scheduling automation")
                    Button("Cancel scheduling", role: .destructive) {
                        creationTask?.cancel()
                    }
                    .accessibilityIdentifier("scheduled-task.blueprint.cancel-request")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle(blueprint.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if store.isInstantiatingBlueprint {
                        creationTask?.cancel()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .bighelpToolbarText()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Review") { review() }
                    .disabled(selectedAgentID.isEmpty || store.isInstantiatingBlueprint)
                    .accessibilityIdentifier("scheduled-task.blueprint.review")
            }
        }
        .confirmationDialog("Schedule this automation?", isPresented: $showsConfirmation, titleVisibility: .visible) {
            Button("Schedule") { create() }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text(reviewSummary)
        }
        .onDisappear {
            if store.isInstantiatingBlueprint { creationTask?.cancel() }
        }
        .accessibilityIdentifier("scheduled-task.blueprint.preview.\(blueprint.key)")
    }

    @ViewBuilder
    private func fieldControl(_ field: ScheduledTaskBlueprintField) -> some View {
        switch field.kind {
        case .time:
            DatePicker("Time", selection: timeBinding(for: field), displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("scheduled-task.blueprint.field.\(field.name)")
        case .enumeration, .weekdays:
            if field.name == "deliver" {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    ForEach(field.options, id: \.self) { option in
                        Toggle(option.capitalized, isOn: deliveryBinding(option, field: field))
                            .frame(minHeight: BighelpTokens.hitTarget)
                    }
                }
                .accessibilityIdentifier("scheduled-task.blueprint.field.\(field.name)")
            } else if !field.options.isEmpty {
                Picker(field.label, selection: valueBinding(for: field)) {
                    ForEach(field.options, id: \.self) { option in Text(option.capitalized).tag(option) }
                }
                .accessibilityIdentifier("scheduled-task.blueprint.field.\(field.name)")
            } else {
                TextField(field.label, text: valueBinding(for: field))
                    .accessibilityIdentifier("scheduled-task.blueprint.field.\(field.name)")
            }
        case .text:
            TextField(field.label, text: valueBinding(for: field), axis: .vertical)
                .lineLimit(2...6)
                .accessibilityIdentifier("scheduled-task.blueprint.field.\(field.name)")
        }
    }

    private func valueBinding(for field: ScheduledTaskBlueprintField) -> Binding<String> {
        Binding(
            get: { values[field.name] ?? field.defaultValue ?? "" },
            set: { values[field.name] = $0 }
        )
    }

    private func timeBinding(for field: ScheduledTaskBlueprintField) -> Binding<Date> {
        Binding(
            get: { Self.date(from: values[field.name] ?? field.defaultValue) ?? .now },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                values[field.name] = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
            }
        )
    }

    private func deliveryBinding(_ option: String, field: ScheduledTaskBlueprintField) -> Binding<Bool> {
        Binding(
            get: { selectedDeliveryOptions(field).contains(option) },
            set: { selected in
                var current = selectedDeliveryOptions(field)
                if selected {
                    current.insert(option)
                } else {
                    current.remove(option)
                }
                values[field.name] = field.options.filter(current.contains).joined(separator: ",")
            }
        )
    }

    private func selectedDeliveryOptions(_ field: ScheduledTaskBlueprintField) -> Set<String> {
        let value = values[field.name] ?? field.defaultValue ?? ""
        return Set(value.split(separator: ",").map(String.init))
    }

    private func review() {
        do {
            _ = try blueprint.validatedValues(values)
            localValidationMessage = nil
            store.clearBlueprintError()
            showsConfirmation = true
        } catch {
            localValidationMessage = (error as? LocalizedError)?.errorDescription
                ?? "Complete the blueprint before scheduling it."
        }
    }

    @State private var localValidationMessage: String?

    private func create() {
        localValidationMessage = nil
        creationTask?.cancel()
        creationTask = Task { @MainActor in
            do {
                _ = try await store.instantiate(blueprint, values: values, agentID: selectedAgentID)
                guard !Task.isCancelled else { return }
                dismiss()
            } catch {
                // Store exposes a fixed, user-safe message and retains this preview.
            }
            creationTask = nil
        }
    }

    private var reviewSummary: String {
        let agent = agents.profiles.first(where: { $0.id == selectedAgentID })?.name ?? "the selected agent"
        return "\(agent) will own \(blueprint.title.lowercased()), scheduled \(blueprint.scheduleDescription)."
    }

    private static func date(from text: String?) -> Date? {
        guard let text else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now)
    }

    @BighelpThemeReader private var theme
}
