import { createScheduledController, env } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import migration from "../migrations/0004_composio_catalog.sql?raw";
import { type ComposioCatalog, type HttpFetch, refreshComposioCatalog } from "../src/composio.js";
import worker, { type Env, handle } from "../src/index.js";

// A made-up key: every test checks it stays out of D1, responses and logs.
const KEY = "ck-made-up-composio-key-7f3a91";
const testEnv = { ...(env as unknown as Env), COMPOSIO_API_KEY: KEY };
const NOW = new Date("2026-10-01T07:41:00Z");

beforeAll(async () => {
  for (const statement of migration.replace(/^--.*$/gm, "").split(";").map((value: string) => value.trim()).filter(Boolean)) {
    await testEnv.DB.prepare(statement).run();
  }
});

beforeEach(async () => {
  await testEnv.DB.prepare("DELETE FROM composio_catalog").run();
});

afterEach(() => {
  vi.restoreAllMocks();
});

/** A native toolkit as Composio's `GET /toolkits` lists it, with made-up data. */
function toolkit(index: number, changes: Record<string, unknown> = {}, meta: Record<string, unknown> = {}) {
  return {
    slug: `app_${index}`,
    name: `App ${index}`,
    type: "native",
    no_auth: false,
    is_local_toolkit: false,
    auth_schemes: ["OAUTH2"],
    // Every toolkit carries this: it's a legacy id, not a deprecation flag.
    deprecated: { toolkitId: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}` },
    meta: {
      description: `Made-up app number ${index}.`,
      logo: `https://logos.example.com/app_${index}.svg`,
      categories: [{ id: "productivity", name: "productivity" }],
      tools_count: 4, triggers_count: 0, version: "20260101_00",
      created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z",
      ...meta,
    },
    ...changes,
  };
}

const many = (count: number, start = 0) => Array.from({ length: count }, (_, index) => toolkit(start + index));

const CATEGORIES = [
  { id: "productivity", name: "Productivity" },
  { id: "developer-tools", name: "Developer Tools" },
  { id: "not-used", name: "Not Used" },
];

/** Stands in for Composio and records each call. */
function fake(route: (url: URL) => Response | Promise<Response>) {
  const calls: { url: URL; headers: Headers }[] = [];
  const fetch: HttpFetch = async (input, init) => {
    const url = new URL(input);
    calls.push({ url, headers: new Headers(init.headers) });
    return route(url);
  };
  return { fetch, calls, toolkitCalls: () => calls.filter((call) => call.url.pathname.endsWith("/toolkits")) };
}

/** Composio with `pages` of toolkits chained by `next_cursor`, and its category list. */
function composio(pages: unknown[][], categories: unknown[] = CATEGORIES) {
  return fake((url) => {
    if (url.pathname === "/api/v3.1/toolkits/categories") {
      return Response.json({ items: categories, next_cursor: null, total_pages: 1, current_page: 1, total_items: 3 });
    }
    const page = Number(url.searchParams.get("cursor")?.replace("page-", "") ?? "0");
    return Response.json({
      items: pages[page] ?? [],
      next_cursor: page + 1 < pages.length ? `page-${page + 1}` : null,
      total_pages: pages.length, current_page: page + 1, total_items: pages.flat().length,
    });
  });
}

const refresh = (source: { fetch: HttpFetch }, now = NOW, target: Env = testEnv) =>
  refreshComposioCatalog(target, { fetch: source.fetch, now: () => now });

async function storedRow() {
  return testEnv.DB.prepare("SELECT * FROM composio_catalog").first<{ document: string; revision: string; fetched_at: string }>();
}

async function stored(): Promise<ComposioCatalog> {
  return JSON.parse((await storedRow())!.document) as ComposioCatalog;
}

const get = (headers: HeadersInit = {}, method = "GET") =>
  handle(new Request("https://catalog.example/v1/composio/catalog.json", { method, headers }), testEnv);

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

