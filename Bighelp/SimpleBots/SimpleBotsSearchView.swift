import SwiftUI

/// Search in Simple Bot mode: every bot by name or what it's for. The filter
/// shows hidden bots too, so a hidden one can come back.
@MainActor
struct SimpleBotsSearchView: View {
    let context: SimpleBotsContext
    let onOpen: (String) -> Void

    private enum Filter: String, CaseIterable, Identifiable {
        case all, pinned, hidden
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All bots"
            case .pinned: "Pinned"
            case .hidden: "Hidden"
            }
        }
    }

    @State private var query = ""
    @State private var filter: Filter = .all
    @FocusState private var isSearchFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    private var bots: [AgentProfile] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return context.agents.profiles.filter { profile in
            let hidden = profile.placement?.isHidden == true
            switch filter {
            case .all: guard !hidden else { return false }
            case .pinned: guard context.agents.isPinned(profile.id) else { return false }
            case .hidden: guard hidden else { return false }
            }
            guard !words.isEmpty else { return true }
            return [profile.name, profile.role, profile.summary].contains { $0.localizedCaseInsensitiveContains(words) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BighelpTokens.space8) {
                SimpleBotsCircleButton(systemImage: "xmark", label: "Close", identifier: "simple-bots.search.close") {
                    dismiss()
                }
                HStack(spacing: BighelpTokens.space8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText).accessibilityHidden(true)
                    TextField("Search", text: $query)
                        .font(.bighelp(.body))
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .accessibilityIdentifier("simple-bots.search.field")
                }
                .padding(.horizontal, BighelpTokens.space16)
                .frame(minHeight: BighelpTokens.hitTarget)
                .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.bighelp(.title3, weight: .medium))
                        .foregroundStyle(filter == .all ? AnyShapeStyle(.primary) : AnyShapeStyle(theme.action))
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .contentShape(.circle)
                        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filter: \(filter.title)")
                .accessibilityIdentifier("simple-bots.search.filter")
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.vertical, BighelpTokens.space12)

            List(bots) { profile in
                Button { onOpen(profile.id) } label: {
                    HStack(spacing: BighelpTokens.space16) {
                        SimpleBotFace(agentID: profile.id, name: profile.name,
                                      imageURL: context.agents.avatarURL(for: profile), size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(profile.name)
                                    .font(.bighelp(.title3, weight: .medium))
                                    .foregroundStyle(theme.primaryText)
                                Spacer()
                                Text("Bot")
                                    .font(.bighelp(.subheadline))
                                    .foregroundStyle(theme.tertiaryText)
                            }
                            let about = profile.summary.isEmpty ? profile.role : profile.summary
                            if !about.isEmpty {
                                Text(about)
                                    .font(.bighelp(.body))
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(minHeight: 64)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .contextMenu {
                    if profile.placement?.isHidden == true {
                        Button("Show on Home", systemImage: "eye") { unhide(profile) }
                    }
                    Button("Bot Profile", systemImage: "person.crop.circle") {
                        dismiss()
                        context.onOpenProfile(profile.id)
                    }
                }
                .accessibilityIdentifier("simple-bots.search.bot.\(profile.id)")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if bots.isEmpty {
                    ContentUnavailableView(filter == .hidden ? "No hidden bots" : "No bots found",
                                           systemImage: "magnifyingglass")
                }
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .onAppear { isSearchFocused = false }
    }

    private func unhide(_ profile: AgentProfile) {
        var placement = profile.placement ?? AgentListPlacement()
        placement.isHidden = false
        Task { @MainActor in try? await context.agents.setPlacement(placement, profileID: profile.id) }
    }
}

/// New Group Chat: pick two or more bots, then Next makes the group and opens it.
@MainActor
struct SimpleBotsGroupChatView: View {
    let context: SimpleBotsContext
    let onCreate: ([String]) -> Void

    @State private var query = ""
    @State private var picked: [String] = []
    @FocusState private var isFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    private var bots: [AgentProfile] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return context.agents.profiles.filter { profile in
            words.isEmpty || profile.name.localizedCaseInsensitiveContains(words)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BighelpTokens.space12) {
                SimpleBotsCircleButton(systemImage: "xmark", label: "Close", identifier: "simple-bots.group.close") {
                    dismiss()
                }
                Text("New Group Chat")
                    .font(.bighelp(.title3, weight: .semibold))
                Spacer()
                Button("Next") { onCreate(picked) }
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(picked.count >= 2 ? theme.actionForeground : theme.secondaryText)
                    .padding(.horizontal, BighelpTokens.space20)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .background(picked.count >= 2 ? theme.action : theme.surface, in: Capsule())
                    .disabled(picked.count < 2)
                    .accessibilityIdentifier("simple-bots.group.next")
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space16)

            HStack(spacing: BighelpTokens.space8) {
                Text("To:").foregroundStyle(theme.tertiaryText)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BighelpTokens.space8) {
                        ForEach(picked, id: \.self) { id in
                            Button {
                                picked.removeAll { $0 == id }
                            } label: {
                                Text(context.agents.profiles.first { $0.id == id }?.name ?? id)
                                    .font(.bighelp(.subheadline, weight: .medium))
                                    .foregroundStyle(theme.actionForeground)
                                    .padding(.horizontal, BighelpTokens.space12)
                                    .padding(.vertical, BighelpTokens.space4)
                                    .background(theme.action, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(context.agents.profiles.first { $0.id == id }?.name ?? id)")
                        }
                        TextField(picked.isEmpty ? "Search Bots" : "", text: $query)
                            .font(.bighelp(.body))
                            .focused($isFieldFocused)
                            .frame(minWidth: 120)
                            .accessibilityIdentifier("simple-bots.group.search")
                    }
                }
            }
            .font(.bighelp(.body))
            .padding(.horizontal, BighelpTokens.space16)
            .frame(minHeight: BighelpTokens.hitTarget + 4)
            .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
            .padding(BighelpTokens.space16)

            List(bots) { profile in
                Button { toggle(profile.id) } label: {
                    HStack(spacing: BighelpTokens.space16) {
                        SimpleBotFace(agentID: profile.id, name: profile.name,
                                      imageURL: context.agents.avatarURL(for: profile), size: 44)
                        Text(profile.name).font(.bighelp(.body)).foregroundStyle(theme.primaryText)
                        Spacer()
                        if picked.contains(profile.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.bighelp(.title3))
                                .foregroundStyle(theme.action)
                        }
                    }
                    .frame(minHeight: 52)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityAddTraits(picked.contains(profile.id) ? .isSelected : [])
                .accessibilityIdentifier("simple-bots.group.bot.\(profile.id)")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(theme.canvas.ignoresSafeArea())
    }

    private func toggle(_ id: String) {
        if picked.contains(id) {
            picked.removeAll { $0 == id }
        } else if picked.count < BotModeRoom.maximumMembers {
            picked.append(id)
            query = ""
        }
    }
}
