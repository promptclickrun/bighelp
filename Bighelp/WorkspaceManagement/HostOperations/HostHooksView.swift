import SwiftUI

/// Settings › Hermes tools › Shell Hooks: the host's hooks by consent, each with its command and
/// Review Removal, then New hook. Every write is reviewed first.
@MainActor
struct HostHooksView: View {
    @Bindable var store: HostOperationsStore

    @State private var event = ""
    @State private var command = ""
    @State private var matcher = ""
    @State private var timeout = "60"
    @State private var approve = false

    var body: some View {
        List {
            messageSections
            configuredSection
            createSection
            contractSection
            scopeSection
        }
        .bighelpFormSurface()
        .navigationTitle("Shell Hooks")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { store.closeShellHooks() }
        .bighelpRefreshable { await store.refreshShellHooks() }
        .task {
            if store.shellHooks == nil { await store.refreshShellHooks() }
            adoptFirstEventIfNeeded()
        }
        .onChange(of: store.shellHooks?.validEvents ?? []) { _, _ in
            adoptFirstEventIfNeeded()
        }
        .bighelpSheet(
            isPresented: Binding(
                get: { store.hookCreateReview != nil },
                set: { if !$0 { store.cancelHookReview() } }
            )
        ) {
            if let review = store.hookCreateReview {
                HookCreateReviewView(store: store, review: review) {
                    command = ""
                    matcher = ""
                    timeout = "60"
                    approve = false
                }
                .bighelpSheetSize(.standard)
            }
        }
        .bighelpSheet(
            isPresented: Binding(
                get: { store.hookDeleteReview != nil },
                set: { if !$0 { store.cancelHookReview() } }
            )
        ) {
            if let review = store.hookDeleteReview {
                HookDeleteReviewView(store: store, review: review)
                    .bighelpSheetSize(.standard)
            }
        }
    }

    private var scopeSection: some View {
        Section {
            LabeledContent("Host", value: store.hostName)
            LabeledContent("Selected profile", value: store.profileID)
            LabeledContent("Unscoped ops target", value: store.operationTargetProfileID ?? "Not verified")
        } header: { Text("Workspace") } footer: {
            Text("Hook routes mutate the serving backend’s profile home and do not accept a profile parameter. bighelp requires that exact target from connection discovery; it never substitutes the selected picker label. The client uses only the stock event, command, matcher, timeout, and approve fields and invents no switches or aliases.")
        }
    }

