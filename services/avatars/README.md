# Public avatar catalog

Cloudflare Worker `bighelp-avatars`, custom domain `avatars.bighelp.app`.
Public reads; publishing is restricted to maintainers with Cloudflare deployment access.
There is **no public upload or mutation API**, user account, or Access seat requirement.
The service does not modify Hermes or the Swift app.

## App integration contract

`GET https://avatars.bighelp.app/v1/avatars.json`

JSON fields:

- `schemaVersion`: `1`. Reject an unsupported major schema without replacing a good cache.
- `revision`: opaque content revision; use the HTTP `ETag` for conditional requests.
- `categories`: `{id, name}` entries for `bighelp` / bighelp (official first-party, `isFirstParty: true`), `faces` / Faces, `shapes` / Shapes, `seasonal` / Seasonal.
- `sets`: currently active collections, each `{id, name, category, startsAt, expiresAt}`.
- `avatars`: currently active choices, each `{id, name, setId, category, startsAt, expiresAt, svg, png, nativeLook?, role?}`.
- `nextChangeAt`: UTC timestamp of the next configured start or expiry, or null.
- `svg` and `png`: `{url, sha256, bytes, contentType}`. PNG also has `width: 512, height: 512`.
- `nativeLook`: existing app metadata for builtin Faces and Shapes, `{style: "face"|"shape", shape, color?}`.

All timestamps have explicit offsets. A set is selectable when `startsAt == null || now >= startsAt`
and `expiresAt == null || now < expiresAt`. Expiry is **exclusive**.

The Halloween collection is category `seasonal`, set `halloween`.
Initial cutoff is `2026-11-03T00:00:00-06:00` (midnight starting November 3, America/Chicago),
which is `2026-11-03T06:00:00Z`. bighelp, Faces and Shapes do not expire. The bighelp collection contains the ten maintainer-supplied official mascots; optional `role` preserves each mascot's tagline.

### Client behavior

1. Fetch anonymously over HTTPS. No cookie, Cloudflare token, service token or host credentials.
   Only trust `avatars.bighelp.app` URLs from this catalog; disallow redirects to other hosts.
2. Cache the last validated catalog and use `If-None-Match` unchanged, including any `W/` prefix.
   The server supports strong/weak validators and lists. A 304 keeps the prior body.
3. Follow `Cache-Control` (at most five minutes, shortened before a scheduled transition).
   Refresh on foreground/picker opening when due, coalescing concurrent fetches. Schedule an
   in-app refresh at `nextChangeAt` while the picker is visible. Do not create an AI cron job.
4. Apply each entry's start/expiry locally too, even when offline or a refresh fails. An empty
   seasonal section is normal. A successfully returned empty active catalog is valid, not a network error.
5. Preserve bundled Faces and Shapes as offline fallbacks, deduplicating by their stable look IDs.
   Do not seed expired seasonal choices from a bundled fallback. Demo mode must stay network-free.
6. Use PNG for remote image display/saving. The original SVG is available for compatible renderers;
   do not assume UIImage/AsyncImage can decode arbitrary remote SVG. These are static pictures,
   not AvatarKit characters or animated native rigs. Expiry does not erase a selected picture.
7. Faces and Shapes are **procedural choices**, not a finite set of personal faces. Their PNG/SVG
   files are neutral preview exports. Applying `nativeLook` through the current face/shape path
   preserves the app's name-derived colors, randomization and editable native behavior. Do not
   replace those controls with fixed photos unless the user explicitly chooses that behavior.
8. Halloween choices use the image/photo save path. Clear incompatible CompanionStore and pet
   overrides through the existing AgentEditorModel save logic, so the previous character cannot
   keep winning over the newly selected image. Cache the downloaded PNG before saving.
9. A selection stores avatar ID, immutable asset URL, hash, and local PNG as appropriate. When
   its set expires, remove it from the picker **without changing an already selected avatar**.
   Old immutable asset URLs remain public. Expiry is discovery scheduling, not access revocation.
10. Bound catalog downloads to 2 MB and each asset to its declared size and at most 2 MB; verify
    SHA-256 before saving. Decode unknown fields leniently and skip malformed individual entries.
    Never discard a good cache because a request failed or a response is oversized/malformed.
11. Test conditional refresh, offline fallback, local expiry at the exact boundary, unknown entries,
    duplicate builtin options, saving a seasonal PNG, and preserving it after expiry. Verify native
    UI on iPhone, Mac Catalyst and visionOS locally, never Apple builds on GitHub Actions.

`HEAD` and CORS preflight are supported. Unsupported paths return 404. Writes return 405.

## Maintainer operations

From `services/avatars`:

```sh
npm ci
npm test
npm run build
npx wrangler deploy
```

Authenticated deployment is the only write path. No credentials belong in the app or public repository.
Read-only users cannot change the list even if they know every URL or send forged headers.

Change an expiry, then test/build/deploy:

```sh
node scripts/set-expiry.mjs halloween '2026-11-03T00:00:00-06:00'
# Remove the cutoff:
node scripts/set-expiry.mjs halloween none
```

A date-only value is refused because it has no timezone. Use the correct offset for the date,
not today's offset. The script changes local `sets.json`; it is not live until deployed.
Set `startsAt` in the same file to schedule a future collection. Request-time filtering handles
activation/expiry with no cron, job, database mutation or new deployment at the cutoff itself.

### Add a set

1. Add a set to `sets.json`, with unique lowercase ID, name, category, `startsAt` and `expiresAt`.
2. Place reviewed SVGs under `sources/<set-id>/` and an `index.json` array of
   `{id, name, file}` entries. IDs and basenames must be safe lowercase identifiers.
3. Review art rights. Publishing is maintainer-only; community submissions are not enabled.
4. Run tests and build. The static SVG validator rejects scripts, event handlers, external images,
   URL paint resources, XML entities, and unsupported markup. Convert more complex SVGs to supported
   paths/shapes before adding them; do not loosen validation just to force an upload through.
5. Inspect the PNG previews, commit source/config and **public/assets/** together, open the PR,
   and deploy with the authorized Cloudflare account. Read back the public list and asset hashes.

Builds emit the runtime `catalog.json` and content-addressed SVG + transparent 512-square PNG files.
`catalog.json` is generated and ignored by git. `public/assets/` is deliberately versioned and
append-only: retaining earlier content hashes keeps already selected avatars working after edits.
Never delete old assets as part of seasonal expiry or normal rebuilds.

Builtin preview sources can be regenerated using `../../scripts/export-builtin.sh` on macOS with Swift.
That exporter compiles the app's existing pure geometry code, not the app itself, and does not change
its Swift source. See the per-source provenance/notice files. Public attribution is at `/NOTICES.txt`.

## Verification and rollback

`npm test` covers seasonal boundary transitions, ETags, read-only methods, asset retention routing,
SVG validation, rasterization and expiry editing. `npm run build` validates every published source.
Use `npx wrangler deploy --dry-run` before uploading. After deploy, fetch the catalog and every
listed SVG/PNG, compare declared bytes and SHA-256, and test weak ETag 304 plus write rejection.

Cloudflare deployment rollback restores the previous Worker/config. Retain all previously published
content-addressed assets in every subsequent upload. The service is isolated from the template catalog.
