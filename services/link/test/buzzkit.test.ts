import { afterEach, describe, expect, it, vi } from "vitest";
import { buzzKitIdentity, readBuzzKitReadiness, sendBuzzKitLinkWake as sendWakeWithSource, sendBuzzKitLiveActivity, sendBuzzKitTestNotification, sendBuzzKitRichNotification, sendBuzzKitSealedNotification } from "../src/buzzkit.js";

const environment = () => ({
  BUZZKIT_API_KEY: `bk_tn_${crypto.randomUUID()}`,
  BUZZKIT_IDENTITY_SECRET: crypto.randomUUID(),
  BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
});

function sendBuzzKitLinkWake(
  env: ReturnType<typeof wakeEnvironment>,
  accountCoordinate: string,
  frameId: string,
) {
  return sendWakeWithSource(env, accountCoordinate, frameId, {
    hostDeviceId: "source-host-fixture",
    authorizationEpoch: 1,
    authorizeEgress: () => {},
  });
}

function wakeEnvironment(
  ownerCoordinates: string | string[] | null = "notification-fixture-coordinate",
) {
  const recipients = ownerCoordinates === null
    ? [] : (Array.isArray(ownerCoordinates) ? ownerCoordinates : [ownerCoordinates]);
  const expiresAt = Math.floor(Date.now() / 1_000) + 300;
  return {
    ...environment(),
    ACCOUNTS: {
      prepare: () => ({
        bind: () => ({
          all: async () => ({
            results: recipients.map((owner_coordinate, index) => ({
              owner_coordinate,
              installation_id: `installation-fixture-${index}`,
              installation_authorization_epoch: 1,
              grant_id: `wake-grant-fixture-${index}`,
              grant_revision: 1,
              grant_expires_at: expiresAt,
            })),
          }),
        }),
      }),
    } as unknown as D1Database,
    USER_LINKS: {
      getByName: () => ({ authorizeNotificationEgress: async () => {} }),
    },
  };
}
afterEach(() => { vi.unstubAllGlobals(); });

function provider() {
  const calls: Array<{ url: string; init: RequestInit; body: Record<string, unknown> | null }> = [];
  vi.stubGlobal("fetch", vi.fn(async (url: string | URL, init: RequestInit = {}) => {
    calls.push({ url: String(url), init, body: init.body ? JSON.parse(String(init.body)) as Record<string, unknown> : null });
    return Response.json({ success: true, data: { id: "msg_fixture", status: "queued", counts: { total: 1, sent: 0, delivered: 0 } } });
  }));
  return calls;
}

