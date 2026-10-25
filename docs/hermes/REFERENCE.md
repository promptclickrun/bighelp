# Stock Hermes management reference

This is the platform-neutral reference for the stock Hermes dashboard HTTP and gateway JSON-RPC calls used by bighelp. An Android implementation can use the same methods, field names, IDs and response variants. Read [CONNECTION.md](CONNECTION.md), [CHAT.md](CHAT.md) and [EXTENSIONS.md](EXTENSIONS.md) alongside it for connection/authentication, live chat, and the companion plugin. The audited client is the code in this repository; this is not an exhaustive statement of every upstream Hermes API.

## Reading the tables

`Q` means URL query parameters, `B` a JSON object body, and `P` a JSON-RPC `params` object. `?` marks an optional field. Paths are relative to the authenticated dashboard origin; insert a properly percent-encoded path component for `{id}`, `{name}`, `{profile}` and `{provider}`. JSON field names are case sensitive. A method without parameters sends an empty object for RPC. HTTP methods without a body omit it unless `{}` is shown.

**Wire versus client policy:** the request fields below are the exact fields the app sends or permits. `WorkspaceOperation` names are local application operations, not a separate protocol. Its registry rejects unknown fields before dispatch; it does not prove upstream rejects those fields. Response fields below describe what the current decoder consumes, including accepted older variants; fields that the decoder ignores can exist on the wire. Client review tokens, local SHA-256 fingerprints, revision hashes and confirmation tokens are not server concurrency controls unless explicitly listed in a request.

**Semantics:** R = read, M = mutation, D = deletion/destructive mutation, J = starts a background action. A successful launch/HTTP acknowledgement does not establish completion. Mutations with a lost response have an unknown outcome until readback establishes what happened. Do not automatically replay them. Recheck the active connection/host identity before dispatch and after every success or failure; results from a retired host must never update a new host's state.

**Capability gates:** the neutral capability names in this document belong to the app. Most typed adapters check them before sending. The central route registry itself is a fixed mapping, not a general capability authorization layer. Several direct administration clients have owner checks and endpoint probing but no `WorkspaceCapability` check; those are marked **endpoint**. Do not invent a server-advertised capability from a local UI flag. Capability names in read rows identify the neutral feature association; they do not assert that each low-level reader calls `require`. Specifically, session catalog reads/edits and Project catalog reads perform owner checks without their own capability test; scheduled-task detail/runs require `schedulesRead`, while its list method performs owner-checked requests. Profile-service operations explicitly require their supplied capability. Scheduled-task mutations, Project mutations and session-folder moves explicitly require the mutation capability shown. The parent management UI can apply additional availability checks.

Sources: [workspace route registry](../../Bighelp/DirectHermes/DirectHermesWorkspaceClient.swift), [operation names](../../Bighelp/Workspace/WorkspaceOperation.swift), [core request scope](../../Bighelp/DirectHermes/DirectHermesCoreRequestScope.swift), [neutral capabilities](../../Bighelp/Workspace/WorkspaceCapabilities.swift).

## Discovery, availability and bounds

| Wire call | Request | Consumed response | Semantics |
|---|---|---|---|
| `GET /api/health` | none | `ok: true`, `auth_required: boolean`; metadata never gates features | R; unauthenticated health is not proof that authenticated access works |
| RPC `gateway.capabilities` | `{}` | **required** `per_session_exclusive_submit: boolean` | R; malformed/missing boolean fails discovery |

`DirectHermesCapabilityManifest` derives the following local allowlist from that single host boolean; it does **not** decode an arbitrary server-provided operation list:

| Availability | Neutral capabilities |
|---|---|
| Available regardless of exclusive submit | `profilesRead`, `sessionsRead`, `modelsRead`, `schedulesRead`, `projectsRead`, `systemStatus`, `skillsRead`, `usageRead`, `logsRead`, `memoryRead`, `personalitiesRead`, `toolsetsRead`, `pluginsRead`, `mcpServersRead`, `messagingPlatformsRead`, `webhooksRead`, `configRead`, `keysRead`, `filesRead`, `dashboardRead`, `dashboardEdit`; `profilesCreate`, `profilesEdit`, `profilesClone`, `agentDefaultsEdit`, `skillsEdit`, `personalitiesEdit`, `voiceOutput`, `configEdit`, `keysEdit`, `webhooksEdit`; `canonicalAgentChat`, `sessionsCreate`, `sessionsEdit`, `chatStop`, `chatSteer`, `approvalsRead`, `approvalsRespond`, `clarificationRespond`, `subagentsRead`, `subagentTail`, `subagentStop`, `subagentSteer`, `attachmentsUpload`, `sessionModelEdit`, `reasoningEdit`, `sessionsFork` |
| Available only when `per_session_exclusive_submit == true` | `chatSend`, `chatQueue`, `slashCommands` |
| When exclusive submit is false | Those three are unavailable with `unsupportedHost`; other capabilities outside the derived list use `unsupportedOperation` |

In particular, `schedulesEdit` and `schedulesRun` are **not** granted by this stock manifest even though cron routes and typed implementations exist. Capability installation/composition may supply availability separately. Do not infer permission to mutate from the existence of a GET route.

