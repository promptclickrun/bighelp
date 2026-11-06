import SwiftUI

/// Search in Bots mode: every bot by name or what it's for. The filter
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
            case .all: String(localized: "All bots")
            case .pinned: String(localized: "Pinned")
            case .hidden: String(localized: "Hidden")
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
                        SimpleBotLiveFace(bot: SimpleBotsBot(profile, imageURL: context.agents.avatarURL(for: profile)),
                                          size: 56, activity: context.activity)
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
                .modifier(SimpleBotActivityValue(key: BotChatActivityStore.liveKey(profile.id), activity: context.activity))
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
