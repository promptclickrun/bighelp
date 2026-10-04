// bighelp Template Catalog: Feed/Ideas/Goals blueprints and agent templates, served to the app and
// bighelp.app, with community submissions held for review.
//
//   /v1/*        public, approved templates only (the app and the site read these)
//   /account/*   behind Cloudflare Access (Google or GitHub): submit and see your own submissions
//   /review/*    behind Cloudflare Access (maintainer email or an agent's service token): review queue

import { type AccessConfig, type KeySource, type Principal, fetchAccessKeys, verifyAccess } from "./access.js";
import {
  type TemplateRow, approved, bySubmitter, find, insert, list, publicView, remove, review, reviewView,
  submitterLoad, submitterView, toTemplate,
} from "./store.js";
import {
  BLUEPRINT_CATEGORIES, type BlueprintPayload, type TemplateKind, type TemplateStatus, ValidationError,
  isRecord, parseCreditName, parseReviewNote, parseTemplate,
} from "./templates.js";

export interface Env {
  DB: D1Database;
  ACCESS_TEAM_DOMAIN: string;
  ACCESS_AUD_ACCOUNT: string;
  ACCESS_AUD_REVIEW: string;
  /** Comma-separated origins allowed to call /account with cookies. */
  SITE_ORIGINS: string;
  /** Where /account/login sends people back to after signing in. */
  SITE_RETURN_URL: string;
}

const MAX_BODY_BYTES = 32 * 1024;
const MAX_PENDING_PER_SUBMITTER = 10;
const MAX_SUBMISSIONS_PER_DAY = 10;
const GROUP_TITLES: Record<(typeof BLUEPRINT_CATEGORIES)[number], string> = {
  productivity: "Productivity",
  marketing: "Marketing",
  content: "Content creation",
  personal: "Personal life",
  research: "Research",
};

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env);
  },
} satisfies ExportedHandler<Env>;

/** The whole router. `keys` and `now` are injectable for tests. */
export async function handle(
  request: Request, env: Env, keys: KeySource = fetchAccessKeys, now: () => Date = () => new Date(),
): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, "") || "/";
  const cors = corsHeaders(request, env);

  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });

  try {
    // Approved templates are public, so any page may read them (no cookies).
    if (path.startsWith("/v1/")) {
      return withHeaders(await publicRoute(request, env, path), { "Access-Control-Allow-Origin": "*" });
    }
    if (path === "/account" || path.startsWith("/account/")) {
      const principal = await verifyAccess(request, accessConfig(env, env.ACCESS_AUD_ACCOUNT), keys);
      if (!principal?.email) return withHeaders(error(401, "Sign in with Google or GitHub first."), cors);
      return withHeaders(await accountRoute(request, env, path, url, principal.email, now()), cors, true);
    }
    if (path === "/review" || path.startsWith("/review/")) {
      const principal = await verifyAccess(request, accessConfig(env, env.ACCESS_AUD_REVIEW), keys);
      if (!principal) return error(401, "Reviewers only.");
      return await reviewRoute(request, env, path, url, reviewerName(principal), now());
    }
    if (path === "/") return json({ service: "bighelp template catalog", docs: "/v1/catalog.json" });
    return error(404, "Not found.");
  } catch (caught) {
    if (caught instanceof ValidationError) {
      return withHeaders(json({ error: caught.message, field: caught.field }, 400), cors, true);
    }
    if (caught instanceof HttpError) return withHeaders(error(caught.status, caught.message), cors, true);
    console.error("catalog error", caught instanceof Error ? caught.message : "unknown");
    return withHeaders(error(500, "Something went wrong. Try again."), cors);
  }
}

// MARK: - Public

async function publicRoute(request: Request, env: Env, path: string): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") return error(405, "Read only.");
  const rows = await approved(env.DB);
  const revision = await revisionOf(rows);
  if (request.headers.get("If-None-Match") === `"${revision}"`) {
    return new Response(null, { status: 304, headers: publicCacheHeaders(revision) });
  }
  let body: unknown;
  switch (path) {
    case "/v1/catalog.json":
      body = {
        schemaVersion: 1,
        revision,
        blueprints: rows.filter((row) => row.kind === "blueprint").map(publicView),
        agents: rows.filter((row) => row.kind === "agent").map(publicView),
      };
      break;
    case "/v1/board-blueprints.json":
      body = boardBlueprintsFile(rows, revision);
      break;
    case "/v1/agent-templates.json":
      body = { schemaVersion: 1, revision, templates: rows.filter((row) => row.kind === "agent").map(publicView) };
      break;
    default:
      return error(404, "Not found.");
  }
  return json(body, 200, publicCacheHeaders(revision));
}

