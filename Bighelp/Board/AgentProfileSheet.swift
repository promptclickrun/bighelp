import SwiftUI

/// Tapping an agent's avatar: what it has been doing, what you approved, what
/// it runs on a schedule, and who it is (vibe, SOUL, MEMORY).
struct AgentProfileSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case activity, approvals, schedules, identity
        var id: String { rawValue }
        var title: String {
            switch self {
            case .activity: "Activity"
            case .approvals: "Approvals"
            case .schedules: "Schedules"
            case .identity: "Identity"
            }
        }
        var systemImage: String {
            switch self {
            case .activity: "list.bullet"
            case .approvals: "checkmark.shield"
            case .schedules: "clock.badge.checkmark"
            case .identity: "touchid"
            }
        }
    }

    let agent: AgentProfile
    let imageURL: URL?
    let activity: AgentActivityKind
    let isConnected: Bool
    let store: AgentBoardStore
    let schedules: [ScheduledTask]
    let onEdit: () -> Void
    let onOpenSchedule: (ScheduledTask) -> Void
    /// Opened from a chat: that chat's model and reasoning, with Change.
    var chatControls: SessionRuntimeControlModel? = nil
    var onChangeModel: (() -> Void)? = nil
    @State private var tab: Tab = .activity
    @State private var document: (title: String, body: AgentIdentityDocuments.Document)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: BighelpTokens.space16) {
                header
                if let chatControls { chatModelCard(chatControls) }
                tabBar
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.bottom, BighelpTokens.space32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.bighelp(.title3).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
                    .bighelpNavigationGlass(in: Circle(), isInteractive: true)
            }
            .buttonStyle(.plain)
            #if targetEnvironment(macCatalyst)
            .keyboardShortcut(.cancelAction)
            #endif
            .padding(BighelpTokens.space16)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("agent.profile.close")
        }
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .bighelpSheetSize(.standard)
        .task(id: agent.id) { await store.loadLogs(agentID: agent.id) }
        .bighelpSheet(isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } })) {
            if let document {
                IdentityDocumentView(title: document.title, document: document.body)
                    .bighelpSheetSize(.standard)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.profile")
    }

    private var header: some View {
        VStack(spacing: BighelpTokens.space8) {
            AgentLiveAvatar(agentID: agent.id, displayName: agent.name, imageURL: imageURL,
                            activity: activity, size: 108)
                .overlay(alignment: .bottomTrailing) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(theme.primaryText)
                            .frame(width: 36, height: 36)
                            .contentShape(.circle)
                            .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: 4)
                    .accessibilityLabel("Edit \(agent.name)")
                    .accessibilityIdentifier("agent.profile.edit")
                }
                .padding(.top, BighelpTokens.space32)
            Text(agent.name)
                .font(.bighelp(.title).weight(.bold))
                .foregroundStyle(theme.primaryText)
            Label(isConnected ? "Connected" : "Offline", systemImage: isConnected ? "bolt.circle.fill" : "bolt.slash.circle")
                .font(.bighelp(.body).weight(.medium))
                .foregroundStyle(isConnected ? Color.green : theme.secondaryText)
                .accessibilityIdentifier("agent.profile.connection")
        }
    }

    private func chatModelCard(_ controls: SessionRuntimeControlModel) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text("THIS CHAT")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(theme.secondaryText)
                .accessibilityAddTraits(.isHeader)
            ChatModelSummaryRow(controls: controls, onChange: onChangeModel)
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.vertical, BighelpTokens.space8)
                .background(theme.surface, in: .rect(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { item in
                let selected = tab == item
                Button {
                    withAnimation(.snappy) { tab = item }
                } label: {
                    Image(systemName: item.systemImage)
                        .font(.bighelp(.title3).weight(.semibold))
                        .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background {
                            if selected {
                                Capsule().fill(theme.primaryText.opacity(0.1))
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("agent.profile.tab.\(item.rawValue)")
            }
        }
        .padding(4)
        .background(Capsule().fill(theme.incomingMessageBackground))
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .activity: activityList
        case .approvals: approvalsList
        case .schedules: schedulesList
        case .identity: identityPanel
        }
    }

    // MARK: Activity

    @ViewBuilder
    private var activityList: some View {
        if store.activity.isEmpty {
            emptyState(symbol: "list.bullet", text: store.logState == .loading
                       ? "Loading…" : "When \(agent.name) uses tools for you, what it did shows up here.")
        } else {
            ForEach(dayGroups(store.activity, date: \.createdAt), id: \.title) { group in
                sectionTitle(group.title)
                ForEach(group.items) { entry in
                    HStack(alignment: .top, spacing: BighelpTokens.space12) {
                        Image(systemName: entry.kind.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(theme.incomingMessageBackground))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.headline)
                                .font(.bighelp(.headline))
                                .foregroundStyle(theme.primaryText)
                            if !entry.summary.isEmpty {
                                Text(entry.summary)
                                    .font(.bighelp(.subheadline))
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.bighelp(.footnote))
                                .foregroundStyle(theme.tertiaryText)
                        }
                    }
                    .padding(.vertical, BighelpTokens.space4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Approvals

    @ViewBuilder
    private var approvalsList: some View {
        if store.approvals.isEmpty {
            emptyState(symbol: "checkmark.shield", text: store.logState == .loading
                       ? "Loading…" : "Things \(agent.name) asked permission for, and what you decided, show up here.")
        } else {
            sectionTitle("Approvals history")
            ForEach(store.approvals) { entry in
                HStack(alignment: .top, spacing: BighelpTokens.space12) {
                    Image(systemName: entry.wasAllowed ? "checkmark.shield" : "xmark.shield")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(entry.wasAllowed ? theme.primaryText : theme.danger)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.incomingMessageBackground))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.description.isEmpty ? entry.command : entry.description)
                            .font(.bighelp(.headline))
                            .foregroundStyle(theme.primaryText)
                        if !entry.sessionTitle.isEmpty {
                            Text(entry.sessionTitle)
                                .font(.bighelp(.subheadline))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Text("\(entry.decisionLabel) · \(entry.createdAt.formatted(.relative(presentation: .named)))")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
                .padding(.vertical, BighelpTokens.space4)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Schedules

    @ViewBuilder
    private var schedulesList: some View {
        if schedules.isEmpty {
            emptyState(symbol: "clock", text: "Reminders and recurring jobs \(agent.name) runs for you show up here.")
        } else {
            ForEach(scheduleGroups, id: \.title) { group in
                sectionTitle(group.title)
                ForEach(group.items) { task in
                    Button { onOpenSchedule(task) } label: {
                        HStack(alignment: .top, spacing: BighelpTokens.space12) {
                            Image(systemName: "calendar")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(theme.primaryText)
                                .frame(width: 44, height: 44)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.incomingMessageBackground))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: task.isPaused ? "pause.circle.fill" : "clock.fill")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(task.isPaused ? theme.secondaryText : Color.orange)
                                        .background(Circle().fill(theme.canvas))
                                        .offset(x: 4, y: 4)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.name)
                                    .font(.bighelp(.headline))
                                    .foregroundStyle(theme.primaryText)
                                Text(task.isPaused ? "Paused" : task.scheduleDescription)
                                    .font(.bighelp(.subheadline))
                                    .foregroundStyle(theme.secondaryText)
                                if let next = task.nextRun, !task.isPaused {
                                    Text(next.formatted(date: .omitted, time: .shortened))
                                        .font(.bighelp(.footnote))
                                        .foregroundStyle(theme.tertiaryText)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, BighelpTokens.space4)
                }
            }
        }
    }

    private var scheduleGroups: [(title: String, items: [ScheduledTask])] {
        var groups: [(title: String, items: [ScheduledTask])] = []
        func title(_ task: ScheduledTask) -> String {
            switch task.schedule {
            case .once: "Reminders"
            case .daily: "Daily"
            case .weekly, .repeating: "Weekly"
            case .monthly: "Monthly"
            case .naturalLanguage, .hermes: "Other"
            }
        }
        for key in ["Reminders", "Daily", "Weekly", "Monthly", "Other"] {
            let items = schedules.filter { title($0) == key }
                .sorted { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) }
            if !items.isEmpty { groups.append((key, items)) }
        }
        return groups
    }

    // MARK: Identity

    private var identityPanel: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Text(agent.name)
                .font(.bighelp(.title2).weight(.bold))
                .foregroundStyle(theme.primaryText)
            if !agent.role.isEmpty {
                Text(agent.role)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
            }
            if !agent.summary.isEmpty {
                Text("VIBE")
                    .font(.bighelp(.caption).monospaced().weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(theme.tertiaryText)
                    .padding(.top, BighelpTokens.space4)
                Text(agent.summary)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
            }
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
                    .font(.bighelp(.body).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(theme.incomingMessageBackground))
            }
            .buttonStyle(.plain)
            .padding(.vertical, BighelpTokens.space8)
            .accessibilityIdentifier("agent.profile.identity.edit")
            HStack(spacing: BighelpTokens.space12) {
                identityCard(title: "SOUL", symbol: "heart.fill", colors: [Color(hex: "B97A86"), Color(hex: "8E5B69")],
                             document: store.identity?.soul ?? .init(text: agent.instructions),
                             identifier: "agent.profile.soul")
                identityCard(title: "MEMORY", symbol: "message.fill", colors: [Color(hex: "A8B23A"), Color(hex: "737A1F")],
                             document: memoryDocument, identifier: "agent.profile.memory")
            }
        }
    }

    private var memoryDocument: AgentIdentityDocuments.Document {
        guard let identity = store.identity else { return .init() }
        let combined = [identity.memory.text, identity.user.text.isEmpty ? "" : "## About you\n" + identity.user.text]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        return .init(text: combined, updatedAt: [identity.memory.updatedAt, identity.user.updatedAt].compactMap { $0 }.max(),
                     truncated: identity.memory.truncated || identity.user.truncated)
    }

    private func identityCard(title: String, symbol: String, colors: [Color],
                              document: AgentIdentityDocuments.Document, identifier: String) -> some View {
        Button {
            self.document = (title == "SOUL" ? "Soul" : "Memory", document)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bighelp(.title2).weight(.heavy))
                    .foregroundStyle(.white)
                Text("ACCESS WITH CARE")
                    .font(.bighelp(.caption2).monospaced())
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: BighelpTokens.space24)
                HStack(alignment: .bottom) {
                    Text(document.updatedAt?.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year(.twoDigits))
                         .replacingOccurrences(of: "/", with: ".") ?? "—")
                        .font(.bighelp(.footnote).monospaced())
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Image(systemName: symbol)
                        .font(.bighelp(.title2))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(BighelpTokens.space16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "SOUL" ? "Soul" : "Memory")
        .accessibilityHint("Opens it to read.")
        .accessibilityIdentifier(identifier)
    }

    // MARK: Pieces

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.bighelp(.title3).weight(.semibold))
            .foregroundStyle(theme.primaryText)
            .padding(.top, BighelpTokens.space8)
            .accessibilityAddTraits(.isHeader)
    }

    private func emptyState(symbol: String, text: String) -> some View {
        VStack(spacing: BighelpTokens.space8) {
            Image(systemName: symbol)
                .font(.bighelp(.title))
                .foregroundStyle(theme.tertiaryText)
            Text(text)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BighelpTokens.space32)
    }

    private func dayGroups<T>(_ items: [T], date: KeyPath<T, Date>) -> [(title: String, items: [T])] {
        var groups: [(title: String, items: [T])] = []
        let calendar = Calendar.current
        for item in items {
            let day = item[keyPath: date]
            let title = calendar.isDateInToday(day) ? "Today"
                : calendar.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            if groups.last?.title == title { groups[groups.count - 1].items.append(item) }
            else { groups.append((title, [item])) }
        }
        return groups
    }

    @BighelpThemeReader private var theme
}

