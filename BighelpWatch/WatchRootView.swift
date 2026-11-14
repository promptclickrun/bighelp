import SwiftUI

enum WatchRoute: Hashable {
    case chat(String)
    /// A new chat, starting with this message.
    case newChat(text: String, key: UUID)
    case need(String)
    case board(WatchBoardKind)
    case boardItem(WatchBoardKind, String)
    case agents
}

/// Home: talk to your agent, what needs you, recent chats, and the agent's
/// Feed, Ideas and Goals.
struct WatchRootView: View {
    @Bindable var store: WatchStore
    @State private var path: [WatchRoute] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let problem = store.homeProblem, store.home?.status != .ready {
                    Section { WatchNotice(text: problem) }
                }
                if let agent = store.agent {
                    talk(to: agent)
                    needs
                    chats
                    board(of: agent)
                    agentChooser(agent)
                } else if store.home == nil, store.isLoadingHome {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
                if let problem = store.homeProblem, store.home?.status == .ready {
                    Section { WatchNotice(text: problem) }
                }
            }
            .navigationTitle("bighelp")
            .navigationDestination(for: WatchRoute.self) { route in destination(route) }
            .refreshable { await store.refreshHome() }
        }
        .task { await store.refreshHome() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshHome() } }
            if phase != .active { store.stopSpeaking() }
        }
    }

    private func talk(to agent: WatchAgent) -> some View {
        Section {
            TextFieldLink(prompt: Text("Talk to \(agent.firstName)")) {
                Label("Talk to \(agent.firstName)", systemImage: "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: WatchDesign.minimumControlHeight, alignment: .leading)
            } onSubmit: { text in
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                path.append(.newChat(text: text, key: UUID()))
            }
            .listItemTint(WatchDesign.Color.outgoing)
            .accessibilityIdentifier("watch.talk")
        }
    }

    /// Who Talk, Feed, Ideas and Goals are for.
    @ViewBuilder
    private func agentChooser(_ agent: WatchAgent) -> some View {
        if (store.home?.agents.count ?? 0) > 1 {
            Section {
                NavigationLink(value: WatchRoute.agents) {
                    HStack(spacing: 8) {
                        WatchAgentOrb(name: agent.name, size: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(agent.name).font(.body)
                            Text("Change bot").font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
                        }
                    }
                }
                .accessibilityIdentifier("watch.agent")
            }
        }
    }

    @ViewBuilder private var needs: some View {
        if let needs = store.home?.needs, !needs.isEmpty {
            Section {
                ForEach(needs) { need in
                    NavigationLink(value: WatchRoute.need(need.id)) { WatchNeedRow(need: need) }
                        .accessibilityIdentifier("watch.need.\(need.id)")
                }
            } header: {
                Text("Needs you").foregroundStyle(WatchDesign.Color.needs)
            }
        }
    }

    @ViewBuilder private var chats: some View {
        if let chats = store.home?.chats, !chats.isEmpty {
            Section("Chats") {
                ForEach(chats.prefix(8)) { chat in
                    NavigationLink(value: WatchRoute.chat(chat.id)) { WatchChatRow(chat: chat) }
                        .accessibilityIdentifier("watch.chat.\(chat.id)")
                }
            }
        }
    }

    private func board(of agent: WatchAgent) -> some View {
        Section("From \(agent.firstName)") {
            ForEach(WatchBoardKind.allCases, id: \.self) { kind in
                NavigationLink(value: WatchRoute.board(kind)) {
                    Label {
                        Text(kind.title)
                    } icon: {
                        Image(systemName: kind.symbol).foregroundStyle(WatchDesign.Color.accent)
                    }
                }
                .accessibilityIdentifier("watch.board.\(kind.rawValue)")
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: WatchRoute) -> some View {
        switch route {
        case .chat(let id): WatchChatView(store: store, start: .existing(id))
        case .newChat(let text, let key): WatchChatView(store: store, start: .new(text, key))
        case .need(let id): WatchNeedView(store: store, needID: id)
        case .board(let kind): WatchBoardView(store: store, kind: kind)
        case .boardItem(let kind, let id): WatchBoardItemView(store: store, kind: kind, itemID: id)
        case .agents: WatchAgentPicker(store: store)
        }
    }
}

struct WatchNeedRow: View {
    let need: WatchNeed

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(need.kind == .approval ? "Approval" : "Question",
                  systemImage: need.kind == .approval ? "checkmark.shield.fill" : "questionmark.bubble.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WatchDesign.Color.needs)
            Text(need.title).font(.headline).lineLimit(2)
            Text(need.agentName).font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
        }
        .padding(.vertical, 2)
    }
}

struct WatchChatRow: View {
    let chat: WatchChatSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            WatchAgentOrb(name: chat.agentName, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(chat.title).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(WatchWhen.text(chat.updatedAt)).font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
                }
                Text(chat.isWorking ? "Working…" : chat.preview)
                    .font(.caption2)
                    .foregroundStyle(chat.isWorking ? WatchDesign.Color.accent : WatchDesign.Color.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A plain sentence about what's wrong and what to do.
struct WatchNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "iphone.slash")
            .font(.caption)
            .foregroundStyle(WatchDesign.Color.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WatchAgentPicker: View {
    @Bindable var store: WatchStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(store.home?.agents ?? []) { agent in
            Button {
                store.chosenAgentID = agent.id
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    WatchAgentOrb(name: agent.name)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(agent.name)
                        if !agent.role.isEmpty {
                            Text(agent.role).font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
                        }
                    }
                    Spacer(minLength: 0)
                    if agent.id == store.agent?.id {
                        Image(systemName: "checkmark").foregroundStyle(WatchDesign.Color.accent)
                    }
                }
            }
        }
        .navigationTitle("Bots")
    }
}

extension WatchAgent {
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

extension WatchBoardKind {
    var symbol: String {
        switch self {
        case .feed: "newspaper"
        case .ideas: "lightbulb"
        case .goals: "target"
        }
    }
}