/** Same shape as the app's bundled `Resources/BoardBlueprints.json`, so its existing parser reads it. */
function boardBlueprintsFile(rows: TemplateRow[], revision: string) {
  const pages = (["feed", "ideas", "goals"] as const).map((page) => ({
    page,
    groups: BLUEPRINT_CATEGORIES.map((category) => ({
      id: category,
      title: GROUP_TITLES[category],
      prompts: rows.flatMap((row) => {
        const template = toTemplate(row);
        if (template.kind !== "blueprint") return [];
        const blueprint: BlueprintPayload = template.payload;
        if (blueprint.board !== page || blueprint.category !== category) return [];
        return [{
          id: row.id,
          text: blueprint.text,
          ...(blueprint.goalCategory ? { goalCategory: blueprint.goalCategory } : {}),
          ...(row.credit_name ? { credit: row.credit_name } : {}),
        }];
      }),
    })).filter((group) => group.prompts.length > 0),
  }));
  return { source: "https://catalog.bighelp.app/v1/board-blueprints.json", schemaVersion: 1, revision, pages };
}

async function revisionOf(rows: TemplateRow[]): Promise<string> {
  const basis = rows.map((row) => `${row.id}:${row.updated_at}`).join("\n");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(basis));
  return [...new Uint8Array(digest)].slice(0, 8).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function publicCacheHeaders(revision: string): HeadersInit {
  return {
    "Cache-Control": "public, max-age=300, stale-while-revalidate=86400",
    ETag: `"${revision}"`,
  };
}

// MARK: - Signed-in submitters

async function accountRoute(
  request: Request, env: Env, path: string, url: URL, email: string, now: Date,
): Promise<Response> {
  if (path === "/account/login" && request.method === "GET") {
    // Access has already signed them in by the time this runs; send them back to the page.
    return Response.redirect(safeReturn(url.searchParams.get("return"), env), 302);
  }
  if (path === "/account/me" && request.method === "GET") {
    return json({ email, submissions: (await bySubmitter(env.DB, email)).map(submitterView) });
  }
  if (path === "/account/submissions" && request.method === "POST") {
    const body = await readJson(request);
    const template = parseTemplate(body);
    const creditName = isRecord(body) ? parseCreditName(body.creditName) : null;
    const dayAgo = new Date(now.getTime() - 86_400_000).toISOString();
    const load = await submitterLoad(env.DB, email, dayAgo);
    if (load.pending >= MAX_PENDING_PER_SUBMITTER) {
      throw new HttpError(429, "You have 10 templates waiting for review. Try again once some are reviewed.");
    }
    if (load.recent >= MAX_SUBMISSIONS_PER_DAY) {
      throw new HttpError(429, "That's 10 submissions today. Try again tomorrow.");
    }
    const id = newId(template.kind);
    await insert(env.DB, {
      id, template, status: "pending", source: "community", creditName, submitterEmail: email,
      now: now.toISOString(),
    });
    return json({ id, status: "pending" }, 201);
  }
  return error(404, "Not found.");
}

function safeReturn(value: string | null, env: Env): string {
  const fallback = env.SITE_RETURN_URL;
  if (!value) return fallback;
  try {
    const target = new URL(value);
    return allowedOrigins(env).includes(target.origin) ? target.toString() : fallback;
  } catch {
    return fallback;
  }
}

// MARK: - Reviewers (Colt, Alfie and other agents)

