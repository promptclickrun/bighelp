# Public, color-editable avatar catalog

Cloudflare Worker **bighelp-avatars**, custom domain **avatars.bighelp.app**.
Public reads. Only maintainers with Cloudflare deployment credentials can publish. There is no
public upload/mutation API, sign-in requirement or per-user Access seat. No Hermes core changes.

**Use AvatarKit JSON as the app's rendering source. PNGs are previews, not editable avatars.**

## Live endpoints

- `GET https://avatars.bighelp.app/v1/avatars.json`: discovery, categories, collections, dates, asset URLs.
- `GET https://avatars.bighelp.app/v1/avatar-kit.json`: active characters in the app's existing AvatarKit schema.
- Each discovery entry's `kit.url`: immutable, single-character AvatarKit pack for caching and saved selections.
- Each entry's `svg.url`: original source art. `png.url`: transparent 512×512 default-color preview.
- `GET https://avatars.bighelp.app/NOTICES.txt`: attribution.

All endpoints are anonymous HTTPS reads. GET/HEAD and CORS OPTIONS work; writes return 405 and unknown
paths return 404. Do not give the app Cloudflare credentials or cookies.

## Categories and collections

| Category ID | Label | Set ID | Count | Expiry |
|---|---|---|---:|---|
| bighelp | bighelp | bighelp | 10 | none |
| bighelp | bighelp | pocket-curios | 20 | none |
| faces | Faces | faces | 10 | none |
| shapes | Shapes | shapes | 8 | none |
| seasonal | Seasonal | halloween | 10 | 2026-11-03T00:00:00-06:00 |

`bighelp` is official first-party art; its category carries `isFirstParty: true`.
Its optional `role` strings preserve the supplied mascot taglines.

Halloween's initial cutoff is midnight **starting November 3, 2026 in America/Chicago**,
`2026-11-03T06:00:00Z`. Expiry removes choices from discovery, not from people's saved avatars.

## Discovery schema

- `schemaVersion`: 1.
- `revision`: opaque content revision. Use the HTTP ETag for conditional requests.
- `avatarKitURL`: the active combined-kit endpoint above.
- `categories`: `{id, name, isFirstParty?}`.
- `sets`: active `{id, name, category, startsAt, expiresAt}` collections.
- `avatars`: active `{id, name, role?, setId, category, startsAt, expiresAt, kit, svg, png, nativeLook?}`.
- Each `kit`, `svg`, `png` descriptor: `{url, sha256, bytes, contentType}`. PNG also has `width` and `height`.
- `nextChangeAt`: next configured start/expiry instant, or null.
- `nativeLook`: existing procedural Faces/Shapes metadata `{style: "face"|"shape", shape}`.

All dates are null or timestamps with explicit offsets. A set is active when start <= now < expiry,
with a null boundary unbounded. Unknown optional fields should not break decoding.

## Native kit contract

Both the combined kit and individual immutable packs have the same top-level format as the app's
bundled `Bighelp/Resources/AvatarKit.json`:

```json
{
  "version": 1,
  "states": ["idle", "listening", "thinking", "waiting", "talking", "happy", "sleeping"],
  "themes": [],
  "keyframes": {},
  "characters": []
}
```

The arrays above illustrate field types; live responses contain the actual themes and characters.
The combined response additionally has `nextChangeAt` and `revision`, ignored by the existing decoder.
Character IDs exactly match discovery IDs. Each character has `name`, `role`, `family: "classic"`,
a numeric `look`, `colors` and a native geometry `tree`. Coordinates are normalized into the renderer's 200×200
art space. The official bighelp, Pocket Curios and Halloween characters come unchanged from the supplied authored packs in
`sources/packs/`, including all seven states and shared animation keyframes. Faces and Shapes remain
static conversions. Their idle style is the fallback for other states. Legacy SVG/PNG assets remain
source previews; render the JSON for authoritative authored appearance and state-aware previews.
Pocket Curios SVG/PNG previews are derived from its native idle JSON with the backdrop disc off.
Its 20 characters are permanent additions under the first-party bighelp category, with no expiry.

Colors are not baked into a raster. Editable fills/strokes use `@p`, `@s`, `@a`, `@ink` slots with the
original colors in `character.colors`. Primary `@p` is present on every avatar. Some accents/highlights
remain literal to preserve the supplied artwork. A primary-color change affects primary surfaces;
secondary/accent surfaces keep their own colors unless the app changes those slots too, as with the
existing kit's colorway behavior. Converted Faces/Shapes slot assignments are explicit in `sources/palettes.json`; authored packs carry
their own palette tokens and defaults and bypass SVG conversion.

Candy Corn's SVG clipping is flattened into ordinary paths at build time. The existing native renderer
does not need new clip support. Native Shape triangle raster/kit viewports retain its overhanging apex.
SVG source bytes are preserved. Unsupported markup fails the build rather than silently losing art.

## Paseo/app implementation requirements

1. Integrate the remote kit into the existing Avatar Studio, preserving the color picker and previews.
   Resolve geometry by string ID from an observable remote/bundled library, not only `AvatarKit.bundled`.
   **Do not decode new IDs through the closed CompanionCharacter enum:** it falls back to lobster for
   unknown IDs. Add a persisted remote ID/asset reference while retaining legacy enum migration.
2. Render using `AvatarKitRenderer` and the current `AvatarKitColors`/appearance color override logic.
   The selected custom color must remain editable after saving and reopening. Do not store the PNG as
   the sole source. Keep the immutable kit pack and appearance settings with the saved selection.
3. Generate a customized PNG snapshot locally only where a picture is required (host avatar, widgets,
   other clients). Clear incompatible companion/pet overrides through the existing save path, without
   discarding the new remote character's saved geometry or color settings.
