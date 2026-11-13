import SwiftUI

struct NativeSessionSpawnTreeView: View {
    let entry: DirectHermesSpawnTreeEntry
    let model: NativeSessionControlsModel

    @Environment(\.dismiss) private var dismiss
    @State private var saveLabel = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Path", value: entry.path)
                    .textSelection(.enabled)
                if !entry.label.isEmpty {
                    LabeledContent("Label", value: entry.label)
                        .textSelection(.enabled)
                }
                LabeledContent("Helpers", value: entry.count.formatted())
                optionalValue("Chat ID", entry.sessionID)
                optionalValue("Started", NativeSessionReadOnlyFormatting.timestamp(entry.startedAt))
                optionalValue("Finished", NativeSessionReadOnlyFormatting.timestamp(entry.finishedAt))
            } header: {
                Text("Saved tree")
            }

            Section {
                if model.isBusy(.spawnTreeLoad), model.loadedSpawnTree == nil {
                    ProgressView("Loading spawn tree…")
                } else if let snapshot = model.loadedSpawnTree {
                    optionalValue("Chat ID", snapshot.sessionID)
                    optionalValue("Started", NativeSessionReadOnlyFormatting.timestamp(snapshot.startedAt))
                    optionalValue("Finished", NativeSessionReadOnlyFormatting.timestamp(snapshot.finishedAt))
                    optionalValue("Label", snapshot.label)
                    LabeledContent("Subagents", value: snapshot.subagents.count.formatted())
                    ForEach(Array(snapshot.subagents.enumerated()), id: \.offset) { index, fields in
                        DisclosureGroup(subagentTitle(index: index, fields: fields)) {
                            NativeSessionControlFieldsView(fields: fields)
                                .padding(.top, BighelpTokens.space8)
                        }
                    }
                } else {
                    Button("Retry load", systemImage: "arrow.clockwise") {
                        Task { await model.loadSpawnTree(path: entry.path) }
                    }
                }
            } header: {
                Text("Snapshot")
            }

            Section {
                TextField("Optional copy label", text: $saveLabel)
                Button("Save a copy", systemImage: "square.and.arrow.down") {
                    let label = saveLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : saveLabel
                    Task { _ = await model.saveLoadedSpawnTree(label: label) }
                }
                .disabled(model.loadedSpawnTree == nil || model.isBusy(.spawnTreeSave))
                if let result = model.lastSpawnTreeSave {
                    LabeledContent("Saved path", value: result.path)
                        .textSelection(.enabled)
                    LabeledContent("Saved chat", value: result.sessionID)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Save typed snapshot")
            } footer: {
                Text("This saves the loaded typed snapshot only. There is no editable JSON payload.")
            }

            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Spawn tree")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .bighelpToolbarText()
            }
        }
        .task(id: entry.path) {
            guard model.selectedSpawnTreePath != entry.path || model.loadedSpawnTree == nil else { return }
            await model.loadSpawnTree(path: entry.path)
        }
        .accessibilityIdentifier("chat.native-session-controls.spawn-tree")
    }

    @ViewBuilder
    private func optionalValue(_ label: String, _ value: String?) -> some View {
        if let value {
            LabeledContent(label) { Text(value).textSelection(.enabled) }
        }
    }

    private func subagentTitle(index: Int, fields: [String: BighelpJSONValue]) -> String {
        let candidates = ["label", "name", "goal", "subagent_id", "id"]
        for key in candidates {
            if let value = fields[key]?.string, !value.isEmpty { return value }
        }
        return "Subagent \(index + 1)"
    }
}