    @ViewBuilder
    private var messageSections: some View {
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Dismiss") { store.clearMessages() }
            }
        }
        if let message = store.successMessage {
            Section {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                Button("Dismiss") { store.clearMessages() }
            }
        }
    }

    private var contractSection: some View {
        Section {
            Label("Shell hooks execute host commands", systemImage: "terminal.fill")
                .foregroundStyle(.orange)
            Text("Create writes host configuration. Removal deletes every hook with the same event and command and revokes that command’s consent.")
            DisclosureGroup("How Hermes applies hooks") {
                Text("Approving creation records the exact event and command consent entry. Existing sessions do not hot-activate the hook; Hermes applies it to a new session or after a messaging-gateway restart.")
                Text("Matcher and timeout do not narrow deletion in the stock endpoint.")
            }
        } header: {
            Text("Safety")
        }
    }

    @ViewBuilder
    private var configuredSection: some View {
        if let snapshot = store.shellHooks {
            if snapshot.hooks.isEmpty {
                Section("Configured hooks") {
                    ContentUnavailableView(
                        "No shell hooks",
                        systemImage: "terminal",
                        description: Text("Hermes returned an empty configured hook list."))
                }
            } else {
                hookSection(String(localized: "Approved"), snapshot.hooks.filter(\.isAllowed))
                hookSection(String(localized: "Not approved"), snapshot.hooks.filter { !$0.isAllowed })
                Section {
                } footer: {
                    Text("Executable reflects the script target now; approved reflects the separate consent allowlist. Neither field is a fabricated on/off toggle.")
                }
            }
        } else if store.isLoading {
            Section { ProgressView("Loading hooks…") }
        } else {
            Section { ContentUnavailableView("Hooks unavailable", systemImage: "terminal") }
        }
    }

    @ViewBuilder
    private func hookSection(_ title: String, _ hooks: [HermesShellHook]) -> some View {
        if !hooks.isEmpty {
            Section(HermesTools.heading(title, hooks.count)) {
                ForEach(hooks) { hookRow($0) }
            }
        }
    }

    /// A hook: what it runs on, its command, its matcher and timeout, and Review Removal in its menu.
    /// Hooks have no page: leaving this screen drops the catalog (`closeShellHooks`).
    private func hookRow(_ hook: HermesShellHook) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            HermesToolIcon(art: .symbol("terminal", key: hook.event))
            VStack(alignment: .leading, spacing: 2) {
                Text(HermesTools.readable(hook.event)).font(.bighelp(.body))
                Text(hook.command)
                    .font(.bighelp(.footnote).monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .privacySensitive()
                Text(HermesTools.line(hook.matcher.map { "Matches \($0)" },
                                      "\(hook.timeoutSeconds) s timeout",
                                      hook.isExecutable ? "Can run now" : "Can't run now",
                                      hook.approvedAt.map { "Approved \($0)" }))
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: BighelpTokens.space4) {
                HermesToolStatus(text: hook.isAllowed ? String(localized: "Approved") : String(localized: "Not approved"),
                                 tone: hook.isAllowed ? .positive : .warning)
                Menu {
                    Button("Review Removal", systemImage: "trash", role: .destructive) {
                        Task { await store.reviewHookDeletion(hook) }
                    }
                    .disabled(!store.canAct)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .accessibilityLabel("More for \(HermesTools.readable(hook.event)) hook")
            }
        }
        .padding(.vertical, BighelpTokens.space4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var createSection: some View {
        Section {
            if let snapshot = store.shellHooks, !snapshot.validEvents.isEmpty {
                Picker("Event", selection: $event) {
                    ForEach(snapshot.validEvents, id: \.self) { Text($0).tag($0) }
                }
                TextField("Command or executable path", text: $command, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                if event == "pre_tool_call" || event == "post_tool_call" {
                    TextField("Tool matcher regex (optional)", text: $matcher)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField("Timeout in seconds (1–300)", text: $timeout)
                    .keyboardType(.numberPad)
                Toggle("Record consent after creation", isOn: $approve)
                Button("Review Hook Creation", systemImage: "checkmark.shield") {
                    let parsedTimeout = timeout.isEmpty ? nil : Int(timeout)
                    Task {
                        await store.reviewHookCreation(.init(
                            event: event, command: command,
                            matcher: matcher.isEmpty ? nil : matcher,
                            timeoutSeconds: parsedTimeout, approve: approve
                        ))
                    }
                }
                .disabled(!store.canAct || event.isEmpty || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (!timeout.isEmpty && Int(timeout) == nil))
                .frame(minHeight: BighelpTokens.hitTarget)
            } else {
                Text("Hermes did not return a valid event catalog, so hook creation is unavailable.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("New hook")
        } footer: {
            Text("Consent defaults off in bighelp. Review the exact command and scope before allowing code execution.")
        }
    }

    private func adoptFirstEventIfNeeded() {
        guard let events = store.shellHooks?.validEvents, !events.isEmpty,
              !events.contains(where: { Data($0.utf8) == Data(event.utf8) }) else { return }
        event = events[0]
        matcher = ""
    }
}

@MainActor
private struct HookCreateReviewView: View {
    @Bindable var store: HostOperationsStore
    let review: HermesShellHookCreateReview
    let onSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Review") {
                    LabeledContent("Host", value: store.hostName)
                    LabeledContent("Target profile", value: store.operationTargetProfileID ?? "Not verified")
                    LabeledContent("Event", value: review.draft.event)
                    LabeledContent("Command") {
                        Text(review.draft.command).font(.bighelp(.caption).monospaced()).multilineTextAlignment(.trailing)
                    }
                    if let matcher = review.draft.matcher { LabeledContent("Matcher", value: matcher) }
                    LabeledContent("Timeout", value: "\(review.draft.timeoutSeconds ?? 60) seconds")
                    LabeledContent("Record consent", value: review.draft.approve ? "Yes" : "No")
                    LabeledContent("Identical entries already present", value: review.existingMatchingEntries.formatted())
                }
                .privacySensitive()
                Section("Consequences") {
                    Text("Hermes will re-read the complete hook catalog before writing. If anything changed after this review, creation is refused. The POST acknowledgement is followed by GET /api/ops/hooks readback.")
                    Label("This command can execute with the Hermes host process’s permissions once consented and activated.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Review Hook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.cancelHookReview(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(store.isMutating)
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Reviewed Hook") {
                        Task {
                            await store.createReviewedHook()
                            if store.hookCreateReview == nil {
                                onSuccess()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!store.canAct)
                }
            }
            .interactiveDismissDisabled(store.isMutating)
        }
    }
}

@MainActor
private struct HookDeleteReviewView: View {
    @Bindable var store: HostOperationsStore
    let review: HermesShellHookDeleteReview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Review") {
                    LabeledContent("Host", value: store.hostName)
                    LabeledContent("Target profile", value: store.operationTargetProfileID ?? "Not verified")
                    LabeledContent("Event", value: review.hook.event)
                    LabeledContent("Command") {
                        Text(review.hook.command).font(.bighelp(.caption).monospaced()).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Entries removed", value: review.matchingCommandsRemoved.formatted())
                }
                .privacySensitive()
                Section("Consequences") {
                    Text("The stock DELETE contract matches event and command only. All matching entries are removed and the command’s allowlist consent is revoked regardless of matcher or timeout.")
                    Text("Hermes will re-read the catalog and refuse the deletion if it changed after review, then verify absence with a second catalog read.")
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Review Hook Removal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.cancelHookReview(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(store.isMutating)
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove \(review.matchingCommandsRemoved) Hook\(review.matchingCommandsRemoved == 1 ? "" : "s")", role: .destructive) {
                        Task {
                            await store.deleteReviewedHook()
                            if store.hookDeleteReview == nil { dismiss() }
                        }
                    }
                    .disabled(!store.canAct)
                }
            }
            .interactiveDismissDisabled(store.isMutating)
        }
    }
}
