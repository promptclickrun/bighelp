# Legacy Link recipient overflow policy

Related incident: #75. This repair changes legacy encrypted-v1 admission only;
it does not require Direct, recipient lanes, native-session migration, a host
plugin update, or a new native application build.

## Approved behavior

Future copies for saturated recipients may be skipped. Previously accepted
frames must remain intact. Returning devices must be able to request fresh
host-backed session state. An offline device must not spend another device's
storage allowance.

| Data | Custody and recovery |
| --- | --- |
| Frames accepted before policy migration | Grandfathered, preserved until the existing authenticated receipt or explicit revocation path removes them |
| Sender's next pending frame at migration | One durable, nonrenewable full-fanout rescue allowance; matching acceptance only after persistence |
| Future normal traffic | Independent recipient quota; saturated-recipient copies omitted before acceptance |
| Returning connected recipient | Separate bounded recovery allowance, without bypassing older retained frames |
| Skipped transient events | Not replayable by the transport; session refresh restores only content actually retained by the host |

The outer v1 frame, encryption, sender sequence, ready control, acceptance and
receipt shapes remain unchanged. Delivery semantics change: acceptance means
custody for policy-selected recipients, not every paired recipient. There is no
empty acceptance: if every recipient is ineligible, the original backpressure
response (or legacy close-and-retry) remains. Acceptance is not proof that a
business mutation completed, a phone rendered content, or a session refreshed.

## Bounds and ordering

Normal recipient budgets are 4,096 frames and 64 MiB. A connected recipient may
also use a separate 512-frame / 4-MiB recovery allowance when its normal budget
is exhausted. A budget is released by receipts or existing explicit revocation,
not by reconnecting, socket replacement, or Durable Object eviction. Old global
recovery overrides must not multiply these new per-recipient budgets.

New active registrations are limited to 16. Existing devices are grandfathered,
including an existing roster above this limit; there is no automatic revocation.
The aggregate payload bound is existing accepted debt, plus the finite cutover
rescue allowance, plus normal/recovery allowances for the bounded active roster.
Database/index overhead and actual provider capacity still require rollout
preflight. This policy does not promise unlimited retention or throughput.

All data for a recipient uses the existing ordered, receipt-driven replay pump.
Fresh replies may be admitted while an older queue drains, but they cannot jump
that queue: existing clients receipt lower sender sequence numbers as duplicates.
A large retained queue can therefore delay the first fresh response. Merely
marking a socket online does not prove successful recovery.

## Migration and rollback

Migration is transactional and has a persistent completion marker. It preserves
inline and chunked ciphertext, frame identities, receipts and delivery order.
Preexisting active sender/epoch next-sequence rescue records are created only
once. Full-fanout rescue is committed with acceptance and its consumption; a
lost acknowledgement retries or reconciles the original identity. New device
registrations and later evictions do not mint rescue allowances.

No queue clearing, re-pairing, device revocation, or administrative fake receipt
is a recovery procedure. There is no TTL purge or claim that all ciphertext is
reconstructible chat history. Voice data, arbitrary sends and correlated
operation results may not be recoverable from session history.

An older Worker can resume global backpressure over the retained queues. It
cannot undo already skipped future copies. Do not reset migration state or
rerun a migration to obtain more space. Rollback after new-policy writes needs
an explicitly reviewed forward-compatible accounting/recovery procedure.

## Acceptance and rollout boundary

Focused acceptance covers saturated-recipient isolation; authenticated encrypted
v1 request/reply delivery; returning-device reservation and ordered backlog
replay; byte and frame limits; chunk accounting; migration and lost-ACK replay;
all-recipient refusal; registration limits and idempotency; and revocation.

Existing app source already requests authoritative session catalogs at reconnect
and refreshes session state after authenticated sequence gaps. Those source
paths do not prove physical-device recovery, and a transport fixture does not
prove a real Hermes catalog response. Production acceptance requires both
signed pre/post diagnostics and an actual fresh agent/session catalog on the
intended phone. Deployment, application updates and host restarts remain
separate authorization boundaries.