describe("Composio catalog refresh", () => {
  it("stores the normalized contract in Composio's usage order", async () => {
    const outcome = await refresh(composio([[
      toolkit(0, { name: "Mail", no_auth: true }, { categories: [{ id: "developer-tools", name: "dev" }, { id: "productivity", name: "p" }] }),
      ...many(59, 1),
    ]]));
    expect(outcome).toMatchObject({ status: "stored", toolkits: 60 });

    const catalog = await stored();
    expect(Object.keys(catalog)).toEqual(["schemaVersion", "revision", "fetchedAt", "categories", "toolkits"]);
    expect(catalog.schemaVersion).toBe(1);
    expect(catalog.fetchedAt).toBe("2026-10-01T07:41:00.000Z");
    expect(catalog.revision).toBe(await sha256(JSON.stringify({ categories: catalog.categories, toolkits: catalog.toolkits })));
    expect(catalog.revision).toMatch(/^[0-9a-f]{64}$/);
    // Only categories some toolkit uses, sorted by name, named by Composio's category list.
    expect(catalog.categories).toEqual([
      { id: "developer-tools", name: "Developer Tools" },
      { id: "productivity", name: "Productivity" },
    ]);
    expect(catalog.toolkits.map((item) => item.slug)).toEqual(Array.from({ length: 60 }, (_, index) => `app_${index}`));
    expect(catalog.toolkits[0]).toEqual({
      slug: "app_0", name: "Mail", description: "Made-up app number 0.", logo: "https://logos.example.com/app_0.svg",
      categories: ["developer-tools", "productivity"], noAuth: true,
    });
    expect(Object.keys(catalog.toolkits[1]!)).toEqual(["slug", "name", "description", "logo", "categories", "noAuth"]);
  });

  it("drops toolkits that fail a check without failing the run", async () => {
    const bad = [
      toolkit(100, { slug: "Gmail" }),
      toolkit(101, { slug: "google-maps" }),
      toolkit(102, { slug: "a".repeat(65) }),
      toolkit(103, { slug: 7 }),
      toolkit(104, { name: "   " }),
      toolkit(105, { name: "N".repeat(81) }),
      toolkit(106, { type: "custom" }),
      toolkit(107, { deprecated: { is_deprecated: true } }),
      "not a toolkit",
      null,
      toolkit(0, { name: "Second app_0" }),
    ];
    const outcome = await refresh(composio([[...many(50), ...bad]]));
    expect(outcome).toMatchObject({ status: "stored", toolkits: 50 });
    const catalog = await stored();
    expect(catalog.toolkits.map((item) => item.slug)).toEqual(Array.from({ length: 50 }, (_, index) => `app_${index}`));
    expect(catalog.toolkits[0]!.name).toBe("App 0");
  });

  it("cleans text, logos and categories", async () => {
    const longDescription = `Starts here. ${"word ".repeat(100)}`;
    const tenCategories = Array.from({ length: 10 }, (_, index) => ({ id: `group-${index}`, name: `Group ${index}` }));
    await refresh(composio([[
      toolkit(0, { name: "  Spaced \n  Name\t" }, { description: "Line one.\n\n   Line\ttwo.\u0000", logo: "http://logos.example.com/a.svg" }),
      toolkit(1, { name: "N".repeat(80) }, { description: longDescription, logo: "javascript:alert(1)" }),
      toolkit(2, {}, { description: "   ", logo: `https://logos.example.com/${"a".repeat(500)}.svg` }),
      toolkit(3, {}, { description: undefined, logo: "https://user:pass@logos.example.com/a.svg" }),
      toolkit(4, {}, { logo: 42, categories: tenCategories }),
      toolkit(5, {}, {
        categories: [
          { id: "Bad Id", name: "Bad" }, { id: "a&b", name: "And" }, { id: "x".repeat(49), name: "Long" },
          { id: "unnamed", name: "   " }, { id: "toolkit-named", name: "  Named   by toolkit " },
          { id: "too-long-name", name: "L".repeat(61) }, { id: "productivity", name: "ignored" }, "oops",
        ],
      }),
      toolkit(6, {}, { categories: "productivity" }),
      toolkit(7, { meta: null }),
      ...many(50, 8),
    ]]));
    const catalog = await stored();
    const bySlug = (slug: string) => catalog.toolkits.find((item) => item.slug === slug)!;

    expect(bySlug("app_0")).toEqual({
      slug: "app_0", name: "Spaced Name", description: "Line one. Line two.", categories: ["productivity"], noAuth: false,
    });
    const description = bySlug("app_1").description!;
    expect([...description]).toHaveLength(280);
    expect(description.startsWith("Starts here. word")).toBe(true);
    expect(description.endsWith("…")).toBe(true);
    expect(bySlug("app_1").name).toHaveLength(80);
    expect(bySlug("app_1")).not.toHaveProperty("logo");
    expect(bySlug("app_2")).not.toHaveProperty("description");
    expect(bySlug("app_2")).not.toHaveProperty("logo");
    expect(bySlug("app_3")).not.toHaveProperty("description");
    expect(bySlug("app_3")).not.toHaveProperty("logo");
    expect(bySlug("app_4").categories).toEqual(tenCategories.slice(0, 8).map((category) => category.id));
    expect(bySlug("app_5").categories).toEqual(["toolkit-named", "productivity"]);
    expect(bySlug("app_6").categories).toEqual([]);
    expect(bySlug("app_7")).toEqual({ slug: "app_7", name: "App 7", categories: [], noAuth: false });

    // Composio's list names the categories it has; the toolkit's own name fills in the rest.
    expect(catalog.categories).toEqual([
      ...tenCategories.slice(0, 8),
      { id: "toolkit-named", name: "Named by toolkit" },
      { id: "productivity", name: "Productivity" },
    ].sort((a, b) => a.name.localeCompare(b.name, "en")));
    expect(catalog.categories.map((category) => category.id)).not.toContain("not-used");
    for (const item of catalog.toolkits) {
      for (const id of item.categories) expect(catalog.categories.map((category) => category.id)).toContain(id);
    }
  });

  it("follows next_cursor and sends the key only in its header", async () => {
    const composioFake = composio([many(30), many(30, 30), many(30, 60)]);
    expect(await refresh(composioFake)).toMatchObject({ status: "stored", toolkits: 90 });
    expect((await stored()).toolkits.map((item) => item.slug)).toEqual(Array.from({ length: 90 }, (_, index) => `app_${index}`));

    const pages = composioFake.toolkitCalls();
    expect(pages.map((call) => call.url.searchParams.get("cursor"))).toEqual([null, "page-1", "page-2"]);
    for (const call of pages) {
      expect(call.url.origin + call.url.pathname).toBe("https://backend.composio.dev/api/v3.1/toolkits");
      expect(Object.fromEntries(call.url.searchParams)).toMatchObject({
        type: "native", sort_by: "usage", include_deprecated: "false", limit: "1000",
      });
    }
    expect(composioFake.calls.map((call) => call.url.pathname)).toContain("/api/v3.1/toolkits/categories");
    for (const call of composioFake.calls) {
      expect(call.headers.get("x-api-key")).toBe(KEY);
      expect(call.url.href).not.toContain(KEY);
    }
  });

  it("reads at most 10 pages", async () => {
    let served = 0;
    const endless = fake((url) => {
      if (url.pathname.endsWith("/categories")) return Response.json({ items: CATEGORIES });
      served += 1;
      return Response.json({ items: many(10, served * 10), next_cursor: "more" });
    });
    expect(await refresh(endless)).toMatchObject({ status: "stored", toolkits: 100 });
    expect(endless.toolkitCalls()).toHaveLength(10);
  });

  it("keeps at most 4000 toolkits", async () => {
    const composioFake = composio(Array.from({ length: 5 }, (_, page) => many(1000, page * 1000)));
    expect(await refresh(composioFake)).toMatchObject({ status: "stored", toolkits: 4000 });
    expect(composioFake.toolkitCalls()).toHaveLength(4);
    expect((await stored()).toolkits.at(-1)!.slug).toBe("app_3999");
  });

  it("leaves the stored copy alone when nothing changed", async () => {
    const first = await refresh(composio([many(60)]));
    const second = await refresh(composio([many(60)]), new Date("2026-10-02T07:41:00Z"));
    expect(second).toEqual({ status: "unchanged", revision: (first as { revision: string }).revision, toolkits: 60 });
    expect((await stored()).fetchedAt).toBe("2026-10-01T07:41:00.000Z");

    const third = await refresh(composio([many(61)]), new Date("2026-10-03T07:41:00Z"));
    expect(third.status).toBe("stored");
    expect((await stored()).fetchedAt).toBe("2026-10-03T07:41:00.000Z");
  });
});

