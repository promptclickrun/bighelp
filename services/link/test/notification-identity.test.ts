import { env } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { handleNotificationIdentityRequest, verifyNotificationOnlyRequest } from "../src/notification-identity.js";
import { handleLoopdyLinkRequest } from "../src/http.js";
import type { LinkEnv } from "../src/user-link.js";

const base = "https://link.loopdy.example";
const path = "/v1/notifications/bootstrap";
const bytes = (value: string) => new TextEncoder().encode(value);
function encoded(value: ArrayBuffer | Uint8Array): string {
  return btoa(String.fromCharCode(...new Uint8Array(value))).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}
function environment(): LinkEnv {
  return {
    ...env,
    NOTIFICATION_BOOTSTRAP_RATE_SECRET: crypto.randomUUID(),
    BUZZKIT_API_KEY: `bk_tn_${crypto.randomUUID()}`,
    BUZZKIT_IDENTITY_SECRET: crypto.randomUUID(),
    BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
  } as LinkEnv;
}
async function fixture() {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const now = Math.floor(Date.now() / 1000);
  const body = { version: 1, installationId: crypto.randomUUID(), requestId: crypto.randomUUID(),
    publicKeySPKI: encoded(await crypto.subtle.exportKey("spki", keys.publicKey) as ArrayBuffer), timestamp: now,
    nonce: encoded(crypto.getRandomValues(new Uint8Array(24))), proof: "" };
  body.proof = encoded(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys.privateKey,
    bytes(["loopdy-notification-bootstrap-v1", "POST", path, body.installationId, body.requestId,
      String(body.timestamp), body.nonce, body.publicKeySPKI].join("\n"))));
  return { keys, now, body, request: () => new Request(base + path, { method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "192.0.2.10" }, body: JSON.stringify(body) }) };
}
async function signedRequest(
  f: Awaited<ReturnType<typeof fixture>>,
  requestPath: string,
  method = "GET",
  body = "",
  authorizationEpoch = 1,
  signingKey: CryptoKey = f.keys.privateKey,
) {
  const nonce = encoded(crypto.getRandomValues(new Uint8Array(24)));
  const transcript = ["loopdy-notification-device-v1", method, requestPath, f.body.installationId,
    String(f.now), nonce, String(authorizationEpoch),
    encoded(await crypto.subtle.digest("SHA-256", bytes(body)))].join("\n");
  return new Request(base + requestPath, { method, body: body || undefined, headers: {
    ...(body ? { "content-type": "application/json" } : {}),
    "x-loopdy-notification-installation": f.body.installationId, "x-loopdy-timestamp": String(f.now),
    "x-loopdy-nonce": nonce, "x-loopdy-authorization-epoch": String(authorizationEpoch),
    "x-loopdy-signature": encoded(await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" }, signingKey, bytes(transcript),
    )),
  } });
}

async function hostRequest(
  keys: CryptoKeyPair,
  grantId: string,
  hostKeyId: string,
  suffix: string,
  body: object,
  now: number,
) {
  const requestPath = `/v1/notifications/host-grants/${grantId}${suffix}`;
  const raw = JSON.stringify(body);
  const nonce = encoded(crypto.getRandomValues(new Uint8Array(32)));
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes(raw))),
    (byte) => byte.toString(16).padStart(2, "0")).join("");
  const transcript = ["loopdy-notification-host-v1", "POST", requestPath, grantId, String(now), nonce, hash].join("\n");
  return new Request(base + requestPath, { method: "POST", body: raw, headers: {
    "content-type": "application/json", "x-loopdy-host-key-id": hostKeyId,
    "x-loopdy-timestamp": String(now), "x-loopdy-nonce": nonce,
    "x-loopdy-signature": encoded(await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" }, keys.privateKey, bytes(transcript),
    )),
  } });
}

