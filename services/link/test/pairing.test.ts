import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { canonicalDeviceRequest, DEVICE_AUTH_HEADERS } from "../src/device-auth.js";
import worker from "../src/index.js";
import { canonicalPairingProof } from "../src/pairing.js";
import { LoopdyLinkError } from "../src/contracts.js";
import type { LinkEnv } from "../src/user-link.js";

const NOW = Math.floor(Date.now() / 1_000);
const ACCOUNT = "account-pairing-fixture-coordinate";
const MOBILE_ID = "mobile-pairing-fixture";

describe("Loopdy Link secure host pairing", () => {
  afterEach(() => vi.restoreAllMocks());

  beforeEach(async () => {
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("DELETE FROM pairing_challenges"),
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
    ]);
  });

  it("pairs a proof-of-possession host without revealing the account coordinate", async () => {
    const mobile = await generateSigningKeys();
    const host = await generateSigningKeys();
    await registerMobile(mobile.publicKeySPKI);
    const claimSecret = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const claimSecretHash = await sha256Base64URL(claimSecret);
    const requestNonce = base64url(crypto.getRandomValues(new Uint8Array(24)));
    const hostAgreementPublicKey = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const timestamp = NOW;
    const proof = await signText(
      host.privateKey,
      await canonicalPairingProof({
        action: "create",
        flowId: "-",
        deviceId: "host-pairing-fixture",
        signingPublicKeySPKI: host.publicKeySPKI,
        agreementPublicKey: hostAgreementPublicKey,
        timestamp,
        nonce: requestNonce,
        secretHash: claimSecretHash,
      }),
    );
    const created = await fetchWorker("/v1/pairing/challenges", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        deviceId: "host-pairing-fixture",
        signingPublicKeySPKI: host.publicKeySPKI,
        agreementPublicKey: hostAgreementPublicKey,
        claimSecretHash,
        timestamp,
        nonce: requestNonce,
        proof,
      }),
    });

    expect(created.status).toBe(201);
    const challenge = await created.json<{
      flowId: string;
      code: string;
      expiresAt: number;
      pairingURL: string;
    }>();
    expect(challenge.code).toMatch(/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$/);
    expect(challenge.pairingURL).toBe(
      `loopdy://link/pair?flow=${challenge.flowId}&code=${challenge.code}`,
    );
    expect(JSON.stringify(challenge)).not.toContain(ACCOUNT);
    expect(JSON.stringify(challenge)).not.toContain(claimSecret);

    const inspectionBody = JSON.stringify({
      flowId: challenge.flowId,
      code: challenge.code,
    });
    const inspected = await signedMobileFetch(
      mobile.privateKey,
      "/v1/pairing/challenges/inspect",
      inspectionBody,
      1,
    );
    expect(inspected.status).toBe(200);
    expect(await inspected.json()).toEqual({
      version: 1,
      flowId: challenge.flowId,
      deviceId: "host-pairing-fixture",
      signingPublicKeySPKI: host.publicKeySPKI,
      agreementPublicKey: hostAgreementPublicKey,
      expiresAt: challenge.expiresAt,
    });

    const lookupBody = JSON.stringify({ code: challenge.code });
    const lookedUp = await signedMobileFetch(
      mobile.privateKey,
      "/v1/pairing/challenges/inspect",
      lookupBody,
      2,
    );
    expect(lookedUp.status).toBe(200);
    expect(await lookedUp.json()).toEqual(expect.objectContaining({ flowId: challenge.flowId }));

    const approvalBody = JSON.stringify({
      code: challenge.code,
      encryptedName: "ciphertext-host-name-v1",
      grantEnvelope: "opaque-e2ee-grant-envelope-value",
    });
    const refusedEnv = { ...env, USER_LINKS: { getByName: () => ({ registerDevice: async () => {
      throw new LoopdyLinkError("device_limit", "Device limit reached");
    } }) } } as unknown as LinkEnv;
    const refused = await signedMobileFetch(mobile.privateKey,
      `/v1/pairing/challenges/${challenge.flowId}/approve`, approvalBody, 900, refusedEnv);
    expect(refused.ok).toBe(false);
    expect(await env.ACCOUNTS.prepare("SELECT state FROM pairing_challenges WHERE flow_id = ?")
      .bind(challenge.flowId).first()).toEqual({ state: "pending" });
    expect(await env.ACCOUNTS.prepare("SELECT device_id FROM device_directory WHERE device_id = ?")
      .bind("host-pairing-fixture").first()).toBeNull();
    const approved = await signedMobileFetch(
      mobile.privateKey,
      `/v1/pairing/challenges/${challenge.flowId}/approve`,
      approvalBody,
      3,
    );
    expect(approved.status).toBe(200);
    expect(await approved.json()).toEqual({
      version: 1,
      state: "approved",
      device: expect.objectContaining({
        deviceId: "host-pairing-fixture",
        role: "host",
        kind: "hermes_host",
      }),
    });

    const claimNonce = base64url(crypto.getRandomValues(new Uint8Array(24)));
    const claimProof = await signText(
      host.privateKey,
      await canonicalPairingProof({
        action: "claim",
        flowId: challenge.flowId,
        deviceId: "host-pairing-fixture",
        signingPublicKeySPKI: host.publicKeySPKI,
        agreementPublicKey: hostAgreementPublicKey,
        timestamp,
        nonce: claimNonce,
        secretHash: claimSecretHash,
      }),
    );
    const claimed = await fetchWorker(`/v1/pairing/challenges/${challenge.flowId}/claim`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ claimSecret, timestamp, nonce: claimNonce, proof: claimProof }),
    });
    expect(claimed.status).toBe(200);
    const grant = await claimed.json<Record<string, unknown>>();
    expect(grant).toEqual({
      version: 1,
      state: "claimed",
      deviceId: "host-pairing-fixture",
      authorizationEpoch: 1,
      grantEnvelope: "opaque-e2ee-grant-envelope-value",
      socketPath: "/v1/socket",
    });
    expect(JSON.stringify(grant)).not.toContain(ACCOUNT);
    expect(JSON.stringify(grant)).not.toContain(claimSecret);

    const replay = await fetchWorker(`/v1/pairing/challenges/${challenge.flowId}/claim`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ claimSecret, timestamp, nonce: claimNonce, proof: claimProof }),
    });
    expect(replay.status).toBe(409);
  });

  it("rejects an invalid host proof and a wrong human-verification code", async () => {
    const mobile = await generateSigningKeys();
    const host = await generateSigningKeys();
    const attacker = await generateSigningKeys();
    await registerMobile(mobile.publicKeySPKI);
    const claimSecret = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const claimSecretHash = await sha256Base64URL(claimSecret);
    const nonce = base64url(crypto.getRandomValues(new Uint8Array(24)));
    const agreementPublicKey = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const canonical = await canonicalPairingProof({
      action: "create",
      flowId: "-",
      deviceId: "host-proof-fixture",
      signingPublicKeySPKI: host.publicKeySPKI,
      agreementPublicKey,
      timestamp: NOW,
      nonce,
      secretHash: claimSecretHash,
    });
    const rejected = await createChallenge({
      deviceId: "host-proof-fixture",
      signingPublicKeySPKI: host.publicKeySPKI,
      agreementPublicKey,
      claimSecretHash,
      timestamp: NOW,
      nonce,
      proof: await signText(attacker.privateKey, canonical),
    });
    expect(rejected.status).toBe(403);

    const valid = await createChallenge({
      deviceId: "host-proof-fixture",
      signingPublicKeySPKI: host.publicKeySPKI,
      agreementPublicKey,
      claimSecretHash,
      timestamp: NOW,
      nonce: base64url(crypto.getRandomValues(new Uint8Array(24))),
      proof: await signText(
        host.privateKey,
        await canonicalPairingProof({
          action: "create",
          flowId: "-",
          deviceId: "host-proof-fixture",
          signingPublicKeySPKI: host.publicKeySPKI,
          agreementPublicKey,
          timestamp: NOW,
          nonce: "unused-will-be-replaced",
          secretHash: claimSecretHash,
        }),
      ),
    });
    // Build a second valid request explicitly so the proof and nonce are identical.
    expect(valid.status).toBe(403);

    const validNonce = base64url(crypto.getRandomValues(new Uint8Array(24)));
    const validProof = await signText(
      host.privateKey,
      await canonicalPairingProof({
        action: "create",
        flowId: "-",
        deviceId: "host-proof-fixture",
        signingPublicKeySPKI: host.publicKeySPKI,
        agreementPublicKey,
        timestamp: NOW,
        nonce: validNonce,
        secretHash: claimSecretHash,
      }),
    );
    const created = await createChallenge({
      deviceId: "host-proof-fixture",
      signingPublicKeySPKI: host.publicKeySPKI,
      agreementPublicKey,
      claimSecretHash,
      timestamp: NOW,
      nonce: validNonce,
      proof: validProof,
    });
    const challenge = await created.json<{ flowId: string }>();
    const wrongCode = await signedMobileFetch(
      mobile.privateKey,
      `/v1/pairing/challenges/${challenge.flowId}/approve`,
      JSON.stringify({
        code: "AAAAAA",
        encryptedName: "ciphertext-host-name-v1",
        grantEnvelope: "opaque-e2ee-grant-envelope-value",
      }),
      2,
    );
    expect(wrongCode.status).toBe(403);
  });

  it("fences an in-flight approved claim while deletion cleanup is held", async () => {
    const host = await generateSigningKeys();
    const flowId = "held-cleanup-pairing-flow-fixture";
    const claimSecret = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const claimSecretHash = await sha256Base64URL(claimSecret);
    const agreementPublicKey = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const accessToken = "held-cleanup-pairing-access-token-with-enough-entropy";
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      ).bind(await sha256Base64URL(accessToken), ACCOUNT, NOW, NOW + 900),
      env.ACCOUNTS.prepare(
        `INSERT INTO pairing_challenges (
           flow_id, code_hash, host_device_id, host_signing_public_key_spki,
           host_agreement_public_key, claim_secret_hash, state, account_coordinate,
           authorization_epoch, encrypted_name, grant_envelope, created_at, expires_at, approved_at
         ) VALUES (?, ?, ?, ?, ?, ?, 'approved', ?, 1, ?, ?, ?, ?, ?)`,
      ).bind(
        flowId,
        await sha256Base64URL("AAAAAA"),
        "held-cleanup-pairing-host",
        host.publicKeySPKI,
        agreementPublicKey,
        claimSecretHash,
        ACCOUNT,
        "encrypted-held-cleanup-host",
        "opaque-held-cleanup-grant-envelope",
        NOW,
        NOW + 600,
        NOW,
      ),
    ]);

    const nonce = base64url(crypto.getRandomValues(new Uint8Array(24)));
    const proof = await signText(host.privateKey, await canonicalPairingProof({
      action: "claim",
      flowId,
      deviceId: "held-cleanup-pairing-host",
      signingPublicKeySPKI: host.publicKeySPKI,
      agreementPublicKey,
      timestamp: NOW,
      nonce,
      secretHash: claimSecretHash,
    }));
    const verify = crypto.subtle.verify.bind(crypto.subtle);
    let verificationEntered!: () => void;
    const verificationStarted = new Promise<void>((resolve) => { verificationEntered = resolve; });
    let releaseVerification!: () => void;
    const verificationHeld = new Promise<void>((resolve) => { releaseVerification = resolve; });
    vi.spyOn(crypto.subtle, "verify").mockImplementation(async (...input) => {
      verificationEntered();
      await verificationHeld;
      return verify(...input);
    });
    const claimPromise = fetchWorker(`/v1/pairing/challenges/${flowId}/claim`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ claimSecret, timestamp: NOW, nonce, proof }),
    });
    await verificationStarted;

    let releaseProvider!: () => void;
    const providerHeld = new Promise<void>((resolve) => { releaseProvider = resolve; });
    let providerEntered!: () => void;
    const providerStarted = new Promise<void>((resolve) => { providerEntered = resolve; });
    vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
      if (init?.method === "DELETE") {
        providerEntered();
        await providerHeld;
        return Response.json({ success: true, data: {} });
      }
      return Response.json({ success: false, error: { code: "not_found" } }, { status: 404 });
    });
    const deletionPromise = worker.fetch(new Request(
      "https://link.loopdy.example/v1/accounts/current",
      { method: "DELETE", headers: { authorization: `Bearer ${accessToken}` } },
    ), {
      ...env,
      BUZZKIT_API_KEY: `bk_tn_${crypto.randomUUID()}`,
      BUZZKIT_IDENTITY_SECRET: crypto.randomUUID(),
      BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
    } as LinkEnv);
    await providerStarted;

    try {
      expect(await env.ACCOUNTS.prepare(
        "SELECT state FROM pairing_challenges WHERE flow_id = ?",
      ).bind(flowId).first()).toEqual({ state: "expired" });
      releaseVerification();
      const claim = await claimPromise;
      expect(claim.status).toBe(409);
      expect(await claim.json()).toEqual(expect.objectContaining({ error: "challenge_used" }));
    } finally {
      releaseVerification();
      releaseProvider();
    }
    expect((await deletionPromise).status).toBe(200);
  });

  it("fences a self-revoked key before cleanup and resumes the exact signed deletion", async () => {
    const mobile = await generateSigningKeys();
    const host = await generateSigningKeys();
    const selfRevokeAccount = `account-self-revoke-${crypto.randomUUID()}`;
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(selfRevokeAccount, NOW),
      env.ACCOUNTS.prepare(`INSERT INTO device_directory(
        device_id,account_coordinate,public_key_spki,status,authorization_epoch,created_at)
        VALUES(?,?,?,'active',1,?)`)
        .bind(MOBILE_ID, selfRevokeAccount, mobile.publicKeySPKI, NOW),
    ]);
    const realStub = (env as unknown as LinkEnv).USER_LINKS.getByName(selfRevokeAccount);
    await realStub.registerDevice({
      deviceId: MOBILE_ID,
      publicKey: mobile.publicKeySPKI,
      role: "mobile",
      kind: "phone",
      encryptedName: "encrypted-self-revoking-mobile",
      revision: 1,
      createdAt: NOW,
    });

    const claimSecretHash = await sha256Base64URL(
      base64url(crypto.getRandomValues(new Uint8Array(32))),
    );
    const agreementPublicKey = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const hostNonce = base64url(crypto.getRandomValues(new Uint8Array(24)));
    const created = await createChallenge({
      deviceId: "host-after-self-revoke",
      signingPublicKeySPKI: host.publicKeySPKI,
      agreementPublicKey,
      claimSecretHash,
      timestamp: NOW,
      nonce: hostNonce,
      proof: await signText(host.privateKey, await canonicalPairingProof({
        action: "create",
        flowId: "-",
        deviceId: "host-after-self-revoke",
        signingPublicKeySPKI: host.publicKeySPKI,
        agreementPublicKey,
        timestamp: NOW,
        nonce: hostNonce,
        secretHash: claimSecretHash,
      })),
    });
    expect(created.status).toBe(201);
    const challenge = await created.json<{ flowId: string; code: string }>();

    let cleanupEntered!: () => void;
    const cleanupStarted = new Promise<void>((resolve) => { cleanupEntered = resolve; });
    let releaseCleanup!: () => void;
    const cleanupHeld = new Promise<void>((resolve) => { releaseCleanup = resolve; });
    const revokeDevice = vi.fn(async () => {
      cleanupEntered();
      await cleanupHeld;
      throw new Error("held device cleanup failed");
    });
    const registerDevice = vi.fn((input) => realStub.registerDevice(input));
    const heldEnv = {
      ...env,
      USER_LINKS: { getByName: () => ({ revokeDevice, registerDevice }) },
    } as unknown as LinkEnv;
    const revokeBody = JSON.stringify({ expectedRevision: 1 });
    const revocation = worker.fetch(await signedMobileRequest(
      mobile.privateKey,
      `/v1/devices/${MOBILE_ID}`,
      "DELETE",
      revokeBody,
      700,
    ), heldEnv);
    await cleanupStarted;

    const approvalBody = JSON.stringify({
      code: challenge.code,
      encryptedName: "encrypted-host-after-self-revoke",
      grantEnvelope: "opaque-host-after-self-revoke-envelope",
    });
    const approval = await worker.fetch(await signedMobileRequest(
      mobile.privateKey,
      `/v1/pairing/challenges/${challenge.flowId}/approve`,
      "POST",
      approvalBody,
      701,
    ), heldEnv);

    expect(approval.status).toBe(403);
    expect(await approval.json()).toEqual(expect.objectContaining({ error: "device_revoked" }));
    expect(registerDevice).not.toHaveBeenCalled();
    expect(await env.ACCOUNTS.prepare(
      "SELECT device_id FROM device_directory WHERE device_id = 'host-after-self-revoke'",
    ).first()).toBeNull();
    expect((await realStub.listDevices()).devices).toEqual([
      expect.objectContaining({ deviceId: MOBILE_ID, lifecycle: "active" }),
    ]);

    releaseCleanup();
    expect((await revocation).status).toBe(500);
    const marker = await env.ACCOUNTS.prepare(`SELECT account_coordinate,expected_revision,authorization_epoch
      FROM notification_device_revocations WHERE device_id=?`).bind(MOBILE_ID).first();
    expect(marker).toEqual({
      account_coordinate: selfRevokeAccount,
      expected_revision: 1,
      authorization_epoch: 1,
    });

    const retried = await worker.fetch(await signedMobileRequest(
      mobile.privateKey,
      `/v1/devices/${MOBILE_ID}`,
      "DELETE",
      revokeBody,
      702,
    ), env);
    expect(retried.status).toBe(200);
    expect(await retried.json()).toEqual(expect.objectContaining({
      device: expect.objectContaining({
        deviceId: MOBILE_ID,
        lifecycle: "revoked",
        revision: 2,
        authorizationEpoch: 2,
      }),
    }));
    expect((await realStub.listDevices()).devices).toEqual([]);
    expect(await env.ACCOUNTS.prepare(
      "SELECT device_id FROM notification_device_revocations WHERE device_id=?",
    ).bind(MOBILE_ID).first()).toEqual({ device_id: MOBILE_ID });

    const completedRetry = await worker.fetch(await signedMobileRequest(
      mobile.privateKey,
      `/v1/devices/${MOBILE_ID}`,
      "DELETE",
      revokeBody,
      703,
    ), env);
    expect(completedRetry.status).toBe(200);
    const wrongRevision = await worker.fetch(await signedMobileRequest(
      mobile.privateKey,
      `/v1/devices/${MOBILE_ID}`,
      "DELETE",
      JSON.stringify({ expectedRevision: 2 }),
      704,
    ), env);
    expect(wrongRevision.status).toBe(403);
    expect(await wrongRevision.json()).toEqual(expect.objectContaining({ error: "device_revoked" }));

    const ordinary = await worker.fetch(await signedMobileRequest(
      mobile.privateKey,
      "/v1/pairing/challenges/inspect",
      "POST",
      JSON.stringify({ flowId: challenge.flowId }),
      705,
    ), env);
    expect(ordinary.status).toBe(403);
    expect(await ordinary.json()).toEqual(expect.objectContaining({ error: "device_revoked" }));
  });
});

