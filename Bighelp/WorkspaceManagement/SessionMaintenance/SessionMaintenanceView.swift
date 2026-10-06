import SwiftUI
import UniformTypeIdentifiers

struct SessionMaintenanceAdoptionRequest: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        case lineageContinuation
        case mostRecent
        case sessionPackageImport
        case foreignHistoryImport
    }

    let profileID: String
    let storedSessionID: String
    let reason: Reason
}

/// Parent integration point for maintenance/portability. `onAdoptSession` must
/// resolve this stored ID through the existing profile-scoped session catalog
/// and bridge, then adopt that coordinate in the retained ChatModel. It must not
/// create a parallel chat/history model or discard drafts/uncertain submissions.
@MainActor
struct SessionMaintenanceView: View {
    @State private var store: SessionMaintenanceStore
    @State private var showsImporter = false
    @State private var exportDocument: SessionMaintenanceDocument?
    @State private var exportFilename = "hermes-session.json"
    @State private var showsExporter = false
    @State private var lineageInput = ""
    @State private var adoptable: SessionMaintenanceAdoptionRequest?
    @State private var closeCandidate: HermesSessionMaintenanceItem?
    @State private var callbackError: String?

    let onAdoptSession: @MainActor (SessionMaintenanceAdoptionRequest) async throws -> Void

    init(
        hostName: String,
        profileID: String,
        client: any HermesSessionMaintenanceManaging,
        onAdoptSession: @escaping @MainActor (SessionMaintenanceAdoptionRequest) async throws -> Void
    ) {
        _store = State(initialValue: SessionMaintenanceStore(
            hostName: hostName, profileID: profileID, client: client
        ))
        self.onAdoptSession = onAdoptSession
    }