private struct IdentityDocumentView: View {
    let title: String
    let document: AgentIdentityDocuments.Document
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    if document.text.isEmpty {
                        Text("Nothing here yet.")
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        Text(document.text)
                            .font(.bighelp(.body).monospaced())
                            .foregroundStyle(theme.primaryText)
                            .textSelection(.enabled)
                    }
                    if document.truncated {
                        Label("Showing the first 64 KB.", systemImage: "scissors")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(BighelpTokens.space20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                }
            }
        }
    }

    @BighelpThemeReader private var theme
}

/// Tapping an agent's name: switch agents, open a group chat, or make a new agent.
struct AgentSwitcherSheet: View {
    struct Group: Identifiable {
        let id: String
        let name: String
        let memberCount: Int
    }

    let agents: [AgentProfile]
    let selectedID: String?
    let imageURL: (AgentProfile) -> URL?
    let groups: [Group]
    let onSelect: (AgentProfile) -> Void
    let onSelectGroup: (Group) -> Void
    let onNewGroup: () -> Void
    let onNewAgent: () -> Void
    let onManageAgents: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Agents") {
                    ForEach(agents) { agent in
                        Button {
                            dismiss()
                            onSelect(agent)
                        } label: {
                            HStack(spacing: BighelpTokens.space12) {
                                AgentLiveAvatar(agentID: agent.id, displayName: agent.name, imageURL: imageURL(agent), size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name).font(.bighelp(.headline)).foregroundStyle(theme.primaryText)
                                    if !agent.role.isEmpty {
                                        Text(agent.role).font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                                    }
                                }
                                Spacer()
                                if agent.id == selectedID {
                                    Image(systemName: "checkmark").foregroundStyle(theme.action).fontWeight(.semibold)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(agent.id == selectedID ? .isSelected : [])
                        .accessibilityIdentifier("agent.switcher.agent.\(agent.id)")
                    }
                    Button {
                        dismiss()
                        onNewAgent()
                    } label: {
                        Label("New agent", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("agent.switcher.new-agent")
                    Button {
                        dismiss()
                        onManageAgents()
                    } label: {
                        Label("Manage agents", systemImage: "person.2")
                    }
                    .accessibilityIdentifier("agent.switcher.manage")
                }
                Section("Group chats") {
                    ForEach(groups) { group in
                        Button {
                            dismiss()
                            onSelectGroup(group)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name).foregroundStyle(theme.primaryText)
                                    Text("\(group.memberCount) agents").font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
                                }
                            } icon: {
                                Image(systemName: "person.3.fill")
                                    .font(.bighelp(.footnote))
                                    .foregroundStyle(theme.action)
                            }
                        }
                        .accessibilityIdentifier("agent.switcher.group.\(group.id)")
                    }
                    Button {
                        dismiss()
                        onNewGroup()
                    } label: {
                        Label("New group chat", systemImage: "plus.bubble")
                    }
                    .accessibilityIdentifier("agent.switcher.new-group")
                }
            }
            .scrollContentBackground(.hidden)
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Switch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                }
            }
        }
        .bighelpSheetSize(.standard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.switcher")
    }

    @BighelpThemeReader private var theme
}
