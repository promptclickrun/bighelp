import Foundation
import Observation

/// Draft-scoped, memory-only controller. No network in init/bind, no transcript
/// store, no credentials and no optional-provider dependency for ordinary chat.
@MainActor @Observable
final class ReferenceHubStore {
    private(set) var owner: ReferenceHubOwner?
    private(set) var results: [ReferenceHubResult] = []
    private(set) var isLoading = false
    private(set) var providerErrors: [String: String] = [:]
    private(set) var providerNotices: [String: String] = [:]
    private(set) var category: ReferenceCategory = .all
    private(set) var query: ReferenceQueryContext?
    private(set) var preview: ReferenceHubPreview?
    private(set) var isResolving = false
    private(set) var selected: [ReferenceDraftSelection] = []
    private(set) var pendingChanges: [ReferenceRevalidationChange] = []
    private(set) var message: String?
    private(set) var isPreparingSend = false
    private(set) var frozenSubmission: ReferenceFrozenDraft?
    private(set) var source = ""
    private(set) var selection = NSRange(location: 0, length: 0)
    private(set) var revision: UInt64 = 0
    private(set) var draftID = UUID()
    private(set) var hasMarkedText = false
    private(set) var isDismissed = false
    private(set) var isEditorActive = false
    private(set) var optionalProviderUnavailableReason: String?
    /// Arrow-key browsing of the drawer on the Mac; observed on its own.
    @ObservationIgnored let keyboard = ReferenceHubKeyboardNavigation()

    @ObservationIgnored private var providers: [ReferenceHubProvider]
    @ObservationIgnored private var recentResults: [ReferenceHubResult] = []
    @ObservationIgnored private let onConnect: ((ReferenceCategory) -> Void)?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var resolveGeneration: UInt64 = 0
    @ObservationIgnored private var preparationGeneration: UInt64 = 0
    @ObservationIgnored private var searchTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var loadingProviders: Set<String> = []
    // Removed snapshots remain available for native typing Undo/Redo. Bounded
    // per draft; never evict one while UIKit may still restore its anchor.
    @ObservationIgnored private var archive: [ReferenceDraftSelection] = []
    @ObservationIgnored private var editTargetID: UUID?
    @ObservationIgnored private var editHandler: ((ReferenceNativeEdit) -> Bool)?

    init(owner: ReferenceHubOwner?, providers: [ReferenceHubProvider],
         onConnect: ((ReferenceCategory) -> Void)? = nil) {
        self.owner = owner
        self.providers = providers
        self.onConnect = onConnect
    }

    var isPresented: Bool { query != nil && !isDismissed && !hasMarkedText && isEditorActive }
    var configuredProviderLabels: [String] { providers.map(\.label) }
    var isCategoryConfigured: Bool { providers.contains { $0.categories.contains(category) } }
    var canConnectCategory: Bool {
        optionalProviderUnavailableReason == nil
            && [.repos, .issues, .prs, .wiki].contains(category) && !isCategoryConfigured && onConnect != nil
    }
    func connectCategory() {
        guard canConnectCategory else { return }
        onConnect?(category)
    }
    var snapshots: [ReferenceSnapshot] { selected.map(\.snapshot) }

    /// Call synchronously at account/host/epoch/session/recipient changes. A
    /// provider-set change is a boundary too, even when owner coordinates match.
    func bind(owner: ReferenceHubOwner?, providers: [ReferenceHubProvider]) {
        recentResults = []
        self.owner = owner
        self.providers = providers
        resetDraft(source: "")
    }

    /// Parent calls after acknowledged send, intentional draft replacement or
    /// restoration. Never call for a normal binding echo or ambiguous receipt.
    func resetDraft(source: String, selections: [ReferenceDraftSelection] = []) {
        cancelDiscovery()
        preparationGeneration &+= 1
        isPreparingSend = false
        frozenSubmission = nil
        editTargetID = nil
        editHandler = nil
        isEditorActive = false
        isSuspended = false
        draftID = UUID()
        revision &+= 1
        let validRestoration = (try? ReferenceCodec.encode(source: source, references: selections.map(\.snapshot))) != nil
        archive = validRestoration ? selections : []
        selected = archive
        self.source = source
        selection = NSRange(location: source.utf16.count, length: 0)
        query = nil
        pendingChanges = []
        message = validRestoration ? nil : "Saved reference metadata is invalid. The full draft source has been preserved."
        isDismissed = false
        hasMarkedText = false
        reconcileSelections()
    }

