# Hermes transport conformance and evidence

The contract baseline is app revision
`09fc79c01aed91734e8006b5355209a31c52feca`. This page describes what to verify in
another implementation. A checked JSON example is documentary evidence, not
proof that a host, provider or device completed a scenario.

## Portable wire vectors

[vectors/wire.json](vectors/wire.json) contains 55 language-neutral framing cases:
20 accepted frames and 35 rejected frames. Each case has:

| Field | Meaning |
|---|---|
| `id` | Stable fixture name; not a protocol request ID |
| `frame` | The exact decoded UTF-8 WebSocket message text to pass to a framing decoder; it may contain line separators |
| `expected` | Ordered classifications, or one rejection category |
| `purpose` | The boundary this case establishes |

The file has `schemaVersion:1`, a `profile` and `sourceRevision`. JSON escaping
in the fixture container is removed once to obtain `frame`; do not double-decode
its contents or normalize its Unicode. These are examples for the pure framing
boundary, not necessarily valid method business payloads. For example, an empty
`approval` params object decodes as a server request but must not cause approval.

A port's vector adapter should:

```text
for each case:
    bytes = UTF8(case.frame)
    result = decodeWholeWebSocketMessage(bytes)
    if expected is a rejection:
        assert result rejected with that category
        assert no events, requests or results were published
    otherwise:
        assert categories match expected in order
        assert original opaque ID bytes are retained
```

Classifications are `event:<type>`, `request:<method>`, `result:<id>` and
`failure:<id>`. Error categories use the existing app decoder names
`invalidResponse` and `messageTooLarge`; a port can map them to its own typed
errors. Verify parsed field values as well as classifications when implementing
the adapter. In particular, retain the refusal reason in `error.data.reason`.

The vectors intentionally include composed/decomposed Unicode IDs, empty IDs,
null results, unknown server methods, newline framing, malformed mixed
request/response envelopes and strict cancellation payloads. They do not replace
size/load tests. Add generated boundary cases for exactly 4,194,304 bytes and
one byte more, 4,096 and 4,097 lines, depth 64/65, 1,024/1,025-byte IDs,
256/257-byte methods, and 4,096/4,097-byte cancellation reasons. Use multibyte
text too; counts are UTF-8 bytes. The nesting depth counts the whole JSON
value, including envelope objects.

Source for expectations: [DirectHermesWire](../../Bighelp/DirectHermes/DirectHermesInterfaces.swift)
and [DirectHermesProtocolParityTests](../../BighelpTests/DirectHermesProtocolParityTests.swift).
The fixture suite is additional portable coverage; the existing Swift tests
remain the executable implementation checks. The documentation validator only
checks fixture structure/JSON examples and links. It does not run the Swift
decoder or certify a port.

## Stateful acceptance matrix

Implement these cases using a scripted host plus disposable real-host checks.
Keep ownership and uncertain-outcome assertions visible in tests; observing a
message on screen is insufficient evidence that it was sent once.

The last column identifies source implementations and existing test/probe paths
to consult. A source link establishes an audited branch, not executed coverage.
Named tests establish only the stated scope; a linked fixture, helper or probe
is not evidence that every assertion in its row has a passing test. None of
these paths was executed against a host or device for this documentation change.

