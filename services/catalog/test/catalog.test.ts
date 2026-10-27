import { env } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import first from "../migrations/0001_templates.sql?raw";
import second from "../migrations/0002_submitter_details.sql?raw";
import third from "../migrations/0003_agent_installs.sql?raw";
import fifth from "../migrations/0005_reviewer_versions.sql?raw";
import type { GitHubLookup } from "../src/agents.js";
import { type Env, type HumanCheck, handle } from "../src/index.js";

const testEnv = env as unknown as Env;
const TEAM = "team.example.cloudflareaccess.com";
let keyPair: CryptoKeyPair;
let publicJwk: JsonWebKey & { kid: string };
const keys = async () => [publicJwk];
// Stands in for Turnstile: only "human" passes.
const human: HumanCheck = async (token) => token === "human";
// Stands in for GitHub's /user: "gh-<id>" tokens belong to a five-year-old account, "gh-new" to a week-old one.
const githubLookups: string[] = [];
const github: GitHubLookup = async (token) => {
  githubLookups.push(token);
  if (token === "gh-new") return { id: "900", login: "fresh", createdAt: new Date(Date.now() - 7 * 86_400_000) };
  const match = /^gh-(\d+)$/.exec(token);
  return match ? { id: match[1]!, login: `dev${match[1]}`, createdAt: new Date("2020-01-01T00:00:00Z") } : null;
};

beforeAll(async () => {
  for (const statement of [first, second, third, fifth].join(";").replace(/^--.*$/gm, "").split(";").map((value: string) => value.trim()).filter(Boolean)) {
    await testEnv.DB.prepare(statement).run();
  }
  keyPair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true, ["sign", "verify"],
  ) as CryptoKeyPair;
  publicJwk = { ...(await crypto.subtle.exportKey("jwk", keyPair.publicKey) as JsonWebKey), kid: "k1" };
});

beforeEach(async () => {
  for (const table of ["templates", "agent_installs", "banned_github_ids"]) {
    await testEnv.DB.prepare(`DELETE FROM ${table}`).run();
  }
  githubLookups.length = 0;
});

function base64url(input: string | ArrayBuffer): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : new Uint8Array(input);
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function token(claims: Record<string, unknown>): Promise<string> {
  const header = base64url(JSON.stringify({ alg: "RS256", kid: "k1" }));
  const payload = base64url(JSON.stringify({
    iss: `https://${TEAM}`, exp: Math.floor(Date.now() / 1000) + 600, ...claims,
  }));
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keyPair.privateKey,
    new TextEncoder().encode(`${header}.${payload}`));
  return `${header}.${payload}.${base64url(signature)}`;
}

