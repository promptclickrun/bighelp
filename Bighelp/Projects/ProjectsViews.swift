import SwiftUI

/// Everything the Projects screens need from the shell.
@MainActor
struct ProjectsContext {
    let store: ProjectsStore
    let workspaces: HermesWorkspaceStore
    let agentID: String
    let isNerdMode: Bool
    let onOpenProject: (String) -> Void
    let onNewChat: (String) -> Void
    let onOpenChat: (ProjectsStore.Chat) -> Void
    /// Nerd Mode: folders and Git in Hermes Tools.
    let onManage: () -> Void
}

/// Projects keep related chats and folders together, like Projects in Claude.
/// Each is a Hermes project: chats started in it run in its folder.
struct ProjectsHomeView: View {
    let context: ProjectsContext
    @State private var isCreating = false

    var body: some View {
        let workspaces = context.workspaces
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Text("Keep related chats and folders together. Chats you start in a project work in its folder.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.bottom, BighelpTokens.space4)
                if let catalog = workspaces.catalog {
                    if catalog.workspaces.isEmpty {
                        empty
                    }
                    ForEach(sorted(catalog.workspaces)) { project in
                        Button { context.onOpenProject(project.id) } label: {
                            ProjectCard(project: project, details: context.store.details[project.id])
                        }
                        .buttonStyle(.bighelpTilePress)
                        .accessibilityIdentifier("projects.card.\(project.id)")
                    }
                } else if workspaces.isLoading {
                    ProgressView("Loading projects")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    unavailable(workspaces.errorMessage)
                }
                if let message = context.store.errorMessage, workspaces.catalog != nil {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space8)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            #if targetEnvironment(macCatalyst)
            // A Mac list can't be pulled down to refresh.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                    .keyboardShortcut("r")
                    .accessibilityIdentifier("projects.refresh")
            }
            #endif
            ToolbarItem(placement: .topBarTrailing) {
                Button { isCreating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New project")
                    .accessibilityIdentifier("projects.new")
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .bighelpSheet(isPresented: $isCreating) {
            HermesWorkspaceCreateView(store: context.workspaces, agentID: context.agentID, noun: "Project") {
                Task { await context.store.refresh() }
            }
            .bighelpSheetSize(.standard)
        }
        .accessibilityIdentifier("projects.screen")
    }

    private func reload() async {
        await context.workspaces.load(agentID: context.agentID)
        await context.store.refresh()
    }

    /// Recently used first; the current project leads.
    private func sorted(_ projects: [HermesWorkspaceSummary]) -> [HermesWorkspaceSummary] {
        projects.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let left = context.store.details[lhs.id]?.lastActive ?? .distantPast
            let right = context.store.details[rhs.id]?.lastActive ?? .distantPast
            return left == right ? lhs.name.localizedCompare(rhs.name) == .orderedAscending : left > right
        }
    }

    private var empty: some View {
        VStack(spacing: BighelpTokens.space12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(theme.action)
            Text("No projects yet")
                .font(.bighelp(.title3).weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Text("Make one for anything you come back to: an app, a trip, your home.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("New project") { isCreating = true }
                .bighelpProminentButtonStyle()
                .buttonBorderShape(.capsule)
                .tint(theme.action)
                .foregroundStyle(theme.actionForeground)
                .accessibilityIdentifier("projects.empty.new")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BighelpTokens.space32)
    }

    private func unavailable(_ message: String?) -> some View {
        VStack(spacing: BighelpTokens.space8) {
            Text("Projects aren't available right now")
                .font(.bighelp(.headline))
                .foregroundStyle(theme.primaryText)
            Text(message ?? "Check that your computer is on and connected, then \(BighelpPlatform.isMac ? "click Refresh" : "pull down") to try again.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BighelpTokens.space32)
        .accessibilityIdentifier("projects.unavailable")
    }

    @BighelpThemeReader private var theme
}

/// One project in the list: its tile, name, description and recent use.
private struct ProjectCard: View {
    let project: HermesWorkspaceSummary
    let details: ProjectsStore.Details?

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            ProjectTile(id: project.id, icon: details?.icon, color: details?.color, size: 48)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                HStack(spacing: BighelpTokens.space8) {
                    Text(project.name)
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    if project.isActive {
                        Text("Current")
                            .font(.bighelp(.caption).weight(.semibold))
                            .foregroundStyle(theme.action)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(theme.action.opacity(0.14), in: .capsule)
                    }
                }
                if !project.description.isEmpty {
                    Text(project.description)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Text(footnote)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.bighelp(.footnote).weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .padding(.top, 4)
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                .stroke(theme.border, lineWidth: BighelpTokens.hairline)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var footnote: String {
        let count = details?.chatCount ?? 0
        let chats = count == 1 ? "1 chat" : "\(count) chats"
        guard let last = details?.lastActive else { return chats }
        return "\(chats) · \(last.formatted(.relative(presentation: .named)))"
    }

    @BighelpThemeReader private var theme
}

/// A project's picture: its emoji on its color, or a folder.
struct ProjectTile: View {
    let id: String
    let icon: String?
    let color: String?
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.opacity(0.18))
            .frame(width: size, height: size)
            .overlay {
                if let emoji {
                    Text(emoji).font(.system(size: size * 0.5))
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(tint)
                }
            }
            .accessibilityHidden(true)
    }

    /// Hermes stores a short icon; only an emoji is drawn as-is.
    private var emoji: String? {
        guard let icon = icon?.trimmingCharacters(in: .whitespaces), icon.count == 1,
              icon.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value > 0x2000 })
        else { return nil }
        return icon
    }

    private var tint: Color {
        if let color, let parsed = Color(projectHex: color) { return parsed }
        // A steady color per project when Hermes has none.
        let palette: [Color] = [.purple, .blue, .teal, .green, .orange, .pink, .indigo]
        let index = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff } % palette.count
        return palette[index]
    }
}

private extension Color {
    init?(projectHex text: String) {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}

/// One project: start a chat in it, see its chats and its folders.
struct ProjectDetailView: View {
    let projectID: String
    let context: ProjectsContext
    @State private var isArchiving = false
    @State private var isStarting = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let project = context.workspaces.catalog?.workspaces.first { $0.id == projectID }
        let details = context.store.details[projectID]
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space20) {
                if let project {
                    header(project, details: details)
                    newChatButton
                    chats
                    if let details, !details.folders.isEmpty { folders(details.folders) }
                } else if context.workspaces.isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    Text("This project isn't available anymore.")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.bottom, BighelpTokens.space32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if context.store.openingChatID != nil {
                OpeningChatOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: context.store.openingChatID)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationTitle(project?.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            #if targetEnvironment(macCatalyst)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .keyboardShortcut("r")
                    .accessibilityIdentifier("project.refresh")
            }
            #endif
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if project?.isActive == false {
                        Button("Make current", systemImage: "checkmark.circle") {
                            Task { _ = await context.workspaces.select(id: projectID, agentID: context.agentID) }
                        }
                    }
                    if context.isNerdMode {
                        Button("Folders and Git", systemImage: "folder.badge.gearshape") { context.onManage() }
                    }
                    Button("Archive project", systemImage: "archivebox", role: .destructive) { isArchiving = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Project options")
                .accessibilityIdentifier("project.options")
            }
        }
        .refreshable { await refresh() }
        .task(id: projectID) {
            if context.workspaces.catalog == nil { await context.workspaces.load(agentID: context.agentID) }
            if context.store.details.isEmpty { await context.store.refresh() }
            await context.store.loadChats(projectID: projectID)
        }
        .confirmationDialog("Archive \(project?.name ?? "this project")?", isPresented: $isArchiving,
                            titleVisibility: .visible) {
            Button("Archive project", role: .destructive) {
                Task {
                    if await context.workspaces.archive(id: projectID, agentID: context.agentID) { dismiss() }
                }
            }
        } message: {
            Text("Its chats and folders stay on your computer.")
        }
        .accessibilityIdentifier("project.screen")
    }