async function registerMobile(publicKeySPKI: string): Promise<void> {
  await env.ACCOUNTS.prepare(
    `INSERT INTO device_directory (
       device_id, account_coordinate, public_key_spki, status,
       authorization_epoch, created_at
     ) VALUES (?, ?, ?, 'active', 1, ?)`,
  )
    .bind(MOBILE_ID, ACCOUNT, publicKeySPKI, NOW)
    .run();
}

async function createChallenge(body: Record<string, unknown>): Promise<Response> {
  return fetchWorker("/v1/pairing/challenges", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function signedMobileFetch(
  privateKey: CryptoKey,
  path: string,
  body: string,
  sequence: number,
  targetEnv: LinkEnv = env,
): Promise<Response> {
  return worker.fetch(await signedMobileRequest(
    privateKey, path, "POST", body, sequence,
  ), targetEnv);
}

async function signedMobileRequest(
  privateKey: CryptoKey,
  path: string,
  method: "POST" | "DELETE",
  body: string,
  sequence: number,
): Promise<Request> {
  const nonce = base64url(
    new TextEncoder().encode(`mobile-pairing-nonce-${sequence}-fixture-value`),
  );
  const canonical = await canonicalDeviceRequest({
    method,
    path,
    deviceId: MOBILE_ID,
    timestamp: NOW,
    nonce,
    authorizationEpoch: 1,
    body,
  });
  return new Request(`https://link.loopdy.example${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      [DEVICE_AUTH_HEADERS.deviceId]: MOBILE_ID,
      [DEVICE_AUTH_HEADERS.timestamp]: String(NOW),
      [DEVICE_AUTH_HEADERS.nonce]: nonce,
      [DEVICE_AUTH_HEADERS.authorizationEpoch]: "1",
      [DEVICE_AUTH_HEADERS.signature]: await signText(privateKey, canonical),
    },
    body,
  });
}

async function fetchWorker(path: string, init?: RequestInit): Promise<Response> {
  return worker.fetch(new Request(`https://link.loopdy.example${path}`, init), env);
}

async function generateSigningKeys(): Promise<{
  privateKey: CryptoKey;
  publicKeySPKI: string;
}> {
  const keyPair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  return {
    privateKey: keyPair.privateKey,
    publicKeySPKI: base64url(
      new Uint8Array((await crypto.subtle.exportKey("spki", keyPair.publicKey)) as ArrayBuffer),
    ),
  };
}

async function signText(privateKey: CryptoKey, value: string): Promise<string> {
  return base64url(
    new Uint8Array(
      await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        privateKey,
        new TextEncoder().encode(value),
      ),
    ),
  );
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
