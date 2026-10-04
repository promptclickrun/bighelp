import { env } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import first from "../migrations/0001_templates.sql?raw";
import second from "../migrations/0002_submitter_details.sql?raw";
import third from "../migrations/0003_agent_installs.sql?raw";
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
  for (const statement of [first, second, third].join(";").replace(/^--.*$/gm, "").split(";").map((value: string) => value.trim()).filter(Boolean)) {
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
  init: { method?: string; body?: unknown; jwt?: string; origin?: string; ip?: string; bearer?: string } = {},
): Promise<Response> {
  const headers = new Headers({ "Content-Type": "application/json", "CF-Connecting-IP": init.ip ?? "203.0.113.7" });
  if (init.jwt) headers.set("Cf-Access-Jwt-Assertion", init.jwt);
  if (init.origin) headers.set("Origin", init.origin);
  if (init.bearer) headers.set("Authorization", `Bearer ${init.bearer}`);
  const request = new Request(`https://catalog.example${path}`, {
    method: init.method ?? "GET",
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  return handle(request, testEnv, { keys, human, github });
}

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