describe("BuzzKit notification provider replaces relay enrollment", () => {
  it("retires account proof issuance for the whole cutover generation while installation identity works", async () => {
    const current = environment();
    const { BUZZKIT_IDENTITY_SECRET_GENERATION: _, ...unversioned } = current;

    await expect(buzzKitIdentity(unversioned, "account-a")).rejects.toMatchObject({
      status: 503,
      code: "buzzkit_identity_generation_unconfigured",
    });
    await expect(buzzKitIdentity({
      ...unversioned,
      BUZZKIT_IDENTITY_SECRET_GENERATION: "legacy-account-v1",
    }, "account-a")).rejects.toMatchObject({
      status: 503,
      code: "buzzkit_identity_generation_unconfigured",
    });
    const transport = vi.fn();
    vi.stubGlobal("fetch", transport);
    await expect(sendBuzzKitLiveActivity(unversioned, {
      externalId: "notify_fixture",
      activityId: "activity_fixture",
      event: "end",
      contentState: { phase: "completed" },
      timestamp: 1_800_000_000,
    }, async () => {})).rejects.toMatchObject({
      status: 503,
      code: "buzzkit_identity_generation_unconfigured",
    });
    expect(transport).not.toHaveBeenCalled();

    await expect(buzzKitIdentity(current, "account-a", "account")).rejects.toMatchObject({
      status: 410,
      code: "buzzkit_account_identity_retired",
    });
    await expect(buzzKitIdentity(current, "notification-a", "notification-instance")).resolves.toMatchObject({
      externalId: expect.stringMatching(/^notify_/),
      identityHash: expect.stringMatching(/^[0-9a-f]{64}$/),
    });
  });

  it.each([
    { endpoint: "a".repeat(64), status: "active", matched: true, active: true },
    { endpoint: "b".repeat(64), status: "active", matched: false, active: false },
    { endpoint: "a".repeat(64), status: undefined, matched: true, active: false },
    { endpoint: "a".repeat(64), status: "invalid", matched: true, active: false },
  ])("requires an exact active current-device subscription: $matched/$active/$status", async (fixture) => {
    const e = environment();
    const identity = await buzzKitIdentity(e, "notification-fixture", "notification-instance");
    const topics: Record<string, string> = {
      "chat-replies-completions": "Chat replies and completions",
      "scheduled-tasks-deliveries": "Scheduled tasks and deliveries",
      "questions-approvals": "Questions and Approvals",
      "subagent-completions": "Subagent Completions",
    };
    vi.stubGlobal("fetch", vi.fn(async (url: string | URL) => {
      const path = new URL(url).pathname;
      const data = path === "/v1/credentials"
        ? { items: [{ channel: "push", provider: "apns", environment: "production", status: "active" }] }
        : path.startsWith("/v1/subscribers/")
          ? { externalId: identity.externalId, verified: true, subscriptions: [{ id: "subscription-fixture", channel: "push", platform: "ios", environment: "production", endpoint: fixture.endpoint, status: fixture.status, enabled: true }] }
          : { slug: path.split("/").at(-1), name: topics[path.split("/").at(-1)!], channels: ["push"] };
      return Response.json({ success: true, data });
    }));
    const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("a".repeat(64)))), (b) => b.toString(16).padStart(2, "0")).join("");
    const readiness = await readBuzzKitReadiness(e, "notification-fixture", "notification-instance", { tokenHash: hash, environment: "production" });
    expect(readiness.subscriber.currentDevice).toMatchObject({ matched: fixture.matched, active: fixture.active });
    expect(readiness.topicSlugs).toEqual(Object.keys(topics));
  });

  it("treats BuzzKit's omitted production environment as production during exact device readback", async () => {
    const e = environment();
    const identity = await buzzKitIdentity(e, "notification-production", "notification-instance");
    const token = "c".repeat(64);
    const topics = new Map([
      ["chat-replies-completions", "Chat replies and completions"],
      ["scheduled-tasks-deliveries", "Scheduled tasks and deliveries"],
      ["questions-approvals", "Questions and Approvals"],
      ["subagent-completions", "Subagent Completions"],
    ]);
    vi.stubGlobal("fetch", vi.fn(async (url: string | URL) => {
      const path = new URL(url).pathname;
      const slug = path.split("/").at(-1)!;
      const data = path === "/v1/credentials"
        ? { items: [{ channel: "push", provider: "apns", environment: null, status: "active" }] }
        : path.startsWith("/v1/subscribers/")
          ? { externalId: identity.externalId, verified: true, subscriptions: [{
              id: "subscription-production", channel: "push", platform: "ios",
              environment: null, endpoint: token, status: "active", enabled: true,
            }] }
          : { slug, name: topics.get(slug), channels: ["push"] };
      return Response.json({ success: true, data });
    }));
    const tokenHash = Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token))),
      (byte) => byte.toString(16).padStart(2, "0"),
    ).join("");

    const readiness = await readBuzzKitReadiness(
      e, "notification-production", "notification-instance",
      { tokenHash, environment: "production" },
    );

    expect(readiness.subscriber.activeIOSPushEnvironments).toEqual(["production"]);
    expect(readiness.subscriber.currentDevice).toEqual({
      matched: true, environment: "production", enabled: true, active: true,
      subscriptionId: "subscription-production",
    });
  });
  it("derives a stable installation subscriber and distinct installation identities", async () => {
    const env = environment();
    expect(await buzzKitIdentity(env, "notification-a", "notification-instance"))
      .toEqual(await buzzKitIdentity(env, "notification-a", "notification-instance"));
    expect((await buzzKitIdentity(env, "notification-b", "notification-instance")).externalId)
      .not.toEqual((await buzzKitIdentity(env, "notification-a", "notification-instance")).externalId);
  });

  it("sends only a silent wake hint and reads the accepted message back", async () => {
    const calls = provider();
    const env = wakeEnvironment();
    const result = await sendBuzzKitLinkWake(env, "account-a", "frame_fixture_0001");
    expect(result).toHaveLength(1);
    expect(result[0]).toMatchObject({ status: "accepted", deliveryId: "msg_fixture", providerStatus: "queued" });
    expect(calls.map((call) => call.init.method)).toEqual(["POST", "GET"]);
    expect(calls[0]?.body?.data).toEqual({ loopdy_link: { version: 2, type: "wake", frameId: "frame_fixture_0001" } });
    expect(calls[0]?.body).not.toHaveProperty("title");
    expect(calls[0]?.body).not.toHaveProperty("deviceId");
    expect(calls[0]?.init.redirect).toBe("manual");
    expect(JSON.stringify(calls[0]?.body)).not.toContain("account-a");
    expect(calls[0]?.body?.to).toBe(
      (await buzzKitIdentity(env, "notification-fixture-coordinate", "notification-instance")).externalId,
    );
  });

  it.each(["completed", "canceled"] as const)(
    "rejects a terminal %s wake readback with no recipients as retryable",
    async (providerStatus) => {
      const calls: string[] = [];
      vi.stubGlobal("fetch", vi.fn(async (url: string | URL, init: RequestInit = {}) => {
        calls.push(`${init.method} ${new URL(url).pathname}`);
        return Response.json({ success: true, data: {
          id: "msg_zero_recipient", status: init.method === "POST" ? "queued" : providerStatus,
          counts: { total: 0, sent: 0, delivered: 0, failed: 0, invalid: 0 },
        } });
      }));

      await expect(sendBuzzKitLinkWake(
        wakeEnvironment(), "account-a", "frame_fixture_0001",
      )).rejects.toMatchObject({
        status: 503,
        code: "buzzkit_wake_zero_recipients",
      });
      expect(calls).toEqual([
        "POST /v1/messages",
        "GET /v1/messages/msg_zero_recipient",
      ]);
    },
  );

  it.each(["queued", "processing"] as const)(
    "preserves an accepted %s wake while recipient fan-out is unsettled",
    async (providerStatus) => {
      vi.stubGlobal("fetch", vi.fn(async (_url: string | URL, init: RequestInit = {}) =>
        Response.json({ success: true, data: {
          id: "msg_unsettled", status: init.method === "POST" ? "queued" : providerStatus,
          counts: { total: 0, sent: 0, delivered: 0 },
        } })));

      await expect(sendBuzzKitLinkWake(
        wakeEnvironment(), "account-a", "frame_fixture_0001",
      )).resolves.toEqual([expect.objectContaining({
        deliveryId: "msg_unsettled",
        providerStatus,
        counts: expect.objectContaining({ total: 0 }),
      })]);
    },
  );

  it("attempts every bound installation before reporting a zero-recipient retry", async () => {
    const calls: string[] = [];
    let messages = 0;
    vi.stubGlobal("fetch", vi.fn(async (url: string | URL, init: RequestInit = {}) => {
      const path = new URL(url).pathname;
      calls.push(`${init.method} ${path}`);
      if (init.method === "POST") {
        messages += 1;
        return Response.json({ success: true, data: {
          id: `msg_fanout_${messages}`, status: "queued", counts: { total: 0 },
        } });
      }
      const accepted = path.endsWith("msg_fanout_2");
      return Response.json({ success: true, data: {
        id: accepted ? "msg_fanout_2" : "msg_fanout_1",
        status: accepted ? "completed" : "canceled",
        counts: accepted ? { total: 1, sent: 1 } : { total: 0, sent: 0 },
      } });
    }));

    await expect(sendBuzzKitLinkWake(
      wakeEnvironment(["notification-coordinate-a", "notification-coordinate-b"]),
      "account-a",
      "frame_fixture_0001",
    )).rejects.toMatchObject({ status: 503, code: "buzzkit_wake_zero_recipients" });
    expect(calls).toEqual([
      "POST /v1/messages",
      "GET /v1/messages/msg_fanout_1",
      "POST /v1/messages",
      "GET /v1/messages/msg_fanout_2",
    ]);
  });

  it("scopes identical wake IDs to the authenticated account", async () => {
    const calls = provider();
    await sendBuzzKitLinkWake(wakeEnvironment("notification-coordinate-a"), "account-a", "frame_fixture_0001");
    await sendBuzzKitLinkWake(wakeEnvironment("notification-coordinate-b"), "account-b", "frame_fixture_0001");
    expect(new Headers(calls[0]?.init.headers).get("Idempotency-Key"))
      .not.toEqual(new Headers(calls[2]?.init.headers).get("Idempotency-Key"));
  });

  it("fails closed when no installation-scoped wake recipient belongs to the account", async () => {
    const transport = vi.fn();
    vi.stubGlobal("fetch", transport);
    const env = wakeEnvironment(null);

    await expect(sendBuzzKitLinkWake(env, "account-a", "frame_fixture_0001"))
      .rejects.toMatchObject({ status: 503, code: "link_wake_recipient_unavailable" });
    expect(transport).not.toHaveBeenCalled();
  });

  it("returns test acceptance rather than claiming device delivery", async () => {
    const calls = provider();
    const result = await sendBuzzKitTestNotification(
      environment(), "notification-a", crypto.randomUUID(), "notification-instance",
      async () => {},
    );
    expect(result.state).toBe("accepted");
    expect(calls[0]?.body?.title).toBe("Loopdy test notification");
    expect(calls).toHaveLength(2);
  });

  it("carries actual agent content and an authorized avatar URL", async () => {
    const calls = provider();
    const avatar = { url: "https://link.loopdy.app/v1/notifications/buzzkit/assets/fixture.png?expires=1800001000&capability=fixture", mimeType: "image/png" as const, sha256: "a".repeat(64) };
    await sendBuzzKitRichNotification(environment(), "notification-a", {
      eventId: "event_fixture", eventType: "session.completed", grantId: "grant_fixture",
      profile: "default", sessionReference: "A".repeat(43), turnId: "turn_fixture", occurredAt: 1_800_000_000,
      agent: { id: "default", name: "Fixture Agent", avatar: { mimeType: "image/png", sha256: avatar.sha256, data: "fixture-only" } },
      content: { kind: "reply", text: "The requested work is complete." }, sound: true,
    }, avatar, "notification-instance", async () => {});
    expect(calls[0]?.body).toMatchObject({ title: "Fixture Agent", body: "The requested work is complete.",
      imageUrl: avatar.url, topic: "chat-replies-completions" });
  });

  it("forwards a sealed alert with only a placeholder and still fits one push", async () => {
    const calls = provider();
    const grantId = crypto.randomUUID();
    const eventId = `${grantId}:${"b".repeat(64)}`;
    const account = btoa("C".repeat(43)).replace(/=+$/, "");
    const avatar = {
      url: `https://link.loopdy.app/v1/notifications/buzzkit/assets/${account}/${"D".repeat(43)}.bin?expires=1800001200&capability=${"E".repeat(43)}`,
      mimeType: "application/octet-stream" as const, sha256: "a".repeat(64),
    };
    const sealed: Record<string, unknown> = {
      v: 2, grantId, eventId, recipientKeyId: "R".repeat(43), senderKeyId: "S".repeat(43), issued: 1_800_000_000,
      ephemeralPublicKey: "P".repeat(87), salt: "s".repeat(43), nonce: "n".repeat(16), ciphertext: "",
      tag: "t".repeat(22), signature: "g".repeat(86),
    };
    // The largest envelope the plugin and this service accept.
    sealed.ciphertext = "c".repeat(2_300 - JSON.stringify(sealed).length);
    expect(JSON.stringify(sealed).length).toBe(2_300);
    await sendBuzzKitSealedNotification(environment(), "notification-a", {
      eventId, eventType: "clarification.required", grantId, profile: "a-long-profile-name-for-budget",
      sessionReference: "A".repeat(43), sealed,
      avatar: { mimeType: "application/octet-stream", sha256: avatar.sha256, data: "fixture-only" }, sound: true,
    }, avatar, "notification-instance", async () => {});
    const body = calls[0]?.body;
    expect(body).toMatchObject({ title: "bighelp", body: "Your agent has a question", topic: "questions-approvals",
      data: { loopdy: { version: 2, eventId, eventType: "clarification.required", grantId, sessionReference: "A".repeat(43),
        sealed, avatar: { url: avatar.url } } } });
    expect(body).not.toHaveProperty("imageUrl");
  });

  it.each([
    ["session.completed", "reply", "chat-replies-completions"],
    ["scheduled.completed", "scheduled", "scheduled-tasks-deliveries"],
    ["clarification.required", "clarification", "questions-approvals"],
    ["subagent.completed", "subagent", "subagent-completions"],
  ] as const)("routes %s through its exact preference topic", async (eventType, kind, topic) => {
    const calls = provider();
    const avatar = { url: "https://link.loopdy.app/v1/notifications/buzzkit/assets/fixture.png?expires=1800001000&capability=fixture", mimeType: "image/png" as const, sha256: "a".repeat(64) };
    await sendBuzzKitRichNotification(environment(), "notification-a", {
      eventId: `event_${eventType}`, eventType, grantId: "grant_fixture",
      profile: "default", sessionReference: "A".repeat(43), turnId: "turn_fixture", occurredAt: 1_800_000_000,
      agent: { id: "default", name: "Fixture Agent", avatar: { mimeType: "image/png", sha256: avatar.sha256, data: "fixture-only" } },
      content: { kind, text: "The requested fixture event is ready." }, sound: true,
    }, avatar, "notification-instance", async () => {});
    expect(calls[0]?.body?.topic).toBe(topic);
  });

  it.each(["update", "end"] as const)("produces a validated Live Activity %s request", async (event) => {
    const calls: Array<Record<string, unknown>> = [];
    vi.stubGlobal("fetch", vi.fn(async (_url: string | URL, init: RequestInit = {}) => {
      calls.push(JSON.parse(String(init.body)) as Record<string, unknown>);
      return Response.json({ success: true, data: { results: [{ id: "activity-token-1", ok: true }] } });
    }));

    const result = await sendBuzzKitLiveActivity(environment(), {
      externalId: "notify_fixture", activityId: "activity_fixture", event,
      contentState: { phase: event === "end" ? "completed" : "using_tool" },
      timestamp: 1_800_000_000,
      staleDate: "2027-01-15T08:02:00.000Z",
      ...(event === "end" ? { dismissalDate: "2027-01-15T08:02:30.000Z" } : {}),
    }, async () => {});

    expect(result).toEqual({ status: "accepted", deliveryId: "activity-token-1" });
    expect(calls).toEqual([expect.objectContaining({
      to: "notify_fixture", activityId: "activity_fixture", event,
      contentState: { phase: event === "end" ? "completed" : "using_tool" },
      timestamp: 1_800_000_000, priority: "high",
    })]);
  });
});
