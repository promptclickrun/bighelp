# Template Catalog (`catalog.bighelp.app`)

A Cloudflare Worker plus D1 that serves Feed/Ideas/Goals blueprints and agent templates to the app and
bighelp.app, and holds community submissions for review. New templates go live without an app build.

| Piece | Name |
|---|---|
| Worker | `bighelp-catalog`, custom domain `catalog.bighelp.app` |
| D1 | `bighelp-catalog` (one table, `templates`; `migrations/`) |
| Turnstile widget | "bighelp Template Catalog submit" (bighelp.app, www, bighelp.pages.dev); secret is the Worker secret `TURNSTILE_SECRET` |
| Access app "review" | path `catalog.bighelp.app/review`, the maintainer's email, or the `bighelp-catalog-reviewer` service token |
| Site page | `bighelp.app/templates` (bighelp-site `src/templates.html`) |

Submitting needs no account. Only reviewers go through Cloudflare Access, and its one app holds just the
maintainer's login and a service token, so it never uses Zero Trust seats for the public. The Worker verifies
that Access JWT itself (signature, audience, issuer, expiry), so a misconfigured Access app can't open
`/review`.

## Routes

**Public, no auth, CORS `*`, `Cache-Control: max-age=300`, `ETag` (send `If-None-Match`, get 304):**

- `GET /v1/catalog.json`: `{ schemaVersion: 1, revision, blueprints: [...], agents: [...] }`
- `GET /v1/board-blueprints.json`: the same shape as the app's bundled `Resources/BoardBlueprints.json`
  (`pages[].groups[].prompts[]` with `id`, `text`, optional `goalCategory`, plus optional `credit`), so
  `BoardBlueprintCatalog(data:)` parses it unchanged.
- `GET /v1/agent-templates.json`: `{ schemaVersion: 1, revision, templates: [...] }`

Only approved templates appear. Submitter emails and review notes never do.

Blueprint: `{ id, board: feed|ideas|goals, category: productivity|marketing|content|personal|research,
text, goalCategory?: health|relationships|finance|career|interests|productivity|other, source:
bighelp|community, credit?, updatedAt }`. `[brackets]` in `text` are the app's fill-in blanks.

Agent: `{ id, name, role, vibe, description?, instructions, category:
work|personal|learning|creative|research|support|fun, symbol?, variables?, source, credit?, updatedAt }`.
`instructions` uses `{{agent_name}}` like the bundled SOUL templates. `symbol` is an SF Symbol name set
by a reviewer; it can be missing. `variables` lists the fields the app asks for before it fills the
template's other `{{key}}`s; submit, review and the seed all check them against the text. The rules are in
[docs/TEMPLATE_VARIABLES.md](docs/TEMPLATE_VARIABLES.md).

The seed (`scripts/build-seed.mjs` → `seed/0001_bundled.sql`) loads exactly what the app bundles today,
with the same ids (`feed-productivity-1`…, `anchor`…), so the app can match remote and bundled items.

**Submitters (no sign-in, CORS `*`, no cookies):**

- `POST /submit/templates`: a blueprint or agent body plus `submitterName`, `username`, `email` and
  `turnstileToken` (from the Turnstile widget). Returns 201 `{ id, status: "pending", statusToken }`.
  400 `{ error, field }` on bad input, 403 if Turnstile fails, 429 at 10 pending or 10 a day per email,
  20 a day per network, or once 200 community templates are waiting across everyone.
- `POST /submit/status` `{ tokens: [statusToken, ...] }`: `{ submissions: [{ id, kind, title, status,
  reviewNote (rejected only), createdAt }] }`. The site keeps each receipt in the browser's storage.
  Only a hash of the receipt is stored.

The username is the public credit. Name and email are visible only to reviewers. They aren't verified;
they link one person's submissions together. The network limit uses an HMAC of the IP address, never the
address itself.

**Agents (through the bighelp plugin, after a one-time GitHub sign-in):**

The plugin signs the person in with GitHub's device flow (OAuth App under `promptclickrun`, no scopes),
then trades the GitHub token for an install token. Limits count per numeric GitHub user ID, so reinstalling
the plugin or adding hosts doesn't add any.

- `POST /agent/register` `{ githubToken }`: the Worker calls GitHub's `GET /user` once and forgets the token.
  201 `{ token, login, dailyLimit }`. 401 if GitHub refuses the token, 403 if the account is younger than
  30 days or banned. Only a SHA-256 of the install token is stored, with the GitHub ID and login.