async function call(
  path: string,
  init: { method?: string; body?: unknown; jwt?: string; origin?: string; ip?: string; bearer?: string; match?: string; reviewHeader?: boolean } = {},
): Promise<Response> {
  const headers = new Headers({ "Content-Type": "application/json", "CF-Connecting-IP": init.ip ?? "203.0.113.7" });
  if (init.jwt) headers.set("Cf-Access-Jwt-Assertion", init.jwt);
  if (init.origin) headers.set("Origin", init.origin);
  if (init.match) headers.set("If-Match", init.match);
  if (init.reviewHeader) headers.set("X-Catalog-Review", "1");
  if (init.bearer) headers.set("Authorization", `Bearer ${init.bearer}`);
  const request = new Request(`https://catalog.example${path}`, {
    method: init.method ?? "GET",
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  return handle(request, testEnv, { keys, human, github });
}

describe("catalog reviewer webapp", () => {
  it("returns a conflict when named templates are created concurrently", async () => {
    const jwt = await reviewer();
    const responses = await Promise.all([1, 2].map(() => call("/review/templates", {
      method: "POST", body: { ...blueprint, id: "same-named-template" }, jwt,
    })));
    expect(responses.map(response => response.status).sort()).toEqual([201, 409]);
  });

  it("changes the public revision even when two writes share a timestamp", async () => {
    const jwt = await reviewer();
    const fixed = new Date("2026-01-01T12:00:00Z");
    const frozen = (path: string, method = "GET", body?: unknown) => handle(
      new Request(`https://catalog.example${path}`, {
        method, headers: { "Cf-Access-Jwt-Assertion": jwt, "Content-Type": "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
      }), testEnv, { keys, now: () => fixed },
    );
    const made = await (await frozen("/review/templates", "POST", blueprint)).json<{ id: string }>();
    const before = (await frozen("/v1/catalog.json")).headers.get("ETag");
    expect((await frozen(`/review/templates/${made.id}`, "PATCH", { text: "A different useful prompt about [my topic]." })).status).toBe(200);
    expect((await frozen("/v1/catalog.json")).headers.get("ETag")).not.toBe(before);
  });

  it("returns the authenticated reviewer identity", async () => {
    const response = await call("/review/session", { jwt: await reviewer() });
    expect(await response.json()).toEqual({ reviewer: "owner@example.com" });
  });

  it("prevents stale edits and deletes from overwriting a newer decision", async () => {
    const jwt = await reviewer();
    const created = await (await call("/review/templates", { method: "POST", body: blueprint, jwt }))
      .json<{ id: string; version: number }>();
    expect(created.version).toBe(1);
    const path = `/review/templates/${created.id}`;
    const options = { method: "PATCH", body: { text: "An updated useful prompt for [my topic]." }, jwt,
      match: '"v1"', origin: "https://catalog.example", reviewHeader: true };
    const results = await Promise.all([call(path, options), call(path, options)]);
    expect(results.map(r => r.status).sort()).toEqual([200, 409]);
    expect((await call(path, { method: "DELETE", jwt, match: '"v1"' })).status).toBe(409);
    const current = await (await call(path, { jwt })).json<{ version: number; status: string }>();
    expect(current.version).toBe(2);
    expect((await call(`${path}/unpublish`, { method: "POST", jwt, body: {}, match: '"v2"' })).status).toBe(200);
    expect((await call(path, { method: "DELETE", jwt, match: '"v3"' })).status).toBe(200);
    expect((await call(path, { jwt })).status).toBe(404);
  });

  it("requires JSON, same-origin UI headers and row preconditions for browser writes", async () => {
    const jwt = await reviewer();
    const made = await (await call("/review/templates", { method: "POST", body: blueprint, jwt })).json<{ id: string }>();
    const path = `/review/templates/${made.id}`;
    const origin = "https://catalog.example";
    expect((await call(path, { method: "PATCH", body: {}, jwt, origin, match: '"v1"' })).status).toBe(403);
    expect((await call(path, { method: "PATCH", body: {}, jwt, origin, reviewHeader: true })).status).toBe(428);
    const form = new Request(`https://catalog.example${path}/approve`, { method: "POST",
      headers: { "Cf-Access-Jwt-Assertion": jwt, "Content-Type": "text/plain" }, body: "{}" });
    expect((await handle(form, testEnv, { keys })).status).toBe(415);
  });

  it("protects the entire reviewer hostname, including the HTML and assets", async () => {
    for (const path of ["/", "/app.js", "/style.css", "/v1/catalog.json"]) {
      const response = await handle(new Request(`https://reviewer.example.test${path}`), { ...testEnv, REVIEWER_HOST: "reviewer.example.test" }, { keys, human });
      expect(response.status, path).toBe(401);
      expect(response.headers.get("Cache-Control")).toContain("no-store");
    }
  });

  it("serves reviewer assets only after verifying Access, without exposing them on public routes", async () => {
    const jwt = await reviewer();
    let reads = 0;
    const reviewerEnv = { ...testEnv, REVIEWER_HOST: "reviewer.example.test", REVIEWER_ASSETS: {
      fetch: async (request: Request) => {
        reads++;
        if (new URL(request.url).pathname !== "/") return new Response("Not found", { status: 404 });
        return new Response("fixture asset", { headers: { "Content-Type": "text/html" } });
      },
    } as unknown as Fetcher };
    const request = (host: string, path: string, signed = true) => new Request(`https://${host}${path}`, {
      headers: signed ? { "Cf-Access-Jwt-Assertion": jwt } : {},
    });
    expect((await handle(request("reviewer.example.test", "/", false), reviewerEnv, { keys })).status).toBe(401);
    expect(reads).toBe(0);
    const html = await handle(request("reviewer.example.test", "/"), reviewerEnv, { keys });
    expect(await html.text()).toBe("fixture asset");
    expect(html.headers.get("Cache-Control")).toContain("no-store");
    expect(html.headers.get("Content-Security-Policy")).toContain("frame-ancestors 'none'");
    expect((await handle(request("reviewer.example.test", "/v1/catalog.json"), reviewerEnv, { keys })).status).toBe(404);
    expect((await handle(request("catalog.example", "/app.js"), reviewerEnv, { keys })).status).toBe(404);
    expect(reads).toBe(2);
  });

  it("bounds fractional and non-finite pagination inputs before querying D1", async () => {
    const jwt = await reviewer();
    await call("/review/templates", { method: "POST", body: blueprint, jwt });
    const response = await call("/review/templates?status=all&limit=1.5&offset=Infinity", { jwt });
    expect(response.status).toBe(200);
    const page = await response.json<{ templates: unknown[]; total: number; nextOffset: number | null }>();
    expect(page.templates).toHaveLength(1);
    expect(page.total).toBe(1);
    expect(page.nextOffset).toBeNull();
  });

  it("rejects cross-origin browser mutations even with a valid reviewer identity", async () => {
    const response = await call("/review/templates", {
      method: "POST", body: blueprint, jwt: await reviewer(), origin: "https://attacker.example",
    });
    expect(response.status).toBe(403);
    expect((await call("/v1/catalog.json")).status).toBe(200);
  });

  it("paginates the complete catalog without silently hiding older templates", async () => {
    const jwt = await reviewer();
    for (let i = 0; i < 3; i += 1) {
      await call("/review/templates", { method: "POST", body: { ...blueprint, id: `page-${i}` }, jwt });
    }
    const page = await (await call("/review/templates?status=all&limit=2&offset=2", { jwt }))
      .json<{ templates: { id: string }[]; total: number; nextOffset: number | null }>();
    expect(page.templates).toHaveLength(1);
    expect(page.total).toBe(3);
    expect(page.nextOffset).toBeNull();
  });

  it("auto-publishes only the configured numeric GitHub owner's authenticated submissions", async () => {
    const bearer = await register("gh-42");
    const request = new Request("https://catalog.example/submit/agent/templates", {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${bearer}` },
      body: JSON.stringify(agent),
    });
    const response = await handle(request, { ...testEnv, OWNER_GITHUB_ID: "42" }, { keys, human, github });
    expect(response.status).toBe(201);
    const created = await response.json<{ id: string; status: string }>();
    expect(created.status).toBe("approved");
    const catalog = await (await call("/v1/catalog.json")).json<{ agents: { id: string }[] }>();
    expect(catalog.agents.map(t => t.id)).toContain(created.id);
    // Unverified web identity and body fields can never grant the owner exception.
    const forged = await submit({ ...agent, status: "approved", source: "bighelp", submitterGithubId: "42" }, {
      username: "promptclickrun", email: "colt.coan@gmail.com",
    });
    expect(await forged.json()).toMatchObject({ status: "pending" });
    expect(await (await agentSubmit(await register("gh-43"), { ...agent, owner: true })).json())
      .toMatchObject({ status: "pending" });
  });
});

const sam = { submitterName: "Sam Rivera", username: "@samr", email: "Sam@Example.com", turnstileToken: "human" };

/** Submits as Sam (or someone else) and returns the receipt. */
async function submit(template: Record<string, unknown>, who: Record<string, unknown> = {}, ip?: string) {
  return call("/submit/templates", { method: "POST", body: { ...template, ...sam, ...who }, ip });
}

async function status(...tokens: string[]) {
  return (await call("/submit/status", { method: "POST", body: { tokens } }))
    .json<{ submissions: { id: string; status: string; reviewNote: string | null }[] }>();
}
const reviewer = () => token({ aud: ["aud-review"], email: "owner@example.com" });
const agentToken = () => token({ aud: ["aud-review"], common_name: "client-id.access" });

const agent = {
  kind: "agent",
  name: "Pilot",
  role: "Travel planner",
  vibe: "Calm, organized, upbeat",
  description: "Turns a vague trip idea into a day-by-day plan.",
  instructions: "You are {{agent_name}}, a travel planner. Ask for dates and budget first, then plan day by day.",
  category: "personal",
};

const blueprint = {
  kind: "blueprint",
  board: "goals",
  category: "personal",
  goalCategory: "health",
  text: "Add a goal to my Goals: walk [8,000] steps a day. Check in each evening.",
};

describe("agent topics", () => {
  it("takes the ten topics and refuses the retired ones", async () => {
    const topics = ["productivity", "business", "coding", "science", "education", "health", "creative", "personal", "leadership", "security"];
    for (const category of topics) expect((await submit(agent, { category })).status, category).toBe(201);
    for (const category of ["work", "learning", "research", "support", "fun"]) {
      const response = await submit(agent, { category });
      expect(response.status, category).toBe(400);
      expect(await response.json()).toMatchObject({ field: "category" });
    }
  });
});

describe("submissions", () => {
  it("needs a name, username, email and a passed person check", async () => {
    expect((await submit(agent, { turnstileToken: "bot" })).status).toBe(403);
    expect((await submit(agent, { turnstileToken: undefined })).status).toBe(403);
    for (const [field, value] of [["submitterName", ""], ["username", "sam r!"], ["email", "sam@"]] as const) {
      const response = await submit(agent, { [field]: value });
      expect(response.status).toBe(400);
      expect(await response.json()).toMatchObject({ field });
    }
  });

  it("holds a submission for review, invisible to the public until approved", async () => {
    const response = await submit(agent);
    expect(response.status).toBe(201);
    const { id, statusToken } = await response.json<{ id: string; statusToken: string }>();

    const before = await (await call("/v1/catalog.json")).json<{ agents: unknown[] }>();
    expect(before.agents).toHaveLength(0);

    expect((await status(statusToken)).submissions).toEqual([expect.objectContaining({ id, status: "pending" })]);
    expect((await status("x".repeat(43))).submissions).toEqual([]);

    const queue = await (await call("/review/templates", { jwt: await reviewer() }))
      .json<{ templates: Record<string, unknown>[] }>();
    expect(queue.templates).toEqual([expect.objectContaining({
      id, submitterName: "Sam Rivera", submitterUsername: "samr", submitterEmail: "sam@example.com",
    })]);

    const approved = await call(`/review/templates/${id}/approve`, { method: "POST", jwt: await agentToken() });
    expect(approved.status).toBe(200);
    expect(await approved.json()).toMatchObject({ status: "approved", reviewedBy: "service-token:client-id.access" });

    const raw = await (await call("/v1/catalog.json")).text();
    const after = JSON.parse(raw) as { agents: Record<string, unknown>[] };
    expect(after.agents).toEqual([expect.objectContaining({ id, name: "Pilot", credit: "samr", source: "community" })]);
    expect(raw).not.toContain("example.com");
    expect(raw).not.toContain("Rivera");
  });

  it("rejects bad input with the field to fix", async () => {
    const response = await submit({ ...blueprint, board: "kanban" });
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ field: "board" });
  });

  it("ignores a symbol from a submitter", async () => {
    const response = await submit({ ...agent, symbol: "flame" });
    const { id } = await response.json<{ id: string }>();
    const row = await (await call(`/review/templates/${id}`, { jwt: await reviewer() })).json<Record<string, unknown>>();
    expect(row.symbol).toBeUndefined();
  });

  it("caps how many one email can have waiting", async () => {
    for (let index = 0; index < 10; index += 1) {
      expect((await submit(blueprint, {}, `198.51.100.${index}`)).status).toBe(201);
    }
    expect((await submit(blueprint, {}, "198.51.100.99")).status).toBe(429);
  });

  it("caps one network even when the emails change", async () => {
    for (let index = 0; index < 20; index += 1) {
      expect((await submit(blueprint, { email: `person${index}@example.com` })).status).toBe(201);
    }
    expect((await submit(blueprint, { email: "fresh@example.com" })).status).toBe(429);
  });
});

/** Signs an install in with a fake GitHub token and returns its install token. */
async function register(githubToken: string): Promise<string> {
  const response = await call("/agent/register", { method: "POST", body: { githubToken } });
  expect(response.status).toBe(201);
  return (await response.json<{ token: string }>()).token;
}

const agentSubmit = (bearer: string | undefined, body: unknown = blueprint) =>
  call("/submit/agent/templates", { method: "POST", body, bearer });

describe("agent submissions", () => {
  it("trades a GitHub sign-in for an install token and never keeps the GitHub token", async () => {
    const response = await call("/agent/register", { method: "POST", body: { githubToken: "gh-42" } });
    expect(response.status).toBe(201);
    const body = await response.json<{ token: string; login: string; dailyLimit: number }>();
    expect(body).toMatchObject({ login: "dev42", dailyLimit: 5 });
    expect(body.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const stored = JSON.stringify((await testEnv.DB.prepare("SELECT * FROM agent_installs").all()).results);
    expect(stored).not.toContain("gh-42");
    expect(stored).not.toContain(body.token);
  });

  it("refuses unknown GitHub tokens and accounts younger than 30 days", async () => {
    expect((await call("/agent/register", { method: "POST", body: { githubToken: "nope" } })).status).toBe(401);
    const young = await call("/agent/register", { method: "POST", body: { githubToken: "gh-new" } });
    expect(young.status).toBe(403);
    expect((await young.json<{ error: string }>()).error).toContain("30 days");
  });

  it("queues a submission for review with the GitHub login as credit", async () => {
    const response = await agentSubmit(await register("gh-42"), agent);
    expect(response.status).toBe(201);
    const { id, statusToken, remainingToday } = await response.json<{ id: string; statusToken: string; remainingToday: number }>();
    expect(remainingToday).toBe(4);
    expect((await status(statusToken)).submissions).toEqual([expect.objectContaining({ id, status: "pending" })]);
    const row = await (await call(`/review/templates/${id}`, { jwt: await reviewer() })).json<Record<string, unknown>>();
    expect(row).toMatchObject({ credit: "dev42", submitterUsername: "dev42", submitterGithubId: "42", submitterEmail: null });
  });

  it("needs a signed-in install", async () => {
    expect((await agentSubmit(undefined)).status).toBe(401);
    expect((await agentSubmit("x".repeat(43))).status).toBe(401);
  });

  it("counts 5 a day per GitHub account across all its installs", async () => {
    const [first, second] = [await register("gh-42"), await register("gh-42")];
    for (let index = 0; index < 5; index += 1) {
      expect((await agentSubmit(index % 2 ? first : second)).status).toBe(201);
    }
    expect((await agentSubmit(first)).status).toBe(429);
    expect((await agentSubmit(await register("gh-42"))).status).toBe(429);
    expect((await agentSubmit(await register("gh-7"))).status).toBe(201);
  });

  it("stops a revoked install", async () => {
    const token = await register("gh-42");
    expect(await (await call("/agent/revoke", { method: "POST", bearer: token })).json()).toEqual({ revoked: true });
    expect((await agentSubmit(token)).status).toBe(401);
  });

  it("lets reviewers ban an account: its installs stop and it can't sign in again until unbanned", async () => {
    const token = await register("gh-42");
    const banned = await call("/review/accounts/42/ban", { method: "POST", body: { note: "spam" }, jwt: await reviewer() });
    expect(await banned.json()).toMatchObject({ banned: true, installsRemoved: 1 });
    expect((await agentSubmit(token)).status).toBe(401);
    expect((await call("/agent/register", { method: "POST", body: { githubToken: "gh-42" } })).status).toBe(403);
    expect((await call("/review/accounts/42/unban", { method: "POST", jwt: await reviewer() })).status).toBe(200);
    expect((await agentSubmit(await register("gh-42"))).status).toBe(201);
  });

  it("keeps ban and unban behind review sign-in", async () => {
    expect((await call("/review/accounts/42/ban", { method: "POST" })).status).toBe(401);
  });

  it("closes every submit route once 200 community templates are waiting", async () => {
    const statement = testEnv.DB.prepare(
      `INSERT INTO templates (id, kind, status, source, payload, created_at, updated_at)
       VALUES (?, 'blueprint', 'pending', 'community', '{}', '2020-01-01T00:00:00Z', '2020-01-01T00:00:00Z')`,
    );
    await testEnv.DB.batch(Array.from({ length: 200 }, (_, index) => statement.bind(`bp-full-${index}`)));
    const full = await agentSubmit(await register("gh-42"));
    expect(full.status).toBe(429);
    expect((await full.json<{ error: string }>()).error).toContain("queue is full");
    expect((await submit(blueprint)).status).toBe(429);
  });
});

describe("review", () => {
  it("is closed without a reviewer token", async () => {
    expect((await call("/review/templates")).status).toBe(401);
    const wrongAudience = await token({ aud: ["aud-other"], email: "owner@example.com" });
    expect((await call("/review/templates", { jwt: wrongAudience })).status).toBe(401);
    const forged = (await reviewer()).slice(0, -4) + "AAAA";
    expect((await call("/review/templates", { jwt: forged })).status).toBe(401);
  });

  it("stays closed when the Access secrets are missing, and the public feed still works", async () => {
    const unset = { ...testEnv, ACCESS_TEAM_DOMAIN: "", ACCESS_AUD_REVIEW: "" } as Env;
    const request = (path: string, jwt?: string) =>
      new Request(`https://catalog.example${path}`, { headers: jwt ? { "Cf-Access-Jwt-Assertion": jwt } : {} });
    expect((await handle(request("/review/templates", await reviewer()), unset, { keys, human })).status).toBe(503);
    expect((await handle(request("/v1/catalog.json"), unset, { keys, human })).status).toBe(200);
  });

  it("needs a reason to reject, and shows the reason to the submitter", async () => {
    const { id, statusToken } = await (await submit(blueprint)).json<{ id: string; statusToken: string }>();
    expect((await call(`/review/templates/${id}/reject`, { method: "POST", jwt: await reviewer() })).status).toBe(400);
    const rejected = await call(`/review/templates/${id}/reject`, {
      method: "POST", body: { note: "Too close to an existing blueprint." }, jwt: await reviewer(),
    });
    expect(rejected.status).toBe(200);
    const mine = await status(statusToken);
    expect(mine.submissions[0]).toMatchObject({ status: "rejected", reviewNote: "Too close to an existing blueprint." });
  });

  it("can edit a submission before approving it", async () => {
    const { id } = await (await submit(agent)).json<{ id: string }>();
    const edited = await call(`/review/templates/${id}`, {
      method: "PATCH", body: { vibe: "Calm and organized", symbol: "airplane" }, jwt: await reviewer(),
    });
    expect(await edited.json()).toMatchObject({ vibe: "Calm and organized", symbol: "airplane", status: "pending" });
  });

  it("publishes reviewer-authored templates straight away", async () => {
    const created = await call("/review/templates", { method: "POST", body: blueprint, jwt: await reviewer() });
    expect(created.status).toBe(201);
    const file = await (await call("/v1/board-blueprints.json"))
      .json<{ pages: { page: string; groups: { id: string; prompts: { goalCategory?: string }[] }[] }[] }>();
    const goals = file.pages.find((page) => page.page === "goals");
    expect(goals?.groups).toEqual([
      expect.objectContaining({ id: "personal", prompts: [expect.objectContaining({ goalCategory: "health" })] }),
    ]);
  });
});

describe("reviewer-named ids", () => {
  it("keeps the id a reviewer gives, and refuses a taken or malformed one", async () => {
    const jwt = await reviewer();
    const created = await call("/review/templates", { method: "POST", body: { ...blueprint, id: "feed-mine-1" }, jwt });
    expect(created.status).toBe(201);
    expect(await created.json()).toMatchObject({ id: "feed-mine-1", status: "approved" });
    const again = await call("/review/templates", { method: "POST", body: { ...blueprint, id: "feed-mine-1" }, jwt });
    expect(again.status).toBe(409);
    const bad = await call("/review/templates", { method: "POST", body: { ...blueprint, id: "Not OK!" }, jwt });
    expect(bad.status).toBe(400);
    expect(await bad.json()).toMatchObject({ field: "id" });
  });

  // The shapes scripts/catalog-sync.py sends: every field, with null for the ones a file leaves out.
  it("takes the sync script's bodies, with null for absent fields", async () => {
    const jwt = await reviewer();
    const pilot = { ...agent, symbol: null, variables: null, creditName: null };
    const made = await call("/review/templates", { method: "POST", body: { ...pilot, id: "pilot-from-repo" }, jwt });
    expect(made.status).toBe(201);
    const edited = await call("/review/templates/pilot-from-repo", {
      method: "PATCH", body: { ...pilot, description: null, symbol: "airplane" }, jwt,
    });
    expect(edited.status).toBe(200);
    const row = await edited.json<Record<string, unknown>>();
    expect(row).toMatchObject({ id: "pilot-from-repo", symbol: "airplane", status: "approved" });
    expect(row.description ?? null).toBeNull();

    const feed = {
      kind: "blueprint", board: "feed", category: "personal", goalCategory: null, creditName: null,
      text: "Every morning, post a short summary of [tech news] to my Feed.",
    };
    expect((await call("/review/templates", { method: "POST", body: { ...feed, id: "feed-from-repo" }, jwt })).status)
      .toBe(201);
    const feedEdit = await call("/review/templates/feed-from-repo", {
      method: "PATCH", body: { ...feed, text: "Every evening, post a short summary of [tech news] to my Feed." }, jwt,
    });
    expect(feedEdit.status).toBe(200);
  });
});

describe("public feed", () => {
  it("answers a matching ETag with 304", async () => {
    await call("/review/templates", { method: "POST", body: blueprint, jwt: await reviewer() });
    const first = await call("/v1/catalog.json");
    const etag = first.headers.get("ETag")!;
    expect(first.headers.get("Cache-Control")).toContain("max-age=300");
    const request = new Request("https://catalog.example/v1/catalog.json", { headers: { "If-None-Match": etag } });
    expect((await handle(request, testEnv, { keys, human })).status).toBe(304);
  });

  it.each(["/v1/catalog.json", "/v1/board-blueprints.json", "/v1/agent-templates.json"])(
    "accepts compression-weakened ETags for %s", async (path) => {
      const first = await call(path);
      const etag = first.headers.get("ETag")!;
      for (const method of ["GET", "HEAD"]) {
        const response = await handle(new Request(`https://catalog.example${path}`, {
          method, headers: { "If-None-Match": `W/${etag}` },
        }), testEnv, { keys, human });
        expect(response.status).toBe(304);
        expect(response.headers.get("ETag")).toBe(etag);
        expect(await response.text()).toBe("");
      }
    },
  );

  it("matches ETag lists and wildcards without matching stale or malformed validators", async () => {
    const etag = (await call("/v1/catalog.json")).headers.get("ETag")!;
    const cases: [string, number][] = [
      [`"stale", W/${etag}`, 304],
      [` W/${etag} , "other" `, 304],
      [`"opaque,comma", ${etag}`, 304],
      ["*", 304],
      [`"stale", W/"other"`, 200],
      [etag.slice(1, -1), 200],
      [`w/${etag}`, 200],
      [`W/ ${etag}`, 200],
      [`${etag} trailing`, 200],
      [`${etag}, malformed`, 200],
    ];
    for (const [value, expected] of cases) {
      const response = await handle(new Request("https://catalog.example/v1/catalog.json", {
        headers: { "If-None-Match": value },
      }), testEnv, { keys, human });
      expect(response.status, value).toBe(expected);
    }
    const missing = await handle(new Request("https://catalog.example/v1/missing.json", {
      headers: { "If-None-Match": "*" },
    }), testEnv, { keys, human });
    expect(missing.status).toBe(404);
  });

  it("lets any page read the public feed", async () => {
    const response = await call("/v1/catalog.json", { origin: "https://anywhere.example" });
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(response.headers.get("Access-Control-Allow-Credentials")).toBeNull();
  });

  it("never offers credentials across origins", async () => {
    const response = await call("/submit/status", { method: "POST", body: { tokens: [] }, origin: "https://anywhere.example" });
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(response.headers.get("Access-Control-Allow-Credentials")).toBeNull();
  });
});

describe("template variables", () => {
  const fieldLead = {
    ...agent,
    name: "Field Lead",
    role: "{{agent_role}}",
    instructions: "You are {{agent_name}}, a {{agent_role}}. Operating context: {{operating_context}}. "
      + "Speak in a {{tone}} way with {{user_name}}.",
    variables: [
      { key: "agent_role", label: "Role", type: "text", example: "Release coordinator", maxLength: 80 },
      { key: "operating_context", label: "Where it works", type: "long_text", required: false,
        whenEmpty: "General work for the user." },
      { key: "tone", label: "Tone", type: "choice", options: ["Warm", "Direct", "Playful"], default: "Direct" },
    ],
  };

  it("serves a submission's variables once it's approved", async () => {
    const response = await submit(fieldLead);
    expect(response.status).toBe(201);
    const { id } = await response.json<{ id: string }>();
    await call(`/review/templates/${id}/approve`, { method: "POST", jwt: await reviewer() });
    const catalog = await (await call("/v1/catalog.json")).json<{ agents: Record<string, unknown>[] }>();
    expect(catalog.agents).toEqual([expect.objectContaining({
      id, role: "{{agent_role}}",
      variables: [
        { key: "agent_role", label: "Role", type: "text", required: true, example: "Release coordinator", maxLength: 80 },
        { key: "operating_context", label: "Where it works", type: "long_text", required: false,
          whenEmpty: "General work for the user." },
        { key: "tone", label: "Tone", type: "choice", required: true, options: ["Warm", "Direct", "Playful"],
          default: "Direct" },
      ],
    })]);
    const file = await (await call("/v1/agent-templates.json")).json<{ templates: Record<string, unknown>[] }>();
    expect(file.templates[0]).toHaveProperty("variables");
  });

  it("refuses bad variables from people and agents with the field to fix", async () => {
    const undeclared = await submit({ ...fieldLead, variables: fieldLead.variables.slice(1) });
    expect(undeclared.status).toBe(400);
    expect(await undeclared.json()).toMatchObject({ field: "role" });
    const reserved = await agentSubmit(await register("gh-42"), {
      ...fieldLead, variables: [...fieldLead.variables, { key: "user_name", label: "You", type: "text" }],
    });
    expect(reserved.status).toBe(400);
    expect(await reserved.json()).toMatchObject({ field: "variables[3].key" });
    const accepted = await agentSubmit(await register("gh-42"), fieldLead);
    expect(accepted.status).toBe(201);
  });

  it("checks reviewer edits and reviewer-written templates the same way", async () => {
    const { id } = await (await submit(fieldLead)).json<{ id: string }>();
    const unused = await call(`/review/templates/${id}`, {
      method: "PATCH", jwt: await reviewer(), body: {
        role: "Field lead",
        instructions: "You are {{agent_name}}. Operating context: {{operating_context}}. Speak in a {{tone}} way, always.",
      },
    });
    expect(unused.status).toBe(400);
    expect(await unused.json()).toMatchObject({ field: "variables[0].key" });
    const edited = await call(`/review/templates/${id}`, {
      method: "PATCH", jwt: await reviewer(),
      body: { variables: fieldLead.variables.map((variable) => ({ ...variable, help: `About ${variable.label}.` })) },
    });
    expect(edited.status).toBe(200);
    expect(await edited.json()).toMatchObject({ variables: [{ help: "About Role." }, {}, {}] });

    const tooLong = await call("/review/templates", {
      method: "POST", jwt: await reviewer(),
      body: { ...fieldLead, variables: [{ ...fieldLead.variables[0], maxLength: 500 }, ...fieldLead.variables.slice(1)] },
    });
    expect(tooLong.status).toBe(400);
    expect(await tooLong.json()).toMatchObject({ field: "variables[0].maxLength" });
    const published = await call("/review/templates", { method: "POST", body: fieldLead, jwt: await reviewer() });
    expect(published.status).toBe(201);
    expect(await published.json()).toMatchObject({ status: "approved", variables: [{ key: "agent_role" }, {}, {}] });
  });
});