describe("a failed refresh keeps the stored catalog", () => {
  const timeout = () => { throw new DOMException("The operation was aborted due to timeout", "TimeoutError"); };
  const scenarios: [string, ReturnType<typeof fake>, string][] = [
    ["toolkits fail", fake(() => new Response("upstream down", { status: 500 })), "toolkits answered 500"],
    ["the key is refused", fake(() => Response.json({ error: `Invalid API key ${KEY}` }, { status: 401 })),
      "toolkits answered 401"],
    ["categories fail", fake((url) => url.pathname.endsWith("/categories")
      ? new Response(null, { status: 503 }) : Response.json({ items: many(60) })), "categories answered 503"],
    ["toolkits aren't JSON", fake(() => new Response("<html>")), "toolkits not JSON"],
    ["toolkits come in another shape", fake(() => Response.json({ data: many(60) })), "toolkits in an unknown shape"],
    ["categories come in another shape", fake((url) => Response.json(url.pathname.endsWith("/categories")
      ? { categories: CATEGORIES } : { items: many(60) })), "categories in an unknown shape"],
    ["a request times out", fake(timeout), "toolkits timed out"],
    ["Composio is unreachable", fake(() => { throw new TypeError("Network connection lost."); }), "toolkits unreachable"],
    ["an answer is too big", fake(() => new Response("[]", { headers: { "Content-Length": String(17 * 1024 * 1024) } })),
      "toolkits too large"],
    ["fewer than 50 toolkits survive", composio([[...many(49), toolkit(99, { slug: "Bad" })]]), "only 49 usable apps"],
    ["the catalog won't fit in D1", composio([Array.from({ length: 2500 }, (_, index) => toolkit(index, {}, {
      description: "d".repeat(280), logo: `https://logos.example.com/${"l".repeat(470)}/${index}.svg`,
    }))]), "catalog too large"],
  ];

  it.each(scenarios)("when %s", async (_, failing, reason) => {
    await refresh(composio([many(60)]));
    const before = await storedRow();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

    expect(await refresh(failing, new Date("2026-10-02T07:41:00Z"))).toEqual({ status: "kept", reason });
    expect(await storedRow()).toEqual(before);
    expect(warn).toHaveBeenCalledWith(`composio catalog: kept the stored copy (${reason})`);
    expect((await get()).status).toBe(200);
  });

  it("does nothing without the key", async () => {
    const composioFake = composio([many(60)]);
    expect(await refresh(composioFake, NOW, { ...testEnv, COMPOSIO_API_KEY: "" })).toEqual({
      status: "kept", reason: "no COMPOSIO_API_KEY",
    });
    expect(composioFake.calls).toHaveLength(0);
    expect(await storedRow()).toBeNull();
  });

  it("runs from the scheduled handler", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const noKey = { ...testEnv, COMPOSIO_API_KEY: "" };
    await expect(worker.scheduled(createScheduledController({ cron: "41 7 * * *" }), noKey)).resolves.toBeUndefined();
    expect(warn).toHaveBeenCalledWith("composio catalog: kept the stored copy (no COMPOSIO_API_KEY)");
  });
});

