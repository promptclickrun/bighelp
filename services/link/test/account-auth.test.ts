import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  beginAccountRegistration,
  completeAccountRegistration,
  type LoopdyPasskeyConfiguration,
  type RegistrationVerification,
} from "../src/account-auth.js";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    ACCOUNTS: D1Database;
  }
}

const CONFIG: LoopdyPasskeyConfiguration = {
  rpName: "Loopdy",
  rpID: "link.loopdy.example",
  expectedOrigin: "https://link.loopdy.example",
  challengeTTLSeconds: 300,
  sessionTTLSeconds: 900,
};

const NOW = 1_788_000_000;

const verifiedRegistration: RegistrationVerification = {
  verified: true,
  credential: {
    id: "credential-fixture-1",
    publicKey: new Uint8Array([1, 2, 3, 4]),
    counter: 0,
    transports: ["internal"],
  },
  credentialDeviceType: "multiDevice",
  credentialBackedUp: true,
};

describe("minimal passkey account bootstrap", () => {
  beforeEach(async () => {
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("DELETE FROM device_nonces"),
      env.ACCOUNTS.prepare("DELETE FROM device_directory"),
      env.ACCOUNTS.prepare("DELETE FROM access_sessions"),
      env.ACCOUNTS.prepare("DELETE FROM passkeys"),
      env.ACCOUNTS.prepare("DELETE FROM auth_challenges"),
      env.ACCOUNTS.prepare("DELETE FROM accounts"),
    ]);
  });

  it("creates an opaque passkey account and stores no ordinary profile fields", async () => {
    const started = await beginAccountRegistration(env.ACCOUNTS, CONFIG, NOW);
    expect(started).not.toHaveProperty("accountCoordinate");
    expect(started.options.challenge).toBeTruthy();

    const session = await completeAccountRegistration(
      env.ACCOUNTS,
      CONFIG,
      { flowId: started.flowId, response: { id: "registration-fixture" } },
      NOW + 1,
      async () => verifiedRegistration,
    );

    expect(session.accessToken).toMatch(/^[A-Za-z0-9_-]{32,}$/);
    expect(session.authorizationEpoch).toBe(1);
    expect(session).not.toHaveProperty("accountCoordinate");
    const account = await env.ACCOUNTS.prepare(
      "SELECT status, authorization_epoch, recovery_verifier FROM accounts",
    ).first();
    expect(account).toEqual({
      status: "active",
      authorization_epoch: 1,
      recovery_verifier: null,
    });
    const columns = await env.ACCOUNTS.prepare("PRAGMA table_info(accounts)").all<{
      name: string;
    }>();
    expect(columns.results.map((column) => column.name)).not.toEqual(
      expect.arrayContaining(["email", "phone", "password", "name", "avatar"]),
    );
  });

  it("consumes a registration challenge exactly once", async () => {
    const started = await beginAccountRegistration(env.ACCOUNTS, CONFIG, NOW);
    const input = { flowId: started.flowId, response: { id: "registration-fixture" } };

    await completeAccountRegistration(
      env.ACCOUNTS,
      CONFIG,
      input,
      NOW + 1,
      async () => verifiedRegistration,
    );

    await expect(
      completeAccountRegistration(
        env.ACCOUNTS,
        CONFIG,
        input,
        NOW + 2,
        async () => verifiedRegistration,
      ),
    ).rejects.toMatchObject({ code: "challenge_used" });
  });

  it("rejects an expired registration challenge before verification", async () => {
    const started = await beginAccountRegistration(env.ACCOUNTS, CONFIG, NOW);
    let verifierCalls = 0;

    await expect(
      completeAccountRegistration(
        env.ACCOUNTS,
        CONFIG,
        { flowId: started.flowId, response: { id: "registration-fixture" } },
        NOW + CONFIG.challengeTTLSeconds + 1,
        async () => {
          verifierCalls += 1;
          return verifiedRegistration;
        },
      ),
    ).rejects.toMatchObject({ code: "challenge_expired" });
    expect(verifierCalls).toBe(0);
  });
});