    /// Synchronous UIKit publication. Byte equality avoids Unicode-normalized
    /// echoes; selection-only changes also invalidate async insertion ownership.
    func receive(source: String, selection: NSRange, hasMarkedText: Bool,
                 selections: [ReferenceDraftSelection]? = nil, restoreArchivedSelections: Bool = false) {
        let changed = !self.source.utf8.elementsEqual(source.utf8)
            || self.selection != selection || self.hasMarkedText != hasMarkedText
        let next = hasMarkedText ? nil : ReferenceQueryContext.parse(source: source, selection: selection)
        guard changed || query != next || (selections != nil && selections != selected) || restoreArchivedSelections else { return }
        self.source = source
        self.selection = selection
        self.hasMarkedText = hasMarkedText
        if let selections {
            selected = selections
            for value in selections where !archive.contains(where: { $0.id == value.id }) {
                archive.append(value)
            }
        }
        if changed {
            revision &+= 1
            preparationGeneration &+= 1
            isPreparingSend = false
            pendingChanges = []
            isDismissed = false
            message = nil
        }
        reconcileSelections(restoreArchived: restoreArchivedSelections)
        guard changed || query != next else { return }
        query = next
        refreshSearch()
    }

    /// Navigation retirement cancels publication without destroying the draft.
    /// Parent must also bind/reset synchronously at an authority boundary.
    func suspend() {
        isSuspended = true
        cancelDiscovery()
        preparationGeneration &+= 1
        isPreparingSend = false
        isEditorActive = false
        editHandler = nil
        editTargetID = nil
    }

    func setEditorActive(_ active: Bool) {
        if active { isSuspended = false }
        guard active != isEditorActive else { return }
        isEditorActive = active
        if !active { cancelDiscovery() }
        else if query != nil { refreshSearch() }
    }

    func attachEditor(id: UUID, apply: @escaping (ReferenceNativeEdit) -> Bool) {
        editTargetID = id
        editHandler = apply
    }

    func detachEditor(id: UUID) {
        guard editTargetID == id else { return }
        editTargetID = nil
        editHandler = nil
        setEditorActive(false)
    }

    func dismiss() {
        isDismissed = true
        cancelDiscovery()
    }

    func selectCategory(_ category: ReferenceCategory) {
        self.category = category
        refreshSearch()
    }

    func clearMessage() { message = nil }
    func setOptionalProviderUnavailableReason(_ reason: String?) {
        optionalProviderUnavailableReason = reason
    }
    func showMessage(_ text: String) { message = text }

    private func cancelDiscovery() {
        generation &+= 1
        resolveGeneration &+= 1
        searchTasks.forEach { $0.cancel() }
        searchTasks = []
        resolveTask?.cancel()
        resolveTask = nil
        loadingProviders = []
        isLoading = false
        isResolving = false
        results = []
        providerErrors = [:]
        providerNotices = [:]
        preview = nil
    }

