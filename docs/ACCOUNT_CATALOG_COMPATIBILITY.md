# Account catalog compatibility

## September 10, 2026 incident

After the build 13 Link deployment, an account with a persisted `native_host`
record received that record from the signed `/v1/devices` endpoint. The shipping
iOS client's finite device-kind decoder rejected the entire device list. This
produced an account-load error, hid paired hosts and prevented readiness even
after successful passkey authentication and fresh phone registration.

Live signed profile and device-list requests succeeded during diagnosis; all
eight encrypted device names decoded with the current account key. The account
contained two Hermes hosts and one Native host. No key loss or missing pairing
record was established.

Native's separate branch had forward-migrated the Durable Object device table.
Deploying the v1 Worker did not undo that schema or its Native record. This is
expected durable-storage behavior; the regression was returning the newer kind
through the older catalog contract.

## Required behavior

- `/v1/devices` exposes only `phone`, `tablet`, `computer` and `hermes_host`.
- Apply the allowlist at the HTTP catalog boundary. Preserve the complete
  internal catalog for account deletion and other existing lifecycle operations.
- Preserve device IDs, encrypted names, keys, grants, revisions and authorization
  epochs. Do not revoke, rewrite or delete Native records to restore older apps.
- Native remains a distinct harness and authority. Its versioned enrollment and
  catalog contract must be separately qualified; never map it to Hermes.
- A Worker rollback must be checked against forward-migrated storage. Merely
  deploying an older binary does not restore an older database schema.
- Keep recognized-kind field validation, signed request authentication and
  mutation authorization strict. This repair changes only list projection.

## Regression evidence

The signed HTTP regression first failed because `native_host` and a future
runtime kind were returned alongside the four v1 kinds. It passes after the
allowlist is applied. A second test uses a real isolated Durable Object with a
forward-migrated Native table and proves the complete rows, grants and schema
remain unchanged after a signed v1 catalog read.

Live API recovery and actual iPhone sign-in acceptance are separate checks.

## Deployed repair

Worker version `5f188a82-5009-49de-a35d-67f668adee37` received 100% of traffic
at `2026-09-11T00:48:04Z` (September 10 locally). The 88-test Link suite,
TypeScript check and deployment dry run passed. A source manifest confirms only
the v1 contract helper, HTTP projection and regression tests differ from the
build 13 Link sources; existing directed phone-tool transport is retained.

Independent live verification at `00:48:30Z` returned HTTP 200 for health, signed
profile and signed device-list requests. The catalog contains three phones, two
tablets and two Hermes hosts, with unchanged IDs, encrypted names, lifecycles,
revisions and authorization epochs. Every returned name still decrypts. A
read-only directory query also confirms the Native registration remains active,
at epoch 1, without a revocation timestamp. No iOS binary or plugin update was
required for this repair. Actual phone sign-in acceptance awaits the user's retry.