    private func refresh() async {
        await context.store.refresh()
        await context.store.loadChats(projectID: projectID)
    }

    private func header(_ project: HermesWorkspaceSummary, details: ProjectsStore.Details?) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            ProjectTile(id: project.id, icon: details?.icon, color: details?.color, size: 64)
            Text(project.name)
                .font(.bighelp(.largeTitle).weight(.bold))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            if !project.description.isEmpty {
                Text(project.description)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.top, BighelpTokens.space8)
    }

    private var newChatButton: some View {
        Button {
            isStarting = true
            context.onNewChat(projectID)
        } label: {
            Label("New chat in this project", systemImage: "square.and.pencil")
                .font(.bighelp(.body).weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
        }
        .bighelpProminentButtonStyle()
        .buttonBorderShape(.capsule)
        .tint(theme.action)
        .foregroundStyle(theme.actionForeground)
        .disabled(isStarting && context.workspaces.selectingID != nil)
        .accessibilityIdentifier("project.new-chat")
    }

    @ViewBuilder
    private var chats: some View {
        let rows = context.store.chats[projectID]
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text("Sessions")
                .font(.bighelp(.title3).weight(.bold))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            if let rows, !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rows) { chat in
                        Button { context.onOpenChat(chat) } label: { chatRow(chat) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("project.chat.\(chat.id)")
                        if chat.id != rows.last?.id { Divider().overlay(theme.border).padding(.leading, BighelpTokens.space16) }
                    }
                }
                .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
            } else if context.store.loadingChats.contains(projectID) && rows == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Text("No sessions yet. Start one above and it'll show up here.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("project.chats.empty")
            }
        }
    }

    private func chatRow(_ chat: ProjectsStore.Chat) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title.isEmpty ? "Untitled chat" : chat.title)
                    .font(.bighelp(.body).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                if !chat.preview.isEmpty {
                    Text(chat.preview)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            if let last = chat.lastActive {
                Text(last.formatted(.relative(presentation: .named)))
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space12)
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func folders(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text("Folders")
                .font(.bighelp(.title3).weight(.bold))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(paths, id: \.self) { path in
                    Label {
                        Text(HermesFolderPath.abbreviated(path, home: context.workspaces.homePath))
                            .font(.bighelp(.subheadline, design: .monospaced))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.head)
                    } icon: {
                        Image(systemName: "folder").foregroundStyle(theme.action)
                    }
                    .padding(.horizontal, BighelpTokens.space16)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                }
            }
            .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
            Text("Chats in this project work in the first folder.")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
        }
        .accessibilityIdentifier("project.folders")
    }

    @BighelpThemeReader private var theme
}

/// Shown while a project chat is found on the host, so the tap visibly did something.
private struct OpeningChatOverlay: View {
    var body: some View {
        ZStack {
            theme.canvas.opacity(0.55).ignoresSafeArea()
            VStack(spacing: BighelpTokens.space12) {
                BighelpThinkingOrb(scenario: .searching, visibleLabel: "Opening chat…")
            }
            .padding(BighelpTokens.space24)
            .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening chat")
        .accessibilityIdentifier("project.opening-chat")
    }

    @BighelpThemeReader private var theme
}