4. Preserve existing procedural Faces/Shapes choices and their name-derived behavior. `nativeLook`
   maps those legacy choices; downloaded Face art uses the neutral preview seed `agent`, not the
   current person's name. Do not replace randomization/name-following controls with a frozen preview.
5. Merge bundled fallback choices without duplicates. A failed fetch must not erase a good cached
   catalog or selection. Demo fixtures must remain network-free. Do not add a second settings/menu.
6. Use HTTPS with exact allowed host `avatars.bighelp.app`, including redirects. Bound catalog/combined
   kit and per-asset downloads to 2 MB. Verify bytes/SHA-256 before caching immutable packs. Add app-side
   bounds for node count, nesting, path length, finite geometry and allowed native primitives; the
   bundled decoder alone was not designed as an arbitrary network-input validator.
7. Return ETags unchanged in `If-None-Match`, including W/. Strong/weak/list validators work. Honor 304
   and Cache-Control (at most five minutes, shortened before the next schedule transition). Coalesce
   requests; refresh on foreground/picker opening when due and at `nextChangeAt` while visible.
8. Apply start/expiry on device even offline. A valid empty seasonal list is expected. At expiry hide
   entries from the picker, but retain already selected geometry, colors and snapshots. Immutable kit,
   SVG and PNG URLs stay public. Expiry is discovery scheduling, not access revocation or forced reset.
9. A JSON change may add characters using current renderer features without an app update. New drawing
   primitives/behaviors still need an app update. Do not claim arbitrary SVG animations work natively.
10. Test cache/304/error handling, custom-color changes and persistence, unknown remote IDs, deduping,
    precise seasonal expiry, retaining an expired selection, switching between existing/pet/remote
    avatars, and cold/offline rendering. Verify iPhone, Mac Catalyst and visionOS locally, never Apple
    builds in GitHub Actions. Native Mac rendering probes here are not device UI acceptance tests.

## Maintainer publishing

From `services/avatars`, using the authorized Cloudflare account:

```sh
npm ci
npm test
npm run build
npx wrangler deploy --dry-run
npx wrangler deploy
node scripts/verify-live.mjs
```

Only deployment credentials can change the live collection. There is no public write route or admin
credential embedded in the application.

Set/remove an expiry, then test, build and deploy:

```sh
node scripts/set-expiry.mjs halloween '2026-11-03T00:00:00-06:00'
node scripts/set-expiry.mjs halloween none
```

The script edits local `sets.json`; it is not live until deployed. Date-only/offset-free timestamps are
refused. Use the offset appropriate for that date, including daylight saving changes. `startsAt` in
`sets.json` schedules future collections. Request-time filtering handles activation and expiry; no
cron, AI job or deployment is needed at the cutoff itself.

To add artwork:

For official bighelp, Pocket Curios or Halloween updates, replace the corresponding reviewed JSON in `sources/packs/`.
For new authored collections, register the set/file/count in `scripts/build.mjs`, add `sets.json`
metadata and `sources/<set-id>/index.json`, then add static idle SVG previews. Use the authored
JSON palette directly, not a second entry in `sources/palettes.json`. Remove fully transparent
state-only groups from static SVG previews (sleeping Z text is invisible at idle); never remove
them from the native JSON. Extend the authored equality test and native animation probe for the new set.
The build preserves character trees and shared animation settings exactly; conflicting settings fail.
The native probe also checks every authored character animates in each of its seven states.

For SVG-derived collections:

1. Add a collection to `sets.json` and reviewed SVGs under `sources/<set-id>/`.
2. Add its `index.json` entries `{id, name, role?, file}`. Keep IDs stable and globally unique.
3. Add explicit palette slots for each ID in `sources/palettes.json`; `p` is mandatory. Pick surfaces
   deliberately, not by guessing that the most frequent SVG color is the body. Preserve art rights.
4. Build validates SVGs and exports color-aware JSON and preview PNGs. Scripts/event handlers,
   external resources and XML entities are refused. Only supported native geometry may publish.
5. Check native renders and color edits, commit source/config plus **public/assets/**, and deploy.

`catalog.json` is generated/ignored. `public/assets/` is deliberately versioned and append-only. Never
remove old hashes during normal updates or seasonal expiry: saved selections depend on them.
Rollback through Cloudflare deployments when needed; preserve published assets on subsequent uploads.
The service is independent of the template catalog.

## Reproduction and verification

- `npm test`: scheduling, ETags, read-only routing, SVG safety, clipping conversion, palette tokens,
  normalized geometry, PNG rendering and expiry editing.
- `npm run build`: validates/converts every source and generates the deployment catalog.
- From repo root, `bash scripts/export-builtin.sh`: isolated Mac Swift export of existing Faces/Shapes,
  checked against the app's frozen face hashes and shape/eye vectors. Does not build/change the app.
- `python3 scripts/verify-native.py <output-directory>` from this service: compiles the app's unchanged
  AvatarKit decoder/renderer in an isolated Mac probe over SSH (`AVATAR_SWIFT_HOST`, optional `AVATAR_SSH_CONFIG`). Decodes and renders
  every character, overrides primary to magenta and verifies each rendered image changes. PNGs permit
  visual comparisons. It uses a test-only hex Color adapter instead of unrelated app dependencies.
- `node scripts/verify-live.mjs`: fetches both feeds plus every referenced JSON/SVG/PNG, checks IDs,
  sizes, hashes, PNG dimensions and JSON primary slots, plus HTTP validators and read-only behavior.

The Swift app itself is unchanged in this infrastructure PR. Paseo still needs to wire the library,
remote selection persistence and native controls into the shipping app.
