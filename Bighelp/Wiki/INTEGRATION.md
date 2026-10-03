# Native Wiki integration API

This is an optional, source-only native provider candidate. The parent owns composition, tests, review, project membership and execution. It has no fixture provider and no direct HTTP/dashboard-token path.

## Construction and ownership

All client/store methods are main-actor isolated. All five owner fields are strings; use the actual authenticated account, selected target host, exact profile, initiating mobile device and current authorization epoch. Identifiers must be nonempty ASCII, not display names. `accountID` must be stable across device registrations (never `credentials.deviceID`); derive it from the authenticated account identity. Device and epoch remain live-request fences, not Wiki allowlists.

```swift
let owner = WikiOwner(accountID: accountID, hostID: selectedHostID,
                      profileID: profileID, deviceID: deviceID,
                      authorizationEpoch: epoch)
let client = WikiLinkClient(owner: owner, workspace: workspaceClient,
                            currentOwner: { liveWikiOwnerOrNil() })
let store = WikiStore(owner: owner, client: client)
// Fully inert baseline, also supported:
let optionalStore = WikiStore(owner: nil, client: nil)
```

`workspaceClient` MUST wrap the existing prepared Link messaging whose selectedHostID closure produces this owner's exact host. `currentOwner` MUST read current authenticated routing state, not capture `owner`. Return nil if there is no explicit host/device/profile/account/epoch. Wiki never puts targetHostId or caller identity in the payload: the existing encrypted envelope owns targetHostId. Wiki operation cases require both advertised operation support and `wiki.v1` through existing negotiation.

Call `store.setContext(owner:client:)` synchronously on account, target host, profile, device, epoch, disconnect, or replacement-transport changes. It cancels all store-owned requests, clears displayed content/connections/recovery and rejects late results. Construct a new bound client for the replacement. Call `deleteAccountData(accountID:)` during explicit account deletion; handle protected-data failure and retry rather than claiming deletion succeeded.

Initialization does not read disk or call the host. `restoreLocalState()` loads inert folder preferences and exact-owner save recovery, never live connections. Opening `WikiBrowserView` is explicit Wiki use: it calls `discoverRoots()` and reconnects saved paths through the current authenticated client. Do not call discovery from global startup or an unconfigured All reference drawer. Local recovery remains scoped to the complete owner; changed authorization epochs do not expose prior-epoch drafts or resume writes.

Folder preferences contain only ID, label and absolute path, scoped by stable account + host + profile. The bounded OS-protected preference file survives relaunch and sign-out. First use migrates the newest matching legacy `WikiLocalState`; an empty preferences file prevents removed paths resurrecting from older snapshots. `renameFolder(id:name:)` and `removeFolder(id:)` persist even when a folder is unavailable. Failed reconnects retain choices for explicit retry.

`OptionalReferenceServices.eraseAccountData(preservingWikiFolders: true)` invalidates active clients and erases drafts, save journals and provider credentials while preserving Wiki folder preferences; without it, those preferences go too.

## Surfaces

```swift
WikiBrowserView(store: store,
                onEdit: { document in /* parent file-bound Scratchpad */ },
                onAddReference: { document in /* parent reference preview */ },
                hostLabel: selectedHostDisplayName,
                onChooseHost: { /* parent host selector */ })
```

Embed in the parent's NavigationStack. `onChooseHost` is optional; the parent owns host selection. Browser creates its own Connect sheet. `WikiConnectionView(store:hostLabel:onChooseHost:onConnected:)` can also be presented directly. The inline folder navigator uses cancellable, debounced `BighelpLinkHermesWorkspaceClient.folderSuggestions` through WikiStore. Suggestions remain non-mutating. Save explicitly calls negotiated `wiki.connect` under the verified encrypted account context to connect a safe existing folder for account-authorized read/write. No host approval or per-device Wiki allowlist is required. Only successful writable `files` roots enable editing; generated, mirror and export sources remain read-only. Name is optional and inferred from the folder.

`WikiDocumentView(store:document:onEdit:onAddReference:)` renders a selected file. Both action closures receive the complete `WikiDocument`: exact owner, connection/root/generation, relative path, base revision, original bytes, original source and fetch time. Its identity is connection ID + path. It never mutates a free Scratchpad. Parent must retain/resolve its own dirty file-bound document when another Edit action arrives. Reference snapshot limits, section selection, preview, recipient confirmation and send-time revalidation remain parent-owned.

The Wiki display reuses `MarkdownDocument` and `MarkdownMessageView` for prose/lists/code and adds tables, heading anchors, task rows, aliases, image handling and original-source inspection. Links are intercepted before opening. Local path resolution is root-confined; fallback short-name search discloses incomplete indexing and requires a choice for ambiguity. External http/https links require confirmation. No external images, HTML, SVG or scripts execute. Supported local images require an explicit Load action and are fetched through Wiki image operations.

## Programmatic browse/reference use

