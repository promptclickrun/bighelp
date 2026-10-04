import { env } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import migration from "../migrations/0001_templates.sql?raw";
import { type Env, handle } from "../src/index.js";

const testEnv = env as unknown as Env;
const TEAM = "team.example.cloudflareaccess.com";
let keyPair: CryptoKeyPair;
let publicJwk: JsonWebKey & { kid: string };
const keys = async () => [publicJwk];

beforeAll(async () => {
  for (const statement of migration.replace(/^--.*$/gm, "").split(";").map((value: string) => value.trim()).filter(Boolean)) {
    await testEnv.DB.prepare(statement).run();
  }
  keyPair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true, ["sign", "verify"],
  ) as CryptoKeyPair;
  publicJwk = { ...(await crypto.subtle.exportKey("jwk", keyPair.publicKey) as JsonWebKey), kid: "k1" };
});

beforeEach(async () => {
  await testEnv.DB.prepare("DELETE FROM templates").run();
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
  init: { method?: string; body?: unknown; jwt?: string; origin?: string } = {},
): Promise<Response> {
  const headers = new Headers({ "Content-Type": "application/json" });
  if (init.jwt) headers.set("Cf-Access-Jwt-Assertion", init.jwt);
  if (init.origin) headers.set("Origin", init.origin);
  const request = new Request(`https://catalog.example${path}`, {
    method: init.method ?? "GET",
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  return handle(request, testEnv, keys);
}

const submitter = () => token({ aud: ["aud-account"], email: "Sam@Example.com" });
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
  creditName: "Sam",
};

const blueprint = {
  kind: "blueprint",
  board: "goals",
  category: "personal",
  goalCategory: "health",
  text: "Add a goal to my Goals: walk [8,000] steps a day. Check in each evening.",
};

describe("submissions", () => {
  it("needs a signed-in person with a token for the submit app", async () => {
    expect((await call("/account/submissions", { method: "POST", body: agent })).status).toBe(401);
    const wrongAudience = await reviewer();
    expect((await call("/account/submissions", { method: "POST", body: agent, jwt: wrongAudience })).status)
      .toBe(401);
    const forged = (await submitter()).slice(0, -4) + "AAAA";
    expect((await call("/account/submissions", { method: "POST", body: agent, jwt: forged })).status).toBe(401);
  });

  it("holds a submission for review, invisible to the public until approved", async () => {
    const response = await call("/account/submissions", { method: "POST", body: agent, jwt: await submitter() });
    expect(response.status).toBe(201);
    const { id } = await response.json<{ id: string }>();

    const before = await (await call("/v1/catalog.json")).json<{ agents: unknown[] }>();
    expect(before.agents).toHaveLength(0);

    const mine = await (await call("/account/me", { jwt: await submitter() }))
      .json<{ email: string; submissions: { id: string; status: string }[] }>();
    expect(mine.email).toBe("sam@example.com");
    expect(mine.submissions).toEqual([expect.objectContaining({ id, status: "pending" })]);

    const queue = await (await call("/review/templates", { jwt: await reviewer() }))
      .json<{ templates: { id: string; submitterEmail: string }[] }>();
    expect(queue.templates).toEqual([expect.objectContaining({ id, submitterEmail: "sam@example.com" })]);

    const approved = await call(`/review/templates/${id}/approve`, { method: "POST", jwt: await agentToken() });
    expect(approved.status).toBe(200);
    expect(await approved.json()).toMatchObject({ status: "approved", reviewedBy: "service-token:client-id.access" });

    const raw = await (await call("/v1/catalog.json")).text();
    const after = JSON.parse(raw) as { agents: Record<string, unknown>[] };
    expect(after.agents).toEqual([expect.objectContaining({ id, name: "Pilot", credit: "Sam", source: "community" })]);
    expect(raw).not.toContain("example.com");
  });

  it("rejects bad input with the field to fix", async () => {
    const response = await call("/account/submissions", {
      method: "POST", body: { ...blueprint, board: "kanban" }, jwt: await submitter(),
    });
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ field: "board" });
  });

  it("ignores a symbol from a submitter", async () => {
    const response = await call("/account/submissions", {
      method: "POST", body: { ...agent, symbol: "flame" }, jwt: await submitter(),
    });
    const { id } = await response.json<{ id: string }>();
    const row = await (await call(`/review/templates/${id}`, { jwt: await reviewer() })).json<Record<string, unknown>>();
    expect(row.symbol).toBeUndefined();
  });

  it("caps how many one person can have waiting", async () => {
    const jwt = await submitter();
    for (let index = 0; index < 10; index += 1) {
      expect((await call("/account/submissions", { method: "POST", body: blueprint, jwt })).status).toBe(201);
    }
    expect((await call("/account/submissions", { method: "POST", body: blueprint, jwt })).status).toBe(429);
  });
});

describe("review", () => {
  it("is closed to submitters", async () => {
    expect((await call("/review/templates", { jwt: await submitter() })).status).toBe(401);
  });

  it("needs a reason to reject, and shows the reason to the submitter", async () => {
    const { id } = await (await call("/account/submissions", { method: "POST", body: blueprint, jwt: await submitter() }))
      .json<{ id: string }>();
    expect((await call(`/review/templates/${id}/reject`, { method: "POST", jwt: await reviewer() })).status).toBe(400);
    const rejected = await call(`/review/templates/${id}/reject`, {
      method: "POST", body: { note: "Too close to an existing blueprint." }, jwt: await reviewer(),
    });
    expect(rejected.status).toBe(200);
    const mine = await (await call("/account/me", { jwt: await submitter() }))
      .json<{ submissions: { status: string; reviewNote: string }[] }>();
    expect(mine.submissions[0]).toMatchObject({ status: "rejected", reviewNote: "Too close to an existing blueprint." });
  });

  it("can edit a submission before approving it", async () => {
    const { id } = await (await call("/account/submissions", { method: "POST", body: agent, jwt: await submitter() }))
      .json<{ id: string }>();
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
    expect((await handle(request, testEnv, keys)).status).toBe(304);
  });

  it("lets any page read the public feed", async () => {
    const response = await call("/v1/catalog.json", { origin: "https://anywhere.example" });
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(response.headers.get("Access-Control-Allow-Credentials")).toBeNull();
  });

  it("lets only the site's origins send cookies", async () => {
    const allowed = await call("/account/me", { jwt: await submitter(), origin: "https://bighelp.example" });
    expect(allowed.headers.get("Access-Control-Allow-Origin")).toBe("https://bighelp.example");
    expect(allowed.headers.get("Access-Control-Allow-Credentials")).toBe("true");
    const other = await call("/account/me", { jwt: await submitter(), origin: "https://evil.example" });
    expect(other.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });
});