async function reviewRoute(
  request: Request, env: Env, path: string, url: URL, reviewer: string, now: Date,
): Promise<Response> {
  const segments = path.split("/").filter(Boolean); // ["review", "templates", id?, action?]
  if (segments[1] !== "templates") return error(404, "Not found.");
  const [, , id, action] = segments;

  if (!id) {
    if (request.method === "GET") {
      const status = oneOfOrUndefined(url.searchParams.get("status") ?? "pending",
        ["pending", "approved", "rejected", "all"] as const);
      const kind = oneOfOrUndefined(url.searchParams.get("kind"), ["blueprint", "agent"] as const);
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 100, 1), 500);
      const rows = await list(env.DB, {
        status: status === "all" ? undefined : status as TemplateStatus | undefined,
        kind: kind as TemplateKind | undefined,
        limit,
      });
      return json({ templates: rows.map(reviewView) });
    }
    if (request.method === "POST") {
      // Reviewers can publish their own templates directly.
      const body = await readJson(request);
      const template = parseTemplate(body, { allowSymbol: true });
      const creditName = isRecord(body) ? parseCreditName(body.creditName) : null;
      const newID = newId(template.kind);
      await insert(env.DB, {
        id: newID, template, status: "approved", source: "bighelp", creditName, submitterEmail: null,
        now: now.toISOString(), reviewedBy: reviewer,
      });
      return json(reviewView((await find(env.DB, newID))!), 201);
    }
    return error(405, "Use GET or POST.");
  }

  const row = await find(env.DB, id);
  if (!row) return error(404, "No template with that id.");

  if (!action) {
    if (request.method === "GET") return json(reviewView(row));
    if (request.method === "DELETE") {
      await remove(env.DB, id);
      return json({ id, deleted: true });
    }
    if (request.method === "PATCH") {
      // Edit before approving: send the full template fields; status stays as it is.
      const body = await readJson(request);
      const template = parseTemplate({ ...toTemplate(row).payload, ...(isRecord(body) ? body : {}), kind: row.kind },
        { allowSymbol: true });
      const creditName = isRecord(body) && "creditName" in body ? parseCreditName(body.creditName) : undefined;
      await review(env.DB, id, {
        status: row.status, note: row.review_note, reviewer, now: now.toISOString(), template, creditName,
      });
      return json(reviewView((await find(env.DB, id))!));
    }
    return error(405, "Use GET, PATCH or DELETE.");
  }

  if (request.method !== "POST") return error(405, "Use POST.");
  const body = await readJson(request, true);
  const fields = isRecord(body) ? body : {};
  if (action === "approve") {
    await review(env.DB, id, {
      status: "approved", note: parseReviewNote(fields.note, false), reviewer, now: now.toISOString(),
    });
  } else if (action === "reject") {
    await review(env.DB, id, {
      status: "rejected", note: parseReviewNote(fields.note, true), reviewer, now: now.toISOString(),
    });
  } else if (action === "unpublish") {
    await review(env.DB, id, {
      status: "pending", note: parseReviewNote(fields.note, false), reviewer, now: now.toISOString(),
    });
  } else {
    return error(404, "Actions are approve, reject and unpublish.");
  }
  return json(reviewView((await find(env.DB, id))!));
}

function reviewerName(principal: Principal): string {
  return principal.email ?? `service-token:${principal.serviceTokenId ?? "unknown"}`;
}

// MARK: - Plumbing

class HttpError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

function accessConfig(env: Env, audience: string): AccessConfig {
  return { teamDomain: env.ACCESS_TEAM_DOMAIN, audience };
}

async function readJson(request: Request, optional = false): Promise<unknown> {
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new HttpError(413, "That's too long.");
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) throw new HttpError(413, "That's too long.");
  if (!text.trim()) {
    if (optional) return {};
    throw new ValidationError("body", "Send a JSON object.");
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new ValidationError("body", "That isn't valid JSON.");
  }
}

function newId(kind: TemplateKind): string {
  return `${kind === "agent" ? "agent" : "bp"}-${crypto.randomUUID().slice(0, 13)}`;
}

function oneOfOrUndefined<const T extends readonly string[]>(value: string | null, allowed: T): T[number] | undefined {
  return value && (allowed as readonly string[]).includes(value) ? value as T[number] : undefined;
}

function allowedOrigins(env: Env): string[] {
  return env.SITE_ORIGINS.split(",").map((origin) => origin.trim()).filter(Boolean);
}

function corsHeaders(request: Request, env: Env): Record<string, string> {
  const origin = request.headers.get("Origin");
  if (!origin || !allowedOrigins(env).includes(origin)) return { Vary: "Origin" };
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Credentials": "true",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "600",
    Vary: "Origin",
  };
}

function withHeaders(response: Response, headers: Record<string, string>, noStore = false): Response {
  const result = new Response(response.body, response);
  for (const [name, value] of Object.entries(headers)) result.headers.set(name, value);
  if (noStore) result.headers.set("Cache-Control", "no-store");
  return result;
}

function json(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  const response = Response.json(body, { status, headers });
  response.headers.set("X-Content-Type-Options", "nosniff");
  if (!response.headers.has("Cache-Control")) response.headers.set("Cache-Control", "no-store");
  return response;
}

function error(status: number, message: string): Response {
  return json({ error: message }, status);
}
