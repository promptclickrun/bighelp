// Composio's app list for the app's Composio Apps section.
//
// People sign in to their own Composio account in the app, but that sign-in can't read Composio's toolkit
// catalog. So a daily cron reads it here with a bighelp-owned developer key, keeps a small normalized copy in
// D1, and `/v1/composio/catalog.json` serves that copy. The key reads catalog metadata only, never people,
// connections or tool runs, and it is never logged, stored or returned.

import { isRecord } from "./templates.js";

export const COMPOSIO_API = "https://backend.composio.dev/api/v3.1";

/** `fetch`, injectable so tests never call Composio. */
export type HttpFetch = (url: string, init: RequestInit) => Promise<Response>;

export interface ComposioCategory {
  id: string;
  name: string;
}

export interface ComposioToolkit {
  slug: string;
  name: string;
  description?: string;
  logo?: string;
  /** Category ids, each one listed in the catalog's `categories`. */
  categories: string[];
  noAuth: boolean;
}

/** What `/v1/composio/catalog.json` serves (README › Routes). */
export interface ComposioCatalog {
  schemaVersion: 1;
  revision: string;
  fetchedAt: string;
  categories: ComposioCategory[];
  toolkits: ComposioToolkit[];
}

export type RefreshOutcome =
  | { status: "stored" | "unchanged"; revision: string; toolkits: number }
  | { status: "kept"; reason: string };

const REQUEST_TIMEOUT_MS = 20_000;
const PAGE_SIZE = 1000;
const MAX_PAGES = 10;
const MAX_TOOLKITS = 4000;
/** Fewer than this means Composio answered oddly: keep the last good list instead. */
const MIN_TOOLKITS = 50;
const MAX_NAME = 80;
const MAX_DESCRIPTION = 280;
const MAX_LOGO_URL = 512;
const MAX_CATEGORY_NAME = 60;
const MAX_CATEGORIES_PER_TOOLKIT = 8;
/** One Composio answer; far above a full page of 1000 toolkits. */
const MAX_RESPONSE_BYTES = 16 * 1024 * 1024;
/** D1 refuses rows over 2 MB. */
const MAX_DOCUMENT_BYTES = 1_900_000;
const SLUG = /^[a-z0-9_]{1,64}$/;
const CATEGORY_ID = /^[a-z0-9-]{1,48}$/;

/** A toolkit before category names are known. */
type ParsedToolkit = Omit<ComposioToolkit, "categories"> & { categories: { id: string; name: string | null }[] };

class RefreshError extends Error {
  constructor(readonly reason: string) {
    super(reason);
  }
}

/**
 * Reads Composio's toolkits and categories and stores the normalized catalog. Never throws: on any failure
 * the stored catalog stays as it is and only a short reason is logged.
 */
export async function refreshComposioCatalog(
  env: { DB: D1Database; COMPOSIO_API_KEY?: string },
  deps: { fetch?: HttpFetch; now?: () => Date } = {},
): Promise<RefreshOutcome> {
  // A wrapper, not `fetch` itself: workerd refuses a `fetch` called as another object's method.
  const send: HttpFetch = deps.fetch ?? ((url, init) => fetch(url, init));
  let outcome: RefreshOutcome;
  try {
    outcome = await refresh(env, send, (deps.now ?? (() => new Date()))());
  } catch (caught) {
    // Fixed reasons only: an exception's message could quote what Composio sent back.
    outcome = { status: "kept", reason: caught instanceof RefreshError ? caught.reason : "unexpected error" };
  }
  if (outcome.status === "kept") {
    console.warn(`composio catalog: kept the stored copy (${outcome.reason})`);
  } else {
    console.log(`composio catalog: ${outcome.status} ${outcome.revision} (${outcome.toolkits} apps)`);
  }
  return outcome;
}

/** The stored catalog, or null before the first good refresh. */
export async function storedComposioCatalog(db: D1Database): Promise<{ document: string; revision: string } | null> {
  return db.prepare("SELECT document, revision FROM composio_catalog WHERE id = 1")
    .first<{ document: string; revision: string }>();
}

