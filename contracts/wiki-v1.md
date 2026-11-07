# Wiki v1 Link contract

> **Historical.** This contract is for the retired Link transport (`targetHostId`, `senderEpoch`, the `wiki.v1`
> capability). Link is gone. Chat and plugin features use native Hermes now (see
> [docs/NATIVE_TRANSPORT.md](../docs/NATIVE_TRANSPORT.md)). Wiki is no longer a feature.
>
> - The bighelp plugin removed the wiki routes and no longer lists `native-wiki-v1` (bighelp-plugin README ›
>   Legacy code). Files that the routes saved stay on hosts, but nothing reads them.
> - The app has no Wiki screen. `WikiBrowserView`, `WikiConnectionView`, `WikiDocumentView` and
>   `WikiSaveControls` are not in it.
> - Hermes tools leaves Wiki out (`WorkspaceDestination.appMenuCases`).
> - If someone sends a Wiki or GitHub reference in chat, the app says that these references are no longer
>   available (`ReferenceChatComposition`).
> - What is left is inactive code: the models, store, drafts and persistence in `Bighelp/Wiki/`, the request
>   codec (`WikiLinkClient`), `DirectHermesWikiClient` (the `wiki/*` plugin routes, behind `native-wiki-v1`) and
>   the reference adapter in `Bighelp/References/`.

Implementation contract for issue #135. User-approved Wiki/reference spec governs privacy, optionality and source fidelity. All operations are optional and advertised using existing negotiated capability string arrays (`wiki.v1`); no new unsolicited top-level response fields. Old hosts are unavailable for Wiki, not broken for chat.

## Authentication

Wiki access is authorized by the authenticated paired account, not a Wiki device allowlist. Every request still requires a verified sending connection and an explicit matching `targetHostId`. Preserve that routing value on `InboundLinkWorkspaceRequest` after the existing frame reader validates it. The relay verifies `senderEpoch` against the sending device's authenticated socket. Mobile and host authorization epochs are independent; never compare them for equality. The host's current epoch remains bound through the pairing authority digest. Never accept caller-supplied identity or permissions inside payload. `agentId` selects an exact profile already authorized by the Wiki grant, not private Hermes session machinery.

One canonical Wiki state directory per paired host authority. Derive an opaque authority identifier from current paired host identity, authorization epoch and account-key generation using a one-way digest; never output the key or use a guessed profile/root as authority. Instantiate lazily only for Wiki work. No plugin setup or Wiki network call is required for ordinary chat/Skills/Commands.

## Operations

Every payload has `agentId: String`; fields below are additional. Reject unknown fields, boolean numeric values, invalid IDs/paths, nonfinite values and oversize envelopes.

| Operation | Payload | Result |
|---|---|---|
| `wiki.roots` | none | `{roots:[WikiRoot]}` |
| `wiki.connect` | `folderPath` absolute exact path | one WikiRoot; explicitly selects a safe folder for durable account-scoped read/write access |
| `wiki.resolve` | `folderPath` absolute exact path | one WikiRoot, only if that exact root is already authorized; never creates or upgrades a grant |
| `wiki.list` | `wikiId,path,offset,limit,query,revision?` | directory DTO |
| `wiki.read` | `wikiId,path,offset,limit,revision?` | file DTO |
| `wiki.search` | `wikiId,query,mode,offset,limit` | `{wikiId,query,mode,matches:[{path,title,snippet,revision}],nextOffset,isComplete,indexedAt}`; mode `name` or `content`; label partial indexing |
| `wiki.image` | `wikiId,path,offset,limit,revision?` | bounded file bytes for allowlisted local image types; no external URL fetch |
| `wiki.save.begin` | `wikiId,path,baseRevision,operationId,totalBytes,sha256` | `{operationId,status:"receiving",nextOffset,totalBytes}` |
| `wiki.save.chunk` | `operationId,offset,data` | `{operationId,status:"receiving",nextOffset,totalBytes}`; data strict base64, at most 65,536 decoded bytes |
| `wiki.save.commit` | `operationId` | SaveResult |
| `wiki.save.status` | `operationId` | receiving status or SaveResult; never resubmits a commit |

WikiRoot: `{wikiId,name,writable,sourceKind,generation}`. The user-chosen host Wiki ID is a deliberately shareable logical source name, not a credential. Native connections may map it to a separate valid reference namespace if needed; do not expose absolute roots in messages. App Save uses `wiki.connect` under the authenticated account. No separate host approval is required. Explicit selection creates an account-scoped file connection or upgrades an existing exact same-authority/profile file connection to read/write, rotating its generation when permissions change. Other same-account devices do not require another Wiki allowlist entry. System, credential and host-control folders, symlinks, stale roots and conflicting profile/authority registrations remain rejected. Generated, mirrored or exported sources remain read-only. A user read-only preference does not revoke the account grant.