The shared HTTP transport clamps a caller-requested timeout to 1…75 seconds (default request timeout 20 s), including provider-refresh 120 s and registry TTS warm-up 180 s requests; these larger requested values are not the effective wire timeout. The shared core scope limits encoded operation payloads to 524,288 bytes and projected results to 2,097,152 bytes. The route registry separately validates raw request JSON at 1,048,576 bytes, except avatar writes at 2,800,000 bytes. Individual direct HTTP clients have their own response/request bounds stated where material. Identifier checks are client policy: profile IDs up to 128 UTF-8 bytes, excluding `all`, `.`, `..`, `/` and `\`; ordinary identifiers up to 160 bytes without `/` or `\`. Registry path identifiers allow ASCII letters, digits, `-_.:` up to 512 bytes, excluding `.` and `..`. Query values are strings/integers/booleans, booleans encoded as `true`/`false`, at most 4,096 UTF-8 bytes each; arrays are not automatically encoded as repeated query fields.

Sources: [manifest](../../Bighelp/DirectHermes/DirectHermesCapabilityManifest.swift), [release contract](../../Bighelp/DirectHermes/DirectHermesReleaseContract.swift), [scope](../../Bighelp/DirectHermes/DirectHermesCoreRequestScope.swift). Tests: [protocol parity](../../BighelpTests/DirectHermesProtocolParityTests.swift), [workspace routing](../../BighelpTests/DirectHermesWorkspaceClientTests.swift), [conditional ownership](../../BighelpTests/DirectHermesConditionalOwnershipTests.swift).

## Profiles, agents and appearance

| Call | Request fields | Response consumed / verification | Semantics; gate |
|---|---|---|---|
| RPC `profiles.list` | P `include_sessions?: boolean` | `{profiles:[Profile]}`. Profile directory requires `name,is_default:boolean,has_avatar:boolean`; also consumes `display_name?`, `description?`, `ui_meta?`, `ui_meta_revisions?`, `canonical_session?` (see catalog below). Lifecycle REST has a stricter inventory below. | R; `profilesRead` |
| RPC `profiles.describe` | P `name` | Object passed through by registry; the current directory service uses `profiles.list` plus SOUL/avatar reads instead and does not define a separate describe-response decoder. | R; `profilesRead` |
| RPC `profiles.create` | P `name`; optional `clone_from`, `clone_all`, `no_alias`, `mirror_credentials`, `description`, `no_skills` | Client requires `ok:true,name` exact and `mirrored:{env:false,auth:false,model_inherited:false,voice:false}` for credential-isolated creation, then reloads profiles. Clone treats a missing/non-false mirrored field as a partial credential-policy outcome. Local `profiles.clone` maps to this same method. | M; `profilesCreate` / `profilesClone` |
| RPC `profiles.configure` | P `name`; optional `description`, `soul`, `model`, `provider`, `confirm_expensive_model`, `ui_meta`, `ui_meta_expected_revisions` | `applied:{description?:boolean,ui_meta?:boolean,ui_meta_conflicts?:…}` is required for metadata edits; model changes may return `confirm_required:true,confirm_message`. Readback confirms exact changed fields. | M; `profilesEdit` or `agentDefaultsEdit` |
| `GET /api/profiles/{profile}/soul` | none | `content:string`, `exists:boolean` (missing SOUL requires empty content) | R; `profilesRead` |
| `PUT /api/profiles/{profile}/soul` | B `content` (≤524,288 UTF-8 bytes at registry) | `ok:true`, then content/exists readback | M; `profilesEdit` |
| RPC `profiles.get_asset` | P `name`, `asset:"avatar"` | `found:boolean`; when found `data` (data URL), `mime`, `size` are decoded as avatar bytes | R; `profilesRead` |
| RPC `profiles.set_asset` | P `name`, `asset:"avatar"`; exactly one of `data:string` or `clear:true` | `ok:true,asset:"avatar",size` exact; reload avatar | M; `profilesEdit` |
| RPC `pet.gallery` | P `localOnly?` | `{pets:[{slug,displayName?,spritesheetUrl?,installed?:boolean,curated?:boolean}]}`; malformed/duplicate rows skipped, max 10,000 | R; `profilesRead` |
| RPC `pet.thumb` | P `slug`, `url?` | `{ok:true,dataUri:base64DataURI}`; first-frame thumbnail max 600,000 decoded bytes | R; `profilesRead` |

Native avatars/placement use the `hermes-bots` namespace: `ui_meta:{"hermes-bots":{…}}`, `ui_meta_expected_revisions:{"hermes-bots":nonnegativeRevision}`. Reads use `ui_meta_revisions["hermes-bots"]` (missing revision support is unavailable, missing namespace revision defaults zero); namespace ≤65,536 encoded bytes. Title/summary come from namespace `title,description` before profile display/description fallbacks; do not replace unrelated namespaces. Cloning is multi-step: copy profile, copy SOUL/avatar/look as selected, optionally share plugin links through the companion plugin. A partial clone does not imply all follow-up copies succeeded.

The endpoint-based lifecycle client additionally implements:

| HTTP/RPC call | Request | Response consumed | Semantics / scope |
|---|---|---|---|
| `GET /api/profiles` | none | `{profiles:[{name,is_default:boolean,skill_count:integer,has_env:boolean,has_alias:boolean,gateway_running:boolean,description_auto:boolean,display_name?,description?,provider?,model?,distribution_name?,distribution_version?,distribution_source?,path?}]}`. Host-operation discovery specifically requires `name,path`. | R; endpoint |
| `GET /api/profiles/active` | none | `active:string`, `current:string` | R; default/serving identities are distinct |
| `PATCH /api/profiles/{profile}` | B `new_name` | `ok:true`, `name` equals requested destination; reload inventory | M; endpoint; revalidate reviewed row, active and current profile |
| `DELETE /api/profiles/{profile}` | none | `ok:true`; inventory confirms absence | D; endpoint; current/default protections are local and rechecked |
| `POST /api/profiles/active` | B `name` | `ok:true`, `active` matches; reload active snapshot | M; changes default, not current connection |
| `POST /api/profiles/{profile}/export` | B `output:string`, `extra_files:{}` | `ok:true`, `archive:string` | M; writes an archive on host, not an HTTP download |
| `POST /api/profiles/import` | B `archive:hostPath`, `name?` | `ok:true`, `name`; reload inventory | M; imports a host-side archive |
| `POST /api/profiles/{profile}/describe-auto` | B `overwrite:boolean` | `ok:boolean`, `reason:string`, `description_auto:boolean`, `description?` | M; can run a model; readback profile |
| `GET /api/profiles/{profile}/setup-command` | none | `command:string` | R; displayed command is not executed by transport |
| RPC `profiles.remember_onboarding` | P `profile`, `answers:{name,context,focus:[string],connectors:[string],theme,accent,layout}` | `saved:true`, `profile` exact, `target:"user"` | M; saves onboarding facts to user memory |

Petdex source: [gallery policy and thumbnail bounds](../../Bighelp/Agents/Petdex/PetdexGallery.swift).

Sources: [directory](../../Bighelp/DirectHermes/DirectHermesAgentDirectoryClient.swift), [profile service](../../Bighelp/DirectHermes/DirectHermesAgentProfileService.swift), [clone](../../Bighelp/DirectHermes/DirectHermesAgentProfileCloneClient.swift), [lifecycle](../../Bighelp/DirectHermes/DirectHermesProfileLifecycleClient.swift). Tests: [agent adapter](../../BighelpTests/DirectHermesAgentAdapterTests.swift), [capability clients](../../BighelpTests/DirectHermesCapabilityClientsTests.swift).

## Durable session catalog and history

A durable session row ID, a runtime session ID, a compaction lineage ID and a visible app row ID are different identities. HTTP catalog/history reads use durable IDs. Live controls use an explicitly established runtime. Never use a REST `is_active` flag to infer ownership of a live runtime, and never create or resume a session just to discover activity.

| Call | Request | Response / variant | Semantics; gate |
|---|---|---|---|
| `GET /api/sessions` | Q `profile?`, `limit?`, `offset?`, `archived?`, `order?`, `source?`, `sources?`, `exclude_sources?`, `cwd_prefix?` | New envelope `{object:"list",data:[Session],has_more:boolean,limit,offset,total?:integer\|null}`; older `{sessions:[Session],total:integer,limit,offset}` with no `object`, `data` or `has_more`. `limit` 1…200, `offset≥0`. | R; `sessionsRead` |
| `GET /api/sessions/{id}` | Q `profile?` | New `{object:"hermes.session",session:Session}` or older bare Session. `id` required; request profile fills an omitted response profile but a mismatched profile fails. | R; `sessionsRead` |
| `GET /api/sessions/search` | Q `q`, `profile?`, `limit?`, `source?`, `sources?`, `exclude_sources?` | `{results:[SessionSearch]}`; row ID may be `id` or `session_id`; `snippet?`. Search client requires exact profile and at most requested limit. | R; `sessionsRead` |
| `GET /api/sessions/{id}/messages` | Q `profile?`, `limit?`, `offset?`, `order?`, `include_compacted?` | `{session_id,profile?,messages:[HistoryRow]}` or `data:[HistoryRow]`; required `pagination:{offset,limit,order,returned}` exactly matches request and actual count. Returned durable ID can be authoritative after compaction. | R; `sessionsRead` |
| RPC `session.list` | P `profile`, `title?`, `include_hidden?`, `limit?`, `offset?` | `{sessions:[…]}`; used to resolve hidden `Bot Chat`, not as a replacement for durable HTTP pagination | R; `sessionsRead` |
| RPC `session.active_list` | P `profile?`, `current_session_id?` | Exactly `{sessions:[{id,session_key,title,preview,started_at,last_active,message_count,model,status,current}]}` in the active-session decoder. `id` is runtime, `session_key` durable. `status` = `idle\|starting\|waiting\|working\|streaming\|resuming`; `current:boolean`. | R; live inventory |
| RPC `session.most_recent` | P `profile` | `session_id:string\|null`; optional `title`, `started_at`, `source`; client confirms durable detail | R; endpoint |

Consumed Session fields are `id:string`, `profile:string`, `started_at:date`, `last_active?:date` (fallback `last_activity_at`, then started), `source?:string`, `title?:string`, `preview?:string`, `message_count?:integer`, `pinned?:flag`, `cwd?:string`, `_lineage_root_id?:string`, `_lineage_ids?:[string]`. Maintenance additionally consumes `archived`, `hidden`, `is_active`, `ended_at`. Catalog flag compatibility accepts boolean or integer 0/1 (absent/null = unspecified); other values fail. Catalog dates are Unix seconds, nonnegative and no later than year 9999. Consumers must not equate a malformed value with true. Dates are Unix seconds or ISO-8601 where the feature decoder permits them.

The catalog loads profiles with `include_sessions:true`; each profile's `canonical_session` is null/absent or `{id,resolved_id?}`. Bot Chats are hidden from HTTP session listing, so merge each profile's canonical registry separately. A registry ID may differ from its resolved compaction successor. The normal list asks each profile for `limit=100`, ascending offset pages, `archived=include`, `order=created` by default (`created|recent` are supported choices), default `exclude_sources:"tool,kanban,bot_room"` and no positive source filter. Archive choices are `exclude|only|include`. `sources` and `exclude_sources` are comma-joined strings (≤32 distinct supplied values per list option); `cwd_prefix` is a host path. Pagination authority is `has_more`, then `offset+limit<total`, then full page fallback. Legacy pinned back-fill duplicates are skipped; unexplained duplicates indicate a changing catalog. Preserve auto-archived rows (`archived` and `auto_archived`), while deliberately archived rows belong in Archived Chats.

History rows and tool-result projection are specified in [CHAT.md](CHAT.md). Fetching a page and rendering a timeline are different operations: preserve row IDs, raw tool messages and compaction lineage; never feed projected user-visible text back as raw host history.

Sources: [catalog](../../Bighelp/Hermes/DirectHermesSessionCatalogClient.swift), [pagination](../../Bighelp/Hermes/DirectHermesSessionCatalogClient+ListRequest.swift), [identity models](../../Bighelp/Hermes/DirectHermesSessionModels.swift), [history projection](../../Bighelp/Hermes/DirectHermesHistoryProjection.swift). Tests: [catalog](../../BighelpTests/DirectHermesSessionCatalogClientTests.swift), [catalog rows](../../BighelpTests/DirectHermesSessionCatalogRowTests.swift), [history](../../BighelpTests/DirectHermesHistoryProjectionTests.swift), [scale](../../BighelpTests/DirectHermesCatalogListScaleTests.swift).

### Editing and maintenance

| Call | Request | Required receipt/readback | Semantics |
|---|---|---|---|
| `PATCH /api/sessions/{id}` | B `profile`, optional `title`, `archived`, `hidden`, `pinned`, `unread`, `request_id`, `expected_revision`, `expected_generation` | `ok:true`, changed fields; reload detail. HTTP 403/404/409 can carry `revision_conflict`, `client_upgrade_required`, `not_found` and other named refusal reasons. | M; `sessionsEdit` |
| `DELETE /api/sessions/{id}` | Q `profile`, optional edit fence fields | `ok:true`; confirm absence | D; `sessionsEdit` |
| RPC `session.title` | P `session_id`, `title` | `pending:false`, `title` exact | M; runtime title path |
| RPC `session.set_hidden` | P `session_id`, `hidden:boolean`, `profile?` | Maintenance consumes `session_key` exact and `hidden` exact; reload detail | M; accepts durable fallback ID |
| RPC `session.archive` | P `session_id`, `archived:boolean`, `profile?` | `ok:true`; reload catalog | M; stored row path for socket-created chats |
| RPC `session.delete` | P `session_id`, `profile?` | `ok:true`, `already_absent?:boolean`; missing row RPC 4007 is recognized | D; native stored row deletion |
| RPC `session.close` | P `profile`, `session_id:runtimeID` | `closed:boolean`; active list no longer contains runtime/durable pair, durable detail retains messages | M; closes an idle runtime, not saved history |
| `GET /api/sessions/stats` | Q `profile` | `total`, `active_store`, `archived`, `messages`, `by_source:{source:count}`; empty-ended count separately queried | R; endpoint |
| `GET /api/sessions/empty/count` | Q `profile` | `count:integer` | R |
| `POST /api/sessions/owner-backfill` | B `profile` | `ok:true`, `profile`, `stamped≥0`; a second idempotent call must stamp zero | M |
| `POST /api/sessions/bulk-delete` | B `profile`, `ids:[string]` | `ok:true`, `deleted == ids.count`; each row must be absent | D; revalidate reviewed detail documents |
| `DELETE /api/sessions/empty` | Q `profile` | `ok:true`, `deleted` equals reviewed count; empty count becomes zero | D |
| `POST /api/sessions/prune` | B `profile`, `dry_run:boolean`, `source?`, `older_than_days?`, `include_archived` | Dry run `ok:true,removed:0,sessions:[Session],matched,skipped_open,oldest_last_active?,newest_last_active?`; commit `ok:true,removed` equals reviewed matches | R when dry-run; D otherwise; compare full dry-run again before delete |
| `GET /api/sessions/{id}/export` | Q `profile` | Session object with exact `id`, `messages:[…]`; client wraps locally as `{schema:1,profile,sessions:[…]}` | R; exported wrapper is local, not HTTP envelope |
| `POST /api/sessions/import` | B `profile`, `sessions:[SessionExport]` | `ok:true`, `imported_ids`, `skipped_ids`, `detached`, `imported`, `skipped`; union matches submitted IDs, reload imported detail | M; wrapper `schema` is not posted |
| `GET /api/sessions/{id}/latest-descendant` | Q `profile` | `requested_session_id`, `session_id`, `path:[string]`, `changed:boolean`; path starts at requested, ends at latest | R; compaction lineage |

Maintenance limits the full catalog to 10,000 rows, bulk selection to 500 IDs and session export/import to 26,214,400 bytes. It lists REST pages with `archived=include,order=recent,full=false`, then supplements hidden native rows; this direct maintenance decoder currently expects the legacy `sessions,total` envelope, unlike the compatibility-normalized general catalog.

An HTTP edit fence is optional at the route registry: `request_id` must be lowercase UUID and accompany a nonnegative integer `expected_revision`; `expected_generation` is nonnegative and allowed only with that pair. The **wire** fence is different from local reviewed snapshots. Socket-created chats can refuse dashboard edits; the editor selects native methods using host row metadata and operation support, rather than blindly retrying a failed destructive route.

Sources: [session editor](../../Bighelp/Hermes/DirectHermesSessionEditor.swift), [maintenance](../../Bighelp/DirectHermes/DirectHermesSessionMaintenanceClient.swift). See [CHAT.md](CHAT.md) for create/resume/activate/fork, live model controls and session replay.

Foreign session migration uses RPC `session.foreign.list` with `{profile,offset,limit,source?}` (`limit` 1…50), returning `{host,unreadable,next_offset?,sessions:[{id,source,label,title,turn_count,excerpt,cwd?,mtime?}]}`. The opaque foreign `id` is not a filesystem path. `session.foreign.preview {profile,id}` returns `{messages:[{role,content}],total,truncated,already_imported?:durableID,cwd?}` (at most 40 preview messages). After comparing a fresh preview to the locally reviewed preview, `session.foreign.import {profile,id}` returns `{session_id,already_imported?:boolean}`. Confirm both the foreign preview's `already_imported` durable ID and the new durable detail. This imports data; it does not create an active runtime.

The prune body also supports optional `started_before`, `started_after` (Unix seconds), `title_like`, `end_reason`, `cwd_prefix`, `model_like`, `provider`, `user_id`, `chat_id`, `chat_type`, `branch_like`, `min_messages`, `max_messages`, `min_tokens`, `max_tokens`, `min_tool_calls`, `max_tool_calls` (nonnegative integers), `min_cost`, `max_cost` (finite nonnegative numbers). `older_than_days` is sent as number or null; when specified the client range is 1…365,000. These are server fields; the review token is local.

## Configuration and runtime defaults

| Call | Request | Response / behavior | Semantics; gate |
|---|---|---|---|
| `GET /api/config` | Q `profile?`, `include_defaults?` | Root configuration object, not a `{config:…}` wrapper | R; `configRead` |
| `PUT /api/config` | B `profile`, `config:{…}` | `ok:true` or feature-specific acknowledgement; deep-merges supplied namespaces, so omitting an existing map key does not delete it | M; `configEdit` |
| RPC `config.get` | P `key`, optional `profile`, `session_id`, `scope` | `key`, `value`, `scope?`; supported current keys below | R; model/reasoning/default readers |
| RPC `config.set` | P `key`, `value`, optional `profile`, `session_id`, `scope`, `confirm_expensive_model` | `key,value,scope?`, `confirm_required?`, `confirm_message?`, `deferred?`; validate value and scope, then read proof | M; `sessionModelEdit`, `reasoningEdit`, `agentDefaultsEdit` or applicable setting gate |
| `GET /api/config/raw` | Q `profile?` | `{yaml:string,path:string}` | R; endpoint; raw YAML can contain private configuration |
| `PUT /api/config/raw` | Q `profile`; B `yaml_text` | `ok:true`, then reload `yaml,path`; YAML need not preserve byte-for-byte formatting | M; endpoint; ≤262,144 UTF-8 bytes; re-read baseline before save |

Registry `config.get/set` key policies (local allowlist):

- `model` and `reasoning`: `scope` omitted, `global`, or `session` with `session_id`; `model` **writes** require a session ID (profile default model writes use `profiles.configure` or `/api/model/set`).
- `fast`: requires profile; writes use `{scope:"session",session_id}` or `{scope:"global"}` without session ID; values `on|off|fast|normal`.
- `yolo`: write only, profile and session ID required, `scope:"session"`, value `on|off`.
- `display.message_reactions`: profile-level request without session ID/scope.
- `terminal.cwd`: profile-level write without session ID/scope; absolute host path ≤4,096 bytes, no control characters.

Agent-default reads ask `/api/config?profile=…&include_defaults=false` and locally project only `agent.{reasoning_effort,service_tier}`, `delegation.{provider,model,reasoning_effort}`, `cron.{model,model_provider}`. `delegation.has_base_url_override` is **locally synthesized** from a nonempty `delegation.base_url`; do not post it. Allowed default writes are `config.agent.reasoning_effort:""` (clears legacy default), `config.delegation.{provider,model,reasoning_effort}`, `config.cron.{model,model_provider}`, string values ≤512 bytes. Runtime defaults separately call `config.get/set` for reasoning/fast and `profiles.configure` for the main provider/model.

Personality configuration uses `GET /api/config`; the active name is `display.personality`, definitions merge root `personalities` with `agent.personalities` (agent wins). A definition may be a prompt string, an array of strings joined by newlines, or `{system_prompt|systemPrompt,description?,tone?,style?}`. Save sends `PUT /api/config {profile,config:{agent:{personalities:{name:{system_prompt,description,tone,style}}}}}`; activate sends `{profile,config:{display:{personality:name}}}`. Built-in definitions are not guessed. Delete and rename are unsupported because deep merge cannot remove old map keys. The catalog fingerprint/revision and the immediate baseline comparison are local, not conditional server writes.

Sources: [runtime defaults](../../Bighelp/DirectHermes/DirectHermesAgentRuntimeDefaultsClient.swift), [personality adapter](../../Bighelp/DirectHermes/DirectHermesCapabilityClients.swift), [raw config](../../Bighelp/DirectHermes/DirectHermesHostOperationsClient+Configuration.swift), [session control](../../Bighelp/DirectHermes/DirectHermesSessionControlClient.swift). Tests: [session control](../../BighelpTests/DirectHermesSessionControlClientTests.swift), [capability management](../../BighelpTests/CapabilityManagementStateTests.swift).

## Models, providers and credentials

These direct administration clients are **endpoint** gated and owner bound. Their profile-specific methods send profile explicitly. Methods called “serving” below intentionally have no profile on the wire: require equality of selected profile and independently established serving profile before calling them.

| Call | Request | Consumed response | Semantics |
|---|---|---|---|
| `GET /api/model/options`, fallback RPC `model.options` | Q/P `profile`, `refresh:boolean`, `include_unconfigured:boolean`, `explicit_only:false`; RPC also supports `session_id?` in registry | `{providers:[ModelProvider]}` | R; management shows configured models (`include_unconfigured:false`), credentials UI includes unconfigured (`true`). HTTP failure except cancellation falls back to same RPC payload. Provider refresh requests 120 s, clamped by the shared HTTP transport to 75 s. |
| `GET /api/model/info` | Q `profile` | `provider`, `model`, `auto_context_length`, `config_context_length`, `effective_context_length` (nonnegative integers), `capabilities?` | R |
| `GET /api/model/recommended-default` | Q `provider` | `provider` exact, `model`, `free_tier?:boolean` | R |
| `GET /api/model/auxiliary` | Q `profile` | `main:{provider,model}`, `tasks:[{task,provider,model,base_url,local_endpoint:boolean}]` | R |
| `POST /api/model/set` | B `profile,scope,provider,model,task,base_url:"",api_key:"",confirm_expensive_model:boolean,reasoning_effort?` | Either `{confirm_required:true,confirm_message}` or `{ok:true}`; read main/auxiliary back to confirm | M; `scope:"main",task:""`; auxiliary uses `scope:"auxiliary",task:<task>`; reset uses `task:"__reset__",provider:"auto",model:""` |
| `GET /api/model/moa` | Q `profile` | `default_preset`, `active_preset`, `presets:{name:MoAPreset}`, `privacy_filter?` | R |
| `PUT /api/model/moa` | Q `profile`; B `profile,default_preset,active_preset,presets` | `ok:true`; reload full document and compare | M; full document write; app refuses nonempty existing `privacy_filter` because write schema cannot preserve it |
| `GET /api/analytics/models` | Q `profile`, `days` (1…365) | Model analytics below | R |
| RPC `setup.status` | P `profile` | `profile?`, `provider_configured?`, `ready?`, `free_tier?`, `other_providers?`, `inference_provider?`, `ok?` (defaults true), `error?` | R |
| RPC `setup.runtime_check` | P `profile`, `provider?` | `ok:boolean`, `provider?`, `model?`, `source?`, `free_tier?`, `profile?`, `error?` | R; nonpersistent readiness check |
| `GET /api/env` | Q `profile` | Object keyed by environment name; each value `{provider?,provider_label?,description?,category?,is_set:boolean,is_password:boolean,advanced:boolean,custom?,channel_managed?}` | R; values/secrets are not returned by this projection |
| `POST /api/providers/validate` | B `profile,key,value,api_key` (companion key may be `""`) | `{ok:boolean,reachable:boolean,message,models?:[string]}` | R/probe; verifies candidate without saving |
| `PUT /api/env` | B `profile,key,value` | Acknowledgement then GET confirms key `is_set:true` | M; app validates candidate first; value ≤16,384 bytes |
| `DELETE /api/env` | B `profile,key` | Acknowledgement then GET confirms unset | D; key grammar ASCII uppercase/digits/underscore, ≤128 bytes |
| `GET /api/providers/custom-endpoints` | Q `profile` | `{endpoints:[{id,name,base_url,model,models:[string],context_length?,discover_models:boolean,has_api_key:boolean,is_current:boolean,source}]}` | R |
| `POST /api/providers/custom-endpoints/validate` | B CustomEndpointDraft below | Validation result `{ok,reachable,message,models?}` | R/probe |
| `POST /api/providers/custom-endpoints` | Q `profile`; B CustomEndpointDraft | `ok:true,id`; list confirms saved row | M |
| `POST /api/providers/custom-endpoints/{id}/activate` | Q `profile` | `ok:true,provider == id`; list confirms `is_current:true` | M |
| `DELETE /api/providers/custom-endpoints/{id}` | Q `profile` | List confirms absence | D |
| `GET /api/credentials/pool` | none | `{providers:[{provider,entries:[{index≥1,id,label,auth_type,source,priority,last_status?,request_count≥0,has_refresh:boolean}]}]}` | R; serving scope |
| `POST /api/credentials/pool` | B `provider,api_key,label?` | `ok:true,provider,count`; list count must increase by one | M; serving scope |
| `DELETE /api/credentials/pool/{provider}/{index}` | none | Reload pool; reviewed entry ID absent | D; serving scope; index is 1-based |
| RPC `model.save_key` | P `slug,api_key` | `{provider:ModelProvider}` with matching slug and `authenticated:true`; refresh list confirms | M; serving scope |
| RPC `model.disconnect` | P `slug` | `slug` exact, `disconnected:true`; refresh provider readback | D; serving scope |
| `GET /api/portal` | none | `logged_in:boolean`, `portal_url?`, `inference_url?`, `provider`, `free_tier:boolean`, `account_tier?`, `subscription_url?`, `features:[{label,state}]` | R; serving account status |

ModelProvider fields consumed across clients: `slug`, `name`, `models?:[string]`, `unavailable_models?:[string]`, `is_current?:boolean` (false default), `is_user_defined?:boolean` (false default), `authenticated?:boolean`, `auth_type?:string`, `free_tier?:boolean`, `key_env?:string`, `total_models?:integer` (falls back to model array count). Provider/model IDs remain host supplied; provider display names are not identity. Model capabilities: `{supports_tools?:boolean,supports_vision?:boolean,supports_reasoning?:boolean,context_window?:integer,max_output_tokens?:integer,model_family?:string}`. Missing capabilities are unknown, not false.

CustomEndpointDraft: `{id:string}` (empty for new), `name`, `base_url`, `model`, `models:[string]`, `discover_models:boolean`, `make_default:boolean`, optional `context_length:positive integer`, `api_key:string`. URL is HTTP(S), no embedded user/password, query or fragment; trailing `/` is stripped locally. There is no profile field inside this body; save uses the query.

MoAPreset: `{reference_models:[{provider,model,reasoning_effort?,enabled?:boolean}],aggregator:{provider,model,reasoning_effort?},reference_temperature:number|null,aggregator_temperature:number|null,reference_timeout:number|null,degraded_reference_policy:"loud"|"silent",fanout?:string,enabled:boolean}`. At least one reference per preset, at most 32; at most 64 presets. Nested provider `moa` is refused locally. Default and nonempty active preset must exist in `presets`.

Model analytics: `{period_days,models:[{provider,model,input_tokens?,output_tokens?,cache_read_tokens?,reasoning_tokens?,estimated_cost?,actual_cost?,sessions?,api_calls?,tool_calls?,last_used_at?,avg_tokens_per_session?,capabilities?}],totals:{distinct_models?,total_input?,total_output?,total_cache_read?,total_reasoning?,total_estimated_cost?,total_actual_cost?,total_sessions?,total_api_calls?}}`. Counts/costs absent in current projection default to zero; `period_days` must match requested days. Do not equate estimated and actual cost.

### Provider OAuth

These are Hermes **provider** sign-in flows, separate from dashboard/browser authentication and companion provider sign-in routes.

| Call | Request | Response consumed | Semantics |
|---|---|---|---|
| `GET /api/providers/oauth` | Q `profile` | `{providers:[{id,name,flow,docs_url?,disconnectable:boolean,status:{…}}]}` | R |
| `POST /api/providers/oauth/{provider}/start` | Q `profile` | `session_id`, `expires_in:positive integer`, `flow`; device flow requires `verification_url,user_code,poll_interval`; PKCE requires `auth_url` | M; starts ephemeral flow |
| `GET /api/providers/oauth/{provider}/poll/{session_id}` | Q `profile` | `session_id` exact, `status`, `expires_at?`, `error_message?`, `reason?`, `account_email?`, `model?` | R; poll interval locally clamped to 2…30 s for device flow, 2 s for PKCE |
| `POST /api/providers/oauth/{provider}/submit` | Q `profile`; B `session_id,code` | `ok:boolean,status,message?`; accepted combinations `true/approved` or `false/error`; approved is confirmed in provider list | M; one-time PKCE code, do not retain |
| `DELETE /api/providers/oauth/sessions/{session_id}` | Q `profile` | `ok:true` | M; cancel flow |
| `DELETE /api/providers/oauth/{provider}` | Q `profile` | `ok:true,provider` exact; list confirms not logged in | D; disconnect provider |

Provider flow is `device_code|pkce`; unknown flow disables start rather than guessing. Provider list also consumes `disconnect_hint?`, `cli_command?` (printable single line) and `status:{logged_in:boolean,source?,source_label?,expires_at?,has_refresh_token?,free_tier?,account_tier?,error?}`; OAuth URLs must be HTTPS. Start expirations are capped locally at 86,400 seconds. Poll statuses are `pending|approved|denied|expired|error|cancelled|unknown`; unrecognized values map to unknown, never approved.

Sources: [providers](../../Bighelp/DirectHermes/DirectHermesProviderClient.swift), [model administration](../../Bighelp/DirectHermes/DirectHermesModelAdministrationClient.swift), [administration codec](../../Bighelp/DirectHermes/DirectHermesAdministrationCodec.swift). Tests: [workspace management](../../BighelpTests/WorkspaceManagementTests.swift), [model display fixture](../../BighelpTests/Fixtures/hermes-model-options-provider-display-names.json).

### Local model runtime

All routes below are unscoped, owner bound and **endpoint** gated. They manage the host's runtime; they do not change a selected profile merely by listing downloaded models.

| Call | Request | Response consumed | Semantics |
|---|---|---|---|
| `GET /api/local-models/status` | none | LocalStatus below | R |
| `GET /api/local-models/hardware` | none | `uma:boolean`, `vram_total_bytes`, `vram_usable_bytes`, `ram_total_bytes`, `ram_available_bytes`, `vram_label`, `gpu_name?`, `gpu_util_percent?`, `vram_used_bytes?` | R |
| `GET /api/local-models/catalog` | none | `{models:[LocalCatalogModel]}` | R |
| `GET /api/local-models/jobs` | none | `{jobs:[LocalJob]}` | R |
| `GET /api/local-models/jobs/{id}` | none | LocalJob | R; exact job ID |
| `GET /api/local-models/search` | Q `q`, `limit` | `{hits:[{repo,downloads,likes,updated,gated}]}` | R |
| `GET /api/local-models/search/files` | Q `repo` | `{files:[{paths:[string],fit,label,total_bytes}]}` | R |
| `POST /api/local-models/runtime/install` | B `backend:string\|null` | `job_id`, `backend?`; read job | J |
| `POST /api/local-models/quickstart` | B `model_id:string\|null` | `job_id,model_id,display_name,needs_runtime,needs_download,download_bytes`; job kind must be quickstart | J |
| `POST /api/local-models/download` | B `model_id` | `model_id,already_downloaded:boolean,job_id?`; already-downloaded and queued-job variants | J |
| `POST /api/local-models/download-browsed` | B `repo,paths:[string]` | Same download admission | J; validated GGUF paths |
| `POST /api/local-models/sideload` | B `path` | `ok:true,model_id`; status must show canonical staged model | M; host-local GGUF path, no phone upload |
| `POST /api/local-models/activate` | B `model_id` | `job_id`; read job with kind activate and matching model | J |
| `POST /api/local-models/eject` | B `model_id` | `ok:true`; status has neither loaded nor loading model | M |
| `DELETE /api/local-models/models/{id}` | none | `ok:true`; staged and loaded model absent | D |
| `POST /api/local-models/server` | B `action` | `ok:true,action` exact; status confirms expected running state | M; action `start\|stop` |

LocalStatus fields: `enabled`, `tag`, `configured_tag`, `update_available`, `runtime_installed`, `runtime_backend`, `server_running`, `active_model_id`, `models:[{id,size_bytes,size_label}]`, `models_dir`, `server_base_url?`, `loaded_models:{modelID:placementString}`, optional `placement:{modelID:{window?,window_label?,spilled?,granted_window?,granted_window_label?}}`, optional `loading:{modelID:{stage:string,value:number,percent:number}}`. Loading progress is observed host data, not a timer estimate.

LocalCatalogModel fields: `id,display_name,description,size_bytes,size_label,native_context,native_context_label,recommended,recommended_reason,downloaded,downloaded_model_id,downloaded_quant,mtp,vision,fits,fit_summary,fit_detail,model_id,quant,quant_reason,quant_validated,variant_count,start_window,start_window_label,spilled,needs_engine,min_engine`; optionality and defaults follow the feature decoder. LocalJob fields: `job_id,kind,status,started_at?,target,model_id?,phase,detail,total_bytes?,done_bytes,percent?,error?`. Kind = `model-activate|model-download|quickstart|runtime-install`; status = `running|done|error`. File-group fit = `fits-gpu|needs-ram|too-big|unknown`. A job's completion is checked from status, not inferred from obtaining `job_id`.

Source: [local model client and decoder](../../Bighelp/DirectHermes/DirectHermesLocalModelsClient.swift).

## Scheduled tasks (cron)

| Call | Request | Consumed response | Semantics; gate |
|---|---|---|---|
| `GET /api/cron/jobs` | Q `profile` | `{jobs:[Task]}` or bare `[Task]` (registry wraps the latter locally) | R; `schedulesRead` |
| `GET /api/cron/jobs/{id}` | Q `profile` | Task plus `last_run_at?`, `last_error?`, `model?`, `provider?` | R; `schedulesRead` |
| `GET /api/cron/jobs/{id}/runs` | Q `profile`, `limit` (1…100) | `{limit,runs:[{id,profile,source:"cron",started_at,last_active,is_active:boolean,archived:boolean,message_count,tool_call_count,title?,preview?,ended_at?,model?}]}` | R; `schedulesRead`; ID must start `cron_{jobID}_` |
| `GET /api/cron/delivery-targets` | none | `{targets:[{id,name,home_target_set:boolean}]}` | R |
| `POST /api/cron/jobs` | Q `profile`; B `schedule`, optional `prompt,name,paused,paused_reason,deliver,skills,model,provider,context_from,workdir` | Task; validate submitted name/prompt/delivery/schedule | M; `schedulesEdit` |
| `PUT /api/cron/jobs/{id}` | Q `profile`; B `updates:{…}` | Task; ID and submitted fields exact | M; `schedulesEdit`; body keeps `updates` wrapper |
| `POST /api/cron/jobs/{id}/pause` / `resume` | Q `profile` | Task; verify enabled/paused state | M; `schedulesEdit` |
| `POST /api/cron/jobs/{id}/trigger` | Q `profile` | Task with actual current state; may atomically resume a paused task | M; `schedulesRun`; admission is not final run success |
| `DELETE /api/cron/jobs/{id}` | Q `profile` | `ok:true`; list confirms absence | D; `schedulesEdit` |
| `GET /api/cron/blueprints` | none | `{blueprints:[Blueprint]}` | R; endpoint |
| `POST /api/cron/blueprints/instantiate` | Q `profile`; B `blueprint:key`, `values:{fieldName:string}` | Task; GET detail confirms exact identity | M; `schedulesEdit`; instantiate only an observed blueprint |

Task fields: `id,profile,name,prompt,deliver,enabled:boolean,state,schedule,schedule_display?,next_run_at?,last_status?,script?,skills?,no_agent?`. State `completed` → completed, `error` → failed; `scheduled|running|paused` uses `enabled` for active/paused. `schedule` is a string or `{kind:"cron",expr}`, `{kind:"once",run_at:ISO8601}`, `{kind:"interval",minutes:positive finite number}`. Dates accept Unix seconds or ISO-8601. `script` nonempty, `skills` nonempty or `no_agent:true` marks host-managed execution; the app does not silently rewrite such a task into a plain prompt.

Blueprint fields: `key,title,description,category,tags:[string],scheduleHuman,fields:[{name,type:"enum"|"text"|"time"|"weekdays",label,default?,options:[string],optional:boolean,strict:boolean,help}]`. Preserve host field types and strict options; values posted by this client are strings. Instantiation values JSON ≤65,536 bytes. The friendly task editor posts `name,prompt,schedule,deliver`; manual delivery identifiers containing `:` are resolved separately. Non-local generic delivery requires known serving-profile identity to avoid routing another profile's task through the serving profile by accident. Listing all agents is separate per-profile reads after `profiles.list {include_sessions:false}`, not `profile=all`, because all-profile upstream listing may suppress individual failures.

Sources: [task client](../../Bighelp/DirectHermes/DirectHermesScheduledTasksClient.swift), [codec](../../Bighelp/DirectHermes/DirectHermesScheduledTaskCodec.swift). Tests: [scheduled tasks](../../BighelpTests/DirectHermesScheduledTasksClientTests.swift).

## Projects, workspaces and repository organization

| RPC / HTTP call | Request | Consumed response | Semantics; gate |
|---|---|---|---|
| RPC `projects.list` | P `profile?` | `{projects:[Project],active_id?:string\|null}` | R; `projectsRead` |
| RPC `projects.get` | P `id`, `profile?` | `{project:Project}` | R; RPC 5062 maps to `project_not_found` |
| RPC `projects.for_cwd` | P `profile,cwd` | `{cwd,project:Project\|null}` | R; exact cwd echo |
| RPC `projects.create` | P `name`; optional `profile,folders,slug,primary_path,description,icon,color,board_slug,use` | `{project:Project,…}`; reload list confirms folder/active selection | M; `projectsEdit` |
| RPC `projects.update` | P `id`; optional `profile,name,description,icon,color,board_slug` | Refreshed project/list | M; `projectsEdit` |
| RPC `projects.archive` | P `id`, optional `profile,restore:boolean` | Project list with archived state | M; `projectsEdit` |
| RPC `projects.set_active` | P `id`, `profile?` | `active_id` exact; reload list | M; changes profile default project |
| RPC `session.workspace.move` | P `session_key:durableID,cwd`, `profile?` | `cwd` exact; `projects.for_cwd` confirms association | M; `sessionWorkspaceEdit`; not a runtime-ID field |
| RPC `projects.tree` | P `profile,preview_limit:3,session_limit:2000` | `{projects:[TreeNode],scoped_session_ids:[string]}` | R; endpoint |
| `GET /api/profiles/projects/tree` | Q `preview_limit=3,session_limit=2000` | `{projects:[TreeNode]}` merged across profiles | R; endpoint; do not infer a profile from merged node |
| RPC `projects.project_sessions` | P `profile,project_id,session_limit:5000` | `{project:TreeNode}` | R; endpoint |
| RPC `projects.discover_repos` | P `profile,scan:false` | `{repos:[{root,label,sessions:count,last_active?}]}` | R; does not request filesystem rescan |
| RPC `projects.add_folder` | P `profile,id,path,is_primary:boolean,label:string\|null` | Project/list acknowledgement; reload overview | M; endpoint; root must come from observed discovery |
| RPC `projects.remove_folder` | P `profile,id,path` | Reload overview confirms removed registration | M; does not mean filesystem deletion |
| RPC `projects.set_primary` | P `profile,id,path` | Reload overview confirms primary | M |
| RPC `projects.delete` | P `profile,id` | Reload overview confirms project registration absent | D; registration deletion |
| `POST /api/profiles/sessions/pull-requests` | B `ids:[durableID]` | `{pull_requests:{sessionID:{number,url}}}` | R/probe; at most 2,000 IDs |
| RPC `project.facts` | P `cwd` | `{facts:null\|{root,kind?,verifyCommands:[string]}}` | R; root must contain requested cwd |
| RPC `verification.status` | P `profile,cwd` | `{verification:{status,evidence?:{canonical_command?\|command?,scope?}}}` | R |

Project: `{id,name,description?,archived:boolean,folders:[{path,label?,is_primary:boolean}]}`. The decoder requires unique IDs and folders; up to 100 folders per project. Selecting a project for a **session** moves its durable session folder and verifies association; selecting outside a session changes the profile's active-project pointer. An archived project can remain in that pointer, so do not use it as a cwd override.

TreeNode fields: `{id,label,path?,color?,icon?,isAuto:boolean,isNoProject:boolean,sessionCount,totalTokens,totalCostUsd,lastActive?,repos:[Repository],previewSessions:[ProjectSession]}`. Repository: `{id,label,path?,sessionCount,groups:[Lane]}`. Lane: `{id,label,path?,isMain:boolean,isKanban:boolean,sessions:[ProjectSession]}`. ProjectSession: `{id,profile?,title?,preview?,cwd?,git_branch?,last_active?|started_at?}`. Tree limits differ from ordinary session catalog limits: up to 2,000 nodes, 500 repositories per node, 500 lanes, 5,000 session rows per lane; HTTP/RPC overall result bound is 2,097,152 bytes.

Host folder strings are not Android-local paths. Project folders permit POSIX absolute paths, Windows drive absolute paths and UNC paths as returned by Hermes. Drive-relative/device paths, `.`/`..`, empty segments and controls are refused. File browsing below uses the separate POSIX confinement contract.

Sources: [project catalog](../../Bighelp/DirectHermes/DirectHermesProjectClient.swift), [lifecycle/tree](../../Bighelp/DirectHermes/DirectHermesProjectLifecycleClient.swift), [decoder](../../Bighelp/WorkspaceManagement/WorkspaceManagementDecoder.swift). Tests: [projects](../../BighelpTests/DirectHermesProjectClientTests.swift), [folder chooser](../../BighelpTests/WorkspaceFolderChooserTests.swift).

### Stock Git

These are fixed stock routes, **endpoint** gated. Every path comes from a known Project's primary folder or an observed linked worktree. There is no arbitrary command/argv endpoint. `path` below is the absolute host repository cwd; `file` is a repository-relative path selected from observed review files.

| Call | Query/body (in addition to `path`) | Consumed response | Semantics |
|---|---|---|---|
| `GET /api/git/status` | Q `path` | null for non-repository, otherwise `{branch?,defaultBranch?,detached:boolean,ahead,behind,changed,added,removed,files:[{path,staged,unstaged,untracked,conflicted}]}` | R; file flags booleans |
| `GET /api/git/branches` | Q `path` | `{branches:[{name,isDefault:boolean,isRemote:boolean,checkedOut?:boolean,worktreePath?}]}` | R |
| `GET /api/git/base-branches` | Q `path` | Same branches; base-only ignores checked-out state | R |
| `GET /api/git/worktrees` | Q `path` | `{worktrees:[{path,branch?,isMain:boolean,detached:boolean,locked:boolean}]}` | R |
| `GET /api/git/gh-auth` | **no path** | `{available:boolean,authenticated:boolean}` | R; process-wide GitHub CLI status |
| `GET /api/git/review/list` | Q `path,scope:"uncommitted"\|"branch"` | `{base?,files:[{path,added,removed,status,staged:boolean}]}` | R |
| `GET /api/git/review/diff` | Q `path,file,scope,staged:boolean` | `{diff:string}` | R; ≤524,288 bytes |
| `GET /api/git/file-diff` | Q `path,file` | `{diff:string}` against HEAD | R; ≤524,288 bytes |
| `GET /api/git/review/commit-context` | Q `path` | `{diff:string,recent:string}`; newline-delimited recent commit subjects | R |
| `GET /api/git/review/rev-parse` | Q `path,ref` (`HEAD`, `HEAD^`, `HEAD^{tree}` used) | `{sha:null\|40/64-hex-string}` | R |
| `GET /api/git/review/ship-info` | Q `path` | `{ghReady:boolean,pr:null\|{number,url,state?}}` | R |
| `POST /api/git/review/pr-list` | B `path,branches:[string],numbers:[]` | `{ghReady:boolean,prs:[{number,draft:boolean,url,branch,title,state}]}` | R/probe |
| `POST /api/git/review/stage` | B `path,file` | `ok:true`; status/review confirms staged | M; one request per selected path |
| `POST /api/git/review/unstage` | B `path,file` | `ok:true`; status/review confirms unstaged | M |
| `POST /api/git/review/revert` | B `path,file` | `ok:true`; selected file leaves review | D; discard changes |
| `POST /api/git/review/commit` | B `path,message,push:false` | `ok:true`; status changes and staged set clears | M |
| `POST /api/git/review/push` | B `path` | `ok:true`; ahead reaches zero or status changes | M; remote side effect |
| `POST /api/git/review/create-pr` | B `path` | `url` validated as pull-request URL; ship/PR list confirms | M; remote side effect |
| `POST /api/git/branch/switch` | B `path,branch` | `branch` exact; status confirms | M |
| `POST /api/git/worktree/add` | B `path,name,branch,base?` **or** `path,existingBranch` | `{path,branch}` for added worktree; worktree listing confirms | M |
| `POST /api/git/worktree/remove` | B `path,worktreePath,force:boolean` | `removed` exact path; listing confirms absent | D; never main or locked worktree |

The stock client's review/status token is a locally computed SHA-256 fingerprint. `prepare` and its UUID confirmation token are in-memory local state, never posted as upstream prepare/execute operations. A stock snapshot permits stage, commit and push in its local `ProjectGitCapabilities` projection; fetch, pull and arbitrary command are false. Do not confuse this adapter with companion plugin `projects.git.capabilities/status/diff/prepare/execute`, whose wire contract is in [EXTENSIONS.md](EXTENSIONS.md).

Sources: [stock Git](../../Bighelp/DirectHermes/DirectHermesStockGitClient.swift), [plugin Git adapter](../../Bighelp/DirectHermes/DirectHermesProjectGitClient.swift). Tests: [project Git](../../BighelpTests/DirectHermesProjectGitClientTests.swift).

## Stock files and text editing

| Call | Request | Response consumed / bounds | Semantics |
|---|---|---|---|
| `GET /api/files` | Q `path?` | Listing below | R; `filesRead`; host-configured managed-file root |
| `GET /api/files/read` | Q `path` | Managed file `path,name,size,data_url` plus root policy fields | R; text preview decoder limit 262,144 decoded bytes; other delivery/media consumers have separate bounds |
| `GET /api/fs/list` | Q `path` | `{entries:[{name,path,isDirectory:boolean}],error?:string}`; `error` nonempty rejects listing; local pagination/filtering, max 50,000 entries | R; endpoint; expands `~`, hides credential folders; response ≤4,194,304 bytes |
| `GET /api/fs/read-text` | Q `path,profile` | `{text:string,path?:resolvedPath,truncated?:boolean,binary?:boolean}`; first 512 KB | R; endpoint; response ≤2,097,152 bytes |
| `POST /api/fs/write-text` | Q `profile`; B `path,content` | `{ok:true}`; viewer rereads baseline before write; save cap 524,288 UTF-8 bytes | M; replaces regular file in one step; does not create folders |
| `GET /api/media` | Q `path` | Authenticated generated image response | R; resolved host media roots; see delivery contract |

Listing: `{path,root,locked_root,can_change_path,parent?,entries:[{path,name,is_directory:boolean,size?:integer,mtime?:UnixSeconds,created?:UnixSeconds,mime_type?:string}]}`. Confined form requires `can_change_path:false`, `locked_root:string`, `root == locked_root`. Explicit unrestricted form is `can_change_path:true,locked_root:null,root:null`; client projection uses `/` as logical root. Every child and parent must remain within the accepted root; names cannot contain separators. File previews use `data:<mime>;base64,…`; decoded byte count must exactly equal `size`, and text must be valid UTF-8 without disallowed controls.

`GET /api/files` is not an arbitrary filesystem escape when a root is locked. A workspace-artifact view may additionally confine an otherwise broad response to literal `/workspace`. Conversely project cwd strings can be Windows paths without changing this POSIX browser policy. Do not widen a denied image/file request to a raw filesystem request or provider URL.

Companion managed files (`/api/plugins/loopdy/workspace-files/capabilities`, POST `list|read`), native workspace-files, recent files and grant-based file APIs are separate contracts in [EXTENSIONS.md](EXTENSIONS.md) and [EXTENSIONS.md](EXTENSIONS.md).

Sources: [workspace HTTP helpers](../../Bighelp/DirectHermes/DirectHermesWorkspaceClient.swift), [file decoder](../../Bighelp/WorkspaceManagement/WorkspaceManagementDecoder.swift), [managed file client](../../Bighelp/DirectHermes/DirectHermesManagedFilesClient.swift). Tests: [managed files](../../BighelpTests/DirectHermesManagedFilesTests.swift), [configured files](../../BighelpTests/ConfiguredWorkspaceFilesTests.swift), [artifacts](../../BighelpTests/WorkspaceArtifactsTests.swift).

## Skills, toolsets, plugins and MCP

The catalog adapter combines four independent reads: skills (`skillsRead`), plugins (`pluginsRead`), MCP servers (`mcpServersRead`) and toolsets (`toolsetsRead`). Treat one failing source as a failed/partial load according to the screen contract, never fabricate an empty installed list.

### Skills and Skill Hub

| Call | Request | Consumed response | Semantics; gate |
|---|---|---|---|
| `GET /api/skills` | Q `profile` | `{skills:[{name,description?,category?,enabled?}]}` or bare array. Older hosts omit `enabled`; presence then means enabled. Hub decoder also consumes `usage≥0,provenance`. | R; `skillsRead` |
| `GET /api/skills/content` | Q `profile,name` | `{name,content,sha256?}`; digest, when supplied, must match SHA-256 of UTF-8 content | R; `skillsRead` |
| `POST /api/skills` | B `profile,name,content,category?` | `ok:true` or `success:true`; GET content supplies saved bytes | M; `skillsEdit` |
| `PUT /api/skills/content` | B `profile,name,content` | `ok:true` or `success:true`; GET content verifies | M; `skillsEdit`; local immediate digest comparison is not atomic server CAS |
| `PUT /api/skills/toggle` | B `profile,name,enabled:boolean` | `ok:true,name,enabled` exact; catalog/readback | M; `skillsEdit` |
| `GET /api/skills/hub/sources` | Q `profile` | `{sources:[{id,label,available?,searchable?,rate_limited?}],featured:[HubItem],installed:[…],index_available:boolean}` | R; endpoint |
| `GET /api/skills/hub/official` | Q `profile` | `{skills:[HubItem]}` | R; endpoint |
| `GET /api/skills/hub/search` | Q `profile,q,source` (default `all`), `limit=50` | `{results:[HubItem],installed:[…],source_counts:{source:integer},timed_out:[string]}` | R; endpoint; keep timeout info |
| `GET /api/skills/hub/preview` | Q `profile,identifier` | `{…HubItem,skill_md:string,files:[string]}` | R; endpoint |
| `GET /api/skills/hub/scan` | Q `profile,identifier` | `{identifier,name,source,trust_level,verdict,summary,policy,policy_reason?,findings:[{severity,category,file?,line?:integer,description}],severity_counts:{severity:integer}}` | R/probe; endpoint |
| `POST /api/skills/hub/install` | B `profile,identifier` | `ok:true`, `action?` or `name?`, `pid?`, `action_id?`; reread or follow action status | M/J; requires observed preview and acceptable scan |
| `POST /api/skills/hub/uninstall` | B `profile,name` | Same action result | D/J; endpoint |
| `POST /api/skills/hub/update` | B `profile` | Same action result | M/J; endpoint; updates installed skills |

HubItem: `{identifier,name,description,source?,trust_level,repo?,tags:[string],category?,installed?:boolean}`. Skill name/category grammar in the document editor is `^[a-z0-9][a-z0-9._-]*$`, max 64 bytes. Document content is nonempty, max 100,000 bytes, allows newline/CR/tab but not other controls. A Hub `identifier` names a host download; it is **not** a zip/upload field. Arbitrary `skillMd`/zip archive import through this adapter is unsupported even though a local operation enum has `skills_tools.import`.

Sources: [skill documents](../../Bighelp/DirectHermes/DirectHermesCapabilityClients.swift), [Hub](../../Bighelp/DirectHermes/DirectHermesSkillsHubClient.swift). Tests: [capability clients](../../BighelpTests/DirectHermesCapabilityClientsTests.swift).

### Toolsets

| HTTP call | Request | Consumed response | Semantics |
|---|---|---|---|
| `GET /api/tools/toolsets` | Q `profile` | Bare array or `{toolsets:[Toolset]}`. Full Toolset `{name,label,description?,platform,platform_label,enabled:boolean,configured:boolean,tools:[string]}`; simpler catalog also accepts `toolCount` in place of tools. | R; `toolsetsRead` / endpoint |
| `GET /api/tools/toolsets/{name}/config` | Q `profile` | ToolsetConfig below | R; endpoint |
| `GET /api/tools/toolsets/{name}/models` | Q `profile,provider?` | `{name,has_models:boolean,provider?,models:[{id,display,speed?,strengths?,price?}],current?,default?}` | R; endpoint |
| `PUT /api/tools/toolsets/{name}` | B `profile,enabled:boolean` | `ok:true,name,enabled` exact; list confirms | M; endpoint |
| `PUT /api/tools/toolsets/{name}/provider` | B `profile,provider,capability?` | `ok:true,name,provider` exact; `needs_nous_auth?:boolean`; reload config | M; endpoint |
| `PUT /api/tools/toolsets/{name}/env` | B `profile,env:{environmentKey:string}` | `ok:true,name`; reload config, secret fields confirmed by set-state | M; endpoint |
| `PUT /api/tools/toolsets/{name}/model` | B `profile,model,provider?` | `ok:true,name,model` exact; reload detail | M; endpoint |
| `POST /api/tools/toolsets/{name}/post-setup` | B `profile,key` | `ok:true,key` exact, optional `action\|name,pid,action_id` | M/J; endpoint |

ToolsetConfig: `{name,has_category:boolean,active_provider?,active_search_backend?,active_extract_backend?,providers:[{name,badge?,tag?,env_vars:[{key,prompt,url?,default?,is_set:boolean}],capabilities?:[string],post_setup?,requires_nous_auth:boolean,is_active:boolean,status,web_backend?}]}`. Displayed environment values are not a credential readback. The selected provider/web capability comes from current config, not a locally invented backend catalog.

Source: [toolsets](../../Bighelp/DirectHermes/DirectHermesToolsetClient.swift).

### Plugin lifecycle

The lightweight registry read is RPC `plugins.manage {profile?,action:"list"}` returning `{plugins:[{key?|name,name,kind?|source?,version?,description?,enabled?|status?,capabilityCount?|provides?:[string]}]}`. MCP lightweight registry read is `mcp.servers.list {profile?}` returning `{servers:[{name,transport?,enabled?,tools?:array|object|null}]}`. A `tools` object here is an include/exclude **configuration filter**, not a discovered tool count.

The installed-plugin management UI instead uses the following unscoped dashboard endpoints (**endpoint** gated). A profile parameter must not be invented for these routes.

| Call | Request | Consumed response | Semantics |
|---|---|---|---|
| `GET /api/dashboard/plugins/hub` | none | `{plugins:[InstalledPlugin]}` | R |
| `GET /api/dashboard/plugins/catalog` | none | `{entries:[PluginEntry],removed:[{name,reason?}]}` | R |
| `GET /api/dashboard/plugins/rescan` | none | `ok:true,count` in 0…10,000; reload catalogs | **M** despite GET: rescans host plugin inventory |
| `POST /api/dashboard/agent-plugins/install` | B `identifier:"",catalog_name,force:false,enable:true,ref:40-hexSHA` | `ok:true`; catalog shows exact requested SHA installed/enabled and installed list resolves the new plugin | M |
| `POST /api/dashboard/agent-plugins/{name}/enable` / `disable` | no body | `ok:true`; hub verifies enabled state | M |
| `POST /api/dashboard/agent-plugins/{name}/update` | no body | `ok:true`; reread installed row | M; local `can_update_git` required |
| `DELETE /api/dashboard/agent-plugins/{name}` | none | `ok:true`; hub verifies absence | D; local `can_remove` required |

InstalledPlugin: `{name,version?,description,source,runtime_status:"enabled"|"disabled"|"inactive",can_remove:boolean,can_update_git:boolean,auth_required:boolean,auth_command?,removed_reason?}`. PluginEntry: `{name,repo,sha,description,maintainer,tier,requires_hermes?,docs_url?,platforms:[string],capabilities:{provides_tools:[string],provides_hooks:[string],provides_middleware:[string],requires_env:[string]},installed:boolean,installed_sha?,update_available:boolean,runtime_status?}`. `sha` is exact 40 hex; install pins the reviewed commit. `requires_hermes` is catalog metadata, not the gateway's general availability gate.

Source: [plugin lifecycle](../../Bighelp/DirectHermes/DirectHermesPluginLifecycleClient.swift). Tests: [plugin update workspace](../../BighelpTests/PluginUpdateWorkspaceClientTests.swift).

### MCP server configuration and OAuth

| Call | Request | Consumed response / verification | Semantics |
|---|---|---|---|
| `GET /api/mcp/servers` | Q `profile` | `{servers:[MCPServer]}` | R; endpoint |
| `GET /api/mcp/catalog` | Q `profile` | `{entries:[MCPEntry],diagnostics:[{name,kind}]}` | R; endpoint |
| `POST /api/mcp/servers` | B `name,profile`; HTTP variant `url,auth:"none"\|"oauth"\|"header",bearer_token?`; stdio variant `command,args:[string],env:{key:string}` | Write acknowledgement; list exact name/transport/enabled state | M; HTTP bearer maps to `auth:"header"`; disabling is a separate request after add |
| `POST /api/mcp/catalog/install` | B `profile,name,env:{key:string},enable:boolean` | `ok:true,name,background:boolean`; background variant `action,pid?,action_id?`; immediate variant confirms server list | M/J; only observed required env fields |
| `PUT /api/mcp/servers/{name}/enabled` | B `profile,enabled:boolean` | `ok:true,name,enabled`; list confirms | M |
| `DELETE /api/mcp/servers/{name}` | Q `profile` | `ok:true`; list confirms absent | D |
| `POST /api/mcp/servers/{name}/test` | Q `profile` | `ok:boolean,tools:integer\|array,prompts?:integer,resources?:integer` | R/probe; tools can carry names/summaries, count may exceed displayed subset |
| RPC `mcp.servers.status` | P `profile` | `checked_at:positive integer` (milliseconds), `servers:[{name,transport,tools:count,connected:boolean,disabled:boolean,status}]` | R; exact configured name/transport set required; cached runtime status |
| RPC `mcp.servers.set_api_key` | P `profile,name,value,env_var?` | `ok:true,name,env_var,server:{name,transport,env:[key],auth?}`; GET config confirms Authorization header name (HTTP) or env key (stdio) | M; refuses HTTP OAuth servers |
| `POST /api/mcp/servers/{name}/auth` | Q `profile` | MCPFlow below | M; start OAuth |
| `GET /api/mcp/oauth/flows/{flow_id}` | none | MCPFlow | R; poll flow |
| `DELETE /api/mcp/oauth/flows/{flow_id}` | none | `ok:true,status` | M; cancel OAuth |
| RPC `reload.mcp` | P `session_id:runtimeID`, `confirm:true` | `{status:"reloaded"}` | M; reload only the intended profile/session after connector/config changes |

MCPServer: `{name,transport,url?,command?,args:[string],auth?,enabled:boolean,env?:{key:…},headers?:{headerName:…}}`; current UI projects only env/header **names**, not values. MCPEntry: `{name,description?,source?,transport,auth_type,required_env:[{name,prompt,required:boolean}],command?,args:[string],url?,install_url?,install_ref?,bootstrap:[string],post_install?,needs_install:boolean,installed:boolean,enabled:boolean}`. MCPFlow: `{flow_id,server_name,status,authorization_url?,tools?,error?}`; only validated web URLs are opened, and failure details are sanitized for display. Names/env-vars are validated locally; HTTP URLs may be `http` or `https` with a host and no embedded credentials.

Source: [MCP](../../Bighelp/DirectHermes/DirectHermesMCPClient.swift), [workspace reload composition](../../Bighelp/DirectHermes/DirectHermesWorkspaceStore.swift). Tests: [capability management](../../BighelpTests/CapabilityManagementStateTests.swift).

## Memory, learning graph and curator

All routes in this section use the direct owner-bound memory client (**endpoint** gated). `/api/memory`, curator and the unscoped RPC learning projection operate in serving-process scope. Optional profile support is explicit in the rows below; a selected profile must not be silently substituted for an unscoped operation.

| Call | Request | Consumed response / verification | Semantics |
|---|---|---|---|
| `GET /api/memory` | none | `{active:string,providers:[MemoryProvider],builtin_files:{memory:bytes,user:bytes}}` | R; `memoryRead` for the simpler workspace adapter |
| `PUT /api/memory/provider` | B `provider` | `ok:true,active` exact; GET confirms active provider | M |
| `GET /api/memory/providers/{provider}/config` | Q `profile?` | `{name,label,docs_url?,fields:[MemoryField]}` | R |
| `PUT /api/memory/providers/{provider}/config` | Q `profile?`; B `values:{key:typedValue}` | `ok:true`; read config confirms nonsecret value or secret `is_set` | M; only observed editable fields |
| `POST /api/memory/providers/{provider}/setup` | B `values:{}` | `{ok:boolean,provider,results:[{kind,name,status}]}`; GET memory confirms provider exists | M; can install dependencies |
| `POST /api/memory/providers/{provider}/oauth/start` | Q `profile?` | `{state:"idle"\|"pending"\|"connected"\|"error",connected:boolean,auth?}`; then GET status | M |
| `GET /api/memory/providers/{provider}/oauth/status` | Q `profile?` | `{state:"idle"\|"pending"\|"connected"\|"error",connected:boolean,auth?}` | R |
| `POST /api/memory/reset` | B `target:"all"\|"memory"\|"user"` | `ok:true,deleted:[string]`; selected builtin byte counts become zero | D; provider reset is not inferred |
| `GET /api/curator` | none | `{enabled:boolean,paused:boolean,interval_hours?,min_idle_hours?,stale_after_days?,archive_after_days?,last_run_at?}` | R |
| `PUT /api/curator/paused` | B `paused:boolean` | `ok:true,paused` exact; reload curator confirms | M |
| `POST /api/curator/run` | no body | `ok:true,pid:positive integer,name:"curator-run",action_id?` | J; follow action status |
| `GET /api/learning/graph` | Q `profile?` | LearningGraph below | R; ≤4,194,304 response bytes |
| `GET /api/learning/node` | Q `id,profile?` | `{ok:true,id,kind,label,content}` | R |
| `PUT /api/learning/node` | B `id,content,profile:string\|null` | `ok:true,message?`; GET node confirms kind/content | M; ≤512,000 content bytes |
| `DELETE /api/learning/node` | B `id,profile:string\|null` | `ok:true,message?`; graph count decreases by one; skill ID absent | D |
| RPC `insights.get` | P `days` (1…3650), `profile?` | `{days:positive integer,sessions:count,messages:count}` | R |
| RPC `learning.frames` | P `cols` (20…160), `rows` (8…80), `frames` (1…120) | LearningTimeline below | R; **no profile parameter** |
| RPC `learning.detail` | P `id` | Same node detail | R; **no profile parameter** |
| RPC `learning.edit` | P `id,content` | `ok:true,message?`; detail readback confirms | M; **no profile parameter** |
| RPC `learning.delete` | P `id` | `ok:true,message?`; timeline readback confirms removal | D; **no profile parameter** |

MemoryProvider: `{name,description,available:boolean,configured:boolean,status,setup:{dependencies_installed:boolean,pip_dependencies:[string],external_dependencies:[{name}],required_env:[string]}}`. Known provider states `ready|needs_config|missing|unavailable`; unknown values remain “other” rather than being treated as ready.

MemoryField: `{key,label,kind,description?,placeholder?,required?:boolean,value:string,is_set?:boolean,options:[string|{value,label?,description?}],minimum?:number,maximum?:number}`. Kinds `text|url`, `secret|password`, `select`, `bool|boolean`, `number`, `integer`, `json`; unknown kinds are uneditable. Values are strings for text/secret/select, booleans for toggles, finite numbers for numeric kinds, and decoded array/object JSON for `json`. Secrets with a blank draft are omitted to preserve existing credentials; successful secret readback requires `is_set:true` and an empty exposed value. A config's `name` must equal requested provider.

LearningGraph: `{memory:[{source,title,body}],nodes:[{id,label,kind,timestamp?,category,useCount:integer,state,createdBy?,pinned:boolean,memorySource?}],edges:[{source,target}],clusters:[{category,count}],stats:{nodes,related_edges,linked_nodes,isolated_pct,categories,agent_created,used,memory_nodes,memory_skill_edges,learned_skills}}`. Edges reference existing nodes; IDs/edges/clusters are unique; `isolated_pct` is 0…100. Memory card preview is locally looked up by memory-node index, not an additional wire field. Node kinds come from the model enum (memory or skill).

LearningTimeline: `{frames:[{reveal:number,visible:count,date,grid:[[…]],labels?:[object]}],legend:[Legend],categories:[Legend],buckets:[{index,label,date,skills,memories,total,category?,color?,nodes:[{id,glyph,label,fullLabel,meta,body,style}]}],summary:[string],axis:{start,end},count,cols,rows}`. Legend is `{glyph,label,style?,color?}`. The client validates grid/label container types but projects timeline metadata rather than exporting arbitrary grid cells. Mutation receipts cannot prove the expected node was changed; reread the exact detail or graph.

Source: [memory client and decoders](../../Bighelp/DirectHermes/DirectHermesMemoryClient.swift).

## Messaging platforms, onboarding and webhooks

These clients are **endpoint** gated. Platform config is profile scoped; Telegram pairing starts without a profile and applies to an explicit profile. Webhook platform/subscription management is unscoped and concerns the serving host.

| Call | Request | Consumed response | Semantics |
|---|---|---|---|
| `GET /api/messaging/platforms` | Q `profile` | `{platforms:[MessagingPlatform]}` | R; `messagingPlatformsRead` in simple adapter |
| `PUT /api/messaging/platforms/{id}` | B `profile,env:{key:string},clear_env:[string],enabled?:boolean` | `ok:true,platform` exact; catalog verifies enabled/replacement set-state/cleared unset-state | M; only environment keys from observed platform |
| `POST /api/messaging/platforms/{id}/test` | Q `profile`; B `{}` | `{ok:boolean,state,message}` | R/probe |
| `POST /api/messaging/telegram/onboarding/start` | B `bot_name?` | TelegramPairing; reread status | M; no profile on start |
| `GET /api/messaging/telegram/onboarding/{pairing_id}` | none | TelegramPairing | R |
| `POST /api/messaging/telegram/onboarding/{pairing_id}/apply` | B `profile,allowed_user_ids:[numeric strings]` | `ok:true,platform:"telegram",needs_restart?,restart_started?`; platform must read enabled/configured | M |
| `POST /api/messaging/whatsapp/onboarding/start` | B `profile,mode,allowed_users:string` | WhatsAppPairing; reread status | M |
| `GET /api/messaging/whatsapp/onboarding/{pairing_id}` | none | WhatsAppPairing | R |
| `POST /api/messaging/whatsapp/onboarding/{pairing_id}/apply` | Q `profile`; B `profile,mode,allowed_users` | `ok:true,platform:"whatsapp",needs_restart?,restart_started?`; read configured platform | M |
| `DELETE /api/messaging/{telegram\|whatsapp}/onboarding/{pairing_id}` | none | `ok:true`; subsequent GET must establish flow absent | M; cancels pairing, does not delete platform |
| `GET /api/webhooks` | none | `{enabled:boolean,base_url,subscriptions:[Webhook]}` | R; simple adapter `webhooksRead` |
| `POST /api/webhooks/enable` | B `{}` | `ok:true,platform:"webhook",enabled:true`; reread confirms | M |
| `POST /api/webhooks` | B `name,description,events:[string],prompt,skills:[string],deliver,deliver_only:boolean,deliver_chat_id?` | `name` exact, `secret:string`; reread subscription verifies config | M; omit `secret` and `script`, host generates strong secret |
| `PUT /api/webhooks/{name}/enabled` | B `enabled:boolean` | `ok:true,name,enabled`; reread verifies | M; `webhooksEdit` in simple adapter |
| `DELETE /api/webhooks/{name}` | none | `ok:true`; reread confirms absence | D |

MessagingPlatform: `{id,name,description,enabled:boolean,configured:boolean,gateway_running:boolean,env_vars:[{key,required:boolean,is_set:boolean,is_password:boolean,advanced:boolean,prompt,help?,url?}],docs_url?,state?,error_message?,ingress_url?}`. Replacement and clear sets must be disjoint; the current client permits ≤64 of each. Do not echo placeholder/redacted values as replacements.

TelegramPairing: `{pairing_id,status,suggested_username?,deep_link?,qr_payload?,expires_at?,bot_username?,owner_user_id?}`. WhatsAppPairing: `{pairing_id,status,mode:"bot"|"self-chat",allowed_users?,qr_payload?,expires_at?,account_id?,account_name?,account_phone?,error?}`. QR payload/deep links come from host; a polling failure does not mean pairing completed.

Webhook: `{name,description,events:[string],skills:[string],deliver,deliver_only:boolean,enabled:boolean,secret_set:boolean,url,created_at?}`. Delivery is `log|origin|telegram|discord|slack|github_comment`. The secret is available only in creation receipt, not list. If description is blank the client supplies `Dashboard-created subscription: {name}`. Delivery-without-agent is disallowed with log-only delivery. A fresh secret must not be persisted in ordinary catalog/UI logs.

Sources: [messaging](../../Bighelp/DirectHermes/DirectHermesMessagingClient.swift), [webhooks](../../Bighelp/DirectHermes/DirectHermesWebhooksClient.swift). Native App Connections are in [GROUPS_AND_DEVICE_TOOLS.md](GROUPS_AND_DEVICE_TOOLS.md); Composio is in [EXTENSIONS.md](EXTENSIONS.md).

## Host operations, gateway, diagnostics and logs

Host operations are **endpoint** gated and bound to a direct connection owner. “Gateway” in these routes is the host's **messaging gateway**, not a request to restart the serving dashboard process from inside its connection. Some operations are deliberately unscoped. Before presenting them as belonging to a profile, resolve serving identity by matching unscoped `/api/config/raw`'s `path` to a unique `/api/profiles` `{name,path}` home, with stable before/after inventories; discard the YAML after type checking when only discovering the path.

| Call | Request | Consumed response | Semantics |
|---|---|---|---|
| `GET /api/status` | Q `profile?` | HostOverview below | R |
| `GET /api/system/stats` | none | SystemStats below | R; `systemStatus` in simple registry |
| `GET /api/egress/status` | none | `{text:string}` | R |
| `GET /api/hermes/update/check` | Q `force:boolean` | `{install_method,current_version,behind?:integer,update_available:boolean,can_apply:boolean,update_command,message?,commits:[{sha,summary,at?:UnixSeconds}]}` | R/probe |
| `POST /api/hermes/update` | B `{}` | ActionReceipt `name:"hermes-update"`; structured receipt/status follows | J; recheck reviewed install/version/update eligibility |
| `GET /api/hermes/update/receipt` | none | UpdateReceipt below; 404 whose detail starts `No update receipt found` means no receipt; other 404/405 means unsupported | R |
| `GET /api/actions/{action}/status` | Q `lines=1` | `{name,running:boolean,pid?,exit_code?,action_id?,receipt?}` | R; match receipt action/process identity |
| `GET /api/ops/checkpoints` | none | `{sessions:[{session,files:count,bytes:count}],total_bytes}` | R |
| `POST /api/ops/backup` | B `output:null` | ActionReceipt with `archive?` | J; creates backup |
| `GET /api/ops/backup/download` | Q `archive` from admitted backup receipt | Binary ZIP; HTTP 200, ZIP signature, content type `application/zip` or `application/octet-stream` | R; authenticated bounded download |
| `POST /api/ops/checkpoints/prune` | B `{}` | ActionReceipt | D/J |
| `POST /api/ops/import` | B `archive:hostPath,force:true` | ActionReceipt | D/J; imports full backup into serving context |
| `POST /api/ops/import-upload` | Multipart fixed fields: archive `file`, `force` (see below) | ActionReceipt plus `uploaded_bytes` equals submitted size | D/J; fixed authenticated upload, max 16,777,216 ZIP bytes |
| `POST /api/ops/{doctor\|security-audit\|prompt-size\|dump\|config-migrate}` | B `{}` | ActionReceipt | J; config migration is a mutation, diagnostic dump can write host output |
| RPC `diagnostics.share_nous` | P `log_lines` (10…2000; default 200) | `ok:true,view_url?:HTTPS,upload_id?,expires_at?`; at least URL or upload ID | M; **external diagnostics upload**, fresh explicit user consent in host client; no silent retry |
| `GET /api/gateway/migrate/plan` | none | GatewayMigrationPlan below | R |
| `POST /api/gateway/migrate` | B `{}` | ActionReceipt | J; fresh plan equals reviewed eligible, no blockers, not already multiplexed |
| `POST /api/gateway/drain` | B `action:"drain"\|"cancel",suppress_notification:false` | `ok:true,action`; drain: `draining:boolean,requested_at?`; cancel: `was_draining?:boolean` | M |
| `POST /api/gateway/{start\|stop\|restart}` | Q `profile`; B `{}` | ActionReceipt whose name matches action | J; messaging gateway lifecycle |
| `GET /api/ops/hooks` | none | `{valid_events:[string],hooks:[{event,matcher?,command,timeout:integer,allowed:boolean,approved_at?,executable:boolean}]}` | R |
| `POST /api/ops/hooks` | B `event,command,approve:boolean,matcher?,timeout?` | `ok:true,event,command,approved:boolean`; exact matching hook count increases | M; event from `valid_events`, timeout 1…300 (default 60) |
| `DELETE /api/ops/hooks` | B `event,command` | `ok:true`; **all** matching event/command hooks absent | D; matcher/timeout not deletion selectors |
| `GET /api/logs` | Q `file,lines,level?,component?,search?` | `{file,lines:[string]}`; returned file exact, rows ≤requested limit | R; rich logs client below |
| `GET /api/analytics/usage` | Q `profile?,days?` | Usage aggregate object decoded by usage client | R; `usageRead`; model attribution separately in `/analytics/models` |

ActionReceipt: `{ok:true,name,pid?:positive integer,action_id?:string,archive?:hostPath}` with at least PID or action ID. An update action ID, when present, must be 32 lowercase hex. Action status phase: `running:true` requires no exit code; not running + exit code 0 = succeeded; nonzero = failed; no exit code = outcome unknown. Correlation is exact action ID when possible, then PID, else action-slot-only/pending identity. A same-named new action must not be taken as the old action's success.

HostOverview fields consumed: `version,release_date?,overall,components` (each component status; gateway status may be nested object), `gateway_running`, `gateway_state?`, `gateway_busy?`, `gateway_drainable?`, `gateway_mode?`, `gateway_shared_with?`, `active_agents?`, `active_sessions?`, `restart_drain_timeout?`. SystemStats: `{os,os_release?,arch,hostname,python_version,python_impl?,hermes_version,cpu_count?,cpu_percent?,load_avg:[number],uptime_seconds?,memory?:{total,used,available,percent},disk?:{total,used,free,percent},process?:{rss,num_threads,create_time},psutil:boolean}`.

GatewayMigrationPlan: `{profiles:[{profile,pid?,service?:{kind?,system?}}],multiplex_flag_on:boolean,live_served:[string],already_multiplexed:boolean,blockers:[string],notices:[string],eligible:boolean}`. The plan fingerprint is local. Shell hook fingerprints and raw-config baseline hashes are also local comparisons with rereads; there is no posted ETag/revision field on these stock mutations.

UpdateReceipt: `{receipt:{schema?,outcome?,started_at?,finished_at?,steps:[{name,ok:boolean,at?}],skips:[{name,at?}],fleet:[{profile,state,code_sha?,code_version?}],gateway_restart?:{incomplete?:boolean}},summary?:{outcome?,started_at?,finished_at?,pre_sha?,post_sha?,post_version?,fleet_states?:[string]}}`. Schema defaults to 1; malformed optional steps/skips/fleet rows are skipped. Summary falls back to receipt outcome (or `unknown`) if absent; SHAs are validated leniently. `gateway_restart.incomplete` is consumed only when it is a boolean. Preserve both summary and step/fleet outcomes instead of equating launch with success.

The rich logs client supports file `agent|errors|gateway|gui|desktop|mcp`, line limit 1…500 (default 100), `level` omitted or `DEBUG|INFO|WARNING|ERROR|CRITICAL`, `component` omitted or `gateway|agent|tools|cli|cron|gui`, and optional trimmed search ≤200 UTF-8 bytes without controls. Response bound is 2,097,152 bytes. Its codec parses timestamp/severity/logger and redacts sensitive patterns. The old `WorkspaceOperation.logsList` allowlist is intentionally narrower: only `file=agent,lines=100`, and its management projection withholds raw messages. Do not mistake that local restriction for the HTTP endpoint schema.

Sources: [host action/status](../../Bighelp/DirectHermes/DirectHermesHostOperationsClient.swift), [inventory](../../Bighelp/DirectHermes/DirectHermesHostOperationsClient+Inventory.swift), [host payload decoder](../../Bighelp/DirectHermes/DirectHermesHostPayload.swift), [gateway](../../Bighelp/DirectHermes/DirectHermesHostOperationsClient+Gateway.swift), [diagnostics](../../Bighelp/DirectHermes/DirectHermesHostOperationsClient+Diagnostics.swift), [backup/import](../../Bighelp/DirectHermes/DirectHermesHostOperationsClient+BackupImport.swift), [multipart transport](../../Bighelp/DirectHermes/DirectHermesHostImportTransport.swift), [hooks](../../Bighelp/DirectHermes/DirectHermesHostOperationsClient+ShellHooks.swift), [logs](../../Bighelp/DirectHermes/DirectHermesLogsClient.swift), [log models](../../Bighelp/WorkspaceManagement/Logs/HermesLogModels.swift). Tests: [logs](../../BighelpTests/HermesLogsTests.swift), [management live probes](../../BighelpTests/DirectHermesManagementLiveTests.swift).

### Terminal and computer-use backends

| Call | Request | Consumed response | Semantics |
|---|---|---|---|
| `GET /api/tools/terminal/backends` | Q `profile` | `{active,backends:[{name,label,description?,active:boolean,status,detail?}]}` | R; endpoint |
| `PUT /api/tools/terminal/backend` | B `profile,backend` | `ok:true,backend` exact; reread active backend | M; require same observed backend row before write |
| `GET /api/tools/computer-use/status` | Q `profile` | ComputerUseStatus below | R; endpoint |
| `POST /api/tools/computer-use/permissions/grant` | Q `profile` | `ok:true,name:"computer-use-grant",pid:positive integer,action_id?,already_running?` | J; host-side permission grant, not Android device permission |
| `GET /api/actions/computer-use-grant/status` | Q `lines=1` | `name,running:boolean,pid?,action_id?,exit_code?` | R; correlate PID/action ID before accepting result |

ComputerUseStatus: `{platform,platform_supported:boolean,installed:boolean,can_grant:boolean,version?,ready?,accessibility?,screen_recording?,screen_recording_capturable?,error?,source?:{attribution?,executable?,note?,pid?,responsible_ppid?},checks:[{label,status,message?}]}`. Terminal backend status is `ready|needs_setup|unavailable`. Unknown ready/permission values stay unknown. The current grant client is available only for an observed Darwin host, supported/installed/can-grant true and not already ready; it rereads the status and compares the full reviewed snapshot before dispatch. This does not implement the phone's device-tool bridge or Bot Screen control leases, which are in [GROUPS_AND_DEVICE_TOOLS.md](GROUPS_AND_DEVICE_TOOLS.md).

Source: [host tool backends](../../Bighelp/DirectHermes/DirectHermesHostToolBackendsClient.swift).

## Voice configuration and stock GPT-Live control plane

These are stock dashboard APIs (**endpoint** gated); the companion live voice session protocol and STT/TTS/media byte transports are covered in [EXTENSIONS.md](EXTENSIONS.md). A stock live session is an explicitly selected engine, not an automatic fallback from the companion voice mode.

| Call | Request | Consumed response | Semantics |
|---|---|---|---|
| `GET /api/audio/voice-config` | Q `profile` | `{ok:true,stt:VoiceRoute,tts:VoiceRoute}` | R; response ≤131,072 bytes; contains short-lived provider credentials in direct mode |
| `GET /api/config` | Q `profile,include_defaults=true` | `tts.provider:"openai"\|"elevenlabs"`, corresponding `tts.openai.voice` or `tts.elevenlabs.voice_id` | R; unknown/missing provider or voice produces no selection |
| `PUT /api/config` | B `profile,config:{tts:{provider:"openai",openai:{voice}}}` or `profile,config:{tts:{provider:"elevenlabs",elevenlabs:{voice_id}}}` | `ok:true`; GET config confirms exact provider/voice | M; deep merge |
| `GET /api/audio/elevenlabs/voices` | Q `profile` | `{available:boolean,voices:[{voice_id,name,label}],error?}`; unavailable requires empty voice array | R; ≤2,000 voices /1,048,576 response bytes |
| `POST /api/audio/tts-lease` | Q `profile`; B `lease,active:boolean` | `ok:true,lease,active` exact, `action?`, `leases?:integer`, `provider?`, `warmed?:boolean`, `error?` | M; holds/releases warm voice resources; action `error` or any error field marks warm failure |
| `GET /api/audio/voice-live/status` | Q `profile` | `{ok:true,mode:"chained"\|"gpt-live",available:boolean,reason?,model,voice}` | R |
| `POST /api/audio/voice-live/session` | Q `profile`; B `sdp:offerString,history:[LiveHistoryMessage]` | `{ok:true,transport:{type:"webrtc",sdp:answerString},session?:{id?}}` | M; WebRTC control exchange only; no capture/playback engine is mounted by this call |

VoiceRoute variants:

```json
{"mode":"relay","reason":"optional reason"}
```

```json
{
  "mode":"direct",
  "wire":"openai-multipart",
  "provider":"host-provider-id",
  "base_url":"https://voice.example.test/v1",
  "api_key":"<ephemeral credential>",
  "model":"optional-model",
  "language":"optional-language",
  "voice":"optional-voice",
  "speed":1
}
```

Only `mode` is required for relay; `reason` is optional. Direct requires `wire,provider,base_url,api_key`; `model,language,voice,speed` are optional. STT wire values are `openai-multipart|xai-stt|elevenlabs-stt`; TTS values are `openai-speech|elevenlabs-tts`. Reject a wire used in the wrong direction and unknown modes/wires. Base URL is HTTPS with host, no embedded user/password/query/fragment; speed, if present, is 0.25…4. Credentials are ephemeral, nonpersistent and not printable: invalidate them when host/profile ownership, scene or presentation retires. If TTS decoding fails after STT decoded, invalidate STT as well.

LiveHistoryMessage is `{type:"message",role:"user"|"assistant"|"developer",content:[{type:"output_text"|"input_text",text}]}`; assistant uses `output_text`, other roles `input_text`. Client limit is 24 messages, each trimmed nonempty text ≤1,200 UTF-8 bytes, total ≤6,000; offer SDP nonempty and ≤524,288 bytes, answer SDP nonempty with response ≤1,048,576 bytes. `session.id` is optional and unrelated to the durable chat ID unless the host explicitly provides a mapping.

TTS lease ID is a client-generated printable identifier (≤256 bytes). The current iOS implementation uses `loopdy-ios:{read-aloud|preview}:{lowercase-UUID}`; this is a client convention, not a demonstrated Android requirement. Registry `voice.warm` maps to the same TTS lease endpoint requesting a 180-second timeout because first warm-up can install a provider package; the shared HTTP transport clamps the effective request timeout to 75 seconds. Lease admission does not mean an audio sample has played.

Source: [voice configuration, direct provider resolver and stock live control](../../Bighelp/DirectHermes/DirectHermesVoiceConfigurationClient.swift). Tests: [voice settings](../../BighelpTests/VoiceSettingsWorkspaceClientTests.swift), [voice media](../../BighelpTests/DirectHermesVoiceMediaTests.swift), [voice client](../../BighelpTests/DirectHermesVoiceClientTests.swift).

## Usage aggregate schema

`GET /api/analytics/usage?profile={profile}&days={days}` returns an object with `daily` and/or `totals` (at least one required by the report decoder), optionally `by_model`:

- `daily:[{day:"YYYY-MM-DD",input_tokens?,output_tokens?,cache_read_tokens?,reasoning_tokens?,estimated_cost?,actual_cost?,sessions?,api_calls?}]`.
- `totals:{total_input?,total_output?,total_cache_read?,total_reasoning?,total_estimated_cost?,total_actual_cost?,total_sessions?,total_api_calls?}`. Missing totals are summed from valid daily rows.
- `by_model:[{model,input_tokens?,output_tokens?,estimated_cost?,actual_cost?,sessions?}]` is the fallback model breakdown. `/api/analytics/models` supplies provider and optional cache-read attribution, as described above.

The current UI projection intentionally reads leniently: malformed individual days/models are skipped, missing counts/costs become zero, daily processing is bounded at 800 rows and model rows at 200. Numeric counts must be finite, nonnegative and below `1e15` (rounded to integer), money finite/nonnegative below `1e9`. These are report policies, not proof that usage was zero when the server omitted a number. Hermes counts usage by when a session started, per profile. Companion `usage/activity` adds host-hour and model/day activity; serving provider subscription limits are another companion route, not inferred from token analytics.

Sources: [usage schema/projection](../../Bighelp/Usage/HermesUsage.swift), [per-profile loader](../../Bighelp/Usage/UsageReaders.swift).

## Operation coverage and unsupported assumptions

The stock route registry includes live chat operations (`session.create/resume/activate/branch/events.since`, `prompt.submit`, session interrupt/steer/queue, slash/catalog, approvals/clarification/subagents); their request/response/event contracts are in [CHAT.md](CHAT.md). `groups.*` and `display.*` use the stock RPC gateway with feature-specific discovery and ownership rules in [GROUPS_AND_DEVICE_TOOLS.md](GROUPS_AND_DEVICE_TOOLS.md). Bot Screen's `display.status/start/stop/thumbnail` require `profile`; observe adds optional `viewer_id`; lease acquire/release require both `profile,viewer_id`.

Companion-native operations such as cards, Feed/Ideas/Goals, recent attachments/files, wiki, agent talks/activity/team settings, templates, image actions/drafts, Composio, alerts, telemetry, provider sign-in and workflows are **not** stock methods just because an enum name resembles RPC. `DirectHermesWorkspaceClient.perform` detects supported companion operations before stock routing; the plugin client uses a fixed feature-gated HTTP route table and its own envelope. See [EXTENSIONS.md](EXTENSIONS.md). Managed media/file reads, attachment byte transfers, audio streaming and full import upload also use fixed transport seams rather than a general JSON operation call; see [EXTENSIONS.md](EXTENSIONS.md).

A case present in `WorkspaceOperation` but without a stock or native route is unsupported, not permission to send an arbitrary method of that name. Examples include archive-byte skill import and generic project directory operations. Neutral local capabilities can be more restrictive than endpoints implemented by direct clients. Unknown JSON properties should not become arbitrary route selection, credential forwarding, filesystem access, shell commands or raw provider URLs.

This reference was audited against application route registries, feature clients, decoders and the linked tests. It describes current requests and consumed response subsets; it does not independently certify every upstream release or every optional server field. Where a decoder intentionally treats optional metadata leniently, this document identifies that policy. Verify uncertain server behavior with authenticated read-only probes or fixtures before implementing a new write variant. The repository's live tests/probes are evidence paths, not claims that a live host was contacted while writing this document.