describe("GET /v1/composio/catalog.json", () => {
  it("answers 503 until a refresh has stored a catalog", async () => {
    const response = await get();
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "catalog_unavailable" });
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(response.headers.get("Cache-Control")).toBe("no-store");
  });

  it("serves the stored catalog with an ETag, CORS and an hour of caching, without calling Composio", async () => {
    await refresh(composio([many(60)]));
    const network = vi.spyOn(globalThis, "fetch");
    const response = await get();
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toContain("application/json");
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(response.headers.get("Access-Control-Allow-Credentials")).toBeNull();
    expect(response.headers.get("Cache-Control")).toContain("max-age=3600");
    const catalog = await response.json<ComposioCatalog>();
    expect(response.headers.get("ETag")).toBe(`"${catalog.revision}"`);
    expect(catalog).toEqual(await stored());
    expect(network).not.toHaveBeenCalled();
  });

  it("answers a matching ETag with 304", async () => {
    await refresh(composio([many(60)]));
    const etag = (await get()).headers.get("ETag")!;
    for (const [value, method] of [[etag, "GET"], [`W/${etag}`, "GET"], [`"stale", ${etag}`, "HEAD"]] as const) {
      const response = await get({ "If-None-Match": value }, method);
      expect(response.status).toBe(304);
      expect(response.headers.get("ETag")).toBe(etag);
      expect(await response.text()).toBe("");
    }
    expect((await get({ "If-None-Match": '"stale"' })).status).toBe(200);

    await refresh(composio([many(61)]));
    expect((await get({ "If-None-Match": etag })).status).toBe(200);
  });
});

describe("the developer key", () => {
  it("never lands in D1, responses or logs", async () => {
    const logs = [vi.spyOn(console, "log"), vi.spyOn(console, "warn"), vi.spyOn(console, "error")]
      .map((spy) => spy.mockImplementation(() => {}));
    await refresh(composio([many(60)]));
    await refresh(fake(() => Response.json({ error: `Invalid API key ${KEY}` }, { status: 401 })));
    await refresh(fake(() => { throw new Error(`fetch failed for ${KEY}`); }));

    const rows = (await testEnv.DB.prepare("SELECT * FROM composio_catalog").all()).results;
    expect(rows).toHaveLength(1);
    expect(JSON.stringify(rows)).not.toContain(KEY);

    for (const response of [await get(), await get({}, "HEAD"), await get({ "If-None-Match": "*" })]) {
      expect(JSON.stringify([...response.headers])).not.toContain(KEY);
      expect(await response.text()).not.toContain(KEY);
    }
    const logged = logs.flatMap((spy) => spy.mock.calls.flat()).map(String);
    expect(logged.length).toBeGreaterThan(0);
    for (const line of logged) expect(line).not.toContain(KEY);
  });
});
