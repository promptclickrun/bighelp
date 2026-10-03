import { env, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { canonicalDeviceRequest, DEVICE_AUTH_HEADERS } from "../src/device-auth.js";
import { completeAccountAuthentication } from "../src/account-auth.js";
import { handleLoopdyLinkRequest } from "../src/http.js";
import worker from "../src/index.js";
import type { LinkEnv, UserLink } from "../src/user-link.js";
import { LoopdyLinkError } from "../src/contracts.js";

const NOW = Math.floor(Date.now() / 1_000);
const ACCOUNT = "account-server-selected-coordinate";
const PROFILE_ACCOUNT = "account-profile-fixture-coordinate";
const SOCKET_FORWARD_ACCOUNT = "account-socket-forward-coordinate";
const ACCESS_TOKEN = "access-token-fixture-value-with-enough-entropy-0001";
const PROFILE_ACCESS_TOKEN = "profile-access-token-fixture-with-enough-entropy-0001";
const DELETE_ACCOUNT = "account-delete-fixture-coordinate";
const DELETE_ACCESS_TOKEN = "delete-access-token-fixture-with-enough-entropy-0001";
const RETRY_DELETE_ACCOUNT = "account-delete-retry-fixture-coordinate";
const RETRY_DELETE_ACCESS_TOKEN = "delete-retry-access-token-fixture-with-enough-entropy-0002";
const SECURITY_DELETE_ACCOUNT = "account-delete-security-fixture-coordinate";
const SECURITY_DELETE_ACCESS_TOKEN =
  "delete-security-access-token-fixture-with-enough-entropy-0003";

function accountDeletionEnvironment(overrides: Partial<LinkEnv> = {}): LinkEnv {
  vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
    if (init?.method === "DELETE") return Response.json({ success: true, data: {} });
    return Response.json({ success: false, error: { code: "not_found" } }, { status: 404 });
  });
  return {
    ...env,
    BUZZKIT_API_KEY: `bk_tn_${crypto.randomUUID()}`,
    BUZZKIT_IDENTITY_SECRET: crypto.randomUUID(),
    BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
    ...overrides,
  } as LinkEnv;
}