- `discoverRoots()` fills `authorizedRoots` and reconnects retained folder choices only on explicit Wiki use; late results cannot restore removed preferences or publish across owner changes.
- `connect(name:root:readOnly:)` verifies the root is in `authorizedRoots`; `connect(name:folderPath:readOnly:)` calls the explicit wiki.connect operation first. Old hosts without this operation fail unavailable; no fallback grants authority.
- `browse(_:path:append:)`, `home(_:)`, `search(_:query:mode:append:)`, `open(_:path:anchor:)` publish observable directory/search/document state.
- `WikiClientProtocol.read(root:path:)` returns complete `WikiBytes`, not a truncated text field. Use it for parent reference revalidation under the same bound owner.
- Base64, exact size, monotonic offsets, stable generation-aware revision and final SHA-256 are checked. UTF-8 is accepted only when re-encoding the decoded scalars produces the identical bytes, retaining BOM/CRLF. Swift canonically-equivalent String equality is not used to select save bytes.
- `disconnect(_:)` removes the local connection, not its host grant or pending drafts. Active saves must first stop/reconcile.

## File-bound saving

The parent owns ongoing unsaved draft persistence. The store durably retains original/working source and the immutable operation as soon as Save is explicitly invoked.

```swift
let outcome = try await store.save(document: originalDocument,
                                   workingSource: fileBoundWorkingSource)
// Never interpret a returned DTO or a completed RPC as successful saving:
if outcome.verifiedCommitted {
    // Parent can rebase using outcome.currentDocument after resolving its dirty state.
}
```

Optional native accessories, neither of which owns an editor:

- `WikiSaveControls(store:document:workingSource:onResult:)`
- `WikiSaveStatusView(store:operationID:onResumeDraft:)`

`pendingSaves` contains retained originals, edited source, phase, upload offset, digest, exact operation ID, host commit revision and optional read-back current document. `reconcileSave(operationID:)` performs status only, then reads current bytes for committed/conflict outcomes. `resumeSave(operationID:)` checks status first, resumes receiving with the same ID and bytes, and never retries commit for a recovered prepared/committing/indeterminate host state. Before an admission was ever acknowledged, an explicit retry may repeat the identical begin only after OPERATION_NOT_FOUND; this client could not yet have sent commit. `discardSave(operationID:)` is explicit destructive local cleanup; require export/discard confirmation, especially for uncertain outcomes.

A committed response must match the original root generation and proposed digest. `verifiedCommitted` requires complete matching readback and no verification failure. `hasLaterExternalChange` distinguishes a recorded commit from subsequently changed current source. Conflict/failed/indeterminate are not success; all retain working and original source. READ_ONLY remains a typed, safe refusal. There is no force overwrite action.

## Resource and persistence scope

- Read/image bytes: 8 MiB; edit/save bytes: 1 MiB; chunks: 64 KiB. Request payload JSON remains below 100,000 bytes before the existing bounded envelope.
- Listing/search page: 100; accumulated visible results: 5,000, after which a truthful limit asks the user to narrow scope.
- Full Markdown rendering: 1 MiB, 8,192 blocks, table width 32 columns/512 rows. Larger layouts explicitly offer the **complete** original source in labeled 32,768-character pages, not an apparently complete prefix.
- Four image loads per opened page; dimensions capped at 16 million decoded source pixels/16,384 per axis, raster allowlist, first-frame downsample to 2,048 pixels. No persistent image cache.
- 32 connections and eight retained operations per exact owner; 40 MiB encoded aggregate owner-epoch files per account and a finite file count. No unresolved draft eviction. Protected temporary-file writes are synchronized before atomic replacement; temporary files are cleaned on failure.
- Default `WikiLocalPersistence` is lazy Application Support/Wiki storage, account/owner names hashed, complete file protection and excluded from backups through the existing bighelp protector. No credential storage. Injectable `WikiPersistence`/directory/protector/availability seams are available for parent tests.

## Deliberate caveats / parent gates

No tests, builds, simulator, QA, live host requests, grants, runtime changes or publication were executed by this worker. Parent must compile against the actual app module, run the supplied RED test and real-wire/native acceptance, and validate live composition.

This is not a full CommonMark/Obsidian implementation: front matter, HTML/embeds, unclosed/nested fence edge cases and unsupported extensions stay source or explicit unsupported blocks. Wiki links on a line containing multi-backtick inline code stay literal instead of rewriting code incorrectly. No executable plugins. Table alignment hints are not separately styled. Original source remains authoritative.

The parent must use its existing Markdown file exporter where an actual named `.md` file is required; Wiki's Share actions expose exact source strings. Theme-aware native controls and readable columns are implemented, but visual/VoiceOver/Dynamic Type behavior is not claimed proven until parent execution. Stronger per-recipient confidentiality or exclusion of unrelated file writers is not claimed.

References opens with a bounded recursive file catalog for connected Wikis, even without a typed query. It visits at most eight roots and 32 directories per browse, includes up to 100 visible results, and reports incomplete discovery. Ordinary non-Markdown files offer **File location only**: JSON source path and size metadata, never decoded or ingested binary contents. Selection and send-time checks re-list the parent directory against the live grant, with at most ten revision-bound pages. The snapshot revision identifies parent directory metadata (including the file's identity/stat), not a content digest. Markdown retains explicit page/section content selection.