| Area / trigger | Required result | Source / existing test or probe path |
|---|---|---|
| Endpoint with deployment prefix and default port | Canonical identity retains prefix; every REST/WS path uses it | [Endpoint source](../../Bighelp/DirectHermes/DirectHermesInterfaces.swift); [endpoint tests](../../BighelpTests/DirectHermesEndpointTests.swift) cover ordinary/default scheme cases; [browser tests](../../BighelpTests/DirectHermesBrowserAuthenticationTests.swift) `syntheticBrokerReturnsThroughTheRealLoopbackListener` checks the prefixed authorize URL |
| Public HTTP, credentials in URL, traversal, redirect | Reject before exposing credentials | [Endpoint source](../../Bighelp/DirectHermes/DirectHermesInterfaces.swift), [HTTP delegate](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift); [endpoint tests](../../BighelpTests/DirectHermesEndpointTests.swift) cover URL credentials/public HTTP; traversal and redirect rules are source-audited here |
| Ungated host root HTML | Extract only inert exact-endpoint token form; no script execution or provider fabrication | [Bootstrap source](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift) `DirectHermesDashboardBootstrap`; [renewal tests](../../BighelpTests/DirectHermesSignInRenewalTests.swift) `aDashboardTokenTurnedAwayIsReadAgainAndTheRequestSentOnce` exercises a valid bootstrap and changed token, not the full malformed-HTML matrix |
| Gated host, multiple password providers, missing picker metadata | Negotiate the selected supported flow; native PKCE does not depend on picker metadata | [Auth source](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift) selects password providers; [protocol parity](../../BighelpTests/DirectHermesProtocolParityTests.swift) `nativeBrowserCapabilityDoesNotRequireProviderPickerMetadata` covers discovery metadata only |
| Provider/principal changes on restore or renewal | Retire the identity; do not attach old history to the replacement account | Source audit: [auth identity verification](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift) `requireIdentity`, [saved identity/vault](../../Bighelp/DirectHermes/DirectHermesCredentialVault.swift); an end-to-end identity-change test is still required for a port |
| Two callers rotate the same credential | Single-flight rotation and compare-before-save prevent overwriting a newer token | Source audit: [auth refresh flight](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift) `refresh`, [rotation persistence](../../Bighelp/DirectHermes/DirectHermesNetworking.swift) `persistRotation`; existing renewal tests do not establish cross-owner storage concurrency |
| Lost token exchange/refresh receipt | Follow flow-specific uncertainty policy, not general RPC mutation retries | Token exchange: [auth source](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift) `browserSignIn`. Refresh: [renewal tests](../../BighelpTests/DirectHermesSignInRenewalTests.swift) `aRenewalCutOffIsSentAgainWithinHermesSafeWindow` / `aRenewalCutOffIsNotResentAfterTheWindow`; browser callback tests do not exercise token redemption |
| WebSocket upgraded but no ready event | No application writes; readiness times out | Source audit: [networking](../../Bighelp/DirectHermes/DirectHermesNetworking.swift) `openSocket` / `nextOutbound`; [protocol probe](../../Scripts/DirectHermesProtocolProbe.py) checks successful readiness, not the missing-ready deadline. `ScriptedHermes` is an HTTP helper, not a WebSocket fixture |
| New socket or automatic reconnect | Register handlers and advertise server requests again | Source audit: [networking](../../Bighelp/DirectHermes/DirectHermesNetworking.swift) `advertiseServerRequests` / `openSocket`; the basic protocol probe does not exercise this handshake |
| Exclusive submission capability true/false/missing/wrong type | Submit/queue/slash admission requires `per_session_exclusive_submit:true`; false preserves independent operations; invalid shape is rejected | [Manifest source](../../Bighelp/DirectHermes/DirectHermesCapabilityManifest.swift); [reconnect parity](../../BighelpTests/DirectHermesReconnectParityTests.swift) `capabilityBooleanIsRequiredAndFalsePreservesReads` |
| Ordered multi-object frame, malformed trailing object | Apply complete decode validation before ordered callbacks; reject malformed frame | [Decoder source](../../Bighelp/DirectHermes/DirectHermesInterfaces.swift) `decode`; [wire vectors](vectors/wire.json) cover valid newline order and `invalid-trailing-line-atomic` checks atomic rejection |
| Duplicate server request, queue capacity | One decision/reply per exact request ID; bounded state | [Protocol parity](../../BighelpTests/DirectHermesProtocolParityTests.swift) |
| Cancel after reply queued, wrong-method cancel, stale handler completion | Retire only exact generation/ID/method; never emit cancelled/stale response | [Protocol parity](../../BighelpTests/DirectHermesProtocolParityTests.swift) `queuedResponseRemainsCancellableAndWrongMethodCannotRetireIt` covers pure queued-state transitions; [networking source](../../Bighelp/DirectHermes/DirectHermesNetworking.swift) fences async handler completion |
| Unknown but well-framed server request | Return `-32601`; no fabricated native content | [Networking source](../../Bighelp/DirectHermes/DirectHermesNetworking.swift) `acceptServerRequest`; [protocol parity](../../BighelpTests/DirectHermesProtocolParityTests.swift) establishes framing acceptance, not execution of the missing-handler response |
| Create receipt lost | Retain the create intent and original idempotency key; validate any recovered session | [Conversation tests](../../BighelpTests/DirectHermesConversationTests.swift) |
| Source/profile omitted or runtime equals stored ID accidentally | Test correct `source:"bighelp"` and distinct ID mapping explicitly | [Release contract](../../Bighelp/DirectHermes/DirectHermesReleaseContract.swift), [conversation tests](../../BighelpTests/DirectHermesConversationTests.swift) |
| `prompt.submit` returns `streaming` | Keep the turn pending until authoritative completion; no second free submit | [Conversation tests](../../BighelpTests/DirectHermesConversationTests.swift), [streaming probe](../../Scripts/DirectHermesStreamingProbe.py) |
| Send while active, admission conflict | Correct steer/queue path; never assert rejected/overlapping work became an answer | [Session control tests](../../BighelpTests/DirectHermesSessionControlClientTests.swift) |
| Cancellation before vs after send begins | Before dispatch is safe; after dispatch may be unknown; local cancellation is not server interrupt | [Networking](../../Bighelp/DirectHermes/DirectHermesNetworking.swift) |
| Socket lost after mutation dispatch | Persist uncertainty; reconnect never resubmits the journal entry | [Networking source](../../Bighelp/DirectHermes/DirectHermesNetworking.swift) records dispatched uncertainty; [conversation tests](../../BighelpTests/DirectHermesConversationTests.swift) `lostPromptReceiptRecoversReadinessWithoutResending` covers scripted prompt receipt loss and journal recovery |
| Runtime replaced, compaction changes stored ID | Resume the durable successor; ignore old-runtime events | [Reconnect parity](../../BighelpTests/DirectHermesReconnectParityTests.swift), [history projection](../../BighelpTests/DirectHermesHistoryProjectionTests.swift) |
| Replay ring incomplete or reset | Reconcile canonical snapshot/history; no invented missing events or successful turns | [Recovery source](../../Bighelp/DirectHermes/DirectHermesConversationClient+Recovery.swift); [conversation tests](../../BighelpTests/DirectHermesConversationTests.swift) `replyFinishedWhileAwayComesFromSavedHistoryWhenReplayIsImpossible` covers canonical-history fallback |
| Modern prompts vs legacy pending events | Use mode selected by snapshot contract; never answer the same prompt on both paths | [Legacy prompt tests](../../BighelpTests/DirectHermesLegacyPromptTests.swift), [secure prompt tests](../../BighelpTests/DirectHermesSecurePromptTests.swift) |
| Secret or sudo cancelled/host changes | Retire secure value and prevent late send; no logging/history copy | [Secure prompt tests](../../BighelpTests/DirectHermesSecurePromptTests.swift) |
| History page returns tool rows and visible rows at different rates | Preserve physical/visible coordinate semantics and page direction | [History projection](../../BighelpTests/DirectHermesHistoryProjectionTests.swift), [catalog tests](../../BighelpTests/DirectHermesSessionCatalogClientTests.swift) |
| Canonical Bot Chat hidden from REST list, archived idle session | Merge profiles' canonical sessions; preserve auto-archived vs deliberately archived behavior | [Catalog row tests](../../BighelpTests/DirectHermesSessionCatalogRowTests.swift) |
| Missing plugin/context feature | Chat works; optional integration unavailable without fallback | [Native context tests](../../BighelpTests/DirectHermesNativeContextTests.swift) |
| Context changes, compressed/weak ETag, mismatched request echo | Normalize only documented context tags; refresh on conflict at owning layer; unknown mutation if correlation lost | [Native context tests](../../BighelpTests/DirectHermesNativeContextTests.swift) |
| Host/principal switched while an HTTP call completes | Discard old result even on HTTP success | [Conditional ownership](../../BighelpTests/DirectHermesConditionalOwnershipTests.swift) |
| Attachment offset lost or digest/size inconsistent | Retry only read chunks by exact offset; validate assembled bytes; no arbitrary file/provider fallback | [Attachment tests](../../BighelpTests/DirectHermesAttachmentClientTests.swift), [managed files](../../BighelpTests/DirectHermesManagedFilesTests.swift) |
| Voice offer replay, provider work duplicate, lost result append receipt | Prevent second allocation/append; use native verified terminal answer only | [Voice client tests](../../BighelpTests/DirectHermesVoiceClientTests.swift), [voice media tests](../../BighelpTests/DirectHermesVoiceMediaTests.swift) |
| Groups older/session capability paths | Use the advertised pending action shape, not host version heuristics | [Recorded fixtures](../../BighelpTests/Fixtures/HermesGroups/session-path.json), [host path tests](../../BighelpTests/HermesGroupsHostPathTests.swift) |
| Groups send receipt lost | Reuse persisted room/event/text/thread identity; never generate another human event | [Groups contract tests](../../BighelpTests/HermesBotModeContractTests.swift) |
| Room log gap, changed authority, duplicate event | Reject inconsistent page; publish only contiguous ordered durable events | [Groups client tests](../../BighelpTests/BighelpLinkHermesBotModeClientTests.swift) |
| Stop receipt lost, later Send | Read log and reconcile persisted `cancel_id`; avoid cancelling newer work through a blind stop repeat | [Groups contract](../HERMES_BOT_MODE.md), [groups client](../../Bighelp/BotMode/HermesBotModeClient.swift) |
| Retry receipt lost or discard action appears | Preserve uncertain attempt; require exact current host task/generation; no inferred task failure from timeout | [Groups approvals](../../BighelpTests/BighelpLinkHermesBotModeApprovalTests.swift), [host path tests](../../BighelpTests/HermesGroupsHostPathTests.swift) |
| Peer grant setup | Keep credential in memory only; register against exact peer catalog and identity | [RoomLink probe](../../Scripts/RoomLinkProbe.py) |
| Device-tool duplicate, permission revoked, owner switch | Match exact operation owner; permission plus explicit agent grant; no false execution on replacement host | [Device tool contract](../IPHONE_DEVICE_TOOLS.md), [native bridge](GROUPS_AND_DEVICE_TOOLS.md) |
| Sealed alert modified or delivered twice | Verify signature and AEAD before rendering; deduplicate by authenticated event identity | [Sealed vector](../../BighelpTests/Fixtures/sealed-alert-v2-vector.json), [delivery contract](DELIVERY.md) |
| Notifications absent/failing, no enrollment | No effect on native sign-in, open, Send or history | [Production acceptance probe](../../Scripts/NativeWorkspaceAcceptanceProbe.py) |