async function refresh(
  env: { DB: D1Database; COMPOSIO_API_KEY?: string }, send: HttpFetch, now: Date,
): Promise<RefreshOutcome> {
  const key = env.COMPOSIO_API_KEY?.trim();
  if (!key) throw new RefreshError("no COMPOSIO_API_KEY");
  const headers = { "x-api-key": key, Accept: "application/json", "User-Agent": "bighelp-catalog" };

  // Composio sorts by usage, so a list cut short by the page or toolkit cap still has the most used apps.
  const toolkits: ParsedToolkit[] = [];
  const slugs = new Set<string>();
  let cursor: string | undefined;
  for (let page = 0; page < MAX_PAGES && toolkits.length < MAX_TOOLKITS; page += 1) {
    const query = new URLSearchParams({
      type: "native", sort_by: "usage", include_deprecated: "false", limit: String(PAGE_SIZE),
    });
    if (cursor) query.set("cursor", cursor);
    const body = await getJson(send, `${COMPOSIO_API}/toolkits?${query}`, headers, "toolkits");
    if (!isRecord(body) || !Array.isArray(body.items)) throw new RefreshError("toolkits in an unknown shape");
    for (const item of body.items) {
      const toolkit = parseToolkit(item);
      if (!toolkit || slugs.has(toolkit.slug)) continue;
      slugs.add(toolkit.slug);
      toolkits.push(toolkit);
      if (toolkits.length >= MAX_TOOLKITS) break;
    }
    cursor = nextCursor(body.next_cursor);
    if (!cursor || body.items.length === 0) break;
  }
  if (toolkits.length < MIN_TOOLKITS) throw new RefreshError(`only ${toolkits.length} usable apps`);

  const categoryBody = await getJson(send, `${COMPOSIO_API}/toolkits/categories`, headers, "categories");
  if (!isRecord(categoryBody) || !Array.isArray(categoryBody.items)) {
    throw new RefreshError("categories in an unknown shape");
  }
  const content = assemble(toolkits, categoryBody.items);
  const revision = await sha256(JSON.stringify(content));

  try {
    const stored = await env.DB.prepare("SELECT revision FROM composio_catalog WHERE id = 1")
      .first<{ revision: string }>();
    // Same content keeps the same bytes, so the ETag (the revision) always names exactly one body.
    if (stored?.revision === revision) return { status: "unchanged", revision, toolkits: content.toolkits.length };
  } catch {
    throw new RefreshError("D1 read failed");
  }
  const catalog: ComposioCatalog = { schemaVersion: 1, revision, fetchedAt: now.toISOString(), ...content };
  const document = JSON.stringify(catalog);
  if (new TextEncoder().encode(document).byteLength > MAX_DOCUMENT_BYTES) throw new RefreshError("catalog too large");
  try {
    await env.DB.prepare(
      `INSERT INTO composio_catalog (id, document, revision, fetched_at) VALUES (1, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET document = excluded.document, revision = excluded.revision,
         fetched_at = excluded.fetched_at`,
    ).bind(document, revision, catalog.fetchedAt).run();
  } catch {
    throw new RefreshError("D1 write failed");
  }
  return { status: "stored", revision, toolkits: content.toolkits.length };
}

// MARK: - Normalizing

/** One toolkit, or null if it fails a check. One bad toolkit never fails the run. */
function parseToolkit(raw: unknown): ParsedToolkit | null {
  if (!isRecord(raw)) return null;
  if (raw.type !== undefined && raw.type !== "native") return null;
  // On a toolkit, `deprecated` is its legacy id (`{ toolkitId }`), not a flag; Composio already leaves
  // deprecated toolkits out. Only an explicit flag drops one here.
  if (raw.deprecated === true || (isRecord(raw.deprecated) && raw.deprecated.is_deprecated === true)) return null;
  if (typeof raw.slug !== "string" || !SLUG.test(raw.slug)) return null;
  const name = cleanText(raw.name);
  if (!name || [...name].length > MAX_NAME) return null;

  const meta = isRecord(raw.meta) ? raw.meta : {};
  const description = truncate(cleanText(meta.description), MAX_DESCRIPTION);
  const logo = httpsURL(meta.logo);
  const categories: ParsedToolkit["categories"] = [];
  for (const entry of Array.isArray(meta.categories) ? meta.categories.slice(0, 32) : []) {
    if (!isRecord(entry) || typeof entry.id !== "string" || !CATEGORY_ID.test(entry.id)) continue;
    if (categories.some((category) => category.id === entry.id)) continue;
    categories.push({ id: entry.id, name: categoryName(entry.name) });
  }
  return {
    slug: raw.slug,
    name,
    ...(description ? { description } : {}),
    ...(logo ? { logo } : {}),
    categories,
    noAuth: raw.no_auth === true,
  };
}

