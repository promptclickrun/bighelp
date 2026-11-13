import SwiftUI

struct NativeSessionRollbackReviewView: View {
    let checkpoint: DirectHermesRollbackCheckpoint
    let model: NativeSessionControlsModel
    let isSessionRunning: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var filePath = ""
    @State private var showsRestoreConfirmation = false
    @State private var showsExactDiff = true

    var body: some View {
        Form {
            if let pending = model.pendingHistoryReconciliation {
                Section {
                    Label("\(pending.kind.label) is waiting for canonical chat refresh. The mutation will not be repeated.",
                          systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.orange)
                    Button("Retry chat refresh") {
                        Task { await model.retryHistoryReconciliation() }
                    }
                    .disabled(model.isBusy(.historyReconciliation))
                }
            }

            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section {
                LabeledContent("Hash", value: checkpoint.hash)
                    .textSelection(.enabled)
                if !checkpoint.timestamp.isEmpty {
                    LabeledContent("Created", value: checkpoint.timestamp)
                        .textSelection(.enabled)
                }
                if !checkpoint.message.isEmpty {
                    Text(checkpoint.message)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Checkpoint")
            }

            Section {
                if model.isBusy(.rollbackDiff), model.rollbackDiff == nil {
                    ProgressView("Loading exact diff…")
                } else if let diff = model.rollbackDiff {
                    if !diff.stat.isEmpty {
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text("Summary")
                                .font(.bighelp(.caption).weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(diff.stat)
                                .font(.bighelp(.body).monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if let rendered = diff.rendered, !rendered.isEmpty, rendered != diff.diff {
                        DisclosureGroup("Computer-rendered review") {
                            Text(rendered)
                                .font(.bighelp(.body).monospaced())
                                .textSelection(.enabled)
                                .padding(.top, BighelpTokens.space4)
                        }
                    }
                    DisclosureGroup("Exact diff", isExpanded: $showsExactDiff) {
                        Text(diff.diff.isEmpty ? "No textual diff." : diff.diff)
                            .font(.bighelp(.body).monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, BighelpTokens.space4)
                    }
                } else {
                    Button("Retry diff", systemImage: "arrow.clockwise") {
                        Task { await model.loadRollbackDiff(checkpoint) }
                    }
                }
            } header: {
                Text("Review")
            }

            Section {
                TextField("Optional single file path", text: $filePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(restoreButtonTitle, systemImage: "clock.arrow.circlepath", role: .destructive) {
                    showsRestoreConfirmation = true
                }
                .disabled(restoreDisabled)
            } header: {
                Text("Restore scope")
            } footer: {
                Text(filePathValue == nil
                     ? "Leaving the path empty restores the checkpoint scope."
                     : "Only the exact path entered above will be requested from the typed rollback API.")
            }

            if let result = model.lastRollbackRestore, !result.success {
                Section("Last restore result") {
                    optionalValue("Reason", result.reason)
                    optionalValue("Error", result.error)
                    optionalValue("Directory", result.directory)
                    optionalValue("File", result.file)
                    stringList("Skipped user edits", result.skippedUserEdits)
                    stringList("Skipped oversized files", result.skippedOversize)
                    stringList("Failed deletes", result.failedDeletes)
                }
            }
        }
        .navigationTitle("Review rollback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .bighelpToolbarText()
            }
        }
        .confirmationDialog(
            restoreButtonTitle,
            isPresented: $showsRestoreConfirmation
        ) {
            Button(restoreButtonTitle, role: .destructive) {
                let path = filePathValue
                Task {
                    if await model.restoreRollback(hash: checkpoint.hash, filePath: path) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(restoreConfirmationMessage)
        }
        .accessibilityIdentifier("chat.native-session-controls.rollback-review")
    }

    private var filePathValue: String? {
        filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : filePath
    }

    private var restoreButtonTitle: String {
        filePathValue == nil ? "Restore checkpoint" : "Restore this file"
    }

    private var restoreConfirmationMessage: String {
        if let filePathValue {
            return "Hermes will restore \(filePathValue) from checkpoint \(checkpoint.hash). Review the diff above. bighelp must refresh canonical chat history after acknowledgement."
        }
        return "Hermes will restore checkpoint \(checkpoint.hash). Review the exact diff above. bighelp must refresh canonical chat history after acknowledgement."
    }

    private var restoreDisabled: Bool {
        isSessionRunning
            || model.rollbackDiff == nil
            || model.isBusy(.rollbackRestore)
            || !model.canRunHistoryMutation
    }

    @ViewBuilder
    private func optionalValue(_ label: String, _ value: String?) -> some View {
        if let value {
            LabeledContent(label) { Text(value).textSelection(.enabled) }
        }
    }

    @ViewBuilder
    private func stringList(_ title: String, _ values: [String]?) -> some View {
        if let values, !values.isEmpty {
            DisclosureGroup("\(title) (\(values.count))") {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(value)
                        .font(.bighelp(.caption).monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}