describe("notification-only identity isolation", () => {
  afterEach(() => vi.restoreAllMocks());

  it("bootstraps idempotently without creating an account and denies ordinary device APIs", async () => {
    const f = await fixture(); const e = environment();
    const before = await env.ACCOUNTS.prepare("SELECT COUNT(*) AS count FROM accounts").first<{ count: number }>();
    const first = await handleNotificationIdentityRequest(f.request(), e, f.now, async () => {});
    expect(first?.status).toBe(201);
    const firstBody = await first!.json();
    const repeat = await handleNotificationIdentityRequest(f.request(), e, f.now, async () => {});
    expect(repeat?.status).toBe(200);
    expect(await repeat!.json()).toEqual(firstBody);
    expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS count FROM accounts").first()).toEqual(before);
    const response = await handleLoopdyLinkRequest(await signedRequest(f, "/v1/devices"), e);
    expect([401, 403]).toContain(response.status);
  });

  it("rejects invalid proof without storing an installation", async () => {
    const f = await fixture(); f.body.proof = encoded(new Uint8Array(64));
    const response = await handleNotificationIdentityRequest(f.request(), environment(), f.now, async () => {});
    expect(response?.status).toBe(401);
    expect(await env.ACCOUNTS.prepare("SELECT installation_id FROM notification_installations WHERE installation_id=?")
      .bind(f.body.installationId).first()).toBeNull();
  });

  it("rejects changed bootstrap bytes and replayed signed request nonces", async () => {
    const f = await fixture(); const e = environment();
    expect((await handleNotificationIdentityRequest(f.request(), e, f.now, async () => {}))?.status).toBe(201);
    const request = await signedRequest(f, "/v1/notifications/host-grants/buzzkit/identity");
    const principal = await verifyNotificationOnlyRequest(request.clone(), new Uint8Array(), e, f.now);
    expect(principal.ownerKind).toBe("notification-instance");
    await expect(verifyNotificationOnlyRequest(request.clone(), new Uint8Array(), e, f.now)).rejects.toThrow();
    f.body.timestamp += 1;
    expect((await handleNotificationIdentityRequest(f.request(), e, f.now, async () => {}))?.status).toBe(409);
  });

  it("blocks test sends while installation revocation cleanup is awaiting", async () => {
    const f = await fixture();
    const e = environment();
    expect((await handleNotificationIdentityRequest(f.request(), e, f.now, async () => {}))?.status).toBe(201);
    let releaseCleanup!: () => void;
    let signalCleanup!: () => void;
    const cleanupEntered = new Promise<void>((resolve) => { signalCleanup = resolve; });
    const cleanupRelease = new Promise<void>((resolve) => { releaseCleanup = resolve; });
    const providerPosts: string[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);
      if (init?.method === "DELETE") {
        signalCleanup();
        await cleanupRelease;
        return Response.json({ success: true, data: {} });
      }
      if (init?.method === "POST") {
        providerPosts.push(url);
        return Response.json({
          success: true,
          data: { id: "msg_installation_cleanup_race", status: "queued", counts: { total: 1, sent: 0 } },
        });
      }
      if (url.includes("/v1/subscribers/")) {
        return Response.json({
          success: false,
          data: null,
          error: { code: "not_found" },
        }, { status: 404 });
      }
      return Response.json({
        success: true,
        data: { id: "msg_installation_cleanup_race", status: "queued", counts: { total: 1, sent: 0 } },
      });
    });
    const revocation = handleLoopdyLinkRequest(
      await signedRequest(f, "/v1/notifications/installations/current", "DELETE"), e,
    );
    await cleanupEntered;
    const testBody = JSON.stringify({ version: 1, requestId: crypto.randomUUID() });

    let send: Response;
    try {
      send = await handleLoopdyLinkRequest(await signedRequest(
        f, "/v1/notifications/host-grants/buzzkit/test", "POST", testBody,
      ), e);
    } finally {
      releaseCleanup();
    }

    expect(send.status).toBe(403);
    expect(providerPosts).toEqual([]);
    expect((await revocation).status).toBe(200);
    expect(await env.ACCOUNTS.prepare(`SELECT state,authorization_epoch FROM notification_installations
      WHERE installation_id=?`).bind(f.body.installationId).first())
      .toEqual({ state: "revoked", authorization_epoch: 2 });
  });

  it("keeps failed installation cleanup fenced and retries it with prior-epoch proof", async () => {
    const f = await fixture();
    const e = environment();
    expect((await handleNotificationIdentityRequest(f.request(), e, f.now, async () => {}))?.status).toBe(201);
    const transport = vi.spyOn(globalThis, "fetch").mockRejectedValueOnce(new Error("cleanup unavailable"));

    const failed = await handleLoopdyLinkRequest(
      await signedRequest(f, "/v1/notifications/installations/current", "DELETE"), e,
    );

    expect(failed.status).toBe(503);
    expect(await env.ACCOUNTS.prepare(`SELECT state,authorization_epoch FROM notification_installations
      WHERE installation_id=?`).bind(f.body.installationId).first())
      .toEqual({ state: "revoked", authorization_epoch: 2 });
    expect(await env.ACCOUNTS.prepare(`SELECT authorization_epoch FROM notification_installation_revocation_cleanup
      WHERE installation_id=?`).bind(f.body.installationId).first())
      .toEqual({ authorization_epoch: 1 });

    transport.mockImplementation(async (input, init) => {
      if (init?.method === "DELETE") return Response.json({ success: true, data: {} });
      expect(String(input)).toContain("/v1/subscribers/");
      return Response.json({
        success: false,
        data: null,
        error: { code: "not_found" },
      }, { status: 404 });
    });
    const retried = await handleLoopdyLinkRequest(
      await signedRequest(f, "/v1/notifications/installations/current", "DELETE"), e,
    );

    expect(retried.status).toBe(200);
    expect(await env.ACCOUNTS.prepare(`SELECT installation_id FROM notification_installation_revocation_cleanup
      WHERE installation_id=?`).bind(f.body.installationId).first()).toBeNull();
  });

  it("returns the revoked result for a signed prior-epoch retry without replay or cleanup writes", async () => {
    const f = await fixture(); const e = environment();
    expect((await handleNotificationIdentityRequest(f.request(), e, f.now, async () => {}))?.status).toBe(201);
    const original = await signedRequest(f, "/v1/notifications/installations/current", "DELETE");
    const originalNonce = original.headers.get("x-loopdy-nonce")!;
    await env.ACCOUNTS.prepare(`INSERT INTO notification_installation_nonces(
      installation_id,nonce,expires_at) VALUES(?,?,?)`)
      .bind(f.body.installationId, originalNonce, f.now + 120).run();
    const committed = await env.ACCOUNTS.prepare(`UPDATE notification_installations
      SET state='revoked',authorization_epoch=authorization_epoch+1,revoked_at=?
      WHERE installation_id=? AND state='active'`)
      .bind(f.now, f.body.installationId).run();
    expect(committed.meta.changes).toBe(1);

    let cleanupCalls = 0;
    const retry = await signedRequest(f, "/v1/notifications/installations/current", "DELETE");
    expect(retry.headers.get("x-loopdy-nonce")).not.toBe(originalNonce);
    const response = await handleNotificationIdentityRequest(retry, e, f.now, async () => {
      cleanupCalls += 1;
    });

    expect(response?.status).toBe(200);
    expect(await response!.json()).toEqual({
      version: 2,
      installation: { installationId: f.body.installationId, state: "revoked" },
    });
    expect(cleanupCalls).toBe(0);
    expect((await env.ACCOUNTS.prepare(`SELECT nonce FROM notification_installation_nonces
      WHERE installation_id=? ORDER BY nonce`).bind(f.body.installationId).all<{ nonce: string }>()).results)
      .toEqual([{ nonce: originalNonce }]);
    expect(await env.ACCOUNTS.prepare(`SELECT state,authorization_epoch FROM notification_installations
      WHERE installation_id=?`).bind(f.body.installationId).first())
      .toEqual({ state: "revoked", authorization_epoch: 2 });
  });

  it("keeps revoked installation credentials invalid for other paths, keys, and epochs", async () => {
    const f = await fixture(); const e = environment();
    expect((await handleNotificationIdentityRequest(f.request(), e, f.now, async () => {}))?.status).toBe(201);
    await env.ACCOUNTS.prepare(`UPDATE notification_installations
      SET state='revoked',authorization_epoch=authorization_epoch+1,revoked_at=?
      WHERE installation_id=? AND state='active'`).bind(f.now, f.body.installationId).run();
    const otherKeys = await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
    ) as CryptoKeyPair;
    let cleanupCalls = 0;
    const cleanup = async () => { cleanupCalls += 1; };

    const otherPath = await handleLoopdyLinkRequest(
      await signedRequest(f, "/v1/notifications/host-grants"), e,
    );
    const otherKey = await handleNotificationIdentityRequest(
      await signedRequest(f, "/v1/notifications/installations/current", "DELETE", "", 1, otherKeys.privateKey),
      e, f.now, cleanup,
    );
    const wrongEpoch = await handleNotificationIdentityRequest(
      await signedRequest(f, "/v1/notifications/installations/current", "DELETE", "", 2),
      e, f.now, cleanup,
    );

    expect(otherPath.status).toBe(403);
    expect(otherKey?.status).toBe(401);
    expect(wrongEpoch?.status).toBe(403);
    expect(cleanupCalls).toBe(0);
  });

  it("claims a real installation-scoped v3 grant", async () => {
    const f = await fixture(); const e = environment();
    expect((await handleNotificationIdentityRequest(f.request(), e, f.now, async () => {}))?.status).toBe(201);
    const host = await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
    ) as CryptoKeyPair;
    const hostRaw = new Uint8Array(await crypto.subtle.exportKey("raw", host.publicKey) as ArrayBuffer);
    const hostPublicKey = encoded(hostRaw);
    const hostKeyId = encoded(await crypto.subtle.digest("SHA-256", hostRaw));
    const grantBody = JSON.stringify({
      version: 3, idempotencyKey: crypto.randomUUID(), instanceId: crypto.randomUUID(),
      hostPublicKey, hostKeyId, profile: "default",
      eventTypes: [
        "session.completed", "session.failed", "scheduled.completed", "scheduled.failed",
        "approval.required", "clarification.required", "subagent.completed", "subagent.failed",
      ],
      expiresAt: f.now + 1_800,
    });
    const created = await handleLoopdyLinkRequest(
      await signedRequest(f, "/v1/notifications/host-grants", "POST", grantBody), e,
    );
    expect(created.status).toBe(201);
    const { grant } = await created.json<{ grant: { grantId: string; state: string } }>();
    expect(grant.state).toBe("issued");
    const claimed = await handleLoopdyLinkRequest(await hostRequest(
      host, grant.grantId, hostKeyId, "/claim",
      { version: 2, idempotencyKey: crypto.randomUUID() }, f.now,
    ), e);
    expect(claimed.status).toBe(200);
    expect((await claimed.json<{ grant: { state: string } }>()).grant.state).toBe("active");
    expect((await env.ACCOUNTS.prepare(
      "SELECT state FROM notification_instance_grants WHERE grant_id=?",
    ).bind(grant.grantId).first<{ state: string }>())?.state).toBe("active");
  });

  it("fails closed without the server rate-protection secret", async () => {
    const f = await fixture();
    const response = await handleNotificationIdentityRequest(f.request(), env as LinkEnv, f.now, async () => {});
    expect(response?.status).toBe(503);
  });
});
