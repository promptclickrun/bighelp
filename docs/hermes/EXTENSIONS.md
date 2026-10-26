# Optional plugins, files, media and voice

This chapter specifies the optional HTTP surfaces used by the native client. It is a wire guide for any client, including Kotlin and Expo. All JSON field spelling and casing below is significant. `?` means an optional property; it is notation, not part of the JSON. Unless a row says otherwise, bodies and successful responses are JSON objects, offsets count bytes, and sizes are decoded bytes.

The app is the primary source for what a compatible client sends and accepts. Companion server behavior was cross-checked against [bighelp-plugin commit `7e1f74f` (3.32.1)](https://github.com/promptclickrun/bighelp-plugin/tree/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf). Features depend on the running process; a version string does not prove a route is available. Where app and current companion differ, that difference is explicit below.

## Native context and request envelope

The bighelp plugin retains its original wire name: `/api/plugins/loopdy`. Native extension paths start `/api/plugins/loopdy/native/`. Use the same authenticated host HTTP transport as core Hermes: provider bearer authentication or `X-Hermes-Session-Token` for the dashboard-session path, plus configured proxy headers. Do not forward those credentials to a media provider. Native requests are not chat JSON-RPC methods.

Start each connection/authorization generation with:

```http
GET /api/plugins/loopdy/native/context
Accept: application/json
Cache-Control: no-store
Authorization: Bearer <host-access-token>
```

No query parameters or body are accepted. A valid response is HTTP 200, at most 16,384 bytes, `Cache-Control: no-store`, and an ETag in quotes:

```http
ETag: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
Cache-Control: no-store
Content-Type: application/json
```

```json
{
  "schemaVersion": 1,
  "pluginVersion": "3.32.1",
  "runtimeId": "opaque-loaded-module-id",
  "servingProfileId": "default",
  "principal": {
    "provider": "example-provider",
    "userId": "example-user",
    "displayName": "Avery"
  },
  "features": ["native-context-v1", "serving-profile-v1", "native-agent-attachments-v1"],
  "unavailable": {"native-workflows-v1": "chat_runner_missing"}
}
```

For dashboard-session authentication, `principal` must be JSON null. For provider authentication, `principal.provider` and `userId` must match the verified login coordinates; do not adopt a different identity from this response. `servingProfileId` is required but may be null. A non-null profile requires `serving-profile-v1`. It identifies the process's proven serving profile, rather than a `profile` query selection. `runtimeId` identifies the loaded HTTP module lifetime; it is not a release checksum or device ID.

The app requires `schemaVersion: 1`, unique features (at most 64), and `native-context-v1`. It bounds `pluginVersion` to 128 UTF-8 bytes, `runtimeId` to 256, feature/profile names to 128 and display name to 200. `unavailable` is an optional, lenient map of at most 64 feature names to fixed reason codes (at most 64 bytes). Unknown entries can be ignored; absent feature means unsupported, regardless of plugin version.

For each native operation after context, send:

```http
POST /api/plugins/loopdy/native/attachments/recent
Content-Type: application/json
If-Match: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
X-Loopdy-Request-ID: 11111111-1111-4111-8111-111111111111

{"agentId":"default","limit":12}
```

`If-Match` is the context ETag, including its quotes. `X-Loopdy-Request-ID` is a canonical lowercase UUID, newly allocated for a logical request. These are preconditions and correlation values, not credentials. The companion rejects duplicate/missing/malformed headers, duplicate JSON properties, non-finite numbers, unknown request properties and excessive JSON nesting. The usual native body limit is 196,608 bytes/depth 24; individual families can have tighter limits. The app's generic adapter has a broader 1 MiB preflight limit except card templates, workflows, My Templates and image drafts, which use 196,608; the server's smaller limit still wins.

A successful response must echo the exact request ID and context ETag. The app normalizes proxy representations of ETags by removing `W/` and one recognized compressed suffix (`-gzip`, `-zstd`, `-br`, `-deflate` inside the quotes), then accepts only `"sha256:<64 lowercase hex>"`. Preserve the original strong context tag for outgoing `If-Match`. Do not equate arbitrary weak tags.

Bind cached context and every in-flight callback to the authenticated authority, authorization generation and connection generation. Before dispatch and after every await, reject a retired owner. A profile/session-bound feature also fences those coordinates. Reconnect, credential replacement and account/host changes require a fresh context and new scoped clients; do not retarget a stale response to the current screen.

Sources: [NativeContext](../../Bighelp/DirectHermes/DirectHermesNativeContext.swift), [HTTP envelope](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift), [ownership tests](../../BighelpTests/DirectHermesNativeContextTests.swift), [proxy ETag tests](../../BighelpTests/DirectHermesConditionalOwnershipTests.swift).

## Errors, uncertain outcomes and retries

Plugin errors have this shape; errors need not carry an ETag, and errors from stock authentication or a disabled plugin may have no request-ID echo:

```json
{"error":{"code":"context_changed","message":"The native context changed; refresh before retrying.","retryable":false,"details":{}}}
```

The generic app adapter maps statuses as follows:

| Status / condition | Meaning to client |
| --- | --- |
| 401, 403 | Authentication required; discard cached context |
| 412 | Context conflict; discard cached context and fetch context again |
| 413 | Capacity exceeded |
| 428 | Missing context/unsupported operation; discard cached context |
| 503 with `runner_unavailable`, `workflows_unavailable`, `store_unavailable` | Explicit rejection before work started |
| Other 5xx | Read: transport unavailable. Mutation: outcome unknown |
| Valid domain `error.code` | Rejection with that fixed code and bounded safe message |
| 404 without a recognized domain code | Plugin required/unavailable |
| Wrong echo ID, wrong/missing success ETag, malformed success body | Read: invalid response. Mutation: outcome unknown |
| Timeout/disconnect/cancellation after a mutation may have left | Outcome unknown; reconcile before sending again |

The generic adapter accepts codes of at most 128 bytes, ASCII letters/digits/`-._`. HTTP 409 is usually a domain conflict, distinct from context 412. Request IDs do **not** imply general deduplication: card templates, board flags and voice each have their own semantics. Current workflows have a separate 24-hour mutation receipt ledger; workflow starts additionally use `clientRunToken`. A 412 alone does not establish that a write never occurred: server checks can follow a completed worker operation. Read back under fresh context.

Several typed app clients retry a context conflict once after reloading context (board, workflows, speaker note, image drafts, My Templates, agent activity). That is existing client policy, not an exactly-once guarantee. Implement safe family-specific reconciliation, and never automatically switch to another host, profile, authentication mode or legacy transport after refusal.

## Complete native route inventory used by this client

All suffixes in the following tables append to `/api/plugins/loopdy/native/`; all use POST except the explicitly marked GET/PUT routes. `R` and `M` describe the app adapter's read/mutation outcome classification. A POST can be a read. Required feature names are literal strings.

### Attachments, files, voice and project review

| Suffix | Class | Feature | Request body | Response / client byte budget |
| --- | --- | --- | --- | --- |
| `context` (GET) | R | discovery | none | context / 16,384 |
| `voice/status` | R | `native-voice-v1` | `{agentId,sessionId,provider}` | `{available,enabled,provider,interruptSupported}` / 196,608 |
| `voice/offer` | M | `native-voice-v1` | `{agentId,sessionId,voiceId,provider,voice,sdp}` | `{voiceId,sdp}` / 196,608 |
| `voice/poll` | R | `native-voice-v1` | `{agentId,sessionId,voiceId,after}` | `{voiceId,closed,next,events,diagnostics?}` / 196,608 |
| `voice/result` | M | `native-voice-v1` | `{agentId,sessionId,voiceId,delegationId,text}` | `{voiceId,appended:true}` / 196,608 |
| `voice/close` | M | `native-voice-v1` | `{agentId,sessionId,voiceId}` | `{voiceId,closed:true}` / 196,608 |
| `attachments/resolve` | R | `native-agent-attachments-v1` | `{agentId,storedId,items:[{itemId,text}]}` | `{items:[{itemId,text,attachments}]}` / 1,048,576; 60 s |
| `attachments/fetch` | R | `native-agent-attachments-v1` | `{agentId,attachmentId,offset}` | chunk described below / 4,259,840; 60 s |
| `attachments/board` | R | `native-agent-board-files-v1` | `{agentId,itemId,index}` | `{attachment:AttachmentMeta}` / 16,384; 60 s |
| `attachments/recent` | R | `native-agent-media-v1` | `{agentId,limit}` | `{items:[AttachmentMeta + storedId,createdAt]}` / 196,608 |
| `workspace-files/scope` | R | `native-workspace-files-v1` | `{path:null,profile?}` | locked workspace listing / 196,608 |
| `workspace-files/list` | R | `native-workspace-files-v1` | `{path:string\|null,profile?}` | locked workspace listing / 196,608 |
| `workspace-files/read` | R | `native-workspace-files-v1` | `{path,profile?}` | locked workspace bytes / up to 25 MiB decoded + Base64 overhead |
| `workspace-files/recent` | R | above + `native-workspace-recent-v1` | `{path:null,profile?}` | recent locked workspace listing / 196,608 |
| `projects/git/capabilities` | R | `native-project-git-read-v1` | `{agentId,sessionId,workspaceId}` | read-only Git capabilities / 196,608 |
| `projects/git/status` | R | `native-project-git-read-v1` | `{agentId,sessionId,workspaceId}` | complete status and content token / 196,608 |
| `projects/git/diff` | R | `native-project-git-read-v1` | above + `{path,side,statusToken,offset,limit}` | structured diff page / 196,608 |

`profile` on configured workspace routes requires `native-workspace-files-agents-v1` when it differs from the serving profile. Default route timeout is 20 seconds; listed overrides are seconds. The artifact adapter separately requires `Cache-Control: no-store` on success and `workspace.profileId` matching the selected profile.

### Board, cards, people and host state

Each board request has `agentId`. The board is per agent; Feed, Ideas and Goals are rows of one store, not three APIs. The base feature is `native-agent-board-v1`.

| Suffix | Class / feature if different | Request body | Successful body / budget |
| --- | --- | --- | --- |
| `board/list` | R | `{agentId,kinds?,limit?,includeDismissed?}` | `{agentId,items}` / 2 MiB |
| `board/update` | M | `{agentId,itemId,liked?,dismissed?,status?,rating?,reason?,read?}` | `{agentId,item}` / 196,608 |
| `board/media` | R | `{agentId,itemId,index}` | `{agentId,mimeType,data,byteCount}` / 12 MiB |
| `board/activity` | R | `{agentId,limit?}` | `{agentId,activity}` / 2 MiB |
| `board/approvals` | R | `{agentId,limit?}` | `{agentId,approvals}` / 2 MiB |
| `board/identity` | R | `{agentId}` | `{agentId,soul,memory,user}` / 2 MiB |
| `board/read` | M / `native-agent-board-feedback-v1` | `{agentId,itemIds,read?}` | `{agentId,updated}` / 16,384 |
| `board/promote` | M / `native-agent-board-feedback-v1` | `{agentId,itemId}` | `{agentId,item}` / 196,608 |
| `board/accept` | M / `native-agent-board-answers-v1` | `{agentId,itemId}` | `{agentId,item}` / 196,608 |
| `cards/templates/list` | R / `native-card-templates-v1` | `{agentId}` | `{agentId,templates:[summary]}` / 196,608 |
| `cards/templates/install` | M / same | `{agentId,template:bundle}` | `{agentId,changed,template:summary}` / 196,608 |
| `cards/templates/remove` | M / same | `{agentId,templateId,version,sha256}` | `{agentId,changed,templateId}` / 196,608 |
| `people/speaking` | M / `native-people-v1` | `{agentId,sessionId,personId,name,renders?}` | `{agentId,sessionId,name,renders?}` / 16,384; 5 s |
| `agents/talk` | R / `native-agent-talk-v1` | `{agentId,sessionId,calls:[{agentId,message}]}` | `{runs}` / 65,536; 10 s |
| `chat/activity` | R / `native-chat-activity-v1` | `{agentId,sessionId}` | `{working,tool,since,canStop}` / 4,096; 10 s |
| `chat/stop` | M / same | `{agentId,sessionId}` | `{stopped}` / 4,096; 10 s |
| `agents/activity` | R / `native-agents-activity-v1` | `{agentIds}` | `{agents:[{agentId,state,tool?}]}` / 32,768; 10 s |
| `team` | M / `native-team-v1` | `{agentId,enabled?}` | `{enabled,agents:[{id,name,role}],reached,failed}` / 65,536; 30 s |
| `agents/plugins/share` | M / `native-agent-plugin-links-v1` | `{agentId}` | `{linked,kept:[{name,reason}]}` / 32,768; 30 s |
| `host/restart` | M / `native-host-restart-v1` | `{confirm:true}` | `{restarting:true,runtimeId,...}`; connection drops |
| `telemetry` (PUT) | M / `native-host-telemetry-v1` | `{enabled:boolean}` | host telemetry state / 16,384; 10 s |

A board item has `id,kind,title,body,icon,section,status,note,links:[{url,title}],images:[{url? ,index?}],files,source,liked,rating?,reason?,read?,dismissed,category?,createdAt,updatedAt`. A file entry has `index,fileName,mimeType,byteCount,addedAt?`; never derive its fetch path from its display name. Identity documents are `{text,updatedAt,truncated}`. Activity rows carry `id,sessionId,title,request,summary,category,outcome,createdAt`; approval history carries `id,sessionTitle,description,command,choice,createdAt` (Unix seconds).

`board/list.kinds` values are `feed`, `idea`, `goal`; default all, limit 1–200 (app requests 200), default excludes dismissed. `status` is `active` or `done`, `rating` is `up`, `down`, `none`; reason is at most 120 characters. `rating`, `reason`, `read` require board feedback support; older plugins receive `liked` instead. `board/read` takes 1–200 IDs and defaults `read:true`. `board/media.index` is 0–5; board file attachments instead use `attachments/board.index` 0–9. Activity/approval history limit is 1–200, app uses 100. A board approval row is history, not an actionable approval request.

`people/speaking.sessionId` is the **stored** chat ID. `personId` is a stable lowercase UUID supplied by the client, not a host authentication principal. The app sends only a saved name (max 40 characters), including empty string when unset, never its displayed “You” placeholder. It waits at most 1.2 seconds before submitting the chat turn, even if the note continues. With `native-card-objects-v1`, `renders` advertises `contact`, `place`, `music`; with `native-image-drafts-v1` it additionally advertises `contact_draft`, `event_draft`. Advertise only components the client actually implements. Omit `renders` for older plugins that reject unknown fields. This contextual name is not proof of an authenticated per-person ACL.

`agents/talk.calls` has at most 16 entries; `message` is the lowercase SHA-256 of the outgoing message with the ends trimmed and Hermes' optional “Message from Name (@handle):” signature removed, not its plaintext. `agents/activity` accepts 1–64 profile IDs; states are `idle`, `waiting`, `working`, with an optional tool when working. Unknown/malformed individual rows remain unknown. `team` omits `enabled` for a read, but the generic adapter conservatively treats all calls as mutations because setting it updates agents' configuration.

Sources: [board codec](../../Bighelp/Board/AgentBoard.swift), [speaker note](../../Bighelp/DirectHermes/DirectHermesChatSpeakerNote.swift), [activity reader](../../Bighelp/DirectHermes/DirectHermesAgentTalkReader.swift), [team](../../Bighelp/Agents/Teamwork.swift), [native route table](../../Bighelp/DirectHermes/DirectHermesNativeContext.swift). Host restart is a real process operation, not a gateway restart or plugin reload acknowledgement.

### Card documents and template integrity

A card template summary has exactly `id,version,name,summary,author,license,minimum_card_version,sha256`; its install bundle adds `parameters_schema,document`. ID is `[a-z0-9][a-z0-9._-]{0,127}`, version a positive safe integer, minimum card version 1, name/author/license at most 120 characters and summary at most 1,000. The digest must match the canonical bundle/document contract; do not hash an arbitrary encoder's presentation JSON. Up to 500 summaries are allowed; overflow fails rather than implying the catalog is complete. Reinstalling identical content is unchanged; same-version different content/downgrade is a conflict. Remove compares the exact version and digest, and already absent is unchanged. Reconcile an uncertain install/remove with list under fresh context.

Cards carried by chat are data envelopes, not host HTTP commands. The `loopdy.card` v1 document requires `schema,version,title,spoken_summary,data_sources,root,elements,content_hash,card_id,created_at,origin`; optional `importance,valid_until` affect presentation only. `origin` is `live`. Elements are keyed by stable IDs and contain `{type,props,children}`; root and child references must resolve, with no cycles/unreachable nodes. Static cards have `data_sources:[]`; opening one performs no arbitrary network request or code execution. The original content hash is SHA-256 over canonical input before renderer-owned `content_hash,card_id,created_at,origin` are added; card ID is the first 32 lowercase digest characters. Draft cards additionally verify intact content before offering a local write.

The base finite catalog is `card,vstack,hstack,grid,text,metric,badge,progress,chart,table,list,divider,spacer,image`. Object/draft components additionally need the negotiated renderers described above. The app bounds documents to 80 elements, depth 12 and 20 children per container, and rejects unknown components/props instead of evaluating them. Implement native equivalents or an inert unsupported-card fallback. Legacy `loopdy.generative_ui` v1/v2 envelopes remain distinct; v2 form/selection responses in the current app go through the ordinary chat send/steer path as user text, preserving the composer draft. A slash-prefixed selection is put into the composer for deliberate send. These are not approval decisions or arbitrary card-authored HTTP actions.

The exhaustive static component property/value rules remain in [the card wire specification](../BIGHELP_CARDS.md), [validator](../../Bighelp/Cards/BighelpCardValidator.swift), and the companion's [versioned JSON schema](https://github.com/promptclickrun/bighelp-plugin/blob/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf/spec/loopdy-card-v1.schema.json). The older card document's Link-specific transport prose is historical; native clients carry these documents through the chat/history transport described in this guide.

### Native Project Git read contract

`projects/git/*` uses `{agentId,sessionId,workspaceId}` where sessionId is an exact **stored** chat ID and workspaceId is the registered Hermes Project ID. The server verifies the stored session's CWD is the Project's exact primary root. Runtime IDs, Files grants and guessed path matches are insufficient. Hidden canonical Bot Chats need public canonical/compression-tip proof; room, cron, delegated and worker sessions are ineligible. This is a read-only review surface even if another API enables Git mutations.

Capabilities are `{schemaVersion:1,capabilities:{status:true,stage:false,commit:false,push:false,fetch:false,pull:false,arbitraryCommand:false},workspaces:[{workspaceId,label,visibility:"private",operations:["status"],remotes:[],branches:[],mutationsEnabled:false}]}`. Status is `{workspaceId,statusToken,head:{oid,branch,detached,upstream,ahead,behind},files,filesPage,staged,changes,conflicts,conflictsPage,dirty}`. Files have `{path,originalPath,index,worktree,kind,insertions,deletions,isBinary}`; counters are `{files,insertions,deletions}`. File/conflict page metadata is `{offset:0,limit,returned,total,nextOffset:null,complete:true}`. Status has no continuation API: complete-list overflow fails at 500 files/conflicts or 160,000 bytes.

Diff request side is `staged` or `worktree`, offset 0–100,000, limit 1–500; statusToken is `sha256:<64 lowercase hex>` from the preceding status. Reply is `{path,side,availability,offset,lines:[{kind,oldLine,newLine,content}],nextOffset,previewContent?}`. Availability is `available`, `binary`, `oversized`; keep explicit unavailable results distinct from an empty text diff. Preserve the same content token across pages, re-read status on `status_changed`, and do not reinterpret combined `@@@` hunks. `scope_changed` means the Project/session association changed. Neither error authorizes fallback or mutation. Source: [native Git adapter](../../Bighelp/DirectHermes/DirectHermesProjectGitClient.swift), [companion contract](https://github.com/promptclickrun/bighelp-plugin/blob/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf/docs/NATIVE_PROJECT_GIT.md).

### Usage, provider sign-in, templates and Composio

| Suffix | Class | Feature | Request | Response / budget |
| --- | --- | --- | --- | --- |
| `usage/list` | R | `native-provider-usage-v1` | `{agentId,refresh?}` | `{agentId,...provider usage}` / 196,608; 60 s |
| `usage/activity` | R | `native-usage-activity-v1` | `{agentId,days}` | `{agentId,...activity}` / 1 MiB; 30 s |
| `provider-sign-in/list` | R | `native-provider-sign-in-v1` | `{agentId}` | `{agentId,providers}` / 65,536; 30 s |
| `provider-sign-in/start` | M | same | `{agentId,providerId}` | sign-in session / 16,384; 30 s |
| `provider-sign-in/status` | R | same | `{agentId,sessionId}` | sign-in session / 16,384 |
| `provider-sign-in/submit` | M | same | `{agentId,sessionId,code}` | sign-in session / 16,384 |
| `provider-sign-in/cancel` | M | same | `{agentId,sessionId}` | sign-in session / 16,384 |
| `composio/status` | R | `native-composio-v1` | `{agentId}` | Composio host setup state / 32,768 |
| `composio/install` | M | same | `{agentId}` | Composio host setup state / 32,768 |
| `my-templates/list` | R | `native-my-templates-v1` | `{}` | `{templates,skipped}` / 4 MiB |
| `my-templates/save` | M | same | `{template:{name,instructions,role?,vibe?,description?,symbol?,category?,variables?}}` | `{template}` / 196,608 |
| `my-templates/delete` | M | same | `{id}` | `{id,deleted}` / 16,384 |

Usage/list returns `{agentId,fetchedAt,cached,providers}`. Each provider row is `{id,name,status,message,plan,detectedVia,activeInHermes,windows,facts,manageUrl,approximate}`; windows are `{label,usedPercent,resetsAt,detail}`, facts are `{label,value}` with already formatted display values. Status is `ok`, `signInNeeded`, `notShared` or `error`; unknown/missing numerical limits must not become zero. Times are UTC ISO 8601. Usage/activity returns `{agentId,days,hours,messages,modelDays,truncated}`; hours is 24 host-local hour counts or null, messages is a nonnegative count or null, and modelDays rows are `{day,model,tokens,cost}`. Tokens here are uncached input plus output and cost is Hermes' estimate. ModelDays has at most 4,000 rows; `truncated:true` means it cannot support a complete per-model chart.

Composio status/install returns `{agentId,schemaVersion:1,connect,servers}`. `connect` is a server name or null; each server is `{name,url,enabled,auth,kind,signedIn}` with auth `oauth`, `headers`, `none`, kind `connect` or `other`, and nullable signedIn. This reports MCP configuration and token presence, not proof that OAuth tokens still work. Install adds/enables the fixed Composio Connect MCP server; connect OAuth still uses Hermes' MCP sign-in flow. Re-read on `composio_changed`; do not expose configuration headers/secrets.

`usage/activity.days` is 1–365. Provider usage uses host credentials and reports observations/limits; do not infer a live balance or bill from missing values. `refresh` requests a fresh observation, not credential refresh.

Sign-in here is an **AI provider's host-side CLI sign-in**, separate from app-to-Hermes authentication. A provider descriptor includes `providerId,name,client,flow,state`, optional `signedIn,docsURL,message,installCommand,replacementKey`; `flow` is `device` or `paste`, and state is `ready`, `notInstalled` or `retired`. A session includes `agentId,sessionId,providerId,flow,status`, optional `link,code,expiresInSeconds,message`. Statuses: `starting`, `waiting`, `needsCode`, `finishing`, `signedIn`, `failed`, `expired`, `cancelled`. The app opens the provider's validated HTTPS link; it never receives the resulting token. `submit.code` is one visible line, 1–2,048 characters. Session ID is a lowercase UUID v4, sessions expire after 15 minutes, at most four run at once. Starting again replaces that provider's unfinished sign-in; do not blindly repeat an uncertain start. Domain errors include `sign_in_not_found`, `sign_in_not_waiting`, `sign_in_retired`, `sign_in_code_invalid`, `sign_in_busy`, `sign_in_start_failed`.

My Templates are host-wide saved agent definitions, not card templates. Required name is 1–40 Unicode scalars; instructions 1–20,000; role/vibe 160, description 400, symbol 60, category 40, variables at most 12. Returned entries additionally carry lowercase UUID `id`, `source:"mine"`, `updatedAt` in UTC. At most 40 templates; a broken entry is skipped and counted. Secret-looking content is rejected (`secret_scan_blocked`); `store_full` and `template_too_large` are separate failures. Saving creates a new ID; it is not a replace-by-name operation. Rendering symbols are platform metadata; other clients should use their own fallback icon.

### Image actions and image drafts

All routes require `native-image-drafts-v1`, use at most 196,608 request bytes, and share `agentId`. Draft routes also share `sessionId`; one draft key is `{agentId,sessionId,draftId}`. Draft IDs match `d_` + 32 lowercase hex. Decisions use a lowercase UUID; hashes use 64 lowercase hex.

| Suffix | Class | Additional request fields | Response / budget |
| --- | --- | --- | --- |
| `image-actions/get` | R | none | `{settings,defaults}` / 65,536 |
| `image-actions/save` | M | `expectedRevision,settings` | `{settings}` / 65,536 |
| `image-drafts/states` | R | `draftIds` (1–50) | `{drafts:[DraftState]}` / 65,536; 10 s |
| `image-drafts/source` | R | `draftId,offset` | `{data,mimeType,totalBytes,offset,nextOffset}` / 4,259,840; 60 s |
| `image-drafts/claim` | M | `draftId,decisionId,fieldsHash,destination` | `DraftState` / 16,384 |
| `image-drafts/finish` | M | `draftId,decisionId,outcome,destination?,reason?,verified?` | `DraftState` / 16,384 |
| `image-drafts/discard` | M | `draftId` | `DraftState` / 16,384 |
| `image-drafts/reopen` | M | `draftId,decisionId` | `DraftState` / 16,384 |

The settings document is `{schemaVersion:1,revision,presets:{business_card?:Preset,event_poster?:Preset}}`, at most 16 KiB. A Preset override has optional/null `offer,instructions,question,messages`; messages has `review,missing_fields,saved,failed,outcome_unknown` string overrides. Omitted/null overrides use defaults supplied by the host. Instructions are at most 4,000 characters; question/messages are at most 500. Placeholder allowlists are review=`destination`, missing_fields=`fields`, saved=`destination,name`, failed=`reason`, outcome_unknown=none. Message templates use the contract's bounded placeholders such as `{{destination}}`, `{{fields}}`, `{{name}}`, `{{reason}}`. Save carries the current integer expectedRevision (at least 1); a stale value yields `revision_conflict`. Do not drop an unknown revision and overwrite with defaults.

Settings and drafts are bound to the agent and the stored chat through compaction. `DraftState` has `draftId,state`, optionally `decisionId,outcome,destination,reason,verified,replacedBy,updatedAt,cardHash`. Known states are `awaiting_review`, `applying`, `saved`, `failed`, `outcome_unknown`, `discarded`, `replaced`; only saved/discarded/replaced are final. `cardHash` binds the host draft to the card shown in history. Never accept a card with a different hash as authority to write.

`claim` records one deliberate save with the hash of the reviewed fields and the user-visible destination label (max 100 characters). The same decision can read its existing claim; competing decisions get `draft_busy` or `draft_decided`. A client then writes through its own Contacts/Calendar capability and posts `finish`; the host does not write the phone's data. `outcome` is `saved`, `failed`, or `outcome_unknown`; failed requires exactly one reason among `permission_denied`, `destination_unavailable`, `invalid_fields`, `write_failed`, while other outcomes must omit reason. Only the claiming decision may finish. An uncertain local write must stay uncertain until verified; `reopen` is an explicit recovery action, not an automatic retry. `states` skips unknown IDs. Source bytes use Base64 chunks and exact offset checks as attachments do.

Sources: [image draft client and state codec](../../Bighelp/ImageDrafts/ImageDraftsClient.swift), [settings schema](../../Bighelp/ImageDrafts/ImageActionsSettings.swift), [draft card binding](../../Bighelp/ImageDrafts/ImageDraftCardHash.swift), [existing feature contract](../IMAGE_DRAFTS.md).

### Workflows: every route

All rows use POST and feature `native-workflows-v1`, except the explicitly listed additive features. Requests and responses are at most 196,608 bytes except `trigger/set`'s client response cap of 65,536. All identifiers are opaque host values; `workflowId`, `runId` and card/form IDs are distinct.

| Suffix | Class | Request body | Successful response |
| --- | --- | --- | --- |
| `workflows/status` | R | `{}` | `{coordinator:{state,heartbeatAt,epoch},slots:{used,total},survivesAppClose,runner:{available,reason?,mode?},hostName}` |
| `workflows/list` | R | `{includeArchived?}` | `{workflows,waiting,active}` |
| `workflows/get` | R | `{workflowId,revision?}` | `{workflow:{id,name,revision,latestRevision,draftVersion,archived,pinned,definition,bindings},validation}` |
| `workflows/draft/save` | M | `{workflowId?,baseDraftVersion,definition}` | `{workflowId,draftVersion,validation}` |
| `workflows/validate` | R | `{workflowId}` | `{validation}` |
| `workflows/publish` | M | `{workflowId,draftVersion}` | `{workflowId,revision}` |
| `workflows/bind` | M | `{workflowId,role,agentId}` (null unbinds) | `{workflowId,bindings}` |
| `workflows/archive` | M | `{workflowId}` | `{workflowId,archived:true}` |
| `workflows/runs/start` | M | `{workflowId,revision,inputs,clientRunToken,sample:false,projects?}` | `{run:RunSummary}` or Dev Factory group start |
| `workflows/runs/list` | R | `{workflowId?,filter,before?,limit?}` | `{runs,hasMore,cursor}` |
| `workflows/runs/get` | R | `{runId}` | `{run:RunDetail}` |
| `workflows/runs/events` | R | `{runId,after,limit?}` | `{events:[{seq,at,kind,stageKey,attempt,text}],cursor,hasMore}` |
| `workflows/runs/control` | M | `{runId,action,expectedVersion}` | `{run:RunSummary}` |
| `workflows/runs/signoff` | M | `{runId,stageKey,decision,artifactSha256,notes?}` | `{run:RunSummary}` |
| `workflows/artifacts/read` | R | `{runId,sha256,offset,length}` | `{sha256,offset,total,data,done}` |
| `workflows/templates/list` | R | `{includeCode?}` | `{templates:[{id,name,description,source,stageCount,roles,updatedAt}]}` |
| `workflows/templates/use` | M | `{templateId,name?}` | `{workflowId,draftVersion,validation}` |
| `workflows/templates/save` | M / `native-workflows-edit-v1` | `{workflowId,name,description?}` | `{templateId}` |
| `workflows/templates/delete` | M / same | `{templateId}` | `{deleted:true}` |
| `workflows/pin` | M / same | `{workflowId,pinned}` | `{workflowId,pinned}` |
| `workflows/unarchive` | M / same | `{workflowId}` | `{workflowId,archived:false}` |
| `workflows/trigger/set` | M / `native-workflows-trigger-v1` | `{workflowId,trigger:{kind,schedule?,inputs?}}` | `{trigger:{kind,schedule?,inputs?,jobId?}}` |

`revision` in get is a positive revision number or `"draft"`; omission uses the server's default draft view. Save a new draft by omitting workflow ID and sending `baseDraftVersion:0`. Save/publish require the current draft version. Bindings are `{role,agentId,approvedAt}`. List summaries include `id,name,revision,draftVersion,hasDraft,stageCount,needsSetupRoles,valid,archived,lastRunAt,pinned`, and newer hosts include `trigger`.

Runs list filter is `all`, `active`, `for_you`, or `attention`, limit 1–50 (default 20); use the returned cursor as `before`, not an event sequence. Events limit is 1–200. Events are read after integer `after`; keep advancing only through accepted rows. Artifact `length` is 1–98,304, `data` is Base64, and `done` must agree with `offset + decoded length == total`. Verify the complete SHA-256 before using an artifact for sign-off. Control action is `pause`, `resume`, `cancel` or `retry`; send the read version as `expectedVersion`. Retry is an explicit new stage attempt. Sign-off decision is `approve` or `changes`; notes at most 2,000 characters, and `artifactSha256` must name the exact artifact the user reviewed. A lost sign-off response is resolved by reading run state, not assuming approval failed.

`RunSummary` has `id,number,workflowId,workflowName,revision,state,stageKey,stageTitle,stageState,stagesDone,stageCount,iteration,startedAt,updatedAt,endedAt,paused,version,sample`; optional `clientRunToken`, `attention:{code,message}`, `failure:{stageKey,code,message}`, `waiting:{kind:"signoff",stageKey,since}`. `RunDetail` adds `inputs,stages,outputs,signoff?,tokens,allowedActions`. A stage includes `key,kind,title,role,agentId,iteration,state,minutes,startedAt,endedAt,uses,attempts`; attempts carry `id,number,iteration,state,agentId,launchedAt,endedAt,durationMs,tokens,outcomeCode`. Output records carry `stageKey,iteration,name,type,sha256,bytes`, optional `wordCount,value`. Tokens can be null, rather than zero.

Run states: `planned`, `launched`, `running`, `checking_output`, `accepted`, `waiting_for_you`, `needs_attention`, `succeeded`, `failed`, `cancelled`; stage state additionally has `pending`. Unknown fields/states must remain readable. Times are UTC whole-second ISO 8601 ending `Z`. Coordinator state is `online`, `starting`, `offline`; runner mode is `stream` or `text`. A failed/unknown stage does not restart automatically. Runs continue on the host after the app closes. The app reads `allowedActions` rather than synthesizing controls from a version number.

A start's `clientRunToken` belongs to one user intent. On uncertainty, list runs and match that token; if needed retry the **same** token to find the existing run. Never allocate a fresh token for a retry. Current companion mutation request IDs are also replay-protected for 24 hours; preserve the same logical request ID if implementing that path. The generic app adapter itself allocates IDs per HTTP perform call, so `clientRunToken` remains its start-recovery proof.

Definition schema 1: `{schemaVersion:1,name,description,roles:[{key,label}],inputs:[{key,label,type,required,choices?,sample?}],limits:{stageMinutes,maxRevisions},stages}`. Keys match `[a-z][a-z0-9_]{0,31}`, name/title 1–80 characters, up to 20 stages/64 KiB definition. Inputs are text (2,000 characters), long_text (20,000), number or choice. Stage minutes 1–60, revision limit 0–5. Every stage has `{key,kind,title}`:

| Stage kind | Additional fields |
| --- | --- |
| `agent` | `role,instructions,tools,uses,outputs:[{name,type,values?}],minutes?` |
| `check` | `rules:[{type,of,min?,max?}]`; types `word_range`, `has_title`, `not_empty`, `number_range` |
| `decision` | `on,pass,changes:{goTo,maxRevisions?}` |
| `signoff` | `file` referencing an earlier markdown_file output |
| `parallel` | `branches` of 2–5 agent stages; requires `native-workflows-parallel-v1` |
| `delivery` | `deliver,to,message?`; requires `native-workflows-delivery-v1` |

Schema 2 adds stage `next` (key/null), graph validation and optional `layout:{inputs:{x,y},stages:{key:{x,y}}}`; it requires `native-workflows-edit-v1`. References are `inputs.key` or `stage.output` and must refer to stages that run before the current one. `native-workflows-outcomes-v1` adds decision outcomes `{end:"succeeded"|"cancelled"|"failed",message?}`. Schema 3/`native-workflows-code-v1` adds Dev Factory; `runs/start.projects` selects at most 10 projects. `trigger.kind` is `manual` or `schedule`; schedule uses the host's cron/time zone and saved inputs. Publish and validate before scheduling. Validation is `{valid,host,issues:[{stageKey?,code,message,severity}]}`: `valid` says schema/graph valid; `host` also says it can run on this host. A saved invalid draft is allowed; publishing needs valid content.

Example new draft request:

```json
{"baseDraftVersion":0,"definition":{"schemaVersion":2,"name":"Review notes","description":"","roles":[],"inputs":[],"limits":{"stageMinutes":20,"maxRevisions":2},"stages":[]}}
```

This is a valid save request with validation issue `no_stages`; it is not a publishable workflow. Sources: [typed client](../../Bighelp/Workflows/WorkflowsClient.swift), [models](../../Bighelp/Workflows/WorkflowModels.swift), [shared workflow vectors](../../BighelpTests/Fixtures/Workflows), [companion full definition contract](https://github.com/promptclickrun/bighelp-plugin/blob/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf/docs/WORKFLOWS.md), [Dev Factory](https://github.com/promptclickrun/bighelp-plugin/blob/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf/docs/DEV_FACTORY.md).

### Room observations and live alerts

Room observations extend canonical Hermes group logs; they are not durable chat events. All need `native-room-activity-v1`, have a 196,608-byte response cap, and use:

| Suffix | Class | Request |
| --- | --- | --- |
| `groups/activity/open` | M | `{roomId,include?,peer?}` |
| `groups/activity/poll` | R | `{roomId,streamId,after,limit}` |
| `groups/activity/close` | M | `{roomId,streamId}` |

`include:["member.responding"]` additionally needs `native-room-typing-v1`. `peer:{homeInstallId,members:[{memberId,profile}]}` additionally needs `native-room-peer-typing-v1` and a current RoomLink reservation, and only carries responding observations. Open returns an empty page with cursor 0. Poll limit 1–8. Close returns `{schemaVersion:1,roomId,streamId,closed:true}`. Pages contain `schemaVersion,runtimeId,roomId,streamId,sourceState,upstreamLoss,openedAt,expiresAt,cursor,highWater,hasMore,resetRequired,resetReason,droppedTotal,projectionDrops,events`. See the group chapter for full coordinates and reset handling. `tool.completed` does not prove success; `upstreamLoss:"unobservable"` cannot be converted into a loss count.

The instant-alert paths require `native-live-alerts-v1`:

| Suffix | Class in generic adapter | Request | Response / budget |
| --- | --- | --- | --- |
| `alerts/listen` | R | `{listenerId,grants:[{grantId,recipientKeyId}],waitSeconds,knownAvatars?}` | `{alerts}` / 1 MiB; 40 s |
| `alerts/ack` | R | `{grants:[{grantId,recipientKeyId}],eventIds}` | acknowledgement / 16,384; 5 s |
| `alerts/stop` | R | `{listenerId,grants:[{grantId,recipientKeyId}]}` | acknowledgement / 16,384; 5 s |

The host holds listen up to 25 seconds and returns at most eight alerts. `knownAvatars` holds up to 32 previously cached avatar SHA-256 values, so unchanged pictures need not be retransmitted. `ack` takes up to 32 handled event IDs. Alerts include `grantId,eventId,eventType,agentId,sessionReference,sealed`, optionally avatar; `eventId` is namespaced by grant and the sealed object's event/grant IDs must match the outer envelope. Decode and verify the sealed alert through the notification protocol before acknowledging/displaying it. These reads use the enrolled device grant; native host authentication alone is not notification enrollment. Notification enrollment, quiet hours and sealed encryption are specified separately.

### Wiki compatibility inventory

The app retains these routes, guarded by `native-wiki-v1` (disconnect by `native-wiki-disconnect-v1`). **The audited companion 3.32.1 no longer implements or advertises them.** Keep this family disabled unless a running host advertises it; do not use it as a fallback for refused Files reads. Native folder suggestions are unsupported.

Every request is POST with `agentId` plus these fields:

| Suffix | Class | Other body fields |
| --- | --- | --- |
| `wiki/roots` | R | none |
| `wiki/connect` | M | `folderPath` |
| `wiki/resolve` | R | `folderPath` |
| `wiki/list` | R | `wikiId,path,offset,limit,query,revision?` |
| `wiki/read` | R | `wikiId,path,offset,limit,revision?` |
| `wiki/search` | R | `wikiId,query,mode,offset,limit` |
| `wiki/image` | R | `wikiId,path,offset,limit,revision?` |
| `wiki/save/begin` | M | `operationId,wikiId,path,baseRevision,totalBytes,sha256` |
| `wiki/save/chunk` | M | `operationId,offset,data` |
| `wiki/save/commit` | M | `operationId` |
| `wiki/save/status` | R | `operationId` |
| `wiki/disconnect` | M | `wikiId` |

The typed codec bounds request JSON to 100,000 bytes and responses below 196,608. Data chunks are at most 65,536 decoded bytes, encoded as canonical Base64; pin the returned revision across pages. Directory responses include `wikiId,path,parent,entries,total,offset,limit,nextOffset,revision`; reads include `wikiId,path,offset,size,availability,revision,data,nextOffset`. Save results include `operationId,status,nextOffset?,totalBytes?,revision?`; receiving must carry a valid next offset, committed must carry a valid revision. Keep the same operation ID for status/recovery after an uncertain commit. Disconnect returns `{wikiId,disconnected:true}` and retires local grants immediately. Sources: [native adapter](../../Bighelp/DirectHermes/DirectHermesWikiClient.swift), [wire codec](../../Bighelp/Wiki/WikiClient.swift), [wiki models and limits](../../Bighelp/Wiki/WikiModels.swift), [tests](../../BighelpTests/DirectHermesWikiClientTests.swift).

## Agent deliveries and generated media

There are three distinct paths: outgoing chat uploads through stock RPC, incoming assistant deliveries through provenance-bound plugin HTTP, and configured workspace/managed-file reads. Preserve the identity and policy of each; an arbitrary string that looks like a path does not authorize a fetch.

### Outgoing chat attachments (stock JSON-RPC)

Uploads stage against the **runtime** `session_id`, then the ordinary prompt submission commits the turn. Persist the user's submission intent before the first staging mutation and upload serially in composer order. Validate the whole batch first: 1–10 unique attachments, 8 MiB each, 24 MiB total, text at most 1 MiB. The transport permits at most one in-flight image/file upload and widens only its fixed attachment frame types (12 MiB maximum frame); it is not a general large-message escape hatch.

| RPC method | Exact params | Result checks |
| --- | --- | --- |
| `image.attach_bytes` | `{session_id,filename,content_base64}` | `attached:true,path,name,count,bytes`, optional bounded text; bytes equals upload length, name matches path basename |
| `file.attach` | `{session_id,name,data_url}` | `attached:true,uploaded:true,name,path,ref_path,ref_text` |
| `pdf.attach` | `{session_id,profile,path,first_page,last_page}` | `attached:true,filename,pages_attached,pages,count,text` |

Example non-image upload params: `{"session_id":"runtime-1","name":"notes.txt","data_url":"data:text/plain;base64,SGVsbG8="}`. A file receipt's `ref_text` begins `@file:` and must decode to exactly `ref_path`; both paths' basename must match `name`. Append only that validated reference text to the submitted prompt. Stock reference wrappers may be backtick, single quote or double quote delimiters, with no embedded matching delimiter; unquoted references may contain no whitespace/brackets/quotes. They are not shell or URL escaping. Images are already queued on the runtime and have no file reference to append.

PDF page attachment first stages the selected original PDF with `file.attach`, then uses **only the validated staging receipt's path** in `pdf.attach`. Never accept a user-authored arbitrary host path. Pages are 1-based inclusive, at most 25/page request; local upload is at most 8 MiB even though stock Hermes' ceiling is 50 MiB. The PDF must parse, start `%PDF-`, be unencrypted and match its `.pdf` filename/MIME. Result page records are `{path,page,name?,width?,height?,token_estimate?}` and must exactly match the selected sequence; returned text is `[User attached PDF: <filename> (<count> page(s))]`. Profile/runtime/connection changes retire the prepared selection.

Do not submit the prompt until every attachment receipt is validated. An uncertain staging call may already have queued bytes; cancellation/disconnect does not prove it failed and must not automatically upload again into a replacement runtime. Sources: [attachment uploader](../../Bighelp/DirectHermes/DirectHermesAttachmentClient.swift), [file reference codec](../../Bighelp/DirectHermes/DirectHermesFileAttachments.swift), [PDF receipt/limits](../../Bighelp/DirectHermes/DirectHermesPDFAttachments.swift), [submission journal path](../../Bighelp/DirectHermes/DirectHermesConversationClient+Attachments.swift).

### Incoming attachment resolution

For assistant text containing `MEDIA:` send the original item text and **stored** session ID. The host resolves paths against assistant history in that session and compaction ancestors, then applies Hermes' gateway delivery policy. It can serve explicit deliveries outside `terminal.cwd` when that policy permits them. It returns opaque IDs rather than asking the client to request an absolute path:

```json
{"agentId":"default","storedId":"stored-chat-1","items":[{"itemId":"message-12","text":"The report is ready.\nMEDIA:/example/output/report.pdf"}]}
```

```json
{"items":[{"itemId":"message-12","text":"The report is ready.","attachments":[{"id":"opaque-attachment-id-1234","fileName":"report.pdf","mimeType":"application/pdf","byteCount":5}]}]}
```

The maximum resolve batch is 50 items; each item ID is 1–200 characters, text at most 100,000 characters (the server also enforces encoded body bounds), stored ID 1–180. `AttachmentMeta` is `{id,fileName,mimeType,byteCount}`. Missing, denied and oversized deliveries produce no attachment and preserve readable original text. Do not erase references until bytes were actually delivered.

Fetch the returned ID with offset 0, then advance using `nextOffset`:

```json
{"agentId":"default","attachmentId":"opaque-attachment-id-1234","offset":0}
```

```json
{"attachmentId":"opaque-attachment-id-1234","mimeType":"application/pdf","byteCount":5,"offset":0,"data":"SGVsbG8=","nextOffset":null}
```

This illustrates framing only; those five bytes are not a PDF and must fail PDF content validation. Real bytes must match their claimed media type. Each response must echo attachment ID/offset, keep byteCount constant, decode to nonempty bytes, remain within byteCount, and set nextOffset to exactly offset + decoded length, or null only at EOF. Do not add a `length` property: the server chooses chunk size. Current chunks are at most 3 MiB − 64 KiB raw (3,080,192 bytes), files at most 25 MiB. The first nonfinal chunk establishes the step; remaining chunks can be fetched three at a time and assembled in offset order. The app retries transient chunk failures after 1 and 3 seconds, never owner/cancellation/invalid request/invalid response/unsupported-operation failures.

`attachments/board` addresses a file through its post and zero-based file index, not a path. `attachments/recent` limit is 1–36 and returns only pictures/videos with `storedId,createdAt` plus metadata. These entries use the same fetch protocol. Cache bytes by authority/profile/stored chat and delivery identity; never share by filename alone.

Decode real images, parse PDFs to require at least one page, and validate playable videos before claiming a ready attachment. Enforce per-file and total limits before allocation. The current app permits at most 8 artifacts/32 MiB total per generated-media resolution and 25 MiB per incoming artifact (see source constants for any changes). Never render HTML, execute files or follow embedded instructions merely because a delivery is authenticated.

### Generated tool output and fallback

For succeeded `image_generate`/`video_generate`, parse a bounded result object with `success:true` and only the explicit `image` or `video` output property. Do not treat source/edit inputs, arbitrary nested text or aliases as delivered outputs. An explicit host image uses the stock image read path; other supported files use managed-file policy. Human history references are whole-line `@file:` / `@image:` references, with validated delimiter parsing and supported absolute paths.

The current client can fetch an explicit hosted generator `image`/`video` HTTPS URL only when no host output path exists and a public-URL policy accepts it. Such requests use no Hermes cookies/tokens, check response MIME and actual media, cap bytes, and remain bound to the originating owner. This is not permission to fetch arbitrary assistant URLs or to follow a policy refusal with a different route. Preserve the original raw text for reconciliation; remove only successfully resolved delivery directives.

Sources: [generated media and chunks](../../Bighelp/DirectHermes/DirectHermesGeneratedMediaClient.swift), [attachment cache](../../Bighelp/Chat/AgentAttachmentCache.swift), [limits](../../Bighelp/Chat/ChatAttachment.swift), [generated media tests](../../BighelpTests/DirectHermesGeneratedMediaTests.swift), [native delivery tests](../../BighelpTests/DirectHermesNativeAttachmentTests.swift).

## Configured workspace versus explicit file grants

Two plugin file APIs coexist and have different authority and path formats.

### Configured workspace (`/native/workspace-files/…`)

This is the artifact/Files view of the agent's own working folder, not a user-supplied root. First request `scope` with `{"path":null}`; add `profile` only with the corresponding advertised feature. A scope/list result is:

```json
{"workspace":{"root":"/example/workspace","source":"terminal.cwd","origin":"config","profileId":"default"},"path":"/example/workspace","parent":null,"entries":[],"root":"/example/workspace","locked_root":"/example/workspace","can_change_path":false}
```

List entries have `name,path,is_directory,size,created,mtime,mime_type`; directory size/MIME can be null. Paths are absolute and must remain beneath the exact root. `workspace.source` stays `terminal.cwd` for compatibility even when Hermes chose its default; `origin` explains `config`, `default`, `docker-volume`, `hermes-workspace`. `read` returns `workspace,path,size,mime_type,data_url,root,locked_root,can_change_path`; `data_url` is exact Base64 bytes. `recent` uses the listing shape, newest first, at most 300 rows; it is bounded history plus a shallow scan, not a complete recursive file index. Ordinary list is capped at 2,000 rows and 196,608 encoded bytes.

The app requires `root == locked_root == workspace.root`, `can_change_path:false`, matching profile, matching requested path and no escaping child/parent rows. Scope is owned by the captured authority/generations. The server refuses Hermes' own settings/key folders, links/special files, remote SSH workspaces and unmounted container workspaces. Fixed refusals include `workspace_in_container`, `workspace_on_remote`, `workspace_windows_unsupported`, `workspace_not_configured`, `workspace_hermes_folder`, `workspace_unavailable`. `native-workspace-hermes-home-v1` signals hosted-Hermes workspace fallback support; without it, a relevant refusal should recommend updating/restarting the plugin rather than inventing a root. Do not fall back to stock files after a refused configured-workspace read.

### Explicit read-only grants (`/workspace-files/…` without `/native`)

These older routes use ordinary host authentication and **do not** use native ETags/request IDs. The operator first grants roots locally. Discover opaque `workspace_id` values and labels; client paths are relative. Never substitute a project ID, configured-workspace absolute path, or host folder for a grant.

| Method / full path | Request | Successful fields |
| --- | --- | --- |
| GET `/api/plugins/loopdy/workspace-files/capabilities` | none | schemaVersion, capabilities/limits, granted roots/IDs |
| POST `/api/plugins/loopdy/workspace-files/list` | `{workspace_id,path?,query?,offset?,limit?,revision?}` | `path,parent,entries,total,offset,limit,next_offset,revision` |
| POST `/api/plugins/loopdy/workspace-files/read` | `{workspace_id,path,offset?,limit?,revision?}` | `availability,size,data,text?,next_offset,revision` |
| POST `/api/plugins/loopdy/workspace-files/status` | `{workspace_id}` | read-only Git status, `hidden_files` |
| POST `/api/plugins/loopdy/workspace-files/diff` | `{workspace_id,path,side,expected_status_token,offset?,limit?}` | structured diff rows, availability, next offset |

Relative `path:""` means root; `parent:null` means already root and `parent:""` means parent is root. Entries have `name,path,kind,size`. Follow `next_offset` even when fewer rows than requested are returned. Pin directory/file revision across pagination; a changed revision requires restarting the read. File limit 8 MiB, chunks at most 64 KiB; `availability` is `available`, `binary`, `oversized`. Binary bytes remain authoritative even with null `text`. Revisions are `sha256:<64 hex>`; an oversized file has no partial preview. This service is read-only and is not a grant to run Git mutations.

Sources: [artifact transport](../../Bighelp/DirectHermes/DirectHermesArtifactClient.swift), [scope validation](../../Bighelp/DirectHermes/DirectHermesWorkspaceFileScope.swift), [legacy route mapping](../../Bighelp/DirectHermes/DirectHermesWorkspaceClient.swift), [companion granted-file contract](https://github.com/promptclickrun/bighelp-plugin/blob/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf/docs/WORKSPACE_FILES.md).

### Managed transfers on stock Hermes routes

After native scope discovery/list validation, the Files client uses fixed stock managed-file operations. This does not extend the locked scope to arbitrary paths. Re-list and match the exact metadata before downloading/mutating; detect scope changes after every await.

| Method / route | Request / result |
| --- | --- |
| GET `/api/files/read?path=…` | JSON `{path,name,size,mime_type,data_url}`; fallback download limit 2 MiB decoded |
| GET `/api/files/download?path=…` | raw bytes; HTTP 200, no Content-Range; limit 16 MiB |
| HEAD `/api/files/stream?path=…` | Accept `audio/*, video/*`; inspect Content-Type/Length/Accept-Ranges, no body |
| GET `/api/files/stream?path=…` | `Range: bytes=start-end` inclusive; HTTP 206, exact `Content-Range: bytes start-end/total`, `Accept-Ranges: bytes` |
| POST `/api/files/upload` | `{path,data_url,overwrite}` for up to 512 KiB decoded |
| POST `/api/files/upload-stream` | multipart `path`, `overwrite`, `file`; limit 16 MiB payload plus 16 KiB overhead |
| POST `/api/files/mkdir` | `{path}` |
| DELETE `/api/files` | `{path,recursive:false}` |

Validate downloaded length against listed size and Content-Length when present, and MIME against the listing. Range responses must contain exactly the requested bytes; the app uses half-open local ranges but converts them to inclusive HTTP endpoints. An unexpected 200 for a requested range is invalid, not a complete replacement. Native binary transfers reject redirects and keep credentials bound to the original host.

A successful upload/mkdir receipt is `{ok:true,path,entry}`; delete echoes `{ok:true,path}`. Verify using authoritative list plus exact-byte readback/hash. After an uncertain upload, read back the destination and compare size and SHA-256 before declaring success. Do not replay an uncertain multipart upload, overwrite, delete or directory creation. A dispatch/owner race after bytes may have left remains outcome unknown. Multipart parts use standard CRLF boundaries and filename metadata; do not send Base64 as the binary file part.

Sources: [managed Files API and reconciliation](../../Bighelp/DirectHermes/DirectHermesManagedFilesClient.swift), [binary transport](../../Bighelp/DirectHermes/DirectHermesManagedFileTransport.swift), [tests](../../BighelpTests/DirectHermesManagedFilesTests.swift), [transfer budgets](../../BighelpTests/DirectHermesTransferBudgetTests.swift).

## Voice protocols

Turn-based speech and live WebRTC are separate transports. Turn-based STT/TTS uses stock Hermes audio routes; live provider audio uses the optional plugin. Native voice must not fall back to a retired relay after failure.

### Live voice handshake and event loop

Use the five native voice routes listed above. Every call is bound to `{agentId,sessionId,voiceId}` and the host authorization/context. The session ID is the **stored** ID of the chat selected for delegated work, not its live runtime ID. Provider is explicitly `codex_subscription` or `api_key`; subscription failure must not silently choose separately billed API-key mode. Credentials stay on the host.

```json
{"agentId":"default","sessionId":"stored-chat-1","provider":"codex_subscription"}
```

```json
{"available":true,"enabled":true,"provider":"codex_subscription","interruptSupported":false}
```

Allocate one voice ID for the call and send an audio-only WebRTC SDP offer:

```json
{"agentId":"default","sessionId":"stored-chat-1","voiceId":"voice-1","provider":"codex_subscription","voice":"cove","sdp":"<complete audio-only WebRTC offer>"}
```

The placeholder must be replaced with real SDP, not sent literally. Success returns `{voiceId:"voice-1",sdp:"<audio-only answer>"}`. Apply that answer to the same local peer. Host setup allocates provider state; do not retry an uncertain offer. Close that exact voice ID on abandoned/late-success setup. The app snapshots a one-use close handle from the original authority before owner retirement; it can close only that allocation and cannot refresh or retarget credentials.

Server session/voice IDs are 1–180 ASCII identifier characters; SDP is at most 180,000 characters and the app additionally requires UTF-8 size at most 262,144, no NUL and audio-only media sections. Chosen subscription voices in this app are `arbor,breeze,cove,ember,juniper,maple,sol,spruce,vale`; API-key voices are `marin,quartz,ripple,vesper,willow,stone,gleam,meridian,bossa,tempo,beacon,delta,cinder`. These are this client's accepted choices, not a universal provider catalog. Native offer HTTP currently has the generic 20-second route timeout; the higher control layer bounds setup at 45 seconds. Media then flows directly between client and provider; the plugin HTTP poll carries events, not microphone PCM.

Poll after sequence 0 initially:

```json
{"agentId":"default","sessionId":"stored-chat-1","voiceId":"voice-1","after":0}
```

```json
{"voiceId":"voice-1","closed":false,"next":1,"events":[{"sequence":1,"event":{"kind":"started"}}]}
```

At most four events/page. Require exact contiguous `sequence == last + 1`, then require `next == last accepted sequence`. On an empty page the app waits 400 ms. Known provider event kinds are `started`, `sideband_attached`, `transcript_delta`, `transcript_done`, `delegation`, `delegation_context_required`, `provider_error`, `transport_closed`, `session_closed`, `audio_cleared`. Transcript events carry role/text and may carry `end_ms`; delegation is `{kind:"delegation",id,text}`, while context-required delegation carries `{kind:"delegation_context_required",id,offset_ms}` and the client derives work text from bounded user transcript deltas through that offset. A feed gap (`voice_feed_gap`) is fatal to the call; do not reconstruct a missing request by guessing.

The app deduplicates delegation IDs, coalesces identical pending request text, limits eight concurrent pending work requests, 1,024 admitted IDs, and bounds text to 3,072 UTF-8 bytes. It submits delegated work through normal Hermes chat (`prompt.submit` when free, `prompt.background` when busy), retaining ordinary chat approvals/history. It does not create a second plugin job queue. A completed result uses:

```json
{"agentId":"default","sessionId":"stored-chat-1","voiceId":"voice-1","delegationId":"delegation-1","text":"The report is saved in the chat."}
```

Server text limit is 1,500 characters; the app bounds summaries in UTF-16 and directs users to the complete chat for longer results. The plugin admits a result only once per known delegation; it marks it consumed before the provider await, so an uncertain provider receipt does not permit replay. `voice_result_unavailable` is not an instruction to rerun work. Closing/muting media leaves accepted Hermes tasks running. On poll failure, emit a visible provider error and close the call without replaying prompts.

Sources: [native session loop](../../Bighelp/Voice/NativeLiveVoiceSession.swift), [control client](../../Bighelp/Voice/LiveVoiceControlClient.swift), [SDP peer policy](../../Bighelp/Voice/BighelpRealtimeAudioPeer.swift), [voice cleanup](../../Bighelp/DirectHermes/DirectHermesVoiceClients.swift), [voice tests](../../BighelpTests/DirectHermesVoiceClientTests.swift), [companion hub](https://github.com/promptclickrun/bighelp-plugin/blob/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf/loopdy_plugin/native_voice.py).

### Turn-based transcription, buffered speech and PCM streaming

Stock transcription is `POST /api/audio/transcribe?profile=<profile>` with `{data_url:"data:<mime>;base64,<bytes>",mime_type}`. Recording ceiling is 25 MiB decoded and the response ceiling is 1 MiB. Validate recording size/MIME and ownership before sending. The exact relay response is `{ok:true,transcript:string,provider?:string}`. Submit that transcript through the ordinary chat path; transcription does not itself execute an agent prompt. This differs from the direct provider response formats below.

Buffered speech is `POST /api/audio/speak?profile=<profile>` with `{text}` (at most 20,000 characters). Success is `{ok:true,data_url,mime_type}`; the data URL must be Base64, have the same audio MIME as mime_type, and decode to nonempty playable audio of at most 8 MiB. Voice/provider/rate come from the host's resolved TTS configuration; no arbitrary provider URL or rate property is added. The settings client reads `/api/config` and `/api/keys` for the selected profile, writes provider key through the stock key endpoint and deep-merges `tts` configuration, then reads back. A local revision hash is a compare-before-write check, not a server CAS guarantee. Warm-up uses `POST /api/audio/tts-lease?profile=<profile>` with `{lease:<unique-client-lease>,active:true}` and a requested 180-second timeout (the current shared HTTP transport clamps it to 75 seconds), then releases that same lease with `active:false`; a receipt with `action:"error"` identifies host restart required or package installation failure.

PCM streaming uses a **separate authenticated** WebSocket at `/api/audio/speak-stream?profile=<profile>&ticket=<freshTicket>` in bearer mode, or `?profile=<profile>&token=<dashboardSessionToken>` in dashboard-session mode. Mint each bearer socket ticket with `POST /api/auth/ws-ticket`, bearer authentication and body `{}`; it is distinct from and cannot reuse the main gateway socket ticket. Convert the base scheme to `ws`/`wss`, retain any configured base path and proxy headers, and enforce TLS, redirect refusal and owner fencing. Send one text frame `{"text":"Hello.","done":true}`.

The exact accepted text control frames are `{"type":"start","sample_rate":24000,"channels":1}`, `{"type":"fallback"}`, and `{"type":"end"}`. Unknown keys or types are invalid. `sample_rate` must be a finite whole number 8,000–96,000 and `channels` must be exactly 1. No `format` property is sent: binary frames are signed 16-bit little-endian PCM. Require one start before any binary bytes; keep rate/channels immutable, preserve an incomplete sample across binary frames, and reject end until some audio arrived and no partial sample remains. Drain all queued audio before reporting playback complete. `fallback` is accepted only before start/audio and asks the caller to use buffered speech; after any PCM playback, failure never authorizes replay. Control frames are capped at 32 KiB, each binary frame at 16 MiB, total PCM at 64 MiB.

Sources: [voice media transport](../../Bighelp/DirectHermes/DirectHermesVoiceMediaTransport.swift), [voice speech output](../../Bighelp/DirectHermes/DirectHermesVoiceClients.swift), [streaming voice tests](../../BighelpTests/DirectHermesVoiceMediaTests.swift).

### Client-direct STT/TTS configuration and provider wire shapes

Turn-based voice can also select provider HTTP directly from the client. First load authenticated `GET /api/audio/voice-config?profile=<profile>` (128 KiB cap). Success is `{ok:true,stt:Route,tts:Route}`. Each Route is either `{mode:"relay",reason?}` or `{mode:"direct",wire,provider,base_url,api_key,model?,language?,voice?,speed?}`. Select STT and TTS independently; a wire must support its declared direction. `base_url` is a complete HTTPS provider base, with no userinfo, query or fragment; append the path components in the table, preserving its existing base path. Optional speed must be finite 0.25–4.

Unlike plugin live voice, this **client-direct** contract intentionally delivers a provider credential to the client. Treat `api_key` as a screen-lifetime secret: retain it only in ephemeral credential storage, never serialize/log/display/persist it, and invalidate it when the host/profile/authorization generation or voice presentation retires. The provider request contains only this provider credential; it must never inherit the host bearer/session token, proxy access headers, cookies, shared credential storage or host URL. Use an isolated no-cache/no-cookie HTTPS session, reject redirects and URL changes, validate the selected owner after each await, and apply response byte caps before buffering. This is distinct from the native live-voice path where provider credentials remain on the host.

All direct requests below use POST; multipart parts contain raw recording bytes, not Base64. The file part is named `file`, filename `recording.<extension matching MIME>`, and carries the recording MIME type. Other multipart fields are text strings, including `format:"true"`. Path suffixes are relative to the returned base URL.

| `wire` / direction | Provider path suffix | Credential header | Exact request fields | Accepted result |
| --- | --- | --- | --- | --- |
| `openai-multipart` / STT | `/audio/transcriptions` | `Authorization: Bearer <provider credential>` | multipart `file`, `model?`, `response_format:"text"`, `language?` | UTF-8 plain text, or JSON object `{text:string}` |
| `xai-stt` / STT | `/stt` | `Authorization: Bearer <provider credential>` | multipart `file`, `format:"true"`, `language?` | JSON `{text:string}` |
| `elevenlabs-stt` / STT | `/speech-to-text` | `xi-api-key: <provider credential>` | multipart `file`, `model_id?`, `language_code?` | JSON `{text:string}` |
| `openai-speech` / TTS | `/audio/speech` | `Authorization: Bearer <provider credential>` | JSON `{model:string\|null,voice:string\|null,input,response_format:"mp3",speed?}`; omit speed when 1 | nonempty audio bytes |
| `elevenlabs-tts` / TTS | `/text-to-speech/{voice}` | `xi-api-key: <provider credential>` | JSON `{text,model_id:string\|null}` | nonempty audio bytes |

STT provider response is capped at 1 MiB and decoded as text with no NUL, then trimmed. The OpenAI wire accepts its requested plain text format and the compatible JSON `text` form; xAI/ElevenLabs require the JSON form. This differs from Hermes relay STT's `transcript` property. Recording limit is 25 MiB plus 16 KiB multipart overhead, metadata fields at most 1,024 UTF-8 bytes with no controls. TTS input is nonempty after trimming and at most 20,000 UTF-8 bytes; its response cap is 8 MiB, with `Accept: audio/mpeg`. Audio MIME comes from Content-Type, with missing or `application/octet-stream` treated as audio/mpeg. Require a 2xx response and the exact requested URL. Provider requests have a 60-second resource budget; failures remain provider/transport errors and must not silently trigger another billed provider or duplicate partially played speech.

Sources: [configuration resolver, direct wire transport and response codecs](../../Bighelp/DirectHermes/DirectHermesVoiceConfigurationClient.swift), [voice tests](../../BighelpTests/DirectHermesVoiceClientTests.swift).

## Independent Hermes Kanban plugin

Kanban has its own `/api/plugins/kanban` mount. It is not the bighelp board and does not use `/native/context` or its ETag headers. Discover it with authenticated `GET /boards?include_archived=false`; 404/405 means mount unavailable. An installed/enabled plugin catalog entry alone does not prove this route is mounted. Ordinary host HTTP authentication and owner fencing still apply.

The following table expands every path generated by the native Kanban clients. Prefix all paths with `/api/plugins/kanban`. Unless noted, task/run-specific calls carry query `board=<slug>`. Percent-encode path components, rather than concatenating raw task/profile names.

| Method / path | Query/body | Main response |
| --- | --- | --- |
| GET `/boards` | `include_archived=true\|false` | `{boards,current}` |
| GET `/board` | `board,include_archived,workflow_template_id?,current_step_key?` | `{columns,tenants,assignees,latest_event_id,now}` |
| GET `/tasks/{taskId}` | board | `{task,comments,events,attachments,links:{parents,children},runs}` |
| POST `/tasks` | board; TaskCreate below | `{task}` |
| PATCH `/tasks/{taskId}` | board; TaskPatch below | write receipt, followed by task readback |
| DELETE `/tasks/{taskId}` | board | `{deleted:true,task_id}` |
| POST `/tasks/{taskId}/comments` | board; `{body,author}` | `{ok:true}` |
| GET `/tasks/{taskId}/attachments` | board | `{attachments}` |
| POST `/tasks/{taskId}/attachments` | board; multipart `file`, `uploaded_by` | `{attachment}` |
| GET `/attachments/{attachmentId}` | board | raw bytes |
| DELETE `/attachments/{attachmentId}` | board | `{ok:true,id}` |
| GET `/runs/{runId}` | board | `{run}` |
| GET `/runs/{runId}/inspect` | board | run process inspection |
| POST `/runs/{runId}/terminate` | board; `{reason:string\|null}` | `{ok:true,run_id,task_id}` |
| POST `/dispatch` | `board,dry_run=false,max=1..32` | dispatcher receipt |
| GET `/assignees` | board | `{assignees}` |
| GET `/config` | none | `{lane_by_profile,include_archived_by_default,render_markdown,...}` |
| GET `/stats` | board | `{by_status,by_assignee,oldest_ready_age_seconds?,now}` |
| GET `/diagnostics` | `board,severity?` | `{diagnostics}` |
| GET `/projects` | none | `{projects}` |
| GET `/model-options` | none | `{providers}` |
| GET `/profiles` | none | `{profiles}` |
| GET `/orchestration` | none | orchestration configuration |
| PUT `/orchestration` | `{orchestrator_profile?,default_assignee?,auto_decompose?,auto_promote_children?}` | orchestration, verified by GET |
| GET `/home-channels` | `board,task_id?` | `{home_channels}` |
| GET `/workers/active` | board | `{workers}` |
| GET `/tasks/{taskId}/log` | `board,tail=<byte count>` | `{task_id,exists,size_bytes,...log tail}` |
| POST `/estimate` | no board; `{title,body:string\|null}` | estimate |
| POST `/tasks/{taskId}/estimate` | board; no body | estimate |
| POST `/boards` | BoardCreate below | `{board}` |
| PATCH `/boards/{slug}` | BoardPatch below | board receipt, verified in catalog |
| DELETE `/boards/{slug}` | `delete=true\|false` | `{result:{slug,action:"deleted"\|"archived"}}` |
| POST `/boards/{slug}/switch` | no body | `{current}` |
| POST `/boards/{slug}/export` | `{output:"",attachments:boolean,logs:boolean}` | `{board,archive,size,counts}` |
| POST `/boards/import` | `{archive,slug:string\|null,switch:boolean}` | `{board,requested_board,renamed,name,counts,attachments_restored,tasks_parked,warnings,activated}` |
| PATCH `/profiles/{profile}` | `{description}` | `{ok:true,profile}` |
| POST `/profiles/{profile}/describe-auto` | `{overwrite:boolean}` | auxiliary outcome, verified by profiles readback |
| POST `/tasks/bulk` | board; BulkPatch below | `{results:[{id,ok,...}]}` |
| POST `/links` | board; `{parent_id,child_id}` | `{ok:true}` |
| DELETE `/links` | `board,parent_id,child_id`; no body | `{ok:true}` |
| POST `/tasks/{taskId}/reassign` | board; `{profile:string\|null,reclaim_first:boolean,reason:string\|null}` | `{ok:true,task_id}` |
| POST `/tasks/{taskId}/reclaim` | board; `{reason:string\|null}` | `{ok:true}` |
| POST `/tasks/{taskId}/specify` | board; `{author:"loopdy"}` | `{ok,task_id,new_title?,...}` |
| POST `/tasks/{taskId}/decompose` | board; `{author:"loopdy"}` | `{ok,task_id,child_ids,...}` |
| POST `/tasks/{taskId}/home-subscribe/{platform}` | board; no body | `{ok:true}` |
| DELETE `/tasks/{taskId}/home-subscribe/{platform}` | board; no body | `{ok:true}` |
| WebSocket `/events` | `board,since,ticket` or `board,since,token` | event batches below |

TaskCreate sends required `title,body,priority,parents,triage,goal_mode`; optional `assignee,tenant,workspace_kind,workspace_path,idempotency_key,max_runtime_seconds,skills,goal_max_turns,model_override,provider_override,reasoning_effort,project_id`. TaskPatch contains only changed properties among `title,body,assignee,status,priority,block_reason,result,summary`; clearing assignee sends `""`, not JSON null. Priority is −1,000…1,000. The app uses an idempotency key for one creation intent, and after a lost response looks up the exact key before claiming creation succeeded.

BoardCreate is `{slug,name,description,icon,color,switch,default_workdir?,project_id?}`; empty default workdir/project are omitted. BoardPatch permits `name,description,icon,color,default_workdir,project_id` and sends only changed fields. BulkPatch always includes `ids,archive,reclaim_first,clear_model_override,clear_reasoning_effort`, optionally `status,assignee,priority,model_override,provider_override,reasoning_effort`.

A board catalog row includes `slug,name,description,icon,color,default_workdir,project_id,project_name,is_current,archived,total,counts`. Columns are `{name:<status>,tasks:[Task]}`. Task required fields include `id,title,status,priority,created_at`; optional fields projected by this client include `body,assignee,created_by,started_at,completed_at,tenant,workspace_kind,workspace_path,branch_name,project_id,result,idempotency_key,latest_summary,current_run_id,worker_pid,last_heartbeat_at,max_runtime_seconds,model_override,provider_override,reasoning_effort,workflow_template_id,current_step_key,skills,max_retries,consecutive_failures,goal_mode,goal_max_turns,completion_contract,block_kind,block_recurrences,link_counts`. Preserve nullability; PID presence does not itself prove a live run. Times here are Unix seconds, unlike workflows' ISO strings. Task status values are `triage`, `todo`, `scheduled`, `ready`, `running`, `blocked`, `review`, `done`, `archived`; they are distinct from bighelp goal status.

This client computes review revisions locally from canonical task/catalog data, then reads immediately before mutation and verifies afterward. Those local revision hashes are **not** wire `If-Match`, and cannot make the backend write atomic with the preceding read. For edits/comments/attachment removal/reassign/reclaim/terminate, a transport failure after dispatch leads to authoritative readback without replay. Export/import and generated descriptions can have side effects; an unverified receipt must remain uncertain. Backend behavior beyond these app-authored request/response checks requires the mounted Kanban server source; this guide does not infer it from the UI.

### Kanban binary attachments and event socket

Upload is multipart with a `file` binary part (safe filename and `Content-Type`) and text part `uploaded_by`; no Base64. The native transport allows 16 MiB/file plus 16 KiB envelope, and 256 KiB JSON receipt. Attachment IDs are positive integers; binary downloads are capped at 16 MiB and MIME/size must match the selected attachment. The stricter transport validates board names `[a-z0-9][a-z0-9_-]{0,63}` and task IDs `t_` followed by 8–238 lowercase hex characters. It rejects hidden/path-like filenames and controls. Use the same authenticated host session and reject redirects.

Open a separate `ws(s)://<host-prefix>/api/plugins/kanban/events?board=<slug>&since=<acceptedCursor>&ticket=<freshTicket>` for bearer mode. Mint a new single-use ticket with `POST /api/auth/ws-ticket` authenticated to Hermes, body `{}`. Dashboard-session mode uses `token=<dashboardToken>` instead. Apply configured proxy headers; do not reuse the gateway socket ticket. The event stream is text JSON only:

```json
{"events":[{"id":41,"task_id":"t_1234abcd","run_id":null,"kind":"task.updated","payload":{},"created_at":1792886400}],"cursor":41}
```

The envelope has exactly `events,cursor`; every row has exactly `id,task_id,run_id,kind,payload,created_at`. Require 1–200 events/frame, positive strictly increasing IDs after the accepted cursor, final event ID equal to cursor, optional positive integer run_id, payload object/null and whole-second timestamp. Binary frames are invalid. Frame limit is 16 MiB. Adopt the cursor before notifying consumers. Reconnect transient connection/server/timeout failures at 250 ms doubling to 8 seconds, up to six consecutive attempts, with a fresh ticket and last accepted cursor. Successful batches or a stable five-second connection reset the retry count. Authentication/policy errors, invalid payloads, owner changes and missing mount do not reconnect automatically. Re-read board/task state for the actual content; event kinds are invalidation hints, not a reason to replay task mutations.

Sources: [Kanban client](../../Bighelp/HermesPlugins/Kanban/DirectHermesKanbanClient.swift), [administration routes](../../Bighelp/HermesPlugins/Kanban/DirectHermesKanbanAdministrationClient.swift), [binary/event protocol](../../Bighelp/DirectHermes/DirectHermesKanbanTransport.swift), [models](../../Bighelp/HermesPlugins/Kanban/KanbanModels.swift), [transport tests](../../BighelpTests/DirectHermesKanbanTransportTests.swift).

## Independent Hermes Achievements plugin

This plugin mounts at `/api/plugins/hermes-achievements`, uses stock host authentication and owner fencing, and has no native-context ETag contract. Discover with GET `/scan-status`, which does not itself start a history scan. A missing/unsupported mount stays unavailable, regardless of plugin inventory.

| Method / suffix | Request | Response |
| --- | --- | --- |
| GET `/scan-status` | none | ScanStatus; cap 128 KiB |
| GET `/achievements` | none | Catalog; cap 4 MiB |
| GET `/recent-unlocks` | none | array of at most 20 unlocked Achievement rows; cap 4 MiB |
| GET `/sessions/{sessionId}/badges` | encoded session ID | `{session_id,badges:[Achievement]}`; cap 4 MiB |
| POST `/rescan` | no body | `{ok:true,...Catalog}` followed by status/readback |
| POST `/reset-state` | no body | `{ok:true}` followed by status verification; cap 64 KiB |

`ScanStatus` requires `state:"idle"|"running"|"failed",run_count,ttl_seconds,snapshot_stale`; nullable metadata is `started_at,finished_at,last_error,last_duration_ms,snapshot_generated_at,snapshot_age_seconds`. `Catalog` has `achievements,unlocked_count,discovered_count,secret_count,total_count,generated_at,is_stale?,scan_meta`; `scan_meta` has `status,mode,sessions_total,sessions_rescanned,sessions_reused,sessions_scanned_so_far?,sessions_expected_total?`. At most 512 unique rows, total equals row count, and the three counts must sum to total.

An Achievement has `id,name,description,criteria,category,kind,icon,state,unlocked,discovered,progress,progress_pct`, optionally `secret,tier,next_tier,next_threshold,unlocked_at,evidence:{session_id?,title?,value?}`. Percentage is integer 0–100, progress nonnegative; dates are Unix seconds. A scan failure is not evidence that no achievements exist.

Before rescan/reset, read catalog and status and ensure no scan is running; compare the locally reviewed snapshot immediately before mutation. On an uncertain rescan, poll status every two seconds, and use an increased `run_count` to prove a new completed/failed run. Never replay an uncertain reset. A confirmed reset must read back idle status with cleared start/end/error/duration/snapshot fields. As with Kanban, these are client-side review/readback rules, not a server CAS promise.

Sources: [Achievements client and codecs](../../Bighelp/HermesPlugins/Achievements/DirectHermesAchievementsClient.swift), [conditional ownership tests](../../BighelpTests/DirectHermesConditionalOwnershipTests.swift).

## Cross-platform implementation notes

Use a single retained HTTP/authentication service with cancellable requests and a captured ownership token; every typed feature must validate that token after asynchronous work. Kotlin can expose this through coroutine-scoped clients; Expo can use an AbortController plus an immutable generation object. A cancelled promise is not evidence that a remote mutation was cancelled.

Use byte-based Base64/UTF-8 APIs, preserve null versus omitted fields, and avoid JavaScript UTF-16 length where the contract counts UTF-8 bytes or Unicode scalars. Validate integer ranges before using JavaScript numbers; native routes cap safe counters at 9,007,199,254,740,991. Serialize request bodies once when computing hashes or retaining intent payloads. Do not recompute a different request token on retry.

A native WebRTC module is needed for live voice; Expo Go alone does not provide this app's native audio peer, raw PCM playback or authenticated custom-header WebSocket behavior on every platform. Build equivalent platform integrations behind the same wire contract. Device tools, Contacts/Calendar writes, secure storage and background notification handling likewise require platform implementations; advertising a renderer or capability commits the client to its actual behavior.

Validation evidence in this chapter is source and fixture review, not a run against a user's host or physical Android/iOS device. Useful app regression suites include `DirectHermesNativeContextTests`, `DirectHermesConditionalOwnershipTests`, `DirectHermesNativeAttachmentTests`, `DirectHermesGeneratedMediaTests`, `DirectHermesManagedFilesTests`, `DirectHermesVoiceClientTests`, `DirectHermesVoiceMediaTests`, `DirectHermesKanbanTransportTests`, `DirectHermesWikiClientTests`, and the workflow fixture suites. No plugin installation/restart or real provider operation is needed to inspect these contracts.
