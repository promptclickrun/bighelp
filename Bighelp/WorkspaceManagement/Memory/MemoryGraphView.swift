import SwiftUI

@MainActor
struct MemoryGraphView: View {
    @Bindable var store: MemoryGraphStore
    @State private var presentedNode: HermesLearningGraph.Node?

    var body: some View {
        List {
            MemoryOperationMessages(store: store)

            if let graph = store.graph {
                Section {
                    Picker("Knowledge type", selection: $store.nodeFilter) {
                        ForEach(MemoryGraphStore.NodeFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .bighelpSegmentedPicker()
                } header: {
                    Text("View")
                }

                Section {
                    if store.visibleNodes.isEmpty {
                        ContentUnavailableView(
                            store.search.isEmpty ? "No learned knowledge" : "No matching knowledge",
                            systemImage: store.search.isEmpty ? "brain" : "magnifyingglass",
                            description: Text(store.search.isEmpty
                                ? "Learned skills and memory chunks will appear here after Hermes records them."
                                : "Try a different search or knowledge type."))
                    }
                    ForEach(store.visibleNodes) { node in
                        Button {
                            presentedNode = node
                        } label: {
                            LearningNodeRow(
                                node: node,
                                connections: connectionCount(for: node, graph: graph))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("memory.node.\(node.rawID)")
                    }
                } header: {
                    HStack {
                        Text("Knowledge")
                        Spacer()
                        Text("\(store.visibleNodes.count)").monospacedDigit()
                    }
                } footer: {
                    Text("Skills are reusable instructions. Removing a skill archives it for Curator recovery.")
                }

                Section("Overview") {
                    LearningGraphSummary(graph: graph, insights: store.insights)
                }

                if !graph.clusters.isEmpty {
                    Section("Advanced · Categories") {
                        ForEach(graph.clusters) { cluster in
                            LabeledContent {
                                Text(cluster.count.formatted())
                                    .monospacedDigit()
                            } label: {
                                Label(cluster.category, systemImage: "circle.hexagongrid")
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            } else if store.isLoading {
                Section { ProgressView("Loading the learning graph…") }
            } else {
                Section {
                    ContentUnavailableView(
                        "Learning graph unavailable",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Refresh to ask Hermes for the selected profile’s learned knowledge."))
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $store.search, prompt: "Search memories and learned skills")
        .refreshable { await store.refreshGraph() }
        .bighelpSheet(item: $presentedNode, onDismiss: { store.closeNode() }) { node in
            MemoryNodeDetailView(store: store, node: node)
                .bighelpSheetSize(.standard)
        }
    }

    private func connectionCount(for node: HermesLearningGraph.Node, graph: HermesLearningGraph) -> Int {
        graph.edges.reduce(into: 0) { count, edge in
            if edge.source.utf8.elementsEqual(node.rawID.utf8) || edge.target.utf8.elementsEqual(node.rawID.utf8) {
                count += 1
            }
        }
    }
}

@MainActor
private struct LearningGraphSummary: View {
    let graph: HermesLearningGraph
    let insights: HermesInsights?

    var body: some View {
        Group {
            metric("Knowledge", value: graph.nodes.count, systemImage: "brain")
            metric("Connections", value: graph.edges.count, systemImage: "point.3.connected.trianglepath.dotted")
            metric("Memories", value: graph.stats.memoryNodes, systemImage: "text.book.closed")
            metric("Learned skills", value: graph.stats.learnedSkills, systemImage: "hammer")
            if let insights {
                metric("\(insights.days)-day sessions", value: insights.sessions, systemImage: "bubble.left.and.bubble.right")
                metric("\(insights.days)-day messages", value: insights.messages, systemImage: "message")
            }
        }
    }

    private func metric(_ title: String, value: Int, systemImage: String) -> some View {
        LabeledContent {
            Text(value.formatted())
                .monospacedDigit()
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct LearningNodeRow: View {
    let node: HermesLearningGraph.Node
    let connections: Int

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text(node.label.isEmpty ? "Untitled \(node.kind.rawValue)" : node.label)
                    .font(.bighelp(.headline))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let preview = node.memoryPreview, !preview.isEmpty {
                    Text(preview)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: 8) {
                    Text(node.category)
                    if node.kind == .skill { Text("Used \(node.useCount) times") }
                    Text("\(connections) links")
                }
                .font(.bighelp(.caption))
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: node.kind == .memory ? "text.book.closed" : "hammer")
                .foregroundStyle(.secondary)
        }
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens details and editing controls")
    }
}

@MainActor
private struct MemoryNodeDetailView: View {
    @Bindable var store: MemoryGraphStore
    let node: HermesLearningGraph.Node

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var editing = false
    @State private var seededID: Data?
    @State private var showingSaveConfirmation = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                MemoryOperationMessages(store: store)
                if let detail = matchingDetail {
                    Section("Content") {
                        if editing {
                            TextEditor(text: $draft)
                                .font(detail.kind == .skill ? .body.monospaced() : .body)
                                .frame(minHeight: 260)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                                .accessibilityIdentifier("memory.node.editor")
                        } else {
                            Text(detail.content.isEmpty ? "No content" : detail.content)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Section {
                        if editing {
                            Button("Review changes", systemImage: "checkmark") {
                                showingSaveConfirmation = true
                            }
                            .disabled(!hasChanges || store.isMutating)
                            Button("Cancel editing", role: .cancel) {
                                draft = detail.content
                                editing = false
                            }
                        } else {
                            Button("Edit \(detail.kind == .skill ? "skill" : "memory")", systemImage: "pencil") {
                                editing = true
                            }
                        }
                    }

                    Section("Advanced · Details") {
                        LabeledContent("Type", value: detail.kind == .skill ? "Learned skill" : "Memory")
                        LabeledContent("Profile", value: store.profileName)
                        LabeledContent("Identifier", value: detail.rawID)
                            .font(.bighelp(.caption))
                    }

                    Section {
                        Button(
                            detail.kind == .skill ? "Archive skill" : "Delete memory",
                            systemImage: detail.kind == .skill ? "archivebox" : "trash",
                            role: .destructive
                        ) {
                            showingDeleteConfirmation = true
                        }
                        .disabled(store.isMutating)
                    } footer: {
                        Text(detail.kind == .skill
                            ? "Archiving is recoverable with Curator restore. It is not permanent deletion."
                            : "Deleting a memory is permanent. Positional memory identifiers change after deletion, so Hermes refreshes the graph before another edit.")
                    }
                } else if store.isLoadingDetail {
                    Section { ProgressView("Loading current content…") }
                } else {
                    Section {
                        ContentUnavailableView(
                            "Knowledge item unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text("Dismiss and refresh the learning graph before trying again."))
                    }
                }
            }
            .navigationTitle(node.label.isEmpty ? "Knowledge" : node.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(store.isMutating)
                }
            }
            .task { await store.loadNode(node) }
            .onChange(of: store.selectedDetail) { _, _ in seedDraft() }
            .confirmationDialog(
                "Save this \(matchingDetail?.kind == .skill ? "skill" : "memory")?",
                isPresented: $showingSaveConfirmation,
                titleVisibility: .visible
            ) {
                if let detail = matchingDetail {
                    Button("Save changes") {
                        Task {
                            if await store.saveNode(detail, content: draft) { editing = false }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Hermes will replace this item’s current content in the selected profile and read it back before confirming success.")
            }
            .confirmationDialog(
                matchingDetail?.kind == .skill ? "Archive this skill?" : "Permanently delete this memory?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                if let detail = matchingDetail {
                    Button(detail.kind == .skill ? "Archive skill" : "Delete memory", role: .destructive) {
                        Task {
                            if await store.deleteNode(detail) { dismiss() }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if matchingDetail?.kind == .skill {
                    Text("Hermes archives learned skills instead of deleting them. A Curator restore can recover this skill.")
                } else {
                    Text("Hermes will permanently remove only the selected memory chunk, then bighelp will require an authoritative graph readback.")
                }
            }
        }
        .interactiveDismissDisabled(store.isMutating)
    }

    private var matchingDetail: HermesLearningNodeDetail? {
        guard let detail = store.selectedDetail,
              detail.rawID.utf8.elementsEqual(node.rawID.utf8) else { return nil }
        return detail
    }

    private var hasChanges: Bool {
        guard let detail = matchingDetail else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.utf8.elementsEqual(detail.content.utf8)
            && draft.utf8.count <= 512_000
    }

    private func seedDraft() {
        guard let detail = matchingDetail else { return }
        let identity = Data(detail.rawID.utf8)
        guard seededID != identity else { return }
        draft = detail.content
        seededID = identity
    }
}
