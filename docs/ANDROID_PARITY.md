# Android parity acceptance matrix

Target: a functioning Android application close to bighelp's everyday Apple workflows. The discovery/demo foundation is not acceptance of the target. Current Apple source and the [transport contract](NATIVE_TRANSPORT.md) define behavior. The implementation plan is [Android end-to-end parity](superpowers/plans/2026-10-27-android-parity.md).

Status is updated from source and executed evidence. **Not started** and **pending** are incomplete. Host capability absence is a runtime state, not proof that the Android implementation exists. Tests of a policy type do not establish live behavior. Apple-only platform surfaces and store-distribution gates have separate dispositions.

Contract references below name chapters under `docs/hermes/`, with product references relative to the repository root. Exact source implementations are linked from those chapters.

| Workflow | Required behavior | Authority | Implementation | Evidence |
|---|---|---|---|---|
| Authentication | Automatic dashboard, session/access token, password PKCE, loopback browser PKCE; restore and rotation | CONNECTION.md §§3–7 | In progress: Task 1 | Pending |
| Proxy access | Independent proxy headers, private HTTP consent and prefix-safe paths | CONNECTION.md §§1–2 | In progress: Task 1 | Endpoint tests exist; full proxy pending |
| Gateway | Ready deadline, ticket subprotocol, ordered RPC/events, heartbeat and reconnect | CONNECTION.md §§7–10 | In progress: Task 1 | Pending |
| Prompts | Questions, approval, secret/sudo and exact cancellation ownership | CHAT.md §§8–9 | Not started | Pending |
| Saved computers | Encrypted credentials, add/select/remove, restore exact principal | CONNECTION.md §6 | Not started | Pending |
| Agents and Bots | Real directory and canonical Bot Chats; edit instructions, model, appearance | REFERENCE.md §Profiles | Not started | Pending |
| Sessions | Catalog, create/resume, search, rename, archive/restore/delete/fork | CHAT.md §§1–3,11 | Not started | Pending |
| Live chat | Streaming, tools, segment finals and authoritative turn terminal | CHAT.md §§4,7 | Not started | Pending |
| Active-turn controls | Steer default, queue, stop and slash/model/reasoning controls | CHAT.md §§4,6,12 | Not started | Pending |
| Durable recovery | Draft/journal before dispatch, no uncertain replay, replay/history after restart | CHAT.md §§5,10–11 | Not started | Pending |
| Reader and input | Stable history anchor, paging, Latest, keyboard, rotation and background recovery | ../CHAT_INTERACTION_CONTRACT.md | Demo only | Live verification pending |
| Rich transcript | Markdown, tools, reasoning and supported cards with inert invalid fallback | EXTENSIONS.md §§Card documents,Agent deliveries | Not started | Pending |
| Outgoing attachments | Image/PDF/file admission and uncertainty, real picker/share | EXTENSIONS.md §Outgoing chat attachments | Not started | Pending |
| Incoming media | Resolved chunked downloads, digest/cache, image/audio/video/file viewer | EXTENSIONS.md §§Incoming attachment resolution,Managed transfers | Not started | Pending |
| Files | Agent workspace scope, browse/read/upload/download/edit with conflict handling | EXTENSIONS.md §Configured workspace; REFERENCE.md §Stock files | Not started | Pending |
| Feed, Ideas, Goals | Per-agent content, details, feedback and state changes; empty by default | EXTENSIONS.md §Board | Not started | Pending |
| Projects | Real catalog/folders/active pointer and exact session workspace binding | REFERENCE.md §Projects | Not started | Pending |
| Code | Project/branch/worktree launch, Changes, supported Ship and staged jobs | REFERENCE.md §Stock Git; AGENTS.md Code mode | Not started | Pending |
| Kanban | Boards, task CRUD/move/comments, attachments and ordered event updates | EXTENSIONS.md §Independent Hermes Kanban plugin | Not started | Pending |
| Workflows and Dev Factory | Recipes/runs/editor/actions, exact sign-off and verified artifacts | EXTENSIONS.md §Workflows | Not started | Pending |
| Scheduled tasks | List/detail/runs, capability-gated friendly editing and run actions | REFERENCE.md §Scheduled tasks | Not started | Pending |
| Usage | Host analytics and provider limits, unknown values remain unknown | REFERENCE.md §Usage; EXTENSIONS.md §Usage | Not started | Pending |
| Apps | Native connection cards, Composio/MCP connection and account management | GROUPS_AND_DEVICE_TOOLS.md §App connection cards; EXTENSIONS.md §Composio | Not started | Pending |
| Groups | Hosted rooms, durable send/log, pending actions and stop; both host paths | GROUPS_AND_DEVICE_TOOLS.md §§1–8 | Not started | Pending |
| Voice | Transcription/speech and supported real live call delegation | EXTENSIONS.md §Voice protocols | Not started | Pending |
| Bot Screen | Authenticated display bridge, bounded RFB viewer and control handoff | GROUPS_AND_DEVICE_TOOLS.md §Display transport | Not started | Pending |
| Android tools | Applicable device tools, explicit grants, OS permission and revocation | GROUPS_AND_DEVICE_TOOLS.md §§9–10 | Not started | Pending |
| Notifications | Foreground alerts and exact-chat routing; background delivery needs real Android adapter | NATIVE_TRANSPORT.md; Android delivery adapter | Not started | No FCM server contract established |
| Settings and navigation | One menu/Settings, appearance/layout/mode, identity, computers and Nerd Mode | ../../DESIGN.md; ../../AGENTS.md | Demo subset | Live acceptance pending |
| Accessibility | TalkBack, focus, font scale, contrast and reduced motion | ../../DESIGN.md | Not started | Pending |
| Apple-only surfaces | Watch, CarPlay, visionOS, Live Activities, Shortcuts, Health/Focus/AlarmKit | PORTING.md §Android and Expo boundaries | Platform boundary | No Android support claim |
| Store distribution | Permanent ID/signing, identity and physical-device checks, Play testing | ../../android/README.md | Account created; verification deferred | Distribution gate, separate from app implementation |

## Evidence classes

- JVM/scripted: deterministic HTTP/WebSocket, persistence, reducers and failure injection.
- Demo emulator: UI controls with explicitly invented data, no Hermes compatibility claim.
- Disposable Hermes: actual isolated host/plugin at recorded revisions, synthetic model and made-up workspace.
- Android emulator/device: installed-file identity and exercised real controls/lifecycle; emulator evidence does not establish physical-device behavior.
- Live services: only explicitly authorized services; no inference from fixtures or an Apple client.

The full goal remains open while required everyday workflows lack implementation or appropriate end-to-end evidence. Each accepted row records exact source/build and evidence; no placeholder control or generic raw-data page counts as implementation.
