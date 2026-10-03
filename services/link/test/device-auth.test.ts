import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  canonicalDeviceRequest,
  DEVICE_AUTH_HEADERS,
  registerDeviceDirectory,
  verifyDeviceRequest,
} from "../src/device-auth.js";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    ACCOUNTS: D1Database;
  }
}

const NOW = 1_788_000_000;

describe("device-bound request authentication", () => {
  afterEach(() => vi.restoreAllMocks());

  beforeEach(async () => {
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("DELETE FROM device_nonces"),
      env.ACCOUNTS.prepare("DELETE FROM device_directory"),
      env.ACCOUNTS.prepare("DELETE FROM access_sessions"),
      env.ACCOUNTS.prepare("DELETE FROM passkeys"),
      env.ACCOUNTS.prepare("DELETE FROM auth_challenges"),
      env.ACCOUNTS.prepare("DELETE FROM accounts"),
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind("account-server-selected", NOW),
    ]);
  });

  it("derives routing from the verified device directory and rejects nonce replay", async () => {
    const keys = await generateDeviceKeys();
    await registerDeviceDirectory(env.ACCOUNTS, {
      accountCoordinate: "account-server-selected",
      deviceId: "device-fixture-1",
      publicKeySPKI: keys.publicKeySPKI,
      authorizationEpoch: 1,
      createdAt: NOW,
    });
    const body = JSON.stringify({ accountCoordinate: "account-attacker-controlled" });
    const headers = await signedHeaders(keys.privateKey, body, {
      nonce: "MDEyMzQ1Njc4OTo7PD0-Pw",
      timestamp: NOW,
      authorizationEpoch: 1,
    });

    const verified = await verifyDeviceRequest(request(body, headers), body, env.ACCOUNTS, NOW);

    expect(verified.accountCoordinate).toBe("account-server-selected");
    await expect(
      verifyDeviceRequest(request(body, headers), body, env.ACCOUNTS, NOW + 1),
    ).rejects.toMatchObject({ code: "nonce_replayed" });
  });

  it("rejects stale clocks and revoked authorization epochs", async () => {
    const keys = await generateDeviceKeys();
    await registerDeviceDirectory(env.ACCOUNTS, {
      accountCoordinate: "account-server-selected",
      deviceId: "device-fixture-1",
      publicKeySPKI: keys.publicKeySPKI,
      authorizationEpoch: 1,
      createdAt: NOW,
    });
    const body = "{}";
    const staleHeaders = await signedHeaders(keys.privateKey, body, {
      nonce: "ERITFBUWFxgZGhscHR4fIA",
      timestamp: NOW - 121,
      authorizationEpoch: 1,
    });
    await expect(
      verifyDeviceRequest(request(body, staleHeaders), body, env.ACCOUNTS, NOW),
    ).rejects.toMatchObject({ code: "stale_timestamp" });

    await env.ACCOUNTS.prepare(
      "UPDATE device_directory SET status = 'revoked', authorization_epoch = 2, revoked_at = ? WHERE device_id = ?",
    )
      .bind(NOW, "device-fixture-1")
      .run();
    const revokedHeaders = await signedHeaders(keys.privateKey, body, {
      nonce: "ISIjJCUmJygpKissLS4vMA",
      timestamp: NOW,
      authorizationEpoch: 1,
    });
    await expect(
      verifyDeviceRequest(request(body, revokedHeaders), body, env.ACCOUNTS, NOW),
    ).rejects.toMatchObject({ code: "device_revoked" });
  });

  it("rejects completion when account deletion is accepted during signature verification", async () => {
    const keys = await generateDeviceKeys();
    await registerDeviceDirectory(env.ACCOUNTS, {
      accountCoordinate: "account-server-selected",
      deviceId: "device-fixture-1",
      publicKeySPKI: keys.publicKeySPKI,
      authorizationEpoch: 1,
      createdAt: NOW,
    });
    const body = "{}";
    const headers = await signedHeaders(keys.privateKey, body, {
      nonce: "MTIzNDU2Nzg5Ojs8PT4_QA",
      timestamp: NOW,
      authorizationEpoch: 1,
    });
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

    const authentication = verifyDeviceRequest(request(body, headers), body, env.ACCOUNTS, NOW);
    await verificationStarted;
    await env.ACCOUNTS.prepare(
      `UPDATE accounts SET status = 'revoked', authorization_epoch = 2, revoked_at = ?
       WHERE account_coordinate = 'account-server-selected'`,
    ).bind(NOW).run();
    releaseVerification();

    await expect(authentication).rejects.toMatchObject({ code: "device_revoked" });
    expect(await env.ACCOUNTS.prepare(
      "SELECT nonce FROM device_nonces WHERE device_id = 'device-fixture-1'",
    ).first()).toBeNull();
  });
});

function request(body: string, headers: Headers): Request {
  return new Request("https://link.loopdy.example/v1/devices", {
    method: "POST",
    headers,
    body,
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

async function signedHeaders(
  privateKey: CryptoKey,
  body: string,
  input: { nonce: string; timestamp: number; authorizationEpoch: number },
): Promise<Headers> {
  const canonical = await canonicalDeviceRequest({
    method: "POST",
    path: "/v1/devices",
    deviceId: "device-fixture-1",
    timestamp: input.timestamp,
    nonce: input.nonce,
    authorizationEpoch: input.authorizationEpoch,
    body,
  });
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      privateKey,
      new TextEncoder().encode(canonical),
    ),
  );
  return new Headers({
    "content-type": "application/json",
    [DEVICE_AUTH_HEADERS.deviceId]: "device-fixture-1",
    [DEVICE_AUTH_HEADERS.timestamp]: String(input.timestamp),
    [DEVICE_AUTH_HEADERS.nonce]: input.nonce,
    [DEVICE_AUTH_HEADERS.authorizationEpoch]: String(input.authorizationEpoch),
    [DEVICE_AUTH_HEADERS.signature]: base64url(signature),
  });
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}
