# Provider logo hosting

A separate Cloudflare Workers Static Assets service serves public provider artwork.
It has no JavaScript entrypoint, account bindings, credentials, R2 dependency or
request-time image transforms. Link, notifications and the marketing site are not
modified by a logo deployment. Cloudflare currently documents static-file requests
as free and unlimited, with no additional asset-storage charge:

https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/

## Export and validate

Run from the repository root on macOS, with Python 3.9+ and system `/usr/bin/sips`:

```sh
python3 Scripts/publish-provider-logos.py --output .build/provider-logos-public
python3 Scripts/publish-provider-logos.py --output .build/provider-logos-public --validate-only
python3 Scripts/test_provider_logo_publisher.py
wrangler deploy --config services/provider-logos/wrangler.jsonc --dry-run
```

The exporter reads the approved asset catalog and its light/dark `Contents.json`
entries. It rejects unsupported/active SVG features before invoking the system
renderer. It preserves transparent canvas proportions and colors, rasterizes to
at most 512 pixels, strips nonvisual metadata and validates the resulting PNGs.
No third-party package is installed or fetched. PNG hashes define immutable paths;
a stable manifest digest identifies the exported catalog. The distribution also
contains the existing third-party notices.

The public output directory contains only the manifest, PNGs, headers and notices.
Do not point Wrangler at the repository root or include source, evidence, private
files or credentials. Generated output is intentionally not committed.

## Publish after approval

Verify the intended Cloudflare login with `wrangler whoami`. The account is chosen
through the operator's authenticated environment, never an account identifier or
secret committed to this repository. Inspect the existing Worker and domain
mapping before deployment. Never take over a hostname owned by another service.

```sh
wrangler deploy --config services/provider-logos/wrangler.jsonc
wrangler deployments list --name loopdy-provider-logos --json
curl --fail --silent --show-error --dump-header /tmp/provider-logo-headers.txt \
  https://logos.loopdy.app/provider-logos/v1/manifest.json \
  --output /tmp/provider-logo-manifest.json
```

Read back the exact deployed version and domain mapping. Fetch every PNG referenced
by the live manifest, verify its SHA-256 against both the manifest and the reviewed
local export, and inspect `Content-Type` and `Cache-Control`. The manifest must
revalidate after five minutes; hash-addressed PNGs are cacheable for one year.
Unknown routes must return 404. Do not enable Worker-first routing or request-time
code, which has different billing semantics.

The app checks on foreground activation, at most once daily after success, with a
15-minute retry delay after failure. It downloads the complete catalog, not just
the selected provider. HTTPS, strict origin/path checks, streamed response limits,
PNG/dimension checks and hashes protect the cache. The manifest's hashes are not
a signature against a compromised publishing account. Valid updates activate
atomically; failed requests retain the last-good local snapshot. Missing caches
use bundled artwork. Existing provider identity and mark-usage rules stay local.

## Update and rollback

1. Update the approved SVG source and provenance after verifying usage rights.
2. Export into the same dedicated output directory, validate, review and publish.
3. Read back the live manifest and all referenced images before announcing success.

The exporter preserves prior hash-addressed PNGs so a client holding the previous
five-minute manifest can finish downloading during rollout. Keep that generated
asset archive between deployments, or restore it from retained release evidence
before export. A clean export contains only current assets and is not a safe
replacement during an active manifest transition. The exporter caps retained
images at 1,000; removal requires an intentional retention review, not automatic
pruning during a publish.

For rollback, restore the previous reviewed manifest and image set into the
retained output while preserving the union of current and previous PNGs, validate,
and deploy it as another atomic release. Do not delete the failed version's PNGs
during rollback. Already-offline clients retain their last-good cache until they
refresh; rollback is not remote erasure.

The initial app change still requires one separately approved app release. Later
artwork-only deployments require no app build. Adding provider identities or
changing placement/eligibility rules remains an app-code change.