    func refreshSearch() {
        cancelDiscovery()
        guard isPresented, let query, let owner else { return }
        if let reason = optionalProviderUnavailableReason,
           [.repos, .issues, .prs, .wiki].contains(category) {
            providerNotices["reference-mode"] = reason
            return
        }
        if query.query.isEmpty {
            results = recentResults.filter { category == .all || $0.category == category }
        }
        let ownedGeneration = generation
        let requestedCategory = category
        let term = query.query
        for provider in providers where requestedCategory == .all || provider.categories.contains(requestedCategory) {
            loadingProviders.insert(provider.id)
            let task = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(220))
                    let page = try await provider.search(owner, requestedCategory, term)
                    let rows = page.results
                    guard let self, !Task.isCancelled, self.generation == ownedGeneration, self.owner == owner else { return }
                    if page.isPartial || rows.count > 100 {
                        self.providerNotices[provider.id] = "\(provider.label): partial results. Refine your search for more specific matches."
                    }
                    var seen = Set(self.results.map(\.id))
                    self.results += rows.prefix(100).filter {
                        $0.providerID == provider.id && provider.categories.contains($0.category)
                            && (requestedCategory == .all || $0.category == requestedCategory)
                            && seen.insert($0.id).inserted
                    }
                    self.results.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                    self.finishSearch(provider.id)
                } catch {
                    guard let self, !Task.isCancelled, self.generation == ownedGeneration, self.owner == owner else { return }
                    self.providerErrors[provider.id] = "\(provider.label) is unavailable. Retry or choose another source."
                    self.finishSearch(provider.id)
                }
            }
            searchTasks.append(task)
        }
        isLoading = !loadingProviders.isEmpty
    }

    private func finishSearch(_ id: String) {
        loadingProviders.remove(id)
        isLoading = !loadingProviders.isEmpty
    }

    /// A row tap inserts the narrow default; inspection remains an explicit action.
    func select(_ result: ReferenceHubResult) {
        resolve(result, insertDefault: true)
    }

    func inspect(_ result: ReferenceHubResult) {
        resolve(result, insertDefault: false)
    }

    /// Local command/skill inspection takes ownership without changing the draft or search.
    func beginLocalInspection() {
        resolveGeneration &+= 1
        resolveTask?.cancel()
        resolveTask = nil
        isResolving = false
        preview = nil
    }

    private func resolve(_ result: ReferenceHubResult, insertDefault: Bool) {
        guard isPresented, results.contains(result), let owner,
              let provider = providers.first(where: { $0.id == result.providerID }) else { return }
        resolveTask?.cancel()
        resolveGeneration &+= 1
        let token = resolveGeneration
        let ownedRevision = revision
        let ownedDraft = draftID
        preview = nil
        isResolving = true
        resolveTask = Task { @MainActor [weak self] in
            do {
                let resolved = try await provider.resolve(owner, result)
                guard let self, !Task.isCancelled, self.resolveGeneration == token,
                      self.owner == owner, self.revision == ownedRevision, self.draftID == ownedDraft else { return }
                guard resolved.result == result, !resolved.options.isEmpty,
                      resolved.options.count <= 100 else { throw ReferenceCodec.Failure.invalidSnapshot }
                // The codec validates each choice before any native edit.
                for option in resolved.options {
                    let expectedCategory: ReferenceCategory
                    switch option.snapshot.kind {
                    case .repository: expectedCategory = .repos
                    case .issue: expectedCategory = .issues
                    case .pullRequest: expectedCategory = .prs
                    case .wiki: expectedCategory = .wiki
                    }
                    guard expectedCategory == result.category else { throw ReferenceCodec.Failure.invalidIdentity }
                    _ = try ReferenceCodec.encode(source: option.snapshot.anchor, references: [option.snapshot])
                }
                self.preview = resolved
                self.isResolving = false
                if insertDefault {
                    // Match scope, not array order: never silently share a
                    // description, section, or whole Wiki folder as a fallback.
                    let option = resolved.options.first { option in
                        switch option.snapshot.kind {
                        case .repository, .issue, .pullRequest:
                            return option.id == "metadata"
                        case .wiki:
                            return option.id == "page" || option.id == "location"
                        }
                    }
                    if let option { self.insert(option) }
                    else { self.message = "Choose the content to include in this reference." }
                }
            } catch {
                guard let self, !Task.isCancelled, self.resolveGeneration == token,
                      self.owner == owner, self.draftID == ownedDraft, self.revision == ownedRevision else { return }
                self.providerErrors[provider.id] = "\(provider.label) could not open this reference. Retry."
                self.isResolving = false
            }
        }
    }

    func closePreview() { preview = nil }

    @discardableResult
    func insert(_ option: ReferenceContentOption) -> Bool {
        guard let preview, preview.options.contains(option), let query, !hasMarkedText,
              archive.count < 64 else {
            message = "This selection is no longer available. Search again, or start a new draft if its undo history is full."
            return false
        }
        do {
            let transaction = try ReferenceEditTransaction.replacing(query, in: source, with: option.snapshot.anchor)
            let next = selected + [ReferenceDraftSelection(providerID: preview.result.providerID,
                sourceKindLabel: preview.sourceKindLabel, snapshot: option.snapshot)]
            _ = try ReferenceCodec.encode(source: transaction.source, references: next.map(\.snapshot))
            let result = preview.result
            let inserted = apply(range: query.range, replacement: option.snapshot.anchor,
                resultingSelection: transaction.selection, selections: next, name: "Insert reference")
            if inserted {
                recentResults.removeAll { $0.id == result.id }
                recentResults.insert(ReferenceHubResult(resourceID: result.resourceID, providerID: result.providerID,
                    category: result.category, title: result.title, subtitle: result.subtitle,
                    state: result.state, isCached: true), at: 0)
                recentResults = Array(recentResults.prefix(20))
            }
            return inserted
        } catch {
            message = "Reference not inserted. Keep at most eight unique references within 32 KiB; choose a smaller section if needed."
            return false
        }
    }

    /// Catalog text only, never an execution. Prefix remains untouched, so a
    /// command inside prose cannot become a leading invocation.
    @discardableResult
    func insertCatalogToken(name: String) -> Bool {
        guard let query, !hasMarkedText, !name.isEmpty, name.utf8.count <= 96,
              name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return false }
        let token = "/\(name) "
        return apply(range: query.range, replacement: token,
            resultingSelection: NSRange(location: query.range.location + token.utf16.count, length: 0),
            selections: selected, name: "Insert command text")
    }

    func remove(_ value: ReferenceDraftSelection) {
        guard selected.contains(value), let range = anchorRange(value.snapshot) else { return }
        let end = range.location + range.length
        let caret = selection.location <= range.location ? selection.location
            : selection.location >= end ? selection.location - range.length : range.location
        _ = apply(range: range, replacement: "", resultingSelection: NSRange(location: caret, length: 0),
                  selections: selected.filter { $0.id != value.id }, name: "Remove reference")
    }

    private func apply(range: NSRange, replacement: String, resultingSelection: NSRange,
                       selections: [ReferenceDraftSelection], name: String) -> Bool {
        guard !hasMarkedText, let editHandler else { return false }
        let edit = ReferenceNativeEdit(draftID: draftID, revision: revision, source: source,
            selection: selection, range: range, replacement: replacement,
            resultingSelection: resultingSelection, selections: selections, actionName: name)
        guard editHandler(edit) else {
            message = "The draft changed. Place the cursor and choose the reference again."
            return false
        }
        dismiss()
        return true
    }

    private func anchorRange(_ snapshot: ReferenceSnapshot) -> NSRange? {
        let text = source as NSString
        let range = text.range(of: snapshot.anchor, options: .literal)
        guard range.location != NSNotFound else { return nil }
        let end = range.location + range.length
        let duplicate = text.range(of: snapshot.anchor, options: .literal,
            range: NSRange(location: end, length: text.length - end))
        let units = Array(source.utf16)
        guard duplicate.location == NSNotFound,
              !ReferenceSourceSyntax.isSuppressed(at: range.location, in: units),
              range.location == 0 || units[range.location - 1] != 33 else { return nil }
        // Only edits to the anchor/its syntactic position detach metadata.
        // An unfinished fence elsewhere in the draft is checked at Send, not a
        // reason to discard an otherwise untouched selected reference.
        return range
    }

    private func reconcileSelections(restoreArchived: Bool = false) {
        let retained = selected.filter { anchorRange($0.snapshot) != nil }
        var next = retained
        var identities = Set(retained.map { $0.snapshot.identityKey })
        // Newest explicitly reviewed revision wins; never fetch new content.
        for value in archive.reversed() where restoreArchived && anchorRange(value.snapshot) != nil {
            if identities.insert(value.snapshot.identityKey).inserted { next.append(value) }
        }
        if selected != next { selected = next }
    }

    /// Parent can persist these records in its existing exact-owner draft store.
    /// Restoration is explicit via resetDraft, not history/network discovery.
    func exportDraftSelections() -> [ReferenceDraftSelection] { selected }

    func owns(_ frozen: ReferenceFrozenDraft) -> Bool {
        !isSuspended && frozen.owner == owner && frozen.draftID == draftID && frozen.revision == revision
            && Data(frozen.routingSource.utf8) == Data(source.utf8) && frozen.selections == selected
    }

    /// Only a proven rejection may discard a frozen submission. For ambiguous
    /// acknowledgements the parent retains/reconciles the same submissionID.
    func releaseRejectedSubmission(id: UUID) {
        guard frozenSubmission?.submissionID == id else { return }
        frozenSubmission = nil
    }

    func prepareSend(maximumMessageBytes: Int? = nil) async -> ReferenceSendPreparation {
        if let frozenSubmission, owns(frozenSubmission) { return .ready(frozenSubmission) }
        guard !isSuspended, !selected.isEmpty, let owner, !hasMarkedText, !isPreparingSend else { return .unavailable }
        preparationGeneration &+= 1
        let token = preparationGeneration
        let ownedDraft = draftID
        let ownedRevision = revision
        let original = selected
        let originalSource = source
        pendingChanges = []
        message = nil
        isPreparingSend = true
        defer { if preparationGeneration == token { isPreparingSend = false } }
        func isCurrent() -> Bool {
            preparationGeneration == token && self.owner == owner && draftID == ownedDraft
                && revision == ownedRevision && selected == original
                && Data(source.utf8) == Data(originalSource.utf8) && !Task.isCancelled
        }
        do {
            var changes: [ReferenceRevalidationChange] = []
            for value in original {
                guard let provider = providers.first(where: { $0.id == value.providerID }) else {
                    throw ReferenceCodec.Failure.invalidIdentity
                }
                let current = try await provider.revalidate(owner, value.snapshot)
                guard isCurrent() else { return .superseded }
                guard current.identityKey == value.snapshot.identityKey,
                      Data(current.anchor.utf8) == Data(value.snapshot.anchor.utf8) else {
                    throw ReferenceCodec.Failure.invalidIdentity
                }
                if !value.snapshot.hasSameContent(as: current) {
                    changes.append(ReferenceRevalidationChange(original: value, current: current))
                }
            }
            guard isCurrent() else { return .superseded }
            if !changes.isEmpty {
                pendingChanges = changes
                return .needsConfirmation(changes)
            }
            let canonical = try ReferenceCodec.encode(source: originalSource,
                references: original.map(\.snapshot), maximumMessageBytes: maximumMessageBytes)
            let frozen = ReferenceFrozenDraft(submissionID: UUID(), draftID: ownedDraft,
                revision: ownedRevision, owner: owner, routingSource: originalSource,
                canonicalText: canonical, selections: original)
            frozenSubmission = frozen
            return .ready(frozen)
        } catch {
            guard isCurrent() else { return .superseded }
            message = "References could not be verified or exceed the message limit. Your draft is unchanged. Retry Send or remove a reference."
            return .unavailable
        }
    }

    /// Explicit acceptance changes only metadata; the next Send revalidates.
    /// No native text edit, send or automatic source refresh occurs here.
    func acceptRevalidationChanges() {
        guard !pendingChanges.isEmpty, archive.count + pendingChanges.count <= 64 else { return }
        let changes = pendingChanges
        var next = selected
        for change in changes {
            guard let index = next.firstIndex(of: change.original) else { return }
            next[index] = ReferenceDraftSelection(providerID: change.original.providerID,
                sourceKindLabel: change.original.sourceKindLabel, snapshot: change.current)
        }
        guard (try? ReferenceCodec.encode(source: source, references: next.map(\.snapshot))) != nil else {
            message = "Updated content exceeds the reference limit. Remove it and choose a smaller section."
            return
        }
        selected = next
        archive += next.filter { value in !archive.contains(where: { $0.id == value.id }) }
        pendingChanges = []
        revision &+= 1
        message = "Updated references selected. Review them, then Send again."
    }
}