Directory: `{wikiId,path,parent,revision,offset,limit,total,entries:[{name,path,kind,size}],nextOffset}`. Nullable parent/nextOffset/entry size; kind comes from existing Files. Root path is empty string. Retain exact byte-bound generation-aware revision.

File: `{wikiId,path,availability,size,offset,data,text,revision,nextOffset,maxFileBytes?}`. Base64 data is authoritative; text may be null for paged files. Availability is `available`, `binary`, or `oversized`. Decode UTF-8 strictly without stripping a leading content BOM. Reassemble with monotonic offsets, stable revision and actual byte limits.

Revision: `wiki-v1:<32 lowercase hex grant generation>:<64 lowercase hex SHA-256>`. Treat as opaque; do not strip generation.

SaveResult: `{operationId,status,revision,errorCode?}`. Status is `prepared`, `committing`, `committed`, `conflict`, `failed`, or `indeterminate`. Conflict is a completed operation with a conflict outcome, not successful saving. READ_ONLY and pre-admission failures remain typed safe errors. ACL/extended-metadata files must not be replaced with weaker permissions; current service refuses edits where metadata cannot be preserved.

## Optional Wiki file creation

Roots may advertise `supportsCreation: true` alongside the existing optional root metadata. Clients require this explicit flag on the current authorized root before creating a file; an omitted or false flag means upgrade/unsupported, not permission to attempt an older host operation. `writable` and the connection's read-only preference remain independent gates.

Creation uses the existing bounded `wiki.save.begin` / chunk / commit / status transaction with `baseRevision: "wiki-new-v1:<32 lowercase hex grant generation>"`. This token is an absent-file precondition, not a content revision. It is accepted only as the base revision of a create request; successful content revisions keep the existing `wiki-v1:<generation>:<sha256>` format. Normal existing-file edits retain their original revision checks.

Only a new `.md` or `.markdown` file beneath an existing authorized folder may be created. The host rechecks authority, grant generation, path ancestry and staged bytes, then atomically links the staged file into an absent destination without replacing any existing file, directory or symlink. No parent directories are implicitly created. Existing destinations are rejected or reported as conflicts, never overwritten or replaced by a local-export fallback.

The same immutable operation identity and private durable journal cover upload retries, lost acknowledgements and restart recovery. Indeterminate operations are reconciled by status, not silently resubmitted as new creates. Native Scratchpad acknowledges a remote save only after exact verified readback and then adopts the saved revision for later edits.

## Transfer/recovery

Begin binds authority/profile/sender/Wiki/grant/path/base revision/digest/size immutably. Duplicate identical begin/chunk/commit is idempotent; different reuse conflicts. Reauthorize at every stage and commit. Staging state belongs outside Wiki roots, is private, bounded and durable, not a dictionary lost on restart. Cap 1 MiB/document, 64 KiB/chunk and finite operation/count/aggregate bytes. Refuse new uploads before evicting unresolved user drafts. Never pass 1 MiB in one workspace payload.

Commit verifies complete exact byte count/hash, then calls the reviewed WikiService save API using the same operation ID. Status reconciles lost acknowledgements. Never auto-replace after a `committing`/indeterminate recovery. Keep current safe errors path-redacted and all complete JSON/encryption envelopes under 196,608 bytes.

Search uses a bounded disposable grant-scoped index outside roots, with explicit partial state and source invalidation. Scope checks precede cached results and follow I/O. Do not call directory-local filtering whole-Wiki search. Image access reuses root/symlink/size protections; native code validates decoded pixel size and never treats SVG/HTML as executable content.

## Native API responsibilities

`WikiLinkClient` wraps `BighelpLinkWorkspaceClient.perform` and adds enum cases matching the operation strings above in `BighelpLinkWireModels.swift`. It retains a `WikiOwner` value (account, host, profile, device, authorization epoch) and checks owner before publishing awaited results. Native construction remains inert with no global setup gate. Remembered folder selections are account/host/profile preferences, not reusable authorization handles. On explicit Wiki use, reconnect retained selections with the current authenticated client; never revive a previous device/epoch's pending writes. Sign-out clears live state but retains folder preferences for the same account, while explicit account deletion removes them. An unavailable host/provider affects only that Wiki or references selected from it.

New Wiki views take closures for Edit in Scratchpad and Add reference rather than writing shared RootShellView/ChatModel directly. Reuse `MarkdownDocument`/`MarkdownMessageView` where they provide the required semantics; add missing table/image/link/heading behavior in focused Wiki files without enabling arbitrary remote resources.