## Run the documentation checks

From the repository root:

```sh
python3 Scripts/validate_hermes_transport_docs.py
```

This uses Python's standard library. It validates local Markdown link targets, table column counts, balanced code
fences, all `json` code blocks, vector metadata, unique vector names and embedded
frame syntax/classification structure. Deliberately invalid JSON frames are valid
fixture strings. It also checks static core HTTP path literals and native route suffix literals
against the reference to catch accidental inventory omissions. Dynamic path
expansions and field semantics still require source review. It does not contact a host,
load credentials, install Hermes or spend provider tokens.

Executable Apple regression tests need the repository's Xcode/SDK environment;
see [DEVELOPMENT.md](../DEVELOPMENT.md) and [AGENTS.md](../../AGENTS.md). Host probes
must use disposable checkouts/homes and record exact source revisions. Do not
point them at a maintainer's host or restart a shared gateway. The
[acceptance probe](../../Scripts/NativeWorkspaceAcceptanceProbe.py) also checks
that core native behavior works when cloud connections are rejected.

## Known limits and open compatibility questions

- The contract is a complete inventory of the native app's integration surface,
  not a promise that every historical Hermes host exposes all of it. No universal
  upstream OpenAPI/schema/version negotiation was found; capability discovery
  and endpoint-specific validation remain necessary.
- Swift source and tests establish what this app sends/accepts. They do not
  prove every host's retention windows, crash durability, exactly-once behavior
  or arbitrary response fields. Documented host-dependent behavior must be
  qualified against the actual deployed source.
- Native `session.create`'s short idempotency window is not indefinite recovery
  and does not make `prompt.submit` idempotent. Refresh, voice result appends,
  groups retry and HTTP mutations each have separate lost-receipt rules.
- Plugin HEAD removed Wiki routes that the audited app still knows. A route
  allowlist and a plugin version string cannot establish capability support.
- Server-request framing accepts more method names than the app implements.
  Unsupported `preview`, terminal, vault or window methods must not fabricate
  results; port only the supported handlers and capabilities.
- Browser callback compatibility, Android secure storage, background execution,
  microphone/WebRTC behavior, OS tools and Android push delivery require device
  and backend evidence beyond the source audit. An iOS APNs enrollment does not
  establish FCM support.
- Fixtures and scripted tests cannot establish provider latency, subscription
  entitlement, production plugin activation, notification delivery or physical
  device voice quality. Record source-only, scripted, disposable-host, simulator
  and device results separately.