/** Names each toolkit's categories and lists just the categories kept toolkits use, sorted by name. */
function assemble(toolkits: ParsedToolkit[], rawCategories: unknown[]): Pick<ComposioCatalog, "categories" | "toolkits"> {
  const names = new Map<string, string>();
  for (const entry of rawCategories.slice(0, 1000)) {
    if (!isRecord(entry) || typeof entry.id !== "string" || !CATEGORY_ID.test(entry.id)) continue;
    const name = categoryName(entry.name);
    if (name && !names.has(entry.id)) names.set(entry.id, name);
  }
  // A category the list doesn't have yet keeps the name its toolkit gives it.
  for (const toolkit of toolkits) {
    for (const category of toolkit.categories) {
      if (category.name && !names.has(category.id)) names.set(category.id, category.name);
    }
  }
  const used = new Set<string>();
  const kept = toolkits.map((toolkit) => {
    const ids = toolkit.categories.map((category) => category.id).filter((id) => names.has(id))
      .slice(0, MAX_CATEGORIES_PER_TOOLKIT);
    for (const id of ids) used.add(id);
    return { ...toolkit, categories: ids };
  });
  const categories = [...used].map((id) => ({ id, name: names.get(id)! }))
    .sort((a, b) => a.name.localeCompare(b.name, "en") || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return { categories, toolkits: kept };
}

function categoryName(value: unknown): string | null {
  const name = cleanText(value);
  return name && [...name].length <= MAX_CATEGORY_NAME ? name : null;
}

/** One line of plain text: control characters and runs of whitespace become one space. */
function cleanText(value: unknown): string {
  return typeof value === "string" ? value.slice(0, 4096).replace(/[\s\p{Cc}]+/gu, " ").trim() : "";
}

function truncate(text: string, max: number): string {
  const characters = [...text];
  return characters.length <= max ? text : `${characters.slice(0, max - 1).join("").trimEnd()}…`;
}

function httpsURL(value: unknown): string | undefined {
  if (typeof value !== "string" || value.length > MAX_LOGO_URL) return undefined;
  let url: URL;
  try {
    url = new URL(value.trim());
  } catch {
    return undefined;
  }
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password) return undefined;
  return url.href.length <= MAX_LOGO_URL ? url.href : undefined;
}

// MARK: - Reading Composio

async function getJson(send: HttpFetch, url: string, headers: Record<string, string>, what: string): Promise<unknown> {
  let response: Response;
  try {
    response = await send(url, { headers, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
  } catch (caught) {
    throw new RefreshError(`${what} ${isTimeout(caught) ? "timed out" : "unreachable"}`);
  }
  if (!response.ok) {
    // The body isn't read: an error page could quote the request back.
    await response.body?.cancel().catch(() => {});
    throw new RefreshError(`${what} answered ${response.status}`);
  }
  let text: string;
  try {
    text = await readText(response, MAX_RESPONSE_BYTES);
  } catch (caught) {
    if (caught instanceof RefreshError) throw new RefreshError(`${what} ${caught.reason}`);
    throw new RefreshError(`${what} ${isTimeout(caught) ? "timed out" : "unreadable"}`);
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new RefreshError(`${what} not JSON`);
  }
}

function nextCursor(value: unknown): string | undefined {
  if (value === null || value === undefined || value === "") return undefined;
  if (typeof value !== "string" || value.length > 1024) throw new RefreshError("toolkits cursor in an unknown shape");
  return value;
}

/** The body as text, refusing more than `limit` bytes. */
async function readText(response: Response, limit: number): Promise<string> {
  if (Number(response.headers.get("Content-Length") ?? "0") > limit) throw new RefreshError("too large");
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      throw new RefreshError("too large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

function isTimeout(caught: unknown): boolean {
  const name = typeof caught === "object" && caught !== null && "name" in caught ? caught.name : undefined;
  return name === "TimeoutError" || name === "AbortError";
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