    var body: some View {
        Group {
            if store.ownsScope {
                List {
                    scopeSection
                    statusSections
                    statisticsSection
                    lifecycleSection
                    cleanupSection
                    ownerBackfillSection
                    selectedSessionsSection
                    portabilitySection
                    foreignSessionsSection
                    lineageSection
                    adoptionSection
                }
                .listStyle(.insetGrouped)
                .refreshable { await store.refresh() }
            } else {
                ContentUnavailableView(
                    "Session maintenance unavailable",
                    systemImage: "rectangle.stack.badge.exclamationmark",
                    description: Text("The selected host changed. Reopen Session Maintenance from the current workspace.")
                )
            }
        }
        .navigationTitle("Session Maintenance")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.statistics == nil { await store.load() } }
        .onDisappear { if !store.ownsScope { store.retire() } }
        .bighelpSheet(isPresented: reviewBinding(\.bulkReview, clear: store.clearBulkReview)) {
            if let review = store.bulkReview { bulkReviewSheet(review).bighelpSheetSize(.standard) }
        }
        .bighelpSheet(isPresented: reviewBinding(\.ownerBackfillReview, clear: store.clearOwnerBackfillReview)) {
            if let review = store.ownerBackfillReview { ownerBackfillReviewSheet(review).bighelpSheetSize(.standard) }
        }
        .bighelpSheet(isPresented: reviewBinding(\.emptyReview, clear: store.clearEmptyReview)) {
            if let review = store.emptyReview { emptyReviewSheet(review).bighelpSheetSize(.standard) }
        }
        .bighelpSheet(isPresented: reviewBinding(\.pruneReview, clear: store.clearPruneReview)) {
            if let review = store.pruneReview { pruneReviewSheet(review).bighelpSheetSize(.standard) }
        }
        .bighelpSheet(isPresented: reviewBinding(\.importReview, clear: store.clearImportReview)) {
            if let review = store.importReview { importReviewSheet(review).bighelpSheetSize(.standard) }
        }
        .bighelpSheet(isPresented: reviewBinding(\.foreignPreview, clear: store.clearForeignPreview)) {
            if let preview = store.foreignPreview { foreignPreviewSheet(preview).bighelpSheetSize(.large) }
        }
        .fileImporter(
            isPresented: $showsImporter, allowedContentTypes: [.json], allowsMultipleSelection: false
        ) { result in
            do {
                let urls = try result.get()
                guard urls.count == 1, let url = urls.first else {
                    callbackError = "Choose one session package."
                    return
                }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                      let size = info.fileSize, size <= DirectHermesHTTP.maximumSessionTransferBytes else {
                    callbackError = "Choose a session package no larger than 25 MiB."
                    return
                }
                store.prepareImport(data: try Data(contentsOf: url, options: .mappedIfSafe))
            } catch {
                callbackError = "The selected JSON file could not be read."
            }
        }
        .fileExporter(
            isPresented: $showsExporter, document: exportDocument,
            contentType: .json, defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            store.clearExport()
            if case .failure = result { callbackError = "The session package was prepared, but \(BighelpPlatform.isMac ? "macOS" : "iOS") did not save it." }
        }
        .confirmationDialog(
            "Close live runtime?",
            isPresented: Binding(
                get: { closeCandidate != nil },
                set: { if !$0 { closeCandidate = nil } }
            ),
            presenting: closeCandidate
        ) { session in
            Button("Close Runtime", role: .destructive) {
                closeCandidate = nil
                Task { await store.closeLive(session) }
            }
            Button("Cancel", role: .cancel) { closeCandidate = nil }
        } message: { session in
            Text("Close only the live runtime for “\(session.title)”. Stored history stays available to resume; this does not delete or archive the session.")
        }
        .alert("Session maintenance", isPresented: Binding(
            get: { callbackError != nil }, set: { if !$0 { callbackError = nil } }
        )) {
            Button("OK", role: .cancel) { callbackError = nil }
        } message: { Text(callbackError ?? "") }
        .accessibilityIdentifier("session-maintenance.root")
    }

    private var scopeSection: some View {
        Section {
            LabeledContent("Host", value: store.hostName)
            LabeledContent("Profile", value: store.profileID)
        } header: { Text("Workspace") } footer: {
            Text("Every operation is scoped to this exact profile. Session chat and history remain in the existing conversation experience.")
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if store.isLoading || store.operationTitle != nil {
            Section { ProgressView(store.operationTitle ?? "Loading sessions") }
        }
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityIdentifier("session-maintenance.error")
                Button("Refresh") { Task { await store.refresh() } }.disabled(store.isBusy)
                Button("Dismiss") { store.clearMessages() }
            }
        }
        if let message = store.successMessage {
            Section {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityIdentifier("session-maintenance.success")
                Button("Dismiss") { store.clearMessages() }
            }
        }
    }

    @ViewBuilder
    private var statisticsSection: some View {
        if let stats = store.statistics {
            Section("Overview") {
                LabeledContent("Sessions", value: stats.total.formatted())
                LabeledContent("Active store", value: stats.activeStore.formatted())
                LabeledContent("Archived", value: stats.archived.formatted())
                LabeledContent("Messages", value: stats.messages.formatted())
                LabeledContent("Empty ended", value: stats.emptyEndedCount.formatted())
                if !stats.bySource.isEmpty {
                    DisclosureGroup("By source") {
                        ForEach(stats.bySource.keys.sorted(), id: \.self) { source in
                            LabeledContent(source, value: (stats.bySource[source] ?? 0).formatted())
                        }
                    }
                }
            }
        }
    }

    private var lifecycleSection: some View {
        Section {
            Button("Find Most Recent Session", systemImage: "clock.arrow.circlepath") {
                Task { await store.findMostRecent() }
            }
            .disabled(store.isBusy)
            .accessibilityIdentifier("session-maintenance.most-recent")

            if let lookup = store.mostRecentLookup {
                if let recent = lookup.session {
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text(recent.title).font(.bighelp(.body))
                        Text(recent.storedSessionID)
                            .font(.bighelp(.caption).monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(recent.source).font(.bighelp(.caption)).foregroundStyle(.secondary)
                    }
                    Button("Open Most Recent in Sessions", systemImage: "arrow.up.forward.app") {
                        adoptable = .init(
                            profileID: lookup.profileID,
                            storedSessionID: recent.storedSessionID,
                            reason: .mostRecent
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "No recent session",
                        systemImage: "clock.badge.questionmark",
                        description: Text("Hermes returned no stored session ID. This stock method also folds host lookup failures into a null result, so refresh before treating the profile as empty.")
                    )
                }
            }
        } header: {
            Text("Open a session")
        } footer: {
            Text("Most Recent uses Hermes’s stored session ID exactly. Closing a live runtime is available from each active session’s Actions menu and never deletes history.")
        }
    }

    private var ownerBackfillSection: some View {
        Section {
            Button("Review Legacy Session Ownership", systemImage: "person.crop.circle.badge.checkmark") {
                Task { await store.prepareOwnerBackfill() }
            }
            .disabled(store.isBusy || store.statistics == nil)
            .accessibilityIdentifier("session-maintenance.owner-backfill.review")
        } header: {
            Text("Advanced · Legacy ownership")
        } footer: {
            Text("Nothing runs automatically. The reviewed operation only stamps empty legacy owner fields with this serving profile and never overwrites an existing owner.")
        }
    }

    private var cleanupSection: some View {
        Section {
            Button("Review Empty Sessions", systemImage: "rectangle.stack.badge.minus") {
                Task { await store.prepareEmptyDelete() }
            }
            .disabled(store.isBusy || (store.statistics?.emptyEndedCount ?? 0) == 0)

            Stepper(
                "Ended at least \(Int(store.pruneFilter.olderThanDays ?? 90)) days ago",
                value: Binding(
                    get: { Int(store.pruneFilter.olderThanDays ?? 90) },
                    set: { store.pruneFilter.olderThanDays = Double($0) }
                ), in: 1...3_650
            )
            Toggle("Include archived sessions", isOn: $store.pruneFilter.includeArchived)
            Button("Preview Prune", systemImage: "clock.badge.questionmark") {
                Task { await store.preparePrune() }
            }
            .disabled(store.isBusy)
        } header: { Text("Cleanup") }
          footer: {
              Text("Preview is a stock Hermes dry run. Before pruning, bighelp repeats the identical dry run and requires the complete target snapshot to match.")
          }
    }

    @ViewBuilder
    private var selectedSessionsSection: some View {
        Section {
            if store.sessions.isEmpty {
                ContentUnavailableView("No sessions", systemImage: "rectangle.stack")
            } else {
                DisclosureGroup("Choose sessions (\(store.selectedSessionIDs.count))") {
                    ForEach(store.sessions) { session in
                        HStack(alignment: .top, spacing: BighelpTokens.space8) {
                            Button {
                                if store.selectedSessionIDs.contains(session.id) {
                                    store.selectedSessionIDs.remove(session.id)
                                } else {
                                    store.selectedSessionIDs.insert(session.id)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: BighelpTokens.space8) {
                                    Image(systemName: store.selectedSessionIDs.contains(session.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(store.selectedSessionIDs.contains(session.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    sessionLabel(session)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(store.selectedSessionIDs.contains(session.id) ? "Selected" : "Not selected"), \(session.title)")

                            Menu {
                                Button(
                                    session.hidden ? "Show in Default List" : "Hide from Default List",
                                    systemImage: session.hidden ? "eye" : "eye.slash"
                                ) {
                                    Task { await store.setHidden(session, hidden: !session.hidden) }
                                }
                                .disabled(session.archived && !session.hidden)
                                .accessibilityIdentifier("session-maintenance.hidden.\(session.id)")

                                if session.active {
                                    Button("Close Live Runtime", systemImage: "xmark.circle", role: .destructive) {
                                        closeCandidate = session
                                    }
                                    .accessibilityIdentifier("session-maintenance.close.\(session.id)")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Actions for \(session.title)")
                            .accessibilityIdentifier("session-maintenance.actions.\(session.id)")
                            .disabled(store.isBusy)
                        }
                    }
                }
                Button("Review \(store.selectedSessionIDs.count) Selected", systemImage: "trash", role: .destructive) {
                    Task { await store.prepareBulkDelete() }
                }
                .disabled(store.selectedSessionIDs.isEmpty || store.isBusy)
            }
        } header: { Text("Sessions and deletion") }
          footer: { Text("Actions keeps hidden state separate from archive state. Archived rows must be restored before hiding so they remain discoverable. Selection is only for the separately reviewed delete operation.") }
    }

    private var portabilitySection: some View {
        Section {
            Menu("Export Session", systemImage: "square.and.arrow.up") {
                ForEach(store.sessions) { session in
                    Button(session.title) {
                        Task {
                            await store.export(session)
                            guard let export = store.pendingExport else { return }
                            exportDocument = SessionMaintenanceDocument(data: export.data)
                            exportFilename = export.filename
                            showsExporter = true
                        }
                    }
                }
            }
            .disabled(store.sessions.isEmpty || store.isBusy)

            Button("Import Session JSON", systemImage: "square.and.arrow.down") {
                showsImporter = true
            }
            .disabled(store.isBusy)
        } header: { Text("Advanced · Import & export") }
          footer: { Text("Packages contain session rows and messages only. Import restores history, not ownership of a live process or messaging channel.") }
    }

    @ViewBuilder
    private var foreignSessionsSection: some View {
        Section {
            Picker("Source", selection: Binding(
                get: { store.foreignSource ?? "all" },
                set: { store.foreignSource = $0 == "all" ? nil : $0 }
            )) {
                Text("All supported tools").tag("all")
                Text("Claude Code").tag("claude")
                Text("Codex CLI").tag("codex")
            }
            Button("Find Foreign Sessions", systemImage: "externaldrive.badge.magnifyingglass") {
                Task { await store.loadForeign() }
            }
            .disabled(store.isBusy)

            if let host = store.foreignHost {
                LabeledContent("Scanned by", value: host)
                if store.foreignUnreadable > 0 {
                    LabeledContent("Unreadable on this page", value: store.foreignUnreadable.formatted())
                }
            }
            ForEach(store.foreignSessions) { item in
                Button { Task { await store.previewForeign(item) } } label: {
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text(item.title).font(.bighelp(.body))
                        Text("\(item.sourceLabel) • \(item.turnCount) turns")
                            .font(.bighelp(.caption)).foregroundStyle(.secondary)
                        if !item.excerpt.isEmpty {
                            Text(item.excerpt).font(.bighelp(.caption)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if store.foreignNextOffset != nil {
                Button("Load More") { Task { await store.loadForeign(reset: false) } }
                    .disabled(store.isBusy)
            }
        } header: { Text("Advanced · Foreign history") }
          footer: {
              Text("Hermes scans only its supported tool folders and returns opaque handles. bighelp never sends a host path or imports before you review the bounded preview.")
          }
    }

    private var lineageSection: some View {
        Section {
            TextField("Stored session ID", text: $lineageInput)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Find Latest Descendant", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath") {
                Task { await store.resolveLineage(sessionID: lineageInput) }
            }
            .disabled(lineageInput.isEmpty || store.isBusy)
            if let lineage = store.lineage {
                LabeledContent("Latest", value: lineage.latestSessionID)
                if lineage.path.count > 1 {
                    DisclosureGroup("Compression lineage (\(lineage.path.count))") {
                        ForEach(Array(lineage.path.enumerated()), id: \.offset) { _, id in
                            Text(id).font(.bighelp(.caption).monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Button("Open Latest in Sessions") {
                    adoptable = .init(
                        profileID: lineage.profileID, storedSessionID: lineage.latestSessionID,
                        reason: .lineageContinuation
                    )
                }
            }
        } header: { Text("Advanced · Lineage") }
          footer: { Text("This resolves compression descendants only. The existing session bridge owns resume and chat adoption.") }
    }

    @ViewBuilder
    private var adoptionSection: some View {
        if let request = adoptable {
            Section("Ready to open") {
                Text(request.storedSessionID).font(.bighelp(.caption).monospaced()).textSelection(.enabled)
                Button("Adopt in Sessions", systemImage: "arrow.up.forward.app") {
                    Task {
                        do {
                            try await onAdoptSession(request)
                            adoptable = nil
                        } catch {
                            callbackError = (error as? LocalizedError)?.errorDescription
                                ?? "Sessions could not adopt this stored session."
                        }
                    }
                }
            }
        }
    }

    private func ownerBackfillReviewSheet(_ review: HermesSessionOwnerBackfillReview) -> some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Serving profile", value: review.profileID)
                    LabeledContent("Store rows reviewed", value: review.storeStatistics.total.formatted())
                    LabeledContent("Archived rows", value: review.storeStatistics.archived.formatted())
                    LabeledContent("Messages", value: review.storeStatistics.messages.formatted())
                }
                Section {
                    Button("Backfill Unowned Legacy Rows") {
                        Task { await store.backfillReviewedOwners() }
                    }
                    .disabled(store.isBusy)
                    .accessibilityIdentifier("session-maintenance.owner-backfill.confirm")
                } footer: {
                    Text("The stock route has no dry run, so the exact affected count is returned only after confirmation. bighelp rechecks this store summary first, sends this exact profile, then requires an idempotent readback to stamp zero additional rows. Existing non-empty owners are never overwritten.")
                }
            }
            .navigationTitle("Review Legacy Ownership")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.clearOwnerBackfillReview() }.keyboardShortcut(.cancelAction)
                        .bighelpToolbarText()
                }
            }
        }
    }

    private func bulkReviewSheet(_ review: HermesSessionBulkDeleteReview) -> some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Profile", value: review.profileID)
                    LabeledContent("Selected", value: review.sessions.count.formatted())
                }
                Section("Exact targets") {
                    ForEach(review.sessions) { session in sessionLabel(session) }
                }
                Section {
                    Button("Delete These Sessions", role: .destructive) {
                        Task { await store.deleteReviewedBulk() }
                    }
                    .disabled(store.isBusy)
                } footer: {
                    Text("bighelp re-reads every target and requires its exact reviewed snapshot before sending one bulk-delete request. Every ID must then read back as absent.")
                }
            }
            .navigationTitle("Review Selected Sessions")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.clearBulkReview() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }

    private func emptyReviewSheet(_ review: HermesSessionEmptyDeleteReview) -> some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Profile", value: review.profileID)
                    LabeledContent("Empty ended sessions", value: review.count.formatted())
                    LabeledContent("All sessions", value: review.stats.total.formatted())
                    LabeledContent("Archived protected", value: review.stats.archived.formatted())
                }
                Section {
                    Button("Delete \(review.count) Empty Sessions", role: .destructive) {
                        Task { await store.deleteReviewedEmpty() }
                    }
                    .disabled(review.count == 0 || store.isBusy)
                } footer: {
                    Text("Hermes defines this target set as ended, non-archived sessions with no message rows. bighelp requires the count to remain exact before deletion and zero afterward.")
                }
            }
            .navigationTitle("Review Empty Sessions")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.clearEmptyReview() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }

    private func pruneReviewSheet(_ review: HermesSessionPruneReview) -> some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Profile", value: review.profileID)
                    LabeledContent("Matched ended sessions", value: review.sessions.count.formatted())
                    LabeledContent("Open sessions skipped", value: review.skippedOpen.formatted())
                    LabeledContent("Archived included", value: review.filter.includeArchived ? "Yes" : "No")
                }
                Section("Exact dry-run targets") {
                    if review.sessions.isEmpty {
                        ContentUnavailableView("Nothing to prune", systemImage: "checkmark.circle")
                    } else {
                        ForEach(review.sessions) { session in sessionLabel(session) }
                    }
                }
                if !review.sessions.isEmpty {
                    Section {
                        Button("Prune These Sessions", role: .destructive) {
                            Task { await store.pruneReviewedSessions() }
                        }
                        .disabled(store.isBusy)
                    } footer: {
                        Text("The complete stock dry-run response must be unchanged immediately before deletion. Every reviewed session must then read back as absent.")
                    }
                }
            }
            .navigationTitle("Review Prune")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.clearPruneReview() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }

    private func importReviewSheet(_ review: HermesSessionImportReview) -> some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Profile", value: review.profileID)
                    LabeledContent("Sessions", value: review.sessionIDs.count.formatted())
                    LabeledContent("Package", value: ByteCountFormatter.string(fromByteCount: Int64(review.byteCount), countStyle: .file))
                }
                Section("Session IDs") {
                    ForEach(review.sessionIDs, id: \.self) { id in
                        Text(id).font(.bighelp(.caption).monospaced()).textSelection(.enabled)
                    }
                }
                Section {
                    Button("Import Reviewed Package") {
                        Task {
                            if let result = await store.importReviewedPackage(),
                               let id = result.importedIDs.first ?? result.skippedIDs.first {
                                adoptable = .init(
                                    profileID: result.profileID, storedSessionID: id,
                                    reason: .sessionPackageImport
                                )
                            }
                        }
                    }
                    .disabled(store.isBusy)
                } footer: {
                    Text("Existing IDs are skipped by Hermes. Imported history is read back by exact ID before bighelp offers to open it.")
                }
            }
            .navigationTitle("Review Import")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.clearImportReview() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }

    private func foreignPreviewSheet(_ preview: HermesForeignSessionPreview) -> some View {
        NavigationStack {
            List {
                Section {
                    Text(preview.title).font(.bighelp(.headline))
                    LabeledContent("Source", value: preview.source)
                    LabeledContent("Messages", value: preview.totalMessages.formatted())
                    if preview.isTruncated { Label("Preview is bounded; import includes the complete parsed history.", systemImage: "ellipsis.circle") }
                    if let existing = preview.alreadyImportedSessionID {
                        Label("Already imported as \(existing)", systemImage: "checkmark.circle")
                    }
                }
                Section("Bounded preview") {
                    ForEach(preview.messages) { message in
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(message.role.capitalized).font(.bighelp(.caption).weight(.semibold)).foregroundStyle(.secondary)
                            Text(message.content).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    if let existing = preview.alreadyImportedSessionID {
                        Button("Open Imported Session") {
                            adoptable = .init(
                                profileID: preview.profileID, storedSessionID: existing,
                                reason: .foreignHistoryImport
                            )
                            store.clearForeignPreview()
                        }
                    } else {
                        Button("Import This History") {
                            Task {
                                if let result = await store.importForeign() {
                                    adoptable = .init(
                                        profileID: result.profileID, storedSessionID: result.sessionID,
                                        reason: .foreignHistoryImport
                                    )
                                }
                            }
                        }
                        .disabled(store.isBusy)
                    }
                } footer: {
                    Text("Import rechecks the exact preview token. Hermes preserves provenance and reads the source file without modifying it.")
                }
            }
            .navigationTitle("Review Foreign History")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.clearForeignPreview() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }

    private func sessionLabel(_ session: HermesSessionMaintenanceItem) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text(session.title).font(.bighelp(.body))
            Text(session.id).font(.bighelp(.caption).monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text("\(session.source) • \(session.messageCount) messages\(session.archived ? " • Archived" : "")\(session.hidden ? " • Hidden" : "")\(session.active ? " • Active" : "")")
                .font(.bighelp(.caption)).foregroundStyle(.secondary)
        }
        .padding(.vertical, BighelpTokens.space4)
    }

    private func reviewBinding<Value>(
        _ keyPath: KeyPath<SessionMaintenanceStore, Value?>,
        clear: @escaping () -> Void
    ) -> Binding<Bool> {
        Binding(get: { store[keyPath: keyPath] != nil }, set: { if !$0 { clear() } })
    }
}

private struct SessionMaintenanceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, !data.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
