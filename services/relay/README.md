# Recovered Loopdy relay

Source-only recovery of the deployed **primary** relay into this repository.
This is not a new service, notification feature, dependency upgrade, or
deployment.

## Authority and limitations

The sole code authority is the downloaded deployed JavaScript module:

- SHA256: `3f07a9f97e5948feec13b683735cec1f997cb0f265eceefab9e52247012befa2`
- Length: **775005 bytes**.
- Input evidence filename: `relay-version-module-0.js`.

Original TypeScript and a source map were unavailable. The official script
and version download paths (including the version's `include=modules` response)
exposed no source map in the acquisition evidence supplied for this recovery.
The module still ends with `//# sourceMappingURL=index.js.map`; that exact line
is retained, but no map is invented or supplied.

These files are recovered **JavaScript byte slices**, not reconstructed original
TypeScript, a source-map reconstruction, or historical repository source. The
original source-boundary comments identify bundled origins only; they do not
prove the presence of those source trees or their complete contents. No archived
repository or historical source snapshot is an input.

`recovery-manifest.json` records the original byte ranges, fragment order,
lengths, SHA256 values, and boundary comments. Runtime-generated identifiers,
renamed symbols, third-party code, comments, whitespace, final exports, and the
final newline remain unchanged. The recovery tooling adds no banner, separator,
module wrapper, import rewrite, or formatting to the Worker output. Original
trailing whitespace and blank lines at fragment boundaries are intentional;
`git diff --check` reports those recovered lines. Do not trim them. The scoped
`.gitattributes` disables Git byte conversion without hiding whitespace warnings.

## Layout and shared scope

- `src/recovered/00-*` through `05-*`: bundled helpers and Zod, split at original
  source comments into bounded sections.
- `06-contracts.js`: bundled first-party contracts before the oRPC dependency.
- `07-vendor-orpc.js`: the original interleaved oRPC dependency section.
- `08-contracts-rpc.js`: bundled first-party RPC contracts.
- `09-schema.js` through `16-index.js`: schema, queue, APNs, auth, crypto,
  storage, Link enrollment, and Worker entry point, in original order.
- `scripts/assemble.mjs`: Node standard-library recovery and assembly tooling.
- `dist/worker.js`: generated Worker main; deliberately not committed.

The fragments share the original single-module symbol scope. They must be
concatenated, not individually imported or independently bundled. In particular,
Link enrollment retains its `cloudflare:workers` import; running this module
as an ordinary Node application is not a Worker runtime check.

## Deterministic build

From the repository root, with Node.js and npm available:

```sh
npm --prefix services/relay run build
```

Or without npm, from any current directory:

```sh
node /path/to/checkout/services/relay/scripts/assemble.mjs build
```

No install, package download, lockfile, transpiler, or bundler is needed. The
script reads binary buffers in the fixed manifest order and checks every byte
range and fragment digest before concatenating them. It checks the complete
output against the pinned deployed digest and length **before writing**
`services/relay/dist/worker.js`. A mismatch fails rather than producing a
rewritten or approximately equivalent baseline. An older output may remain after
a failed build: never consume it unless the current build succeeds.

This recovery intentionally pins the baseline. Future behavior changes require
a separately reviewed development/build contract; do not silently repin the
provenance digest or mix feature edits into this recovery.

## Repeat recovery from the authoritative module

From the repository root:

```sh
npm --prefix services/relay run recover -- /path/to/relay-version-module-0.js
```

Recovery accepts only the pinned module digest and size. It slices raw bytes at
the recorded original comments and creates source fragments plus the manifest;
it does not build a Worker. Existing identical files are left alone. Different
existing fragments or manifest cause a refusal, not an overwrite. No acquisition
path, timestamp, credentials, account identity, resource IDs, or deployment
version identifier is embedded in the generated manifest.

For authorized source acquisition, the generic Cloudflare API paths are:

```text
GET /client/v4/accounts/{account_id}/workers/scripts/{script_name}
GET /client/v4/accounts/{account_id}/workers/workers/{worker_id}/versions/{version_id}?include=modules
```

An authorized operator supplies independently verified account, script, and
version coordinates privately and keeps authentication in memory. Extract the
actual JavaScript module part without decoding/re-encoding or newline changes;
a multipart envelope or API JSON response is not the module. This script accepts
a local module file only and makes no network calls. Reacquiring current script
content is not proof that it still names this baseline; the pinned digest is the
acceptance gate.

## Copyright and third-party code

The deployed bundle includes Zod and oRPC code, with dependency versions and
origin paths preserved in its boundary comments. All original bundled code and
notices remain byte-identical. `third-party/` additionally retains the license
files fetched from the exact five npm package versions named by those comments;
`third-party/licenses.json` records verified package-archive SHA512 integrity.
This recovers those notices without claiming the compiled bundle is original
upstream source or changing the applicable licenses.

## Configuration and validation handoff

`wrangler.recovery.jsonc` is a **local validation configuration**, using the
verified primary relay compatibility date `2026-08-28` and `nodejs_compat` flag.
It deliberately contains no live database, queue, secret or account bindings and
is not a production deployment configuration. Never deploy it.

The integration owner independently ran the deterministic assembly, compared
its bytes with the downloaded module, passed both checks in
`Scripts/relay-recovery.test.mjs`, and ran this local packaging check:

```sh
wrangler deploy --config services/relay/wrangler.recovery.jsonc --dry-run
```

The output reported `--dry-run: exiting now`; nothing was uploaded. The two
recovery checks prove exact byte preservation and JavaScript parsing, not new
notification behavior. Live `/health` separately returned status `ok` before
this recovery. No APNs send, database/queue mutation, deployment, migration,
resource creation or production service restart was performed.

Future release configuration must preserve the existing live bindings and use
reviewed feature source, not this binding-free validation configuration. The
unchanged recovery does not itself provide the unread-session feature.
