import SwiftUI

/// The agent's Feed, Ideas or Goals, newest first.
struct WatchBoardView: View {
    @Bindable var store: WatchStore
    let kind: WatchBoardKind

    private var items: [WatchBoardItem]? { store.boards[kind] }

    var body: some View {
        List {
            if let items {
                if items.isEmpty {
                    Text(emptyText)
                        .font(.caption)
                        .foregroundStyle(WatchDesign.Color.secondaryText)
                        .listRowBackground(Color.clear)
                }
                ForEach(items) { item in
                    NavigationLink(value: WatchRoute.boardItem(kind, item.id)) { WatchBoardRow(item: item, kind: kind) }
                        .accessibilityIdentifier("watch.item.\(item.id)")
                }
            } else if store.boardProblems[kind] == nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            if let problem = store.boardProblems[kind] {
                WatchNotice(text: problem).listRowBackground(Color.clear)
            }
        }
        .navigationTitle(kind.title)
        .task { await store.loadBoard(kind) }
        .refreshable { await store.loadBoard(kind) }
    }

    private var emptyText: String {
        let name = store.agent?.firstName ?? "Your bot"
        return switch kind {
        case .feed: "Nothing in the Feed yet. Ask \(name) for updates on your iPhone."
        case .ideas: "No ideas yet. Ask \(name) for some."
        case .goals: "No goals yet. Tell \(name) what you're working toward."
        }
    }
}

struct WatchBoardRow: View {
    let item: WatchBoardItem
    let kind: WatchBoardKind

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(item.icon.isEmpty ? " " : item.icon)
                .font(.title3)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if item.isUnread {
                        Circle().fill(WatchDesign.Color.coral).frame(width: 6, height: 6)
                            .accessibilityLabel("New")
                    }
                    Text(item.title).font(.body.weight(.semibold)).lineLimit(2)
                        .strikethrough(kind == .goals && item.isDone)
                }
                Text(item.note.isEmpty ? item.body : item.note)
                    .font(.caption2)
                    .foregroundStyle(WatchDesign.Color.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One item, with its full text, and a way to it on the iPhone.
struct WatchBoardItemView: View {
    @Bindable var store: WatchStore
    let kind: WatchBoardKind
    let itemID: String
    @State private var notice: String?

    private var item: WatchBoardItem? { store.boards[kind]?.first { $0.id == itemID } }

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        if !item.icon.isEmpty { Text(item.icon).font(.title2).accessibilityHidden(true) }
                        Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    }
                    if kind == .goals || !item.note.isEmpty {
                        HStack(spacing: 6) {
                            if kind == .goals {
                                Text(item.isDone ? "Done" : "Active")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(item.isDone ? WatchDesign.Color.done.opacity(0.3)
                                                                          : WatchDesign.Color.accent.opacity(0.25)))
                            }
                            if !item.note.isEmpty {
                                Text(item.note).font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
                            }
                        }
                    }
                    if !item.body.isEmpty {
                        Text(item.body).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(WatchDesign.Color.secondaryText)
                    if let link {
                        Button {
                            Task { notice = await store.openOnPhone(link) ?? "Check your iPhone." }
                        } label: {
                            Label("Open on iPhone", systemImage: "iphone")
                        }
                        .accessibilityIdentifier("watch.open-on-iphone")
                    }
                    if let notice { WatchNotice(text: notice) }
                }
            }
        }
        .navigationTitle(kind.title)
        .userActivity(WatchPhoneLink.handoffActivityType, element: link) { link, activity in
            activity.title = link.title
            activity.userInfo = ["url": link.url]
            activity.isEligibleForHandoff = true
        }
    }

    private var link: WatchPhoneLink? {
        guard let item, let agent = store.agent else { return nil }
        return .board(kind, agentID: agent.id, title: item.title)
    }
}

extension WatchBoardItem {
    var isDone: Bool { status == "done" }
}