describe("Loopdy Link HTTP control plane", () => {
  afterEach(() => vi.restoreAllMocks());
  beforeEach(async () => {
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("DELETE FROM device_nonces"),
      env.ACCOUNTS.prepare("DELETE FROM device_directory"),
      env.ACCOUNTS.prepare("DELETE FROM access_sessions"),
      env.ACCOUNTS.prepare("DELETE FROM passkeys"),
      env.ACCOUNTS.prepare("DELETE FROM auth_challenges"),
      env.ACCOUNTS.prepare("DELETE FROM account_deletion_receipts"),
      env.ACCOUNTS.prepare("DELETE FROM accounts"),
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(ACCOUNT, NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(await sha256Base64URL(ACCESS_TOKEN), ACCOUNT, NOW, NOW + 900),
    ]);
  });

  it("lists notification grants for an authenticated account device without any paired host", async () => {
    const keys = await generateDeviceKeys();
    const access = "notification-only-test-access-token-value";
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("INSERT INTO accounts (account_coordinate,status,authorization_epoch,created_at) VALUES (?,'active',1,?)").bind("notification-test-account",NOW),
      env.ACCOUNTS.prepare("INSERT INTO access_sessions (token_hash,account_coordinate,authorization_epoch,created_at,expires_at) VALUES (?,?,1,?,?)").bind(await sha256Base64URL(access),"notification-test-account",NOW,NOW+900),
    ]);
    const registered = await fetchWorker("/v1/devices", {
      method: "POST",
      headers: { authorization: `Bearer ${access}`, "content-type": "application/json" },
      body: JSON.stringify({ deviceId: "notification-only-mobile", publicKeySPKI: keys.publicKeySPKI,
        role: "mobile", kind: "phone", encryptedName: "opaque-name", revision: 1 }),
    });
    expect(registered.status).toBe(201);
    const result = await signedFetch(keys.privateKey, "/v1/notifications/host-grants", "GET", "", 47001,
      "notification-only-mobile");
    expect(result.status).toBe(200);
    expect(await result.json()).toEqual({ version: 1, grants: [] });
    expect((await fetchWorker("/v1/notifications/host-grants")).status).toBe(401);
  });

  it("retires legacy account notification grants and the shared BuzzKit subscriber", async () => {
    const keys = await generateDeviceKeys();
    const account = "legacy-notification-retirement-account";
    const access = "legacy-notification-retirement-access-token";
    const deviceId = "legacy-notification-retirement-device";
    const grantId = crypto.randomUUID();
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate,status,authorization_epoch,created_at) VALUES (?,'active',1,?)",
      ).bind(account, NOW),
      env.ACCOUNTS.prepare(
        "INSERT INTO access_sessions (token_hash,account_coordinate,authorization_epoch,created_at,expires_at) VALUES (?,?,1,?,?)",
      ).bind(await sha256Base64URL(access), account, NOW, NOW + 900),
    ]);
    expect((await fetchWorker("/v1/devices", {
      method: "POST",
      headers: { authorization: "Bearer " + access, "content-type": "application/json" },
      body: JSON.stringify({ deviceId, publicKeySPKI: keys.publicKeySPKI,
        role: "mobile", kind: "phone", encryptedName: "opaque", revision: 1 }),
    })).status).toBe(201);
    await env.ACCOUNTS.prepare(`INSERT INTO notification_grants(
      grant_id,account_coordinate,device_id,authorization_epoch,idempotency_key,request_digest,
      public_json,state,revision,created_at,expires_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)`)
      .bind(grantId, account, deviceId, 1, crypto.randomUUID(), "fixture-digest",
        JSON.stringify({ grantId, state: "active", revision: 1 }), "active", 1, NOW, NOW + 1_800).run();
    const providerCalls: Array<{ method: string; path: string }> = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (url, init) => {
      providerCalls.push({ method: init?.method ?? "GET", path: new URL(String(url)).pathname });
      if (init?.method === "DELETE") {
        return Response.json({ success: true, data: {} });
      }
      return Response.json({ success: false, error: { code: "not_found" } }, { status: 404 });
    });
    const targetEnv = {
      ...env,
      BUZZKIT_API_KEY: `bk_tn_${crypto.randomUUID()}`,
      BUZZKIT_IDENTITY_SECRET: crypto.randomUUID(),
      BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
    } as LinkEnv;
    const path = "/v1/notifications/host-grants/buzzkit/identity";
    const result = await handleLoopdyLinkRequest(
      await signedRequest(keys.privateKey, deviceId, path, "DELETE", "", 70_001),
      targetEnv,
    );

    expect(result.status).toBe(200);
    expect(await result.json()).toEqual({ version: 1, identity: { scope: "account", state: "revoked" } });
    expect((await env.ACCOUNTS.prepare("SELECT state FROM notification_grants WHERE grant_id=?")
      .bind(grantId).first<{ state: string }>())?.state).toBe("revoked");
    expect(await env.ACCOUNTS.prepare(
      "SELECT account_coordinate FROM notification_account_scope_retirements WHERE account_coordinate=?",
    ).bind(account).first()).not.toBeNull();
    expect(providerCalls.map((call) => call.method)).toEqual(["DELETE", "GET"]);
    expect(providerCalls.every((call) => call.path.startsWith("/v1/subscribers/acct_"))).toBe(true);

    const recreated = JSON.stringify({ version: 2, idempotencyKey: crypto.randomUUID(),
      hostPublicKey: base64url(new Uint8Array(65).fill(1)), hostKeyId: base64url(new Uint8Array(32).fill(1)),
      profile: "default", eventTypes: ["session.completed"], expiresAt: NOW + 1_800 });
    expect((await handleLoopdyLinkRequest(
      await signedRequest(keys.privateKey, deviceId, "/v1/notifications/host-grants", "POST", recreated, 70_002),
      targetEnv,
    )).status).toBe(410);
    expect((await handleLoopdyLinkRequest(
      await signedRequest(keys.privateKey, deviceId, path, "GET", "", 70_003), targetEnv,
    )).status).toBe(410);
    expect((await handleLoopdyLinkRequest(
      await signedRequest(keys.privateKey, deviceId, path, "DELETE", "", 70_004), targetEnv,
    )).status).toBe(200);
  });

  it.each([false, true])("binds exact host grants and optional approval authority (approval=%s)", async (approvalEnabled) => {
    const keys = await generateDeviceKeys();
    const account = "notification-grant-lifecycle-account-" + String(approvalEnabled);
    const access = "notification-grant-lifecycle-access-fixture";
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("INSERT INTO accounts (account_coordinate,status,authorization_epoch,created_at) VALUES (?,'active',1,?)").bind(account,NOW),
      env.ACCOUNTS.prepare("INSERT INTO access_sessions (token_hash,account_coordinate,authorization_epoch,created_at,expires_at) VALUES (?,?,1,?,?)").bind(await sha256Base64URL(access),account,NOW,NOW+900),
    ]);
    const deviceId = "notification-grant-mobile-" + String(approvalEnabled);
    expect((await fetchWorker("/v1/devices", {method:"POST",headers:{authorization:`Bearer ${access}`,"content-type":"application/json"},
      body:JSON.stringify({deviceId,publicKeySPKI:keys.publicKeySPKI,role:"mobile",kind:"phone",encryptedName:"opaque",revision:1})})).status).toBe(201);
    await runInDurableObject<UserLink, void>(env.USER_LINKS.getByName(account), (_instance, state) => {
      state.storage.sql.exec("UPDATE devices SET push_state='ready',push_revision=1 WHERE device_id=?",deviceId);
    });
    const host = await crypto.subtle.generateKey({name:"ECDSA",namedCurve:"P-256"},true,["sign","verify"]) as CryptoKeyPair;
    const exportedHost = await crypto.subtle.exportKey("raw",host.publicKey);
    if (!(exportedHost instanceof ArrayBuffer)) throw new Error("Raw fixture key must be binary");
    const hostRaw = new Uint8Array(exportedHost);
    const hostKeyId = base64url(new Uint8Array(await crypto.subtle.digest("SHA-256",hostRaw)));
    const sends: unknown[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
      if (init?.method === "POST") sends.push(JSON.parse(String(init.body)));
      return Response.json({success:true,data:{id:"msg_fixture",status:"queued",counts:{total:1,sent:0}}});
    });
    const targetEnv = {...env,BUZZKIT_API_KEY:`bk_tn_${crypto.randomUUID()}`,BUZZKIT_IDENTITY_SECRET:crypto.randomUUID(),
      BUZZKIT_IDENTITY_SECRET_GENERATION:"notification-instance-v2"} as LinkEnv;
    const root = "/v1/notifications/host-grants";
    const body = JSON.stringify({version:2,idempotencyKey:crypto.randomUUID(),hostPublicKey:base64url(hostRaw),hostKeyId,
      profile:"default",eventTypes:approvalEnabled ? ["session.completed","session.failed","approval.required"] : ["session.completed","session.failed"],expiresAt:NOW+1800});
    const create = await handleLoopdyLinkRequest(await signedRequest(keys.privateKey,deviceId,root,"POST",body,71001),targetEnv);
    expect(create.status).toBe(201);
    const {grant} = await create.json<{grant:{grantId:string;revision:number;state:string}}>();
    const duplicate = await handleLoopdyLinkRequest(await signedRequest(keys.privateKey,deviceId,root,"POST",body,71002),targetEnv);
    expect((await duplicate.json<{grant:{grantId:string}}>()).grant.grantId).toBe(grant.grantId);
    async function hostRequest(suffix: string, payload: object) {
      const path=root+"/"+grant.grantId+suffix;
      const raw=JSON.stringify(payload);
      const nonce=base64url(crypto.getRandomValues(new Uint8Array(32)));
      const hash=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(raw))),b=>b.toString(16).padStart(2,"0")).join("");
      const transcript=["loopdy-notification-host-v1","POST",path,grant.grantId,String(NOW),nonce,hash].join("\n");
      const signature=base64url(new Uint8Array(await crypto.subtle.sign({name:"ECDSA",hash:"SHA-256"},host.privateKey,new TextEncoder().encode(transcript))));
      return new Request("https://link.loopdy.example"+path,{method:"POST",body:raw,headers:{"content-type":"application/json",
        "x-loopdy-host-key-id":hostKeyId,"x-loopdy-timestamp":String(NOW),"x-loopdy-nonce":nonce,"x-loopdy-signature":signature}});
    }
    const claim=await hostRequest("/claim",{version:2,idempotencyKey:crypto.randomUUID()});
    const replay=claim.clone();
    expect((await handleLoopdyLinkRequest(claim,targetEnv)).status).toBe(200);
    expect((await handleLoopdyLinkRequest(replay,targetEnv)).status).toBe(409);
    const avatarBytes = new Uint8Array([1,2,3]);
    const avatarHash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",avatarBytes)),b=>b.toString(16).padStart(2,"0")).join("");
    const event={version:2,eventId:grant.grantId+":"+"a".repeat(64),eventType:"session.completed",sessionReference:"a".repeat(43),
      turnId:"turn-fixture",occurredAt:NOW,agent:{id:"default",name:"Fixture Agent",avatar:{mimeType:"image/png",sha256:avatarHash,data:"data:image/png;base64,AQID"}},
      content:{kind:"reply",text:"Actual fixture reply"},sound:false};
    // Real signatures/grants and Worker storage; only vendor transport is mocked.
    expect((await handleLoopdyLinkRequest(await hostRequest("/events",event),targetEnv)).status).toBe(202);
    expect(sends).toHaveLength(1);
    const approval = {...event, eventId:grant.grantId+":"+"b".repeat(64), eventType:"approval.required",content:{kind:"approval",text:"Run this fixture?"}};
    expect((await handleLoopdyLinkRequest(await hostRequest("/events",approval),targetEnv)).status).toBe(approvalEnabled ? 202 : 400);
    for (const invalid of [
      {...event, eventType:"clarification.required"},
      {...event, eventId:grant.grantId+":invalid"},
      {...event, eventId:grant.grantId+":"+"A".repeat(64)},
      {...event, eventId:crypto.randomUUID()+":"+"a".repeat(64)},
    ]) expect((await handleLoopdyLinkRequest(await hostRequest("/events",invalid),targetEnv)).status).toBe(400);
    const expectedSends = approvalEnabled ? 2 : 1;
    const saved = await env.ACCOUNTS.prepare("SELECT public_json FROM notification_grants WHERE grant_id=?").bind(grant.grantId).first<{public_json:string}>();
    expect(JSON.parse(saved!.public_json).eventTypes).toEqual(JSON.parse(body).eventTypes);
    const wrong=await hostRequest("/events",event);
    wrong.headers.set("x-loopdy-host-key-id","b".repeat(43));
    expect((await handleLoopdyLinkRequest(wrong,targetEnv)).status).toBe(401);
    expect(sends).toHaveLength(expectedSends);
    const stalePermission = await signedRequest(keys.privateKey,deviceId,`/v1/devices/${deviceId}/push`,"PUT",JSON.stringify({revision:1,state:"denied"}),71004);
    expect((await handleLoopdyLinkRequest(stalePermission,targetEnv)).status).toBe(404);
    expect((await env.ACCOUNTS.prepare("SELECT state FROM notification_grants WHERE grant_id=?").bind(grant.grantId).first<{state:string}>())?.state).toBe("active");
    const removal=await signedRequest(keys.privateKey,deviceId,root+"/"+grant.grantId,"DELETE",JSON.stringify({version:2,expectedRevision:1}),71003);
    expect((await handleLoopdyLinkRequest(removal,targetEnv)).status).toBe(200);
    expect((await env.ACCOUNTS.prepare("SELECT state FROM notification_grants WHERE grant_id=?").bind(grant.grantId).first<{state:string}>())?.state).toBe("revoked");
    expect((await handleLoopdyLinkRequest(await hostRequest("/events",event),targetEnv)).status).toBe(403);
    expect(sends).toHaveLength(expectedSends);
  });

  it("does not publish directory credentials when recipient enrollment is refused", async () => {
    const keys = await generateDeviceKeys();
    const targetEnv = { ...env, USER_LINKS: { getByName: () => ({ registerDevice: async () => {
      throw new LoopdyLinkError("device_limit", "Device limit reached");
    } }) } } as unknown as LinkEnv;
    const response = await handleLoopdyLinkRequest(new Request("https://link.loopdy.example/v1/devices", {
      method: "POST", headers: { authorization: `Bearer ${ACCESS_TOKEN}`, "content-type": "application/json" },
      body: JSON.stringify({ deviceId: "device-refused-fixture", publicKeySPKI: keys.publicKeySPKI,
        role: "mobile", kind: "phone", encryptedName: "encrypted-refused-fixture", revision: 1 }),
    }), targetEnv);
    expect(response.ok).toBe(false);
    expect(await env.ACCOUNTS.prepare("SELECT device_id FROM device_directory WHERE device_id = ?")
      .bind("device-refused-fixture").first()).toBeNull();
  });

  it("does not expose marketplace catalog, publishing, or install routes", async () => {
    for (const path of [
      "/v1/marketplace/items",
      "/v1/marketplace/drafts",
      "/v1/marketplace/install-approvals/removed/redeem",
      "/.well-known/skills/marketplace/removed/versions/1/index.json",
    ]) {
      const response = await handleLoopdyLinkRequest(
        new Request(`https://link.loopdy.example${path}`),
        env,
      );
      expect(response.status, path).toBe(404);
    }
  });

  it("fences the account while retired Marketplace cleanup is unavailable", async () => {
    const account = "account-marketplace-retirement-fixture";
    const accessToken = "marketplace-retirement-access-token-with-enough-entropy";
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(account, NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(await sha256Base64URL(accessToken), account, NOW, NOW + 900),
    ]);
    await env.MARKETPLACE_RETIREMENT.prepare(
      "CREATE TABLE reports (owner_account_id TEXT NOT NULL)",
    ).run();
    await env.MARKETPLACE_RETIREMENT.prepare(
      "INSERT INTO reports (owner_account_id) VALUES (?)",
    ).bind(account).run();

    const response = await handleLoopdyLinkRequest(
      new Request("https://link.loopdy.example/v1/accounts/current", {
        method: "DELETE",
        headers: { authorization: `Bearer ${accessToken}` },
      }),
      env,
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      version: 1,
      error: "marketplace_cleanup_unavailable",
      message: "Retired Marketplace data cleanup is not acknowledged. Try account deletion again.",
    });
    expect(await env.ACCOUNTS.prepare(
      "SELECT status, authorization_epoch FROM accounts WHERE account_coordinate = ?",
    ).bind(account).first()).toEqual({ status: "revoked", authorization_epoch: 2 });
    await env.MARKETPLACE_RETIREMENT.prepare("DROP TABLE reports").run();
  });

  it("atomically fences every account authority while BuzzKit cleanup is held", async () => {
    const account = "account-buzzkit-deletion-failure-fixture";
    const accessToken = "buzzkit-deletion-failure-access-token-with-enough-entropy";
    const secondAccessToken = "buzzkit-deletion-second-session-with-enough-entropy";
    const passkeyID = "buzzkit-deletion-passkey-fixture";
    const deviceID = "buzzkit-deletion-device-fixture";
    const keys = await generateDeviceKeys();
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(account, NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(await sha256Base64URL(accessToken), account, NOW, NOW + 900),
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(await sha256Base64URL(secondAccessToken), account, NOW, NOW + 900),
      env.ACCOUNTS.prepare(
        `INSERT INTO passkeys (
           credential_id, account_coordinate, webauthn_user_id, public_key, counter,
           device_type, backed_up, created_at
         ) VALUES (?, ?, ?, ?, 0, 'multiDevice', 1, ?)`,
      ).bind(passkeyID, account, "deletion-webauthn-user", new Uint8Array([1, 2, 3]), NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO auth_challenges (flow_id, kind, challenge, expires_at)
         VALUES ('deletion-auth-flow-fixture', 'authentication', 'challenge-fixture', ?)`,
      ).bind(NOW + 300),
      env.ACCOUNTS.prepare(
        `INSERT INTO device_directory (
           device_id, account_coordinate, public_key_spki, status,
           authorization_epoch, created_at
         ) VALUES (?, ?, ?, 'active', 1, ?)`,
      ).bind(deviceID, account, keys.publicKeySPKI, NOW),
    ]);
    const providerCalls: string[] = [];
    let releaseProvider!: () => void;
    const providerHeld = new Promise<void>((resolve) => { releaseProvider = resolve; });
    let providerEntered!: () => void;
    const providerStarted = new Promise<void>((resolve) => { providerEntered = resolve; });
    vi.spyOn(globalThis, "fetch").mockImplementation(async (url, init) => {
      providerCalls.push(`${init?.method ?? "GET"} ${new URL(String(url)).pathname}`);
      if (init?.method === "DELETE") {
        providerEntered();
        await providerHeld;
        return Response.json({ success: true, data: {} });
      }
      return Response.json({
        success: true,
        data: { externalId: new URL(String(url)).pathname.split("/").at(-1), verified: true },
      });
    });

    const responsePromise = handleLoopdyLinkRequest(
      new Request("https://link.loopdy.example/v1/accounts/current", {
        method: "DELETE",
        headers: { authorization: `Bearer ${accessToken}` },
      }),
      {
        ...env,
        BUZZKIT_API_KEY: `bk_tn_${crypto.randomUUID()}`,
        BUZZKIT_IDENTITY_SECRET: crypto.randomUUID(),
        BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
      } as LinkEnv,
    );
    await providerStarted;
    try {
      expect(await env.ACCOUNTS.prepare(
        "SELECT status, authorization_epoch, revoked_at FROM accounts WHERE account_coordinate=?",
      ).bind(account).first()).toEqual({
        status: "revoked", authorization_epoch: 2, revoked_at: expect.any(Number),
      });
      const acceptanceMarkers = await env.ACCOUNTS.prepare(
        "SELECT token_hash FROM account_deletion_receipts",
      ).all<{ token_hash: string }>();
      expect(acceptanceMarkers.results).toHaveLength(1);
      expect(acceptanceMarkers.results[0]?.token_hash).not.toBe(await sha256Base64URL(accessToken));
      const secondSession = await handleLoopdyLinkRequest(
        new Request("https://link.loopdy.example/v1/accounts/key-envelope", {
          headers: { authorization: `Bearer ${secondAccessToken}` },
        }),
        env,
      );
      expect(secondSession.status).toBe(401);
      expect(await secondSession.json()).toEqual(expect.objectContaining({ error: "session_expired" }));
      const signedDeviceRequest = await signedRequest(
        keys.privateKey, deviceID, "/v1/devices", "GET", "", 71_001,
      );
      const deviceRequest = await handleLoopdyLinkRequest(signedDeviceRequest, env);
      expect(deviceRequest.status).toBe(403);
      expect(await deviceRequest.json()).toEqual(expect.objectContaining({ error: "device_revoked" }));
      let passkeyVerifierCalls = 0;
      await expect(completeAccountAuthentication(
        env.ACCOUNTS,
        {
          rpName: "Loopdy", rpID: "link.loopdy.example",
          expectedOrigin: "https://link.loopdy.example",
          challengeTTLSeconds: 300, sessionTTLSeconds: 900,
        },
        { flowId: "deletion-auth-flow-fixture", response: { id: passkeyID } },
        NOW,
        async () => {
          passkeyVerifierCalls += 1;
          return { verified: true, newCounter: 1 };
        },
      )).rejects.toMatchObject({ code: "passkey_unknown" });
      expect(passkeyVerifierCalls).toBe(0);
    } finally {
      releaseProvider();
    }
    const response = await responsePromise;

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      version: 1,
      error: "notification_cleanup_unavailable",
      message: "Notification provider cleanup was not confirmed. Try account deletion again.",
    });
    expect(providerCalls.map((call) => call.split(" ")[0])).toEqual(["DELETE", "GET"]);
    expect(providerCalls.every((call) => call.includes("/v1/subscribers/acct_"))).toBe(true);
    expect(await env.ACCOUNTS.prepare(
      "SELECT status FROM accounts WHERE account_coordinate=?",
    ).bind(account).first()).toEqual({ status: "revoked" });
    expect(await env.ACCOUNTS.prepare(
      "SELECT account_coordinate FROM notification_account_scope_retirements WHERE account_coordinate=?",
    ).bind(account).first()).not.toBeNull();
  });

  it("rejects passkey completion when deletion is accepted during verification", async () => {
    const account = "account-passkey-deletion-race-fixture";
    const accessToken = "passkey-deletion-race-access-token-with-enough-entropy";
    const credentialID = "passkey-deletion-race-credential";
    const flowID = "passkey-deletion-race-flow-fixture";
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(account, NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(await sha256Base64URL(accessToken), account, NOW, NOW + 900),
      env.ACCOUNTS.prepare(
        `INSERT INTO passkeys (
           credential_id, account_coordinate, webauthn_user_id, public_key, counter,
           device_type, backed_up, created_at
         ) VALUES (?, ?, ?, ?, 0, 'multiDevice', 1, ?)`,
      ).bind(credentialID, account, "passkey-deletion-race-user", new Uint8Array([1, 2, 3]), NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO auth_challenges (flow_id, kind, challenge, expires_at)
         VALUES (?, 'authentication', 'passkey-deletion-race-challenge', ?)`,
      ).bind(flowID, NOW + 300),
    ]);

    let verificationEntered!: () => void;
    const verificationStarted = new Promise<void>((resolve) => { verificationEntered = resolve; });
    let releaseVerification!: () => void;
    const verificationHeld = new Promise<void>((resolve) => { releaseVerification = resolve; });
    const authenticationPromise = completeAccountAuthentication(
      env.ACCOUNTS,
      {
        rpName: "Loopdy", rpID: "link.loopdy.example",
        expectedOrigin: "https://link.loopdy.example",
        challengeTTLSeconds: 300, sessionTTLSeconds: 900,
      },
      { flowId: flowID, response: { id: credentialID } },
      NOW,
      async () => {
        verificationEntered();
        await verificationHeld;
        return { verified: true, newCounter: 1 };
      },
    );
    await verificationStarted;

    let providerEntered!: () => void;
    const providerStarted = new Promise<void>((resolve) => { providerEntered = resolve; });
    let releaseProvider!: () => void;
    const providerHeld = new Promise<void>((resolve) => { releaseProvider = resolve; });
    vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
      if (init?.method === "DELETE") {
        providerEntered();
        await providerHeld;
        return Response.json({ success: true, data: {} });
      }
      return Response.json({ success: false, error: { code: "not_found" } }, { status: 404 });
    });
    const deletionPromise = handleLoopdyLinkRequest(
      new Request("https://link.loopdy.example/v1/accounts/current", {
        method: "DELETE",
        headers: { authorization: `Bearer ${accessToken}` },
      }),
      {
        ...env,
        BUZZKIT_API_KEY: `bk_tn_${crypto.randomUUID()}`,
        BUZZKIT_IDENTITY_SECRET: crypto.randomUUID(),
        BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
      } as LinkEnv,
    );
    await providerStarted;

    try {
      releaseVerification();
      await expect(authenticationPromise).rejects.toMatchObject({ code: "passkey_unknown" });
      expect((await env.ACCOUNTS.prepare(
        "SELECT COUNT(*) AS count FROM access_sessions WHERE account_coordinate = ?",
      ).bind(account).first<{ count: number }>())?.count).toBe(1);
      expect(await env.ACCOUNTS.prepare(
        "SELECT consumed_at FROM auth_challenges WHERE flow_id = ?",
      ).bind(flowID).first()).toEqual({ consumed_at: null });
    } finally {
      releaseProvider();
    }
    expect((await deletionPromise).status).toBe(200);
  });

  it("exposes payload-free delivery diagnostics only for the signed device account", async () => {
    const keys = await generateDeviceKeys();
    const diagnosticAccount = "account-diagnostics-isolated";
    const diagnosticToken = "diagnostics-access-token-fixture-0001";
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)").bind(diagnosticAccount, NOW),
      env.ACCOUNTS.prepare("INSERT INTO access_sessions (token_hash, account_coordinate, authorization_epoch, created_at, expires_at) VALUES (?, ?, 1, ?, ?)").bind(await sha256Base64URL(diagnosticToken), diagnosticAccount, NOW, NOW + 900),
    ]);
    await fetchWorker("/v1/devices", {
      method: "POST",
      headers: { authorization: `Bearer ${diagnosticToken}`, "content-type": "application/json" },
      body: JSON.stringify({ deviceId: "device-diagnostics", publicKeySPKI: keys.publicKeySPKI,
        role: "mobile", kind: "phone", encryptedName: "private-name-sentinel", revision: 1 }),
    });
    const stub = env.USER_LINKS.getByName(diagnosticAccount);
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      state.storage.sql.exec(`INSERT INTO pending_frames
        (recipient_device_id, sender_device_id, frame_id, sequence, encoded_frame, created_at)
        VALUES ('device-diagnostics', 'host-fixture', 'diagnostic-frame-fixture', 1, 'private-ciphertext', 1)`);
    });
    const response = await signedFetch(keys.privateKey, "/v1/delivery/diagnostics", "GET", "", 900, "device-diagnostics");
    expect(response.status).toBe(200);
    const value = await response.json<Record<string, any>>();
    expect(value.delivery.retainedFrames).toBeGreaterThanOrEqual(1);
    expect(value.delivery.recipients).toContainEqual(expect.objectContaining({
      deviceId: "device-diagnostics", pendingFrames: 1, pendingBytes: 18,
    }));
    expect(JSON.stringify(value)).not.toContain("private-ciphertext");
    expect(JSON.stringify(value)).not.toContain("private-name-sentinel");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect((await fetchWorker("/v1/delivery/diagnostics")).status).toBe(401);
    const after = await signedFetch(keys.privateKey, "/v1/delivery/diagnostics", "GET", "", 901, "device-diagnostics");
    expect(await after.json()).toEqual(value);
  });

  it("serves the exact Associated Domains document required by Loopdy passkeys", async () => {
    const response = await fetchWorker("/.well-known/apple-app-site-association");

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(await response.json()).toEqual({
      webcredentials: { apps: ["ZWDGY4GYX9.app.loopdy.mobile"] },
    });
  });

  it("serves passkey options without exposing an account routing coordinate", async () => {
    const response = await fetchWorker("/v1/accounts/registration/options", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json<Record<string, unknown>>();
    expect(body.version).toBe(1);
    expect(body.flowId).toEqual(expect.any(String));
    expect(body.options).toEqual(expect.objectContaining({ challenge: expect.any(String) }));
    expect(JSON.stringify(body)).not.toContain("accountCoordinate");
  });

  it("stores one opaque account-key envelope and returns it only to a passkey session", async () => {
    const envelope = "opaque-account-key-envelope-value-0123456789";
    const stored = await fetchWorker("/v1/accounts/key-envelope", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${ACCESS_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ envelope }),
    });

    expect(stored.status).toBe(200);
    expect(await stored.json()).toEqual({ version: 1, state: "ready" });

    const loaded = await fetchWorker("/v1/accounts/key-envelope", {
      headers: { authorization: `Bearer ${ACCESS_TOKEN}` },
    });
    expect(loaded.status).toBe(200);
    expect(await loaded.json()).toEqual({ version: 1, envelope });

    const conflicting = await fetchWorker("/v1/accounts/key-envelope", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${ACCESS_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ envelope: "different-opaque-envelope-value-0123456789" }),
    });
    expect(conflicting.status).toBe(409);

    const unauthenticated = await fetchWorker("/v1/accounts/key-envelope");
    expect(unauthenticated.status).toBe(401);
  });

  it("stores and loads the account profile avatar through signed account routing", async () => {
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(PROFILE_ACCOUNT, NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(
        await sha256Base64URL(PROFILE_ACCESS_TOKEN),
        PROFILE_ACCOUNT,
        NOW,
        NOW + 900,
      ),
    ]);
    const keys = await generateDeviceKeys();
    await fetchWorker("/v1/devices", {
      method: "POST",
      headers: {
        authorization: `Bearer ${PROFILE_ACCESS_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceId: "device-profile-avatar",
        publicKeySPKI: keys.publicKeySPKI,
        role: "mobile",
        kind: "phone",
        encryptedName: "ciphertext-device-name",
        revision: 1,
      }),
    });
    const profile = {
      expectedRevision: 0,
      encryptedDisplayName: "encrypted-display-name-0001",
      avatar: {
        mimeType: "image/png",
        byteCount: 60_000,
        sha256: "sha256-profile-avatar-0001",
        encryptedData: "e".repeat(70_000),
      },
      updatedAt: NOW + 1,
    };
    const body = JSON.stringify(profile);
    expect(body.length).toBeGreaterThan(65_536);

    const saved = await signedFetch(
      keys.privateKey,
      "/v1/accounts/profile",
      "PUT",
      body,
      1,
      "device-profile-avatar",
    );
    expect(saved.status).toBe(200);
    expect(await saved.json()).toEqual({
      version: 1,
      profile: {
        revision: 1,
        encryptedDisplayName: profile.encryptedDisplayName,
        avatar: profile.avatar,
        updatedAt: profile.updatedAt,
      },
    });

    const loaded = await signedFetch(
      keys.privateKey,
      "/v1/accounts/profile",
      "GET",
      "",
      2,
      "device-profile-avatar",
    );
    expect(loaded.status).toBe(200);
    expect(await loaded.json()).toEqual({
      version: 1,
      profile: {
        revision: 1,
        encryptedDisplayName: profile.encryptedDisplayName,
        avatar: profile.avatar,
        updatedAt: profile.updatedAt,
      },
    });
  });

  it("rejects account profile bodies above the profile route limit", async () => {
    const response = await fetchWorker("/v1/accounts/profile", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: "x".repeat(3_000_001),
    });

    expect(response.status).toBe(413);
    expect(await response.json()).toEqual({
      version: 1,
      error: "body_too_large",
      message: "Request body is too large",
    });
  });

  it("deletes the passkey-authorized account and its per-user relay state", async () => {
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(DELETE_ACCOUNT, NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO auth_challenges (
           flow_id, kind, account_coordinate, webauthn_user_id, challenge, expires_at
         ) VALUES (?, 'registration', ?, ?, ?, ?)`,
      ).bind(
        "registration-delete-fixture",
        DELETE_ACCOUNT,
        "webauthn-delete-fixture",
        "challenge-delete-fixture",
        NOW + 600,
      ),
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(await sha256Base64URL(DELETE_ACCESS_TOKEN), DELETE_ACCOUNT, NOW, NOW + 900),
    ]);
    const stub = env.USER_LINKS.getByName(DELETE_ACCOUNT);
    await stub.registerDevice({
      deviceId: "mobile-delete-fixture",
      publicKey: "mobile-public-key-fixture",
      role: "mobile",
      kind: "phone",
      encryptedName: "encrypted-mobile-name-fixture",
      revision: 1,
      createdAt: NOW,
    });
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      state.storage.sql.exec("UPDATE devices SET push_state='ready',push_revision=1 WHERE device_id=?", "mobile-delete-fixture");
      state.storage.sql.exec("CREATE TABLE IF NOT EXISTS live_activities (activity_id TEXT PRIMARY KEY, device_id TEXT, session_reference TEXT, status TEXT, revision INTEGER, lease_expires INTEGER, created_at INTEGER, updated_at INTEGER)");
      state.storage.sql.exec(
        `INSERT INTO live_activities (
           activity_id, device_id, session_reference, status,
           revision, lease_expires, created_at, updated_at
         ) VALUES (?, ?, ?, 'active', 1, ?, ?, ?)`,
        "legacy/account-activity",
        "mobile-delete-fixture",
        "S".repeat(43),
        NOW + 600,
        NOW,
        NOW,
      );
    });
    await env.ACCOUNTS.prepare(
      `INSERT INTO device_directory (
         device_id, account_coordinate, public_key_spki, status,
         authorization_epoch, created_at
       ) VALUES (?, ?, ?, 'active', 1, ?)`,
    )
      .bind("mobile-delete-fixture", DELETE_ACCOUNT, "mobile-public-key-fixture", NOW)
      .run();
    const revokeDevice = vi.fn(async (input) => ({ status: "revoked" as const, ...input }));
    const revokeLiveActivity = vi.fn(async (input) => ({
      status: "revoked" as const,
      activityId: input.activityId,
      revision: input.revision,
    }));

    const response = await handleLoopdyLinkRequest(
      new Request("https://link.loopdy.example/v1/accounts/current", {
        method: "DELETE",
        headers: { authorization: `Bearer ${DELETE_ACCESS_TOKEN}` },
      }),
      accountDeletionEnvironment({
        APNS_ENROLLMENT: { revokeDevice, revokeLiveActivity },
      } as unknown as Partial<LinkEnv>),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ version: 1, state: "deleted" });
    expect(revokeDevice).not.toHaveBeenCalled();
    expect(revokeLiveActivity).not.toHaveBeenCalled();
    expect(
      await env.ACCOUNTS.prepare(
        "SELECT account_coordinate FROM accounts WHERE account_coordinate = ?",
      )
        .bind(DELETE_ACCOUNT)
        .first(),
    ).toBeNull();
    expect(await env.ACCOUNTS.prepare(
      "SELECT account_coordinate FROM notification_account_scope_retirements WHERE account_coordinate=?",
    ).bind(DELETE_ACCOUNT).first()).toBeNull();
    expect(
      await env.ACCOUNTS.prepare(
        "SELECT device_id FROM device_directory WHERE account_coordinate = ?",
      )
        .bind(DELETE_ACCOUNT)
        .first(),
    ).toBeNull();
    expect(
      await env.ACCOUNTS.prepare(
        "SELECT flow_id FROM auth_challenges WHERE account_coordinate = ?",
      )
        .bind(DELETE_ACCOUNT)
        .first(),
    ).toBeNull();
  });

  it("returns the deleted result for a retry after the deletion response is lost", async () => {
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(RETRY_DELETE_ACCOUNT, NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(
        await sha256Base64URL(RETRY_DELETE_ACCESS_TOKEN),
        RETRY_DELETE_ACCOUNT,
        NOW,
        NOW + 900,
      ),
    ]);

    const deletionRequest = () =>
      new Request("https://link.loopdy.example/v1/accounts/current", {
        method: "DELETE",
        headers: { authorization: `Bearer ${RETRY_DELETE_ACCESS_TOKEN}` },
      });

    const first = await handleLoopdyLinkRequest(deletionRequest(), accountDeletionEnvironment());
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({ version: 1, state: "deleted" });

    const retry = await handleLoopdyLinkRequest(deletionRequest(), env);
    expect(retry.status).toBe(200);
    expect(await retry.json()).toEqual({ version: 1, state: "deleted" });

    const receiptColumns = await env.ACCOUNTS.prepare(
      "PRAGMA table_info(account_deletion_receipts)",
    ).all<{ name: string }>();
    expect(receiptColumns.results.map(({ name }) => name)).toEqual(["token_hash", "expires_at"]);
    const receipt = await env.ACCOUNTS.prepare(
      "SELECT token_hash, expires_at FROM account_deletion_receipts",
    ).first<{ token_hash: string; expires_at: number }>();
    expect(receipt?.token_hash).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(receipt?.token_hash).not.toBe(RETRY_DELETE_ACCESS_TOKEN);
    expect(receipt?.expires_at).toBeGreaterThan(NOW);
    expect(JSON.stringify(receipt)).not.toContain(RETRY_DELETE_ACCOUNT);
  });

  it("retries the final account Durable Object purge from the deletion receipt", async () => {
    const account = "account-delete-final-purge-retry-fixture";
    const accessToken = "delete-final-purge-retry-access-token-with-enough-entropy";
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(account, NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(await sha256Base64URL(accessToken), account, NOW, NOW + 900),
    ]);
    const deleteAccountData = vi.fn()
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error("final purge unavailable"))
      .mockRejectedValueOnce(new Error("final purge still unavailable"))
      .mockResolvedValueOnce(undefined);
    const deletionCoordinates: string[] = [];
    const getByName = vi.fn((coordinate: string) => {
      deletionCoordinates.push(coordinate);
      return {
        beginAccountDeletion: async () => {},
        deleteAccountData,
        retireNotificationScope: async () => {},
      };
    });
    const targetEnv = {
      ...accountDeletionEnvironment(),
      USER_LINKS: { getByName },
    } as unknown as LinkEnv;
    const deletionRequest = () =>
      new Request("https://link.loopdy.example/v1/accounts/current", {
        method: "DELETE",
        headers: { authorization: `Bearer ${accessToken}` },
      });

    const first = await handleLoopdyLinkRequest(deletionRequest(), targetEnv);
    expect(first.status).toBe(500);
    expect(await env.ACCOUNTS.prepare(
      "SELECT account_coordinate FROM accounts WHERE account_coordinate = ?",
    ).bind(account).first()).toBeNull();
    const pendingReceipts = await env.ACCOUNTS.prepare(
      "SELECT token_hash FROM account_deletion_receipts ORDER BY token_hash",
    ).all<{ token_hash: string }>();
    expect(pendingReceipts.results).toHaveLength(3);
    expect(JSON.stringify(pendingReceipts.results)).not.toContain(account);
    expect(JSON.stringify(pendingReceipts.results)).not.toContain(accessToken);

    const failedRetry = await handleLoopdyLinkRequest(deletionRequest(), targetEnv);
    expect(failedRetry.status).toBe(500);
    expect(await failedRetry.json()).toEqual({
      version: 1,
      error: "internal_error",
      message: "Loopdy Link request failed",
    });
    expect((await env.ACCOUNTS.prepare(
      "SELECT token_hash FROM account_deletion_receipts",
    ).all()).results).toHaveLength(3);

    await env.ACCOUNTS.prepare(
      "UPDATE account_deletion_receipts SET expires_at = ?",
    ).bind(NOW - 1).run();

    const successfulRetry = await handleLoopdyLinkRequest(deletionRequest(), targetEnv);
    expect(successfulRetry.status).toBe(200);
    expect(await successfulRetry.json()).toEqual({ version: 1, state: "deleted" });
    expect(deleteAccountData).toHaveBeenCalledTimes(4);
    expect(deletionCoordinates).toEqual([account, account, account, account, account]);
    const completedReceipts = await env.ACCOUNTS.prepare(
      "SELECT token_hash FROM account_deletion_receipts",
    ).all<{ token_hash: string }>();
    expect(completedReceipts.results).toEqual([
      { token_hash: await sha256Base64URL(accessToken) },
    ]);

    const acknowledgedRetry = await handleLoopdyLinkRequest(deletionRequest(), targetEnv);
    expect(acknowledgedRetry.status).toBe(200);
    expect(await acknowledgedRetry.json()).toEqual({ version: 1, state: "deleted" });
    expect(deleteAccountData).toHaveBeenCalledTimes(4);
    expect(globalThis.fetch).toHaveBeenCalledTimes(2);
  });

  it("finishes accepted deletion from its pending marker after the bearer expires", async () => {
    const account = "account-delete-pending-marker-fixture";
    const accessToken = "delete-pending-marker-access-token-with-enough-entropy";
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(account, NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(await sha256Base64URL(accessToken), account, NOW, NOW + 900),
    ]);
    const deleteAccountData = vi.fn()
      // The cleanup-complete marker is durable before the first account purge.
      .mockRejectedValueOnce(new Error("server stopped after pending marker"))
      .mockResolvedValue(undefined);
    const targetEnv = {
      ...accountDeletionEnvironment(),
      USER_LINKS: { getByName: () => ({
        beginAccountDeletion: async () => {},
        deleteAccountData,
        retireNotificationScope: async () => {},
      }) },
    } as unknown as LinkEnv;
    const deletionRequest = () =>
      new Request("https://link.loopdy.example/v1/accounts/current", {
        method: "DELETE",
        headers: { authorization: `Bearer ${accessToken}` },
      });

    const interrupted = await handleLoopdyLinkRequest(deletionRequest(), targetEnv);
    expect(interrupted.status).toBe(500);
    const pending = await env.ACCOUNTS.prepare(
      "SELECT token_hash FROM account_deletion_receipts",
    ).all<{ token_hash: string }>();
    const tokenHash = await sha256Base64URL(accessToken);
    expect(pending.results).toHaveLength(2);
    expect(pending.results.every(({ token_hash }) => token_hash !== tokenHash)).toBe(true);
    await env.ACCOUNTS.prepare(
      "UPDATE access_sessions SET expires_at = ? WHERE token_hash = ?",
    ).bind(NOW - 1, tokenHash).run();

    const resumed = await handleLoopdyLinkRequest(deletionRequest(), targetEnv);

    expect(resumed.status).toBe(200);
    expect(await resumed.json()).toEqual({ version: 1, state: "deleted" });
    expect(deleteAccountData).toHaveBeenCalledTimes(3);
    expect((await env.ACCOUNTS.prepare(
      "SELECT account_coordinate FROM accounts WHERE account_coordinate = ?",
    ).bind(account).first())).toBeNull();
    expect((await env.ACCOUNTS.prepare(
      "SELECT token_hash FROM account_deletion_receipts ORDER BY token_hash",
    ).all<{ token_hash: string }>()).results).toEqual([
      { token_hash: await sha256Base64URL(accessToken) },
    ]);
    expect(globalThis.fetch).toHaveBeenCalledTimes(2);
  });

  it("keeps pre-cleanup deletion authority durable past bearer expiry", async () => {
    const account = "account-delete-accepted-marker-fixture";
    const accessToken = "delete-accepted-marker-access-token-with-enough-entropy";
    const tokenHash = await sha256Base64URL(accessToken);
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(account, NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(tokenHash, account, NOW, NOW + 900),
    ]);
    const providerMethods: string[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
      const method = init?.method ?? "GET";
      providerMethods.push(method);
      if (providerMethods.length === 1) {
        return Response.json({ success: false, error: { code: "unavailable" } }, { status: 503 });
      }
      if (method === "DELETE") return Response.json({ success: true, data: {} });
      return Response.json({ success: false, error: { code: "not_found" } }, { status: 404 });
    });
    const targetEnv = {
      ...env,
      BUZZKIT_API_KEY: `bk_tn_${crypto.randomUUID()}`,
      BUZZKIT_IDENTITY_SECRET: crypto.randomUUID(),
      BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
    } as LinkEnv;
    const deletionRequest = () =>
      new Request("https://link.loopdy.example/v1/accounts/current", {
        method: "DELETE",
        headers: { authorization: `Bearer ${accessToken}` },
      });

    const cleanupFailed = await handleLoopdyLinkRequest(deletionRequest(), targetEnv);
    expect(cleanupFailed.status).toBe(503);
    const acceptedMarkers = await env.ACCOUNTS.prepare(
      "SELECT token_hash FROM account_deletion_receipts",
    ).all<{ token_hash: string }>();
    expect(acceptedMarkers.results).toHaveLength(1);
    expect(acceptedMarkers.results[0]?.token_hash).not.toBe(tokenHash);
    await env.ACCOUNTS.prepare(
      "UPDATE access_sessions SET expires_at = ? WHERE token_hash = ?",
    ).bind(NOW - 1, tokenHash).run();

    const resumed = await handleLoopdyLinkRequest(deletionRequest(), targetEnv);

    expect(resumed.status).toBe(200);
    expect(await resumed.json()).toEqual({ version: 1, state: "deleted" });
    expect(providerMethods).toEqual(["DELETE", "DELETE", "GET"]);
    expect((await env.ACCOUNTS.prepare(
      "SELECT account_coordinate FROM accounts WHERE account_coordinate = ?",
    ).bind(account).first())).toBeNull();
    expect((await env.ACCOUNTS.prepare(
      "SELECT token_hash FROM account_deletion_receipts",
    ).all<{ token_hash: string }>()).results).toEqual([{ token_hash: tokenHash }]);
  });

  it("does not authorize an unrelated bearer token after account deletion", async () => {
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(SECURITY_DELETE_ACCOUNT, NOW),
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(
        await sha256Base64URL(SECURITY_DELETE_ACCESS_TOKEN),
        SECURITY_DELETE_ACCOUNT,
        NOW,
        NOW + 900,
      ),
    ]);

    const first = await handleLoopdyLinkRequest(
      new Request("https://link.loopdy.example/v1/accounts/current", {
        method: "DELETE",
        headers: { authorization: `Bearer ${SECURITY_DELETE_ACCESS_TOKEN}` },
      }),
      accountDeletionEnvironment(),
    );
    expect(first.status).toBe(200);

    const unrelated = await handleLoopdyLinkRequest(
      new Request("https://link.loopdy.example/v1/accounts/current", {
        method: "DELETE",
        headers: { authorization: "Bearer unrelated-access-token-with-enough-entropy-0001" },
      }),
      env,
    );
    expect(unrelated.status).toBe(401);
    expect(await unrelated.json()).toEqual({
      version: 1,
      error: "account_deletion_not_accepted",
      message: "Account deletion was not accepted",
    });
  });

  it("rejects non-HTTPS and oversized JSON before account work", async () => {
    const insecure = await worker.fetch(
      new Request("http://link.loopdy.example/v1/accounts/registration/options", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      }),
      env,
    );
    expect(insecure.status).toBe(400);

    const oversized = await fetchWorker("/v1/accounts/registration/options", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ padding: "x".repeat(65_537) }),
    });
    expect(oversized.status).toBe(413);
  });

  it("routes the exact authenticated websocket Request to the account Durable Object", async () => {
    const keys = await generateDeviceKeys();
    await env.ACCOUNTS.prepare(
      "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
    )
      .bind(SOCKET_FORWARD_ACCOUNT, NOW)
      .run();
    await env.ACCOUNTS.prepare(
      `INSERT INTO device_directory (
         device_id, account_coordinate, public_key_spki, status,
         authorization_epoch, created_at
       ) VALUES (?, ?, ?, 'active', 1, ?)`,
    )
      .bind("device-socket-forward", SOCKET_FORWARD_ACCOUNT, keys.publicKeySPKI, NOW)
      .run();
    const request = await signedRequest(
      keys.privateKey,
      "device-socket-forward",
      "/v1/socket",
      "GET",
      "",
      7,
    );
    request.headers.set("Upgrade", "websocket");
    request.headers.set("Sec-WebSocket-Key", "c2VjdXJlLWZpeHR1cmUta2V5LTAxMjM0NTY3ODkw");
    request.headers.set("Sec-WebSocket-Version", "13");

    let forwarded: Request | undefined;
    const getByName = vi.fn(() => ({
      fetch: vi.fn(async (candidate: Request) => {
        forwarded = candidate;
        return new Response(null, { status: 204 });
      }),
    }));
    const response = await handleLoopdyLinkRequest(request, {
      ...env,
      USER_LINKS: { getByName } as unknown as LinkEnv["USER_LINKS"],
    } as unknown as LinkEnv);

    expect(response.status).toBe(204);
    expect(forwarded).toBe(request);
    expect(forwarded?.headers.get(DEVICE_AUTH_HEADERS.signature)).toBe(
      request.headers.get(DEVICE_AUTH_HEADERS.signature),
    );
    expect(forwarded?.headers.get("sec-websocket-key")).toBe(
      request.headers.get("sec-websocket-key"),
    );
    expect(getByName).toHaveBeenCalledWith(SOCKET_FORWARD_ACCOUNT);
  });

  it("keeps the v1 device catalog usable when stored devices include newer runtime kinds", async () => {
    const account = "account-kind-catalog-compatibility";
    const token = "access-kind-catalog-compatibility-fixture-0001";
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)")
        .bind(account, NOW),
      env.ACCOUNTS.prepare("INSERT INTO access_sessions (token_hash, account_coordinate, authorization_epoch, created_at, expires_at) VALUES (?, ?, 1, ?, ?)")
        .bind(await sha256Base64URL(token), account, NOW, NOW + 900),
    ]);
    const keys = await generateDeviceKeys();
    const registration = await fetchWorker("/v1/devices", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ deviceId: "device-kind-compatibility", publicKeySPKI: keys.publicKeySPKI,
        role: "mobile", kind: "phone", encryptedName: "ciphertext-v1", revision: 1 }),
    });
    expect(registration.status).toBe(201);
    const { device } = await registration.json<{ device: Record<string, unknown> }>();
    // A newer runtime's persisted rows can outlive the Worker version that wrote
    // them. Simulate that RPC boundary without changing/revoking any rows.
    const stored = Object.freeze(["phone", "tablet", "computer", "hermes_host", "native_host", "future_host"]
      .map((kind) => Object.freeze({ ...device, deviceId: `device-${kind}`, kind,
        role: kind.endsWith("host") ? "host" : "mobile" })));
    const targetEnv = { ...env, USER_LINKS: { getByName: () => ({
      listDevices: async () => ({ devices: stored }),
    }) } } as unknown as LinkEnv;
    const request = await signedRequest(keys.privateKey, "device-kind-compatibility",
      "/v1/devices", "GET", "", 9002);
    const response = await handleLoopdyLinkRequest(request, targetEnv);
    expect(response.status).toBe(200);
    const value = await response.json<{ version: number; devices: Array<{ deviceId: string; kind: string }> }>();
    expect(value.version).toBe(1);
    expect(value.devices.map((entry) => entry.kind)).toEqual(["phone", "tablet", "computer", "hermes_host"]);
    expect(value.devices.map((entry) => entry.deviceId)).toEqual([
      "device-phone", "device-tablet", "device-computer", "device-hermes_host",
    ]);
    expect(stored).toHaveLength(6);
    expect(stored[4]?.kind).toBe("native_host");
  });

  it("preserves a forward-migrated Native device and grant while serving the signed v1 catalog", async () => {
    const account = "account-native-catalog-rollback";
    const token = "access-native-catalog-rollback-fixture-0001";
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)")
        .bind(account, NOW),
      env.ACCOUNTS.prepare("INSERT INTO access_sessions (token_hash, account_coordinate, authorization_epoch, created_at, expires_at) VALUES (?, ?, 1, ?, ?)")
        .bind(await sha256Base64URL(token), account, NOW, NOW + 900),
    ]);
    const keys = await generateDeviceKeys();
    const registration = await fetchWorker("/v1/devices", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ deviceId: "rollback-phone", publicKeySPKI: keys.publicKeySPKI,
        role: "mobile", kind: "phone", encryptedName: "ciphertext-phone", revision: 1 }),
    });
    expect(registration.status).toBe(201);
    const stub = env.USER_LINKS.getByName(account);
    await stub.registerDevice({ deviceId: "rollback-hermes", publicKey: keys.publicKeySPKI,
      role: "host", kind: "hermes_host", encryptedName: "ciphertext-hermes", revision: 1, createdAt: NOW });
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      // Test storage only: reproduce Native v2's forward table migration. An
      // older Worker must continue serving v1 without downmigrating this table.
      const schema = state.storage.sql.exec<{ sql: string }>(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'devices'",
      ).one().sql;
      state.storage.transactionSync(() => {
        state.storage.sql.exec(schema.replace("devices", "devices_native_v2")
          .replace("'hermes_host'", "'hermes_host', 'native_host'"));
        state.storage.sql.exec(`
          INSERT INTO devices_native_v2 SELECT * FROM devices;
          DROP TABLE devices;
          ALTER TABLE devices_native_v2 RENAME TO devices;
          CREATE INDEX devices_lifecycle_idx ON devices (lifecycle, role, created_at, device_id);
          INSERT INTO devices (device_id, public_key, role, kind, encrypted_name, lifecycle,
            revision, authorization_epoch, connection_state, created_at)
          SELECT 'rollback-native', public_key, 'host', 'native_host', 'ciphertext-native',
            'active', 7, 3, 'offline', created_at FROM devices WHERE device_id = 'rollback-hermes';
          INSERT INTO host_grants (host_device_id, state, created_at)
          SELECT 'rollback-native', 'active', created_at FROM devices WHERE device_id = 'rollback-native';
        `);
      });
    });
    const readStoredState = () => runInDurableObject(stub, (_instance, state) => ({
      devices: state.storage.sql.exec("SELECT * FROM devices ORDER BY device_id").toArray(),
      grants: state.storage.sql.exec("SELECT * FROM host_grants ORDER BY host_device_id").toArray(),
      schema: state.storage.sql.exec("SELECT sql FROM sqlite_master WHERE name = 'devices'").toArray(),
    }));
    const before = await readStoredState();
    const response = await signedFetch(keys.privateKey, "/v1/devices", "GET", "", 9003, "rollback-phone");
    expect(response.status).toBe(200);
    const catalog = await response.json<{ devices: Array<{ deviceId: string; kind: string }> }>();
    expect(catalog.devices.map(({ deviceId, kind }) => ({ deviceId, kind }))).toEqual([
      { deviceId: "rollback-phone", kind: "phone" },
      { deviceId: "rollback-hermes", kind: "hermes_host" },
    ]);
    expect(await readStoredState()).toEqual(before);
    expect((await stub.listDevices()).devices).toContainEqual(expect.objectContaining({
      deviceId: "rollback-native", kind: "native_host", lifecycle: "active", revision: 7, authorizationEpoch: 3,
    }));
  });

  it("registers, lists, renames, and revokes through server-derived account routing", async () => {
    const keys = await generateDeviceKeys();
    const registration = await fetchWorker("/v1/devices", {
      method: "POST",
      headers: {
        authorization: `Bearer ${ACCESS_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        accountCoordinate: "account-attacker-controlled",
        deviceId: "device-fixture-1",
        publicKeySPKI: keys.publicKeySPKI,
        role: "mobile",
        kind: "phone",
        encryptedName: "ciphertext-v1",
        revision: 1,
      }),
    });
    expect(registration.status).toBe(201);
    const registered = await registration.json<Record<string, unknown>>();
    expect(registered.device).toEqual(
      expect.objectContaining({
        deviceId: "device-fixture-1",
        revision: 1,
        encryptedName: "ciphertext-v1",
      }),
    );
    expect(JSON.stringify(registered)).not.toContain(keys.publicKeySPKI);
    expect(JSON.stringify(registered)).not.toContain(ACCOUNT);

    const list = await signedFetch(keys.privateKey, "/v1/devices", "GET", "", 1);
    expect(list.status).toBe(200);
    expect(await list.json()).toEqual(
      expect.objectContaining({
        devices: [expect.objectContaining({ deviceId: "device-fixture-1", revision: 1 })],
      }),
    );

    const renameBody = JSON.stringify({ expectedRevision: 1, encryptedName: "ciphertext-v2" });
    const renamed = await signedFetch(
      keys.privateKey,
      "/v1/devices/device-fixture-1/name",
      "PATCH",
      renameBody,
      2,
    );
    expect(renamed.status).toBe(200);
    expect(await renamed.json()).toEqual(
      expect.objectContaining({
        device: expect.objectContaining({ deviceId: "device-fixture-1", revision: 2 }),
      }),
    );

    const revokeBody = JSON.stringify({ expectedRevision: 2 });
    const revoked = await signedFetch(
      keys.privateKey,
      "/v1/devices/device-fixture-1",
      "DELETE",
      revokeBody,
      3,
    );
    expect(revoked.status).toBe(200);
    expect(await revoked.json()).toEqual(
      expect.objectContaining({
        device: expect.objectContaining({ lifecycle: "revoked", authorizationEpoch: 2 }),
      }),
    );
    expect(
      await env.ACCOUNTS.prepare(
        "SELECT status, authorization_epoch FROM device_directory WHERE device_id = ?",
      )
        .bind("device-fixture-1")
        .first(),
    ).toEqual({ status: "revoked", authorization_epoch: 2 });

    const rejected = await signedFetch(keys.privateKey, "/v1/devices", "GET", "", 4);
    expect(rejected.status).toBe(403);
  });

  it("revokes a device when trusted storage contains a legacy Live Activity identifier", async () => {
    const keys = await generateDeviceKeys();
    const deviceId = "device-legacy-revoke";
    await fetchWorker("/v1/devices", {
      method: "POST",
      headers: {
        authorization: `Bearer ${ACCESS_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceId,
        publicKeySPKI: keys.publicKeySPKI,
        role: "mobile",
        kind: "phone",
        encryptedName: "ciphertext-legacy-revoke",
        revision: 1,
      }),
    });
    const stub = env.USER_LINKS.getByName(ACCOUNT);
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      state.storage.sql.exec("UPDATE devices SET push_state='ready',push_revision=1 WHERE device_id=?", deviceId);
      state.storage.sql.exec(
        "CREATE TABLE IF NOT EXISTS live_activities (activity_id TEXT PRIMARY KEY, device_id TEXT, session_reference TEXT, status TEXT, revision INTEGER, lease_expires INTEGER, created_at INTEGER, updated_at INTEGER)",
      );
      state.storage.sql.exec(
        `INSERT INTO live_activities (
           activity_id, device_id, session_reference, status,
           revision, lease_expires, created_at, updated_at
         ) VALUES (?, ?, ?, 'active', 1, ?, ?, ?)`,
        "legacy/activity-id",
        deviceId,
        "L".repeat(43),
        NOW + 600,
        NOW,
        NOW,
      );
    });
    const revokeDevice = vi.fn(async (input) => ({ status: "revoked" as const, ...input }));
    const revokeLiveActivity = vi.fn(async () => {
      throw new Error("public Live Activity revocation must not receive legacy stored IDs");
    });
    const body = JSON.stringify({ expectedRevision: 1 });
    const request = await signedRequest(
      keys.privateKey,
      deviceId,
      `/v1/devices/${deviceId}`,
      "DELETE",
      body,
      30,
    );

    const response = await handleLoopdyLinkRequest(request, {
      ...env,
      APNS_ENROLLMENT: { revokeDevice, revokeLiveActivity },
    } as unknown as LinkEnv);

    expect(response.status).toBe(200);
    expect(revokeDevice).not.toHaveBeenCalled();
    expect(revokeLiveActivity).not.toHaveBeenCalled();
    expect(
      await runInDurableObject<UserLink, string>(stub, (_instance, state) =>
        state.storage.sql
          .exec<{ status: string }>(
            "SELECT lifecycle AS status FROM devices WHERE device_id = ?",
            deviceId,
          )
          .one().status,
      ),
    ).toBe("revoked");
  });

  it("does not revoke push state for a stale target device revision", async () => {
    const keys = await generateDeviceKeys();
    const deviceId = "device-stale-revoke";
    await fetchWorker("/v1/devices", {
      method: "POST",
      headers: {
        authorization: `Bearer ${ACCESS_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceId,
        publicKeySPKI: keys.publicKeySPKI,
        role: "mobile",
        kind: "phone",
        encryptedName: "ciphertext-stale-revoke",
        revision: 1,
      }),
    });
    const stub = env.USER_LINKS.getByName(ACCOUNT);
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      state.storage.sql.exec("UPDATE devices SET push_state='ready',push_revision=1 WHERE device_id=?", deviceId);
    });
    const revokeDevice = vi.fn(async (input) => ({ status: "revoked" as const, ...input }));
    const body = JSON.stringify({ expectedRevision: 2 });
    const request = await signedRequest(
      keys.privateKey,
      deviceId,
      `/v1/devices/${deviceId}`,
      "DELETE",
      body,
      31,
    );

    const response = await handleLoopdyLinkRequest(request, {
      ...env,
      APNS_ENROLLMENT: { revokeDevice },
    } as unknown as LinkEnv);

    expect(response.status).toBe(409);
    expect(revokeDevice).not.toHaveBeenCalled();
    expect((await stub.listDevices()).devices).toEqual([
      expect.objectContaining({ deviceId, lifecycle: "active", revision: 1 }),
    ]);
  });

  it("rejects the retired APNs enrollment route without calling its binding", async () => {
    const keys = await generateDeviceKeys();
    await fetchWorker("/v1/devices", {
      method: "POST",
      headers: {
        authorization: `Bearer ${ACCESS_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceId: "device-push-1",
        publicKeySPKI: keys.publicKeySPKI,
        role: "mobile",
        kind: "phone",
        encryptedName: "ciphertext-push-v1",
        revision: 1,
      }),
    });
    const enrollDevice = vi.fn(async () => ({
      status: "accepted" as const,
      deviceId: "device-push-1",
      revision: 1,
      leaseExpires: NOW + 2_592_000,
      senderKeyRevision: 1,
      currentSenderKey: { key_id: "sender-key" },
      previousSenderKey: null,
    }));
    const binding = {
      enrollDevice,
      revokeDevice: vi.fn(),
    };
    const body = JSON.stringify({
      revision: 1,
      pushToken: "00ff11aa",
      recipientPublicKey: "recipient-public-key",
      recipientKeyId: "recipient-key-id",
      environment: "sandbox",
      topic: "com.loopdy.app",
    });
    const request = await signedRequest(
      keys.privateKey,
      "device-push-1",
      "/v1/devices/device-push-1/push",
      "PUT",
      body,
      5,
    );
    const response = await handleLoopdyLinkRequest(request, {
      ...env,
      APNS_ENROLLMENT: binding,
    } as unknown as LinkEnv);

    expect(response.status).toBe(404);
    expect(enrollDevice).not.toHaveBeenCalled();
  });

  it("rejects both retired sender-key enrollment routes", async () => {
    const keys = await generateDeviceKeys();
    await fetchWorker("/v1/devices", {
      method: "POST",
      headers: {
        authorization: `Bearer ${ACCESS_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceId: "device-push-ack",
        publicKeySPKI: keys.publicKeySPKI,
        role: "mobile",
        kind: "phone",
        encryptedName: "ciphertext-push-ack",
        revision: 1,
      }),
    });
    const acknowledgedSenderKey = "A".repeat(43);
    const acknowledgeSenderKeys = vi.fn(async () => ({
      status: "accepted" as const,
      deviceId: "device-push-ack",
      revision: 2,
      senderKeyRevision: 1,
      acknowledgedSenderKeyIds: [acknowledgedSenderKey],
    }));
    const binding = {
      enrollDevice: vi.fn(async () => ({
        status: "accepted" as const,
        deviceId: "device-push-ack",
        revision: 1,
        leaseExpires: NOW + 2_592_000,
        senderKeyRevision: 1,
        currentSenderKey: { key_id: acknowledgedSenderKey },
        previousSenderKey: null,
      })),
      acknowledgeSenderKeys,
      revokeDevice: vi.fn(),
      wakeDevice: vi.fn(),
    };
    const enrollmentBody = JSON.stringify({
      revision: 1,
      pushToken: "00ff11aa",
      recipientPublicKey: "recipient-public-key",
      recipientKeyId: "recipient-key-id",
      environment: "sandbox",
      topic: "com.loopdy.app",
    });
    const enrollmentRequest = await signedRequest(
      keys.privateKey,
      "device-push-ack",
      "/v1/devices/device-push-ack/push",
      "PUT",
      enrollmentBody,
      50,
    );
    expect(
      (
        await handleLoopdyLinkRequest(enrollmentRequest, {
          ...env,
          APNS_ENROLLMENT: binding,
        } as unknown as LinkEnv)
      ).status,
    ).toBe(404);
    const body = JSON.stringify({
      revision: 2,
      senderKeyRevision: 1,
      acknowledgedSenderKeyIds: [acknowledgedSenderKey],
    });
    const request = await signedRequest(
      keys.privateKey,
      "device-push-ack",
      "/v1/devices/device-push-ack/push/ack",
      "POST",
      body,
      51,
    );
    const response = await handleLoopdyLinkRequest(request, {
      ...env,
      APNS_ENROLLMENT: binding,
    } as unknown as LinkEnv);

    expect(response.status).toBe(404);
    expect(acknowledgeSenderKeys).not.toHaveBeenCalled();
  });

  it("does not accept tokens through the retired device Live Activity route", async () => {
    const keys = await generateDeviceKeys();
    await fetchWorker("/v1/devices", {
      method: "POST",
      headers: {
        authorization: `Bearer ${ACCESS_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceId: "device-live-1",
        publicKeySPKI: keys.publicKeySPKI,
        role: "mobile",
        kind: "phone",
        encryptedName: "ciphertext-live-v1",
        revision: 1,
      }),
    });
    const registerLiveActivity = vi.fn(async () => ({
      status: "accepted" as const,
      activityId: "activity-live-1",
      revision: 1,
    }));
    const revokeLiveActivity = vi.fn(async () => ({
      status: "revoked" as const,
      activityId: "activity-live-1",
      revision: 2,
    }));
    const binding = { registerLiveActivity, revokeLiveActivity };
    const sessionReference = "A".repeat(43);
    const body = JSON.stringify({
      revision: 1,
      sessionReference,
      pushToken: "00ff11aa",
      environment: "sandbox",
      topic: "com.example.loopdy",
      timestamp: NOW,
      leaseExpires: NOW + 28_800,
    });
    const request = await signedRequest(
      keys.privateKey,
      "device-live-1",
      "/v1/devices/device-live-1/live-activities/activity-live-1",
      "PUT",
      body,
      60,
    );
    const response = await handleLoopdyLinkRequest(request, {
      ...env,
      APNS_ENROLLMENT: binding,
    } as unknown as LinkEnv);

    expect(response.status).toBe(404);
    const registration = await response.json();
    expect(JSON.stringify(registration)).not.toContain("00ff11aa");
    expect(registerLiveActivity).not.toHaveBeenCalled();

    const revokeBody = JSON.stringify({ revision: 2, timestamp: NOW });
    const revokeRequest = await signedRequest(
      keys.privateKey,
      "device-live-1",
      "/v1/devices/device-live-1/live-activities/activity-live-1",
      "DELETE",
      revokeBody,
      61,
    );
    const revoked = await handleLoopdyLinkRequest(revokeRequest, {
      ...env,
      APNS_ENROLLMENT: binding,
    } as unknown as LinkEnv);
    expect(revoked.status).toBe(404);
  });

  it("does not mirror OS permission into retired relay enrollment", async () => {
    const keys = await generateDeviceKeys();
    await fetchWorker("/v1/devices", {
      method: "POST",
      headers: {
        authorization: `Bearer ${ACCESS_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceId: "device-push-denied",
        publicKeySPKI: keys.publicKeySPKI,
        role: "mobile",
        kind: "phone",
        encryptedName: "ciphertext-push-denied",
        revision: 1,
      }),
    });
    const body = JSON.stringify({ revision: 1, state: "denied" });
    const request = await signedRequest(
      keys.privateKey,
      "device-push-denied",
      "/v1/devices/device-push-denied/push",
      "PUT",
      body,
      6,
    );

    const response = await handleLoopdyLinkRequest(request, env);

    expect(response.status).toBe(404);
  });
});

async function fetchWorker(path: string, init?: RequestInit): Promise<Response> {
  return worker.fetch(new Request(`https://link.loopdy.example${path}`, init), env);
}

async function signedFetch(
  privateKey: CryptoKey,
  path: string,
  method: string,
  body: string,
  nonceSequence: number,
  deviceId = "device-fixture-1",
): Promise<Response> {
  const request = await signedRequest(
    privateKey,
    deviceId,
    path,
    method,
    body,
    nonceSequence,
  );
  return worker.fetch(request, env);
}

async function signedRequest(
  privateKey: CryptoKey,
  deviceId: string,
  path: string,
  method: string,
  body: string,
  nonceSequence: number,
): Promise<Request> {
  const nonce = base64url(new TextEncoder().encode(`nonce-sequence-${nonceSequence}-fixture`));
  const canonical = await canonicalDeviceRequest({
    method,
    path,
    deviceId,
    timestamp: NOW,
    nonce,
    authorizationEpoch: 1,
    body,
  });
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      privateKey,
      new TextEncoder().encode(canonical),
    ),
  );
  const headers = new Headers({
    [DEVICE_AUTH_HEADERS.deviceId]: deviceId,
    [DEVICE_AUTH_HEADERS.timestamp]: String(NOW),
    [DEVICE_AUTH_HEADERS.nonce]: nonce,
    [DEVICE_AUTH_HEADERS.authorizationEpoch]: "1",
    [DEVICE_AUTH_HEADERS.signature]: base64url(signature),
  });
  if (body) headers.set("content-type", "application/json");
  return new Request(`https://link.loopdy.example${path}`, {
    method,
    headers,
    body: body || undefined,
  });
}

async function generateDeviceKeys(): Promise<{
  privateKey: CryptoKey;
  publicKeySPKI: string;
}> {
  const keyPair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const spki = new Uint8Array(
    (await crypto.subtle.exportKey("spki", keyPair.publicKey)) as ArrayBuffer,
  );
  return { privateKey: keyPair.privateKey, publicKeySPKI: base64url(spki) };
}

async function sha256Base64URL(value: string): Promise<string> {
  return base64url(
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))),
  );
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}
