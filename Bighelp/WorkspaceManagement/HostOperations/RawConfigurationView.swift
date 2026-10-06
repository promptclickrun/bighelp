import SwiftUI

@MainActor
struct RawConfigurationView: View {
    @Bindable var store: RawConfigurationStore

    @Environment(\.dismiss) private var dismiss
    @State private var isExpanded = false
    @State private var saveAfterExpandedEditor = false
    @State private var confirmsLeaving = false
    @State private var confirmsReload = false

    var body: some View {
        List {
            scopeSection
            messageSections

            if let snapshot = store.snapshot {
                editorSection(snapshot)
                actionSection
                warningSection
            } else if store.isLoading {
                Section { ProgressView("Loading private configuration…") }
            } else {
                Section {
                    ContentUnavailableView(
                        "Configuration not loaded",
                        systemImage: "lock.doc",
                        description: Text("Load the selected profile’s bounded raw configuration when you are ready to edit it."))
                    Button("Load Private Configuration") { Task { await store.load() } }
                        .disabled(!store.ownsScope)
                }
                warningSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Raw Configuration")
        .navigationBarTitleDisplayMode(.inline)
        // Unsaved edits: Back asks first, and swiping back is off until they're saved or discarded.
        .navigationBarBackButtonHidden(store.hasChanges)
        .toolbar {
            if store.hasChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.backward") { confirmsLeaving = true }
                        .accessibilityIdentifier("host.raw-config.back")
                        .bighelpToolbarText()
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Reload", systemImage: "arrow.clockwise") {
                    if store.hasChanges { confirmsReload = true } else { Task { await store.load() } }
                }
                .disabled(!store.ownsScope || store.isLoading || store.isSaving)
                Button("Save") { store.prepareReview() }
                    .fontWeight(.semibold)
                    .disabled(!store.canSave)
                    .accessibilityIdentifier("host.raw-config.save")
            }
        }
        .alert("Discard your changes?", isPresented: $confirmsLeaving) {
            Button("Discard Changes", role: .destructive) {
                store.discardDraft()
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You haven't saved your changes to config.yaml. If you leave now, they'll be lost.")
        }
        .alert("Reload and lose your changes?", isPresented: $confirmsReload) {
            Button("Reload", role: .destructive) { Task { await store.load() } }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Reloading replaces your unsaved changes with the file on the host.")
        }
        .bighelpSheet(isPresented: $isExpanded, onDismiss: {
            // Save from the big editor opens the review once the editor is gone.
            if saveAfterExpandedEditor {
                saveAfterExpandedEditor = false
                store.prepareReview()
            }
        }) {
            RawConfigurationExpandedEditor(store: store) {
                saveAfterExpandedEditor = true
                isExpanded = false
            }
            .bighelpSheetSize(.large)
        }
        .task { if store.snapshot == nil { await store.load() } }
        .onDisappear { store.closePrivateEditor() }
        .bighelpSheet(
            isPresented: Binding(
                get: { store.review != nil },
                set: { if !$0 { store.cancelReview() } }
            )
        ) {
            if let review = store.review {
                RawConfigurationReviewView(store: store, review: review)
                    .bighelpSheetSize(.large)
            }
        }
    }

    private var scopeSection: some View {
        Section {
            LabeledContent("Host", value: store.hostName)
            LabeledContent("Profile", value: store.profileID)
            if let path = store.snapshot?.path {
                LabeledContent("Resolved file") {
                    Text(path).font(.bighelp(.caption).monospaced()).multilineTextAlignment(.trailing)
                }
            }
        } header: { Text("Workspace") } footer: {
            Text("Changes stay a draft until you \(BighelpPlatform.isMac ? "click" : "tap") Save, and the draft is gone when you leave this screen. The editor never includes content in errors, runs commands, or exposes an arbitrary host request console.")
        }
    }

    @ViewBuilder
    private var messageSections: some View {
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Dismiss") { store.clearMessages() }
            }
        }
        if let message = store.successMessage {
            Section {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Button("Dismiss") { store.clearMessages() }
            }
        }
        if store.saveOutcomeNeedsReview {
            Section {
                Label("Save outcome requires readback", systemImage: "questionmark.diamond.fill")
                    .foregroundStyle(.orange)
                Text("Editing and resubmission are disabled until Reload obtains the selected profile’s authoritative document.")
            }
        }
    }

    private var warningSection: some View {
        Section {
            Label("Full-document replacement", systemImage: "doc.badge.gearshape")
            Text("Hermes parses the proposal as a YAML mapping, then atomically rewrites config.yaml. The stock raw endpoint does not run the broader configuration-structure validator and does not create a backup.")
            Text("Saving can change live approval-mode indicators. Other settings may apply only to a new session or gateway lifecycle. bighelp does not restart anything after this save.")
        } header: {
            Text("About saving")
        } footer: {
            Text("Create and download a host backup separately before replacing configuration when you need a recovery point.")
        }
    }

    private func editorSection(_ snapshot: HermesRawConfigurationSnapshot) -> some View {
        Section {
            YAMLTextView(text: $store.draft, isEditable: store.canEdit)
                .frame(minHeight: 360)
                .privacySensitive()
                .accessibilityLabel("Private raw Hermes configuration")
                .accessibilityIdentifier("host.raw-config.editor")


            LabeledContent("Loaded", value: snapshot.loadedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Original bytes", value: snapshot.yaml.utf8.count.formatted())
            LabeledContent("Draft bytes", value: store.draft.utf8.count.formatted())
            if store.remainingBytes < 0 {
                Label("Draft exceeds the private editor limit by \((-store.remainingBytes).formatted()) bytes.", systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
            } else {
                LabeledContent("Remaining limit", value: store.remainingBytes.formatted())
            }
        } header: {
            HStack {
                Text("YAML document")
                Spacer()
                Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") { isExpanded = true }
                    .font(.bighelp(.subheadline))
                    .textCase(nil)
                    .disabled(!store.canEdit)
                    .accessibilityHint("Full screen, with Find and Find and Replace")
                    .accessibilityIdentifier("host.raw-config.expand")
            }
        } footer: {
            Text("Limit: \(DirectHermesHostOperationsClient.maximumRawConfigurationBytes.formatted()) UTF-8 bytes. Review shows exact original/proposed snapshots and every changed line before PUT /api/config/raw is available.")
        }
    }

    private var actionSection: some View {
        Section {
            Button("Review and Save", systemImage: "doc.text.magnifyingglass") {
                store.prepareReview()
            }
            .disabled(!store.canSave)
            .frame(minHeight: BighelpTokens.hitTarget)

            Button("Discard Changes", role: .destructive) { store.discardDraft() }
                .disabled(!store.canEdit || !store.hasChanges)
                .accessibilityIdentifier("host.raw-config.discard")
        } header: {
            Text("Save")
        } footer: {
            Text("Save shows every changed line before anything is written to the host.")
        }
    }
}

@MainActor
private struct RawConfigurationReviewView: View {
    @Bindable var store: RawConfigurationStore
    let review: HermesRawConfigurationReview
    @Environment(\.dismiss) private var dismiss

    private var diff: ExactRawConfigurationDiff {
        ExactRawConfigurationDiff(original: review.original.yaml, proposed: review.proposedYAML)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Host", value: store.hostName)
                    LabeledContent("Profile", value: review.original.profileID)
                    LabeledContent("Resolved file") {
                        Text(review.original.path).font(.bighelp(.caption).monospaced()).multilineTextAlignment(.trailing)
                    }
                } header: { Text("Workspace") } footer: {
                    Text("The save is owner-bound and re-reads this exact path and original UTF-8 snapshot. Any change on the host invalidates this review.")
                }

                Section("Exact change summary") {
                    LabeledContent("Unchanged prefix", value: diff.commonPrefixCount.formatted() + " lines")
                    LabeledContent("Removed", value: diff.removed.count.formatted() + " lines")
                    LabeledContent("Added", value: diff.added.count.formatted() + " lines")
                    LabeledContent("Unchanged suffix", value: diff.commonSuffixCount.formatted() + " lines")
                }

                changedLinesSection
                exactSnapshotSection("Original snapshot", text: review.original.yaml)
                exactSnapshotSection("Proposed replacement", text: review.proposedYAML)

                Section("Final impact") {
                    Label("This replaces the complete file. Omitted keys are removed. Comments and explicit defaults may be normalized by Hermes readback.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("The endpoint does not create a backup and bighelp will not restart a session, gateway, or host process. A successful PUT is not accepted until GET /api/config/raw returns the target path again.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Review Raw Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .privacySensitive()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.cancelReview()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isSaving)
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.isSaving ? "Saving…" : "Save") {
                        Task {
                            await store.saveReviewed(review)
                            if store.review == nil { dismiss() }
                        }
                    }
                    .disabled(store.isSaving || !store.ownsScope)
                }
            }
            .interactiveDismissDisabled(store.isSaving)
        }
    }

    private var changedLinesSection: some View {
        Section {
            if diff.removed.isEmpty && diff.added.isEmpty {
                Text("No changed lines.")
            } else {
                ForEach(Array(diff.removed.enumerated()), id: \.offset) { offset, line in
                    Text("− \(diff.commonPrefixCount + offset + 1)  \(line)")
                        .font(.bighelp(.caption).monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                ForEach(Array(diff.added.enumerated()), id: \.offset) { offset, line in
                    Text("+ \(diff.commonPrefixCount + offset + 1)  \(line)")
                        .font(.bighelp(.caption).monospaced())
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Changed line block")
        } footer: {
            Text("This is an exact contiguous replacement diff: the shared prefix and suffix are unchanged; every intervening original and proposed line is shown.")
        }
    }

    private func exactSnapshotSection(_ title: String, text: String) -> some View {
        Section {
            ScrollView([.horizontal, .vertical]) {
                Text(text.isEmpty ? "" : text)
                    .font(.bighelp(.caption).monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, BighelpTokens.space4)
            }
            .frame(minHeight: 160, maxHeight: 280)
            if text.isEmpty { Text("Empty document").foregroundStyle(.secondary) }
            LabeledContent("UTF-8 bytes", value: text.utf8.count.formatted())
        } header: {
            Text(title)
        }
    }
}

private struct ExactRawConfigurationDiff {
    let commonPrefixCount: Int
    let removed: [String]
    let added: [String]
    let commonSuffixCount: Int

    init(original: String, proposed: String) {
        let old = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = proposed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var prefix = 0
        while prefix < min(old.count, new.count),
              Data(old[prefix].utf8) == Data(new[prefix].utf8) {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.count - prefix, new.count - prefix),
              Data(old[old.count - suffix - 1].utf8) == Data(new[new.count - suffix - 1].utf8) {
            suffix += 1
        }
        commonPrefixCount = prefix
        commonSuffixCount = suffix
        removed = Array(old[prefix..<(old.count - suffix)])
        added = Array(new[prefix..<(new.count - suffix)])
    }
}