- `POST /agent/revoke` with `Authorization: Bearer <token>`: `{ revoked }`.
- `POST /submit/agent/templates` with `Authorization: Bearer <token>`: the same template body as the web
  form, no name, email or Turnstile. 201 `{ id, status: "pending", statusToken, credit, remainingToday }`.
  401 if the install isn't signed in (or its account was banned), 429 at 5 a day or 10 pending per GitHub
  account, or when the queue is full. The GitHub login is the public credit. Status works like the web form.

**Reviewers (`/review`, Access service token or the maintainer's login):**

- `GET /review/templates?status=pending|approved|rejected|all&kind=&limit=`
- `GET|PATCH|DELETE /review/templates/:id` (PATCH edits fields before approving, including `symbol`)
- `POST /review/templates/:id/approve|reject|unpublish` with `{ note }`; reject requires a note,
  which the submitter sees
- `POST /review/templates`: publish a reviewer-written template straight away
- `POST /review/accounts/:githubId/ban` `{ note }` / `unban`: a ban signs out every install of that GitHub
  account and blocks it from signing in again

## Reviewing

`scripts/catalog-review.py` wraps the review API. It reads `CF_ACCESS_CLIENT_ID` and
`CF_ACCESS_CLIENT_SECRET` from the environment or `~/.config/bighelp-catalog/reviewer.env`:

```sh
catalog-review list                      # pending queue
catalog-review show bp-1234abcd-5678
catalog-review edit agent-… vibe="Calm, organized" symbol=airplane
catalog-review approve agent-…
catalog-review reject bp-… --note "Too close to an existing blueprint."
catalog-review ban 12345678 --note "Spam"   # GitHub user ID, shown as github:<id> in list
```

Raw HTTP works too: send the two `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers. A bad token
gets a 302 to the Access login, not a 401. The service token expires a year after it was made; rotate it in
Zero Trust › Access › Service Tokens and update the env file.

## App integration (not built yet)

What the app needs, in the same style as `ProviderLogoStore`:

1. A store that fetches `/v1/board-blueprints.json` and `/v1/agent-templates.json` on foreground at
   most every few hours, with `If-None-Match`, a size cap (say 1 MB), https and host checks, and no
   cookies. It keeps the last good copy in Caches and uses the bundled JSON when there is none.
2. `BoardBlueprintCatalog.shared` becomes "remote snapshot if present, else bundled". The parser
   already ignores unknown keys (`credit`, `schemaVersion`, `revision`).
3. The agent picker's Templates rail reads remote agents. `AgentSoulTemplate.soul` reads from the
   bundle today; remote templates carry `instructions` inline. Fall back to
   `person.crop.square` when `symbol` is missing, and show `credit` on community cards.
4. Demo fixtures keep the bundled data; `-use-demo-fixtures` must not hit the network.
5. Optional: a "Share a template" link in the Blueprints sheet and agent picker to
   `https://bighelp.app/templates#submit`.

Community text is untrusted: render it as plain text, never Markdown links or HTML.

## Develop and deploy

```sh
npm install
npm run typecheck      # wrangler types && tsc
npm test               # vitest in workerd: Access gating, review flow, public feed, CORS
npx wrangler d1 migrations apply bighelp-catalog --remote
npx wrangler deploy
```

The Worker reads three secrets. Set each one once with `npx wrangler secret put <NAME>`:

- `TURNSTILE_SECRET`: the secret key of the "bighelp Template Catalog submit" Turnstile widget.
- `ACCESS_TEAM_DOMAIN`: the Zero Trust team domain, for example `team.cloudflareaccess.com`.
- `ACCESS_AUD_REVIEW`: the Application Audience (AUD) tag of the "review" Access app.

The team domain contains the account owner's name, so it stays out of this public repo. If a secret is
missing, the review routes answer 503 and the public routes keep working.

A deploy from an older checkout set the two Access values as plain variables. Cloudflare refuses a secret
with the same name as a variable. So, the first time, deploy this version first, then put the two secrets.
Until you put them, review answers 503.

`compatibility_date` must stay at or before the newest date the pinned workerd supports, or tests
won't start. Deploys run from the Mac, where wrangler is logged in.
