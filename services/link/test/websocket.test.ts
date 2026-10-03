import { env, evictDurableObject, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { canonicalDeviceRequest, DEVICE_AUTH_HEADERS } from "../src/device-auth.js";
import worker from "../src/index.js";
import type { LinkEnv, UserLink } from "../src/user-link.js";
import { PendingDeliveryStore } from "../src/pending-delivery.js";

let ACCOUNT = "account-websocket-fixture-coordinate";
const NOW = Math.floor(Date.now() / 1_000);

describe("hibernating account sockets", () => {
  beforeEach(async () => {
    // This Workers pool preserves Durable Object instances across cases. Give
    // each test its own account rather than letting old recipients consume quota.
    ACCOUNT = `account-websocket-${crypto.randomUUID()}`;
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("DELETE FROM device_nonces"),
      env.ACCOUNTS.prepare("DELETE FROM device_directory"),
      env.ACCOUNTS.prepare("DELETE FROM access_sessions"),
      env.ACCOUNTS.prepare("DELETE FROM passkeys"),
      env.ACCOUNTS.prepare("DELETE FROM auth_challenges"),
      env.ACCOUNTS.prepare("DELETE FROM accounts"),
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts (account_coordinate, status, authorization_epoch, created_at) VALUES (?, 'active', 1, ?)",
      ).bind(ACCOUNT, NOW),
    ]);
  });

  it("keeps offline state-backed presentation out of storage while preserving a legacy copy", async () => {
    const phone = await registerDevice("state-offline", "mobile", "phone");
    await registerDevice("state-legacy", "mobile", "phone");
    const hostKeys = await registerDevice("state-host", "host", "hermes_host");
    const mobile = await connectBuffered("state-offline", phone.privateKey, 4001, true, false, true);
    expect(mobile.ready.capabilities).toContain("state-backed-presentation-v1");
    expect(await mobile.next()).toMatchObject({type: "presentation.reset", reason: "reconnect"});
    await mobile.dispose();
    const host = await connectBuffered("state-host", hostKeys.privateKey, 4002, true, false, true);
    try {
      for (let sequence = 1; sequence <= 40; sequence++) {
        const frame = {...durableFixtureFrame("state-host", sequence, "state"), deliveryClass: "presentation"};
        host.socket.send(JSON.stringify(frame));
        expect(await host.next()).toMatchObject({type: "accepted", sequence});
      }
      const pending = await runInDurableObject<UserLink, Array<{recipient_device_id:string; encoded_frame:string}>>(env.USER_LINKS.getByName(ACCOUNT), (_instance, state) =>
        state.storage.sql.exec<{recipient_device_id:string; encoded_frame:string}>("SELECT recipient_device_id,encoded_frame FROM pending_frames").toArray());
      expect(pending).toHaveLength(40);
      expect(pending.every(row => row.recipient_device_id === "state-legacy")).toBe(true);
      expect(pending.every(row => JSON.parse(row.encoded_frame).deliveryClass === undefined)).toBe(true);
    } finally { await host.dispose(); }
  });

  it("isolates a stalled state-backed recipient and preserves reliable replay after transient delivery", async () => {
    const slowKeys = await registerDevice("state-slow", "mobile", "phone");
    const fastKeys = await registerDevice("state-fast", "mobile", "phone");
    const hostKeys = await registerDevice("state-stream-host", "host", "hermes_host");
    const slow = await connectBuffered("state-slow", slowKeys.privateKey, 4011, true, false, true);
    const fast = await connectBuffered("state-fast", fastKeys.privateKey, 4012, true, false, true);
    const host = await connectBuffered("state-stream-host", hostKeys.privateKey, 4013, true, false, true);
    try {
      expect(await slow.next()).toMatchObject({type:"presentation.reset"});
      expect(await fast.next()).toMatchObject({type:"presentation.reset"});
      const closed = nextClose(slow.socket);
      for (let sequence=1; sequence<=34; sequence++) {
        const frame = {...durableFixtureFrame("state-stream-host", sequence, "live"),deliveryClass:"presentation"};
        host.socket.send(JSON.stringify(frame));
        expect(await host.next()).toMatchObject({type:"accepted",sequence});
        expect(await fast.next()).toEqual(frame);
        fast.socket.send(JSON.stringify({version:1,type:"receipt",deviceId:"state-fast",sourceDeviceId:"state-stream-host",frameId:frame.id,sequence}));
        expect(await fast.next()).toMatchObject({type:"receipt.accepted"});
        if (sequence <= 32) expect(await slow.next()).toEqual(frame);
      }
      expect(await slow.next()).toMatchObject({type:"presentation.reset",reason:"overflow"});
      expect(await closed).toMatchObject({code:4005});
      const reliable = durableFixtureFrame("state-stream-host", 35, "reliable");
      host.socket.send(JSON.stringify(reliable));
      expect(await host.next()).toMatchObject({type:"accepted",sequence:35});
      expect(await fast.next()).toEqual(reliable);
      const saved = await runInDurableObject<UserLink, number>(env.USER_LINKS.getByName(ACCOUNT), (_instance,state) =>
        state.storage.sql.exec<{n:number}>("SELECT COUNT(*) AS n FROM pending_frames WHERE frame_id=?",reliable.id).one().n);
      expect(saved).toBe(2);
    } finally { await slow.dispose(); await fast.dispose(); await host.dispose(); }
  });

  it("clears a same-epoch opt-in on legacy reconnect and never reclassifies retained backlog", async () => {
    const phoneKeys=await registerDevice("state-downgrade", "mobile", "phone");
    const hostKeys=await registerDevice("state-downgrade-host", "host", "hermes_host");
    const first=await connectBuffered("state-downgrade",phoneKeys.privateKey,4021,true,false,true);
    expect(await first.next()).toMatchObject({type:"presentation.reset"});
    await first.dispose();
    const legacy=await connectBuffered("state-downgrade",phoneKeys.privateKey,4022);
    const host=await connectBuffered("state-downgrade-host",hostKeys.privateKey,4023,true,false,true);
    try {
      const frame={...durableFixtureFrame("state-downgrade-host",1,"downgraded"),deliveryClass:"presentation"};
      host.socket.send(JSON.stringify(frame));
      expect(await host.next()).toMatchObject({type:"accepted"});
      const {deliveryClass,...durable}=frame;
      expect(await legacy.next()).toEqual(durable);
      await evictDurableObject(env.USER_LINKS.getByName(ACCOUNT));
      const rows=await runInDurableObject<UserLink,Array<{encoded_frame:string}>>(env.USER_LINKS.getByName(ACCOUNT),(_instance,state)=>
        state.storage.sql.exec<{encoded_frame:string}>("SELECT encoded_frame FROM pending_frames WHERE frame_id=?",frame.id).toArray());
      expect(rows).toHaveLength(1);
      expect(JSON.parse(rows[0]!.encoded_frame)).toEqual(durable);
    } finally { await legacy.dispose(); await host.dispose(); }
  });

  it.each(["mobile", "unnegotiated-host"])("refuses presentation classification from %s before admission", async (role) => {
    const phoneKeys=await registerDevice("state-refusal-phone","mobile","phone");
    const hostKeys=await registerDevice("state-refusal-host","host","hermes_host");
    const isPhone=role==="mobile";
    const id=isPhone ? "state-refusal-phone" : "state-refusal-host";
    const sender=await connectBuffered(id,isPhone?phoneKeys.privateKey:hostKeys.privateKey,4031,true,false,isPhone);
    try {
      if(isPhone) expect(await sender.next()).toMatchObject({type:"presentation.reset"});
      const closed=nextClose(sender.socket);
      sender.socket.send(JSON.stringify({...durableFixtureFrame(id,1,"refusal"),deliveryClass:"presentation"}));
      await closed;
      const count=await runInDurableObject<UserLink,number>(env.USER_LINKS.getByName(ACCOUNT),(_instance,state)=>
        state.storage.sql.exec<{n:number}>("SELECT COUNT(*) AS n FROM frame_ids").one().n);
      expect(count).toBe(0);
    } finally { await sender.dispose(); }
  });

  it("routes a directed frame only to the named phone and keeps other phones out of its backlog", async () => {
    const phone = await registerDevice("direct-phone-a", "mobile", "phone");
    await registerDevice("direct-phone-b", "mobile", "phone");
    const host = await registerDevice("direct-host-a", "host", "hermes_host");
    const sender = await connectBuffered("direct-host-a", host.privateKey, 2901, true, true);
    const target = await connectBuffered("direct-phone-a", phone.privateKey, 2902);
    try {
      expect(sender.ready.capabilities).toContain("directed-frames-v1");
      const frame = { ...durableFixtureFrame("direct-host-a", 1, "directed"), targetDeviceId: "direct-phone-a" };
      sender.socket.send(JSON.stringify(frame));
      expect(await sender.next()).toMatchObject({ type: "accepted", id: frame.id });
      const delivered = await target.next();
      const recipients = await runInDurableObject<UserLink, string[]>(env.USER_LINKS.getByName(ACCOUNT), (_instance, state) =>
        state.storage.sql.exec<{ recipient_device_id: string }>("SELECT recipient_device_id FROM pending_frames WHERE frame_id = ?", frame.id)
          .toArray().map((row) => row.recipient_device_id));
      expect(recipients).toEqual(["direct-phone-a"]);
      expect(delivered).toEqual(frame);
    } finally { await target.dispose(); await sender.dispose(); }
  });

  it("routes a directed phone result only to its selected host", async () => {
    const phone = await registerDevice("result-phone", "mobile", "phone");
    const host = await registerDevice("result-host-a", "host", "hermes_host");
    await registerDevice("result-host-b", "host", "hermes_host");
    const sender = await connectBuffered("result-phone", phone.privateKey, 2911, true, true);
    const target = await connectBuffered("result-host-a", host.privateKey, 2912);
    try {
      const frame = { ...durableFixtureFrame("result-phone", 1, "result-directed"), targetDeviceId: "result-host-a" };
      sender.socket.send(JSON.stringify(frame));
      expect(await sender.next()).toMatchObject({ type: "accepted", id: frame.id });
      const delivered = await target.next();
      const recipients = await runInDurableObject<UserLink, string[]>(env.USER_LINKS.getByName(ACCOUNT), (_instance, state) =>
        state.storage.sql.exec<{ recipient_device_id: string }>("SELECT recipient_device_id FROM pending_frames WHERE frame_id = ?", frame.id)
          .toArray().map((row) => row.recipient_device_id));
      expect(recipients).toEqual(["result-host-a"]);
      expect(delivered).toEqual(frame);
    } finally { await target.dispose(); await sender.dispose(); }
  });

  it.each(["unpaired-target", "refuse-host", "refuse-phone-revoked"])("rejects directed delivery to %s without accepting or broadcasting it", async (targetDeviceId) => {
    await registerDevice("refuse-phone", "mobile", "phone");
    await registerDevice("refuse-phone-revoked", "mobile", "phone");
    const host = await registerDevice("refuse-host", "host", "hermes_host");
    const stub = env.USER_LINKS.getByName(ACCOUNT);
    await stub.revokeDevice({ deviceId: "refuse-phone-revoked", expectedRevision: 1, revokedAt: NOW });
    const sender = await connectBuffered("refuse-host", host.privateKey, 2921, true, true);
    try {
      const closed = nextClose(sender.socket);
      sender.socket.send(JSON.stringify({ ...durableFixtureFrame("refuse-host", 1, "refuse-directed"), targetDeviceId }));
      expect(await closed).toMatchObject({ reason: "frame rejected" });
      const counts = await runInDurableObject<UserLink, number[]>(stub, (_instance, state) => [
        state.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM pending_frames").one().n,
        state.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM frame_ids").one().n,
      ]);
      expect(counts).toEqual([0, 0]);
    } finally { await sender.dispose(); }
  });

  it("requires explicit directed-delivery negotiation instead of falling back to broadcast", async () => {
    await registerDevice("legacy-target", "mobile", "phone");
    const host = await registerDevice("legacy-host", "host", "hermes_host");
    const sender = await connectBuffered("legacy-host", host.privateKey, 2931);
    try {
      expect(sender.ready.capabilities).not.toContain("directed-frames-v1");
      const closed = nextClose(sender.socket);
      sender.socket.send(JSON.stringify({ ...durableFixtureFrame("legacy-host", 1, "legacy-directed"), targetDeviceId: "legacy-target" }));
      expect(await closed).toMatchObject({ reason: "frame rejected" });
      expect(await runInDurableObject<UserLink, number>(env.USER_LINKS.getByName(ACCOUNT), (_instance, state) =>
        state.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM pending_frames").one().n)).toBe(0);
    } finally { await sender.dispose(); }
  });

  it("isolates a saturated recipient without deleting accepted backlog", async () => {
    await registerDevice("mobile-overflow-offline", "mobile", "phone");
    const mobileKeys = await registerDevice("mobile-overflow-online", "mobile", "phone");
    const hostKeys = await registerDevice("host-overflow", "host", "hermes_host");
    const stub = env.USER_LINKS.getByName(ACCOUNT);
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      state.storage.sql.exec(`WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 4096)
        INSERT INTO pending_frames (recipient_device_id, sender_device_id, frame_id, sequence, encoded_frame, created_at)
        SELECT 'mobile-overflow-offline', 'host-overflow', 'retained-overflow-' || x, x, 'encrypted-fixture', 1 FROM n`);
      state.storage.sql.exec("UPDATE devices SET last_inbound_sequence = 4096 WHERE device_id = 'host-overflow'");
    });
    const host = await connectBuffered("host-overflow", hostKeys.privateKey, 1701);
    const mobile = await connectBuffered("mobile-overflow-online", mobileKeys.privateKey, 1702);
    try {
      const frame = durableFixtureFrame("host-overflow", 4097, "overflow");
      host.socket.send(JSON.stringify(frame));
      expect(await host.next()).toMatchObject({ type: "accepted", id: frame.id, sequence: 4097 });
      expect(await mobile.next()).toEqual(frame);
      expect(await runInDurableObject<UserLink, number>(stub, (_instance, state) =>
        state.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM pending_frames WHERE recipient_device_id = 'mobile-overflow-offline'").one().n,
      )).toBe(4096);
    } finally {
      await mobile.dispose();
      await host.dispose();
    }
  });

  it("reserves fresh encrypted catalog replies for a returning full recipient and replays old frames first", async () => {
    const returningKeys = await registerDevice("mobile-returning", "mobile", "phone");
    await registerDevice("mobile-return-healthy", "mobile", "phone");
    const hostKeys = await registerDevice("host-returning", "host", "hermes_host");
    const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]) as CryptoKey;
    const seal = async (payload: unknown) => {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv,
        additionalData: new TextEncoder().encode("loopdy-link-frame-v1") }, key,
      new TextEncoder().encode(JSON.stringify(payload))));
      const combined = new Uint8Array(iv.length + encrypted.length);
      combined.set(iv); combined.set(encrypted, iv.length);
      return base64url(combined);
    };
    const open = async (ciphertext: string) => {
      const raw = Uint8Array.from(atob(ciphertext.replaceAll("-", "+").replaceAll("_", "/")), c => c.charCodeAt(0));
      return JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: raw.slice(0, 12),
        additionalData: new TextEncoder().encode("loopdy-link-frame-v1") }, key, raw.slice(12))));
    };
    const oldCiphertext = await seal({ type: "fixture.accepted.backlog", retained: true });
    const stub = env.USER_LINKS.getByName(ACCOUNT);
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      state.storage.transactionSync(() => {
        for (let sequence = 1; sequence <= 4096; sequence++) {
          const frame = { ...durableFixtureFrame("host-returning", sequence, "return-old"), ciphertext: oldCiphertext };
          state.storage.sql.exec("INSERT INTO pending_frames (recipient_device_id, sender_device_id, frame_id, sequence, encoded_frame, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            "mobile-returning", frame.senderDeviceId, frame.id, sequence, JSON.stringify(frame), NOW);
        }
        state.storage.sql.exec("UPDATE devices SET last_inbound_sequence = 4096 WHERE device_id = 'host-returning'");
      });
    });
    const host = await connectBuffered("host-returning", hostKeys.privateKey, 1711);
    let returning: Awaited<ReturnType<typeof connectBuffered>> | undefined;
    try {
      const skipped = durableFixtureFrame("host-returning", 4097, "return-skip");
      host.socket.send(JSON.stringify(skipped));
      expect(await host.next()).toMatchObject({ type: "accepted", id: skipped.id });
      returning = await connectBuffered("mobile-returning", returningKeys.privateKey, 1712);
      const requestPayload = { version: 1, type: "workspace.request", requestId: "catalog-return-fixture", operation: "sessions.list", payload: {} };
      const request = { ...durableFixtureFrame("mobile-returning", 1, "catalog-request"), ciphertext: await seal(requestPayload) };
      returning.socket.send(JSON.stringify(request));
      const deliveredRequest = await host.next();
      expect(deliveredRequest).toEqual(request);
      expect(await open(String(deliveredRequest.ciphertext))).toEqual(requestPayload);
      const responsePayload = { version: 1, type: "workspace.result", requestId: requestPayload.requestId, operation: "sessions.list", payload: { sessions: [{ id: "fresh-session-fixture" }] } };
      const reply = { ...durableFixtureFrame("host-returning", 4098, "catalog-reply"), ciphertext: await seal(responsePayload) };
      host.socket.send(JSON.stringify(reply));
      expect(await host.next()).toMatchObject({ type: "accepted", id: reply.id });
      let priorSequence = 0;
      let retainedCount = 0;
      for (;;) {
        const value = await returning.next();
        if (value.type !== "frame") continue;
        expect(Number(value.sequence)).toBeGreaterThan(priorSequence);
        priorSequence = Number(value.sequence);
        if (value.id === reply.id) {
          expect(retainedCount).toBe(4096);
          expect(await open(String(value.ciphertext))).toEqual(responsePayload);
          break;
        }
        expect(value.ciphertext).toBe(oldCiphertext);
        expect(value.sequence).toBe(++retainedCount);
        returning.socket.send(JSON.stringify({ version: 1, type: "receipt", deviceId: "mobile-returning",
          frameId: value.id, sourceDeviceId: "host-returning", sequence: value.sequence }));
      }
    } finally {
      await returning?.dispose();
      await host.dispose();
    }
  }, 30_000);

  it("admits new traffic above the former frame cap only with bounded recovery headroom", async () => {
    const stub = env.USER_LINKS.getByName(ACCOUNT);
    const result = await runInDurableObject<UserLink, boolean[]>(stub, (_instance, state) => {
      state.storage.sql.exec(`WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 4096)
        INSERT INTO pending_frames (recipient_device_id, sender_device_id, frame_id, sequence, encoded_frame, created_at)
        SELECT 'offline-tablet', 'host', 'retained-frame-' || x, x, 'encrypted-fixture', 1 FROM n`);
      const ordinary = new PendingDeliveryStore(state.storage);
      const recovery = new PendingDeliveryStore(state.storage, { frames: 65536, bytes: 536870912 });
      return [ordinary.canRetain("new-frame", 1), recovery.canRetain("new-frame", 1)];
    });
    expect(result).toEqual([false, true]);
  });

  it("drains more than one durable replay page in order without reconnecting", async () => {
    const mobileKeys = await registerDevice("mobile-durable-pages", "mobile", "phone");
    const hostKeys = await registerDevice("host-durable-pages", "host", "hermes_host");
    const host = await connectBuffered("host-durable-pages", hostKeys.privateKey, 701);
    let mobile: Awaited<ReturnType<typeof connectBuffered>> | undefined;
    try {
      for (let sequence = 1; sequence <= 514; sequence += 1) {
        const frame = durableFixtureFrame("host-durable-pages", sequence, "pages");
        host.socket.send(JSON.stringify(frame));
        expect(await host.next()).toMatchObject({ type: "accepted", id: frame.id, sequence });
      }
      const stub = env.USER_LINKS.getByName(ACCOUNT);
      await evictDurableObject(stub);
      mobile = await connectBuffered("mobile-durable-pages", mobileKeys.privateKey, 702);
      const received: number[] = [];
      while (received.length < 514) {
        const value = await mobile.next();
        if (value.type === "receipt.accepted") continue;
        expect(value.type).toBe("frame");
        received.push(Number(value.sequence));
        mobile.socket.send(JSON.stringify({
          version: 1, type: "receipt", deviceId: "mobile-durable-pages",
          frameId: value.id, sourceDeviceId: "host-durable-pages", sequence: value.sequence,
        }));
      }
      expect(received).toEqual(Array.from({ length: 514 }, (_, index) => index + 1));
      expect(new Set(received).size).toBe(514);
      expect(mobile.socket.readyState).toBe(WebSocket.OPEN);
      const finalID = durableFixtureFrame("host-durable-pages", 514, "pages").id;
      let finalReceiptAccepted = false;
      while (!finalReceiptAccepted) {
        const acknowledgement = await mobile.next();
        expect(acknowledgement.type).toBe("receipt.accepted");
        finalReceiptAccepted = acknowledgement.frameId === finalID;
      }
      expect(await runInDurableObject<UserLink, number>(stub, (_instance, state) =>
        state.storage.sql.exec<{ count: number }>(
          "SELECT COUNT(*) AS count FROM pending_frames WHERE recipient_device_id = ?",
          "mobile-durable-pages",
        ).one().count,
      )).toBe(0);
    } finally {
      await mobile?.dispose();
      await host.dispose();
    }
  }, 20_000);

  it("backpressures before accepting a full account and resumes the same frame after a receipt", async () => {
    const mobileKeys = await registerDevice("mobile-pressure-resume", "mobile", "phone");
    const hostKeys = await registerDevice("host-pressure-resume", "host", "hermes_host");
    const host = await connectBuffered("host-pressure-resume", hostKeys.privateKey, 703);
    let mobile: Awaited<ReturnType<typeof connectBuffered>> | undefined;
    try {
      for (let sequence = 1; sequence <= 4096; sequence += 1) {
        const frame = durableFixtureFrame("host-pressure-resume", sequence, "pressure");
        host.socket.send(JSON.stringify(frame));
        expect(await host.next()).toMatchObject({ type: "accepted", id: frame.id, sequence });
      }
      const pending = durableFixtureFrame("host-pressure-resume", 4097, "pressure");
      host.socket.send(JSON.stringify(pending));
      expect(await host.next()).toMatchObject({
        version: 1, type: "backpressure", id: pending.id, sequence: 4097,
        retryAfterMs: 1000, reason: "storage_limit",
      });
      expect(host.socket.readyState).toBe(WebSocket.OPEN);
      const stub = env.USER_LINKS.getByName(ACCOUNT);
      expect(await runInDurableObject<UserLink, number>(stub, (_instance, state) =>
        state.storage.sql.exec<{ last_inbound_sequence: number }>(
          "SELECT last_inbound_sequence FROM devices WHERE device_id = ?", "host-pressure-resume",
        ).one().last_inbound_sequence,
      )).toBe(4096);
      mobile = await connectBuffered("mobile-pressure-resume", mobileKeys.privateKey, 704);
      const first = await mobile.next();
      expect(first).toMatchObject({ type: "frame", sequence: 1 });
      mobile.socket.send(JSON.stringify({
        version: 1, type: "receipt", deviceId: "mobile-pressure-resume",
        frameId: first.id, sourceDeviceId: "host-pressure-resume", sequence: 1,
      }));
      let receiptAccepted = false;
      for (let index = 0; index < 514 && !receiptAccepted; index += 1) {
        const message = await mobile.next();
        receiptAccepted = message.type === "receipt.accepted" && message.frameId === first.id;
      }
      expect(receiptAccepted).toBe(true);
      host.socket.send(JSON.stringify(pending));
      expect(await host.next()).toMatchObject({ type: "accepted", id: pending.id, sequence: 4097 });
    } finally {
      await mobile?.dispose();
      await host.dispose();
    }
  }, 30_000);

  it("refuses an entirely byte-saturated recipient set and preserves legacy backpressure behavior", async () => {
    await registerDevice("mobile-byte-offline", "mobile", "phone");
    const hostKeys = await registerDevice("host-byte-modern", "host", "hermes_host");
    const legacyKeys = await registerDevice("host-byte-legacy", "host", "hermes_host");
    const stub = env.USER_LINKS.getByName(ACCOUNT);
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      const encoded = "A".repeat(1_800_000);
      state.storage.transactionSync(() => {
        for (let sequence = 1; sequence <= 38; sequence += 1) {
          state.storage.sql.exec(
            "INSERT INTO pending_frames (recipient_device_id, sender_device_id, frame_id, sequence, encoded_frame, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            "mobile-byte-offline", "host-byte-modern", `frame-byte-seed-${sequence}`, sequence, encoded, NOW,
          );
        }
        state.storage.sql.exec("UPDATE devices SET last_inbound_sequence = 38 WHERE device_id = ?", "host-byte-modern");
      });
    });
    const modern = await connectBuffered("host-byte-modern", hostKeys.privateKey, 705);
    let legacy: Awaited<ReturnType<typeof connectBuffered>> | undefined;
    try {
      legacy = await connectBuffered("host-byte-legacy", legacyKeys.privateKey, 706, false);
      const frame = { ...durableFixtureFrame("host-byte-modern", 39, "bytes"), ciphertext: "A".repeat(300_000) };
      modern.socket.send(JSON.stringify(frame));
      expect(await modern.next()).toMatchObject({ type: "backpressure", id: frame.id, sequence: 39 });
      expect(await runInDurableObject<UserLink, number>(stub, (_instance, state) =>
        state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM pending_frames WHERE frame_id = ?", frame.id).one().count,
      )).toBe(0);
      expect(await runInDurableObject<UserLink, number>(stub, (_instance, state) =>
        state.storage.sql.exec<{ last_inbound_sequence: number }>(
          "SELECT last_inbound_sequence FROM devices WHERE device_id = ?", "host-byte-modern",
        ).one().last_inbound_sequence,
      )).toBe(38);
      const closed = nextClose(legacy.socket);
      legacy.socket.send(JSON.stringify({ ...frame, id: "frame-byte-legacy-0001", senderDeviceId: "host-byte-legacy", sequence: 1 }));
      expect(await closed).toEqual({ code: 1013, reason: "storage limit" });
    } finally {
      await modern.dispose();
      await legacy?.dispose();
    }
  }, 20_000);

  it("rescues the original pending full fanout once across migration and lost acknowledgement", async () => {
    await registerDevice("mobile-rescue-old", "mobile", "phone");
    const hostKeys = await registerDevice("host-rescue", "host", "hermes_host");
    const stub = env.USER_LINKS.getByName(ACCOUNT);
    const old = durableFixtureFrame("host-rescue", 1, "rescue-debt");
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      state.storage.sql.exec("INSERT INTO pending_frames (recipient_device_id, sender_device_id, frame_id, sequence, encoded_frame, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        "mobile-rescue-old", old.senderDeviceId, old.id, old.sequence, JSON.stringify(old), NOW);
      state.storage.sql.exec("UPDATE devices SET last_inbound_sequence = 1 WHERE device_id = 'host-rescue'");
      // Reconstruct the pre-policy schema, retaining existing ciphertext/counters.
      state.storage.sql.exec(`DROP TRIGGER pending_recipient_update;
        DROP TRIGGER pending_delivery_insert; DROP TRIGGER pending_delivery_delete;
        DROP TABLE pending_recipient_usage; DROP TABLE pending_recipient_skips; DROP TABLE legacy_sender_rescue;
        ALTER TABLE pending_frames DROP COLUMN retention_class;
        UPDATE link_delivery_state SET schema_version = 1`);
    });
    await evictDurableObject(stub);
    await stub.listDevices();
    await registerDevice("mobile-rescue-new", "mobile", "phone");
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      for (const recipient of ["mobile-rescue-old", "mobile-rescue-new"]) {
        state.storage.sql.exec(`WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 4096)
          INSERT INTO pending_frames (recipient_device_id, sender_device_id, frame_id, sequence, encoded_frame, created_at)
          SELECT ?, 'other-host-fixture', ? || x, x, 'opaque-fixture', 1 FROM n`, recipient, `full-${recipient}-`);
      }
    });
    let host = await connectBuffered("host-rescue", hostKeys.privateKey, 1721);
    try {
      const pending = durableFixtureFrame("host-rescue", 2, "rescue-pending");
      host.socket.send(JSON.stringify(pending));
      expect(await host.next()).toMatchObject({ type: "accepted", id: pending.id, sequence: 2 });
      const copies = () => runInDurableObject<UserLink, Array<{ recipient_device_id: string; encoded_frame: string; retention_class: number }>>(stub, (_instance, state) =>
        state.storage.sql.exec<{ recipient_device_id: string; encoded_frame: string; retention_class: number }>(
          "SELECT recipient_device_id, encoded_frame, retention_class FROM pending_frames WHERE frame_id = ? ORDER BY recipient_device_id", pending.id).toArray());
      expect(await copies()).toEqual(["mobile-rescue-new", "mobile-rescue-old"].map(recipient_device_id =>
        ({ recipient_device_id, encoded_frame: JSON.stringify(pending), retention_class: 0 })));
      await host.dispose();
      await evictDurableObject(stub);
      host = await connectBuffered("host-rescue", hostKeys.privateKey, 1722);
      expect(host.ready).toMatchObject({ lastInboundSequence: 2, lastInboundFrameId: pending.id });
      host.socket.send(JSON.stringify(pending));
      expect(await host.next()).toMatchObject({ type: "accepted", id: pending.id });
      expect(await copies()).toHaveLength(2);
      const next = durableFixtureFrame("host-rescue", 3, "rescue-next");
      host.socket.send(JSON.stringify(next));
      expect(await host.next()).toMatchObject({ type: "backpressure", id: next.id });
      expect(await runInDurableObject<UserLink, string>(stub, (_instance, state) =>
        state.storage.sql.exec<{ encoded_frame: string }>("SELECT encoded_frame FROM pending_frames WHERE frame_id = ?", old.id).one().encoded_frame,
      )).toBe(JSON.stringify(old));
    } finally {
      await host.dispose();
    }
  }, 20_000);

  it("migrates legacy inline and chunked pending data once without loss", async () => {
    await registerDevice("mobile-migration", "mobile", "phone");
    await registerDevice("host-migration", "host", "hermes_host");
    const stub = env.USER_LINKS.getByName(ACCOUNT);
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      state.storage.transactionSync(() => {
        for (const name of ["pending_recipient_update", "pending_delivery_insert", "pending_delivery_delete", "pending_delivery_inline_update",
                            "pending_delivery_chunk_insert", "pending_delivery_chunk_delete", "pending_delivery_chunk_update"]) {
          state.storage.sql.exec(`DROP TRIGGER IF EXISTS ${name}`);
        }
        state.storage.sql.exec("DROP INDEX IF EXISTS pending_frames_delivery_idx");
        state.storage.sql.exec("DROP TABLE pending_frame_refs; DROP TABLE link_delivery_state");
        state.storage.sql.exec("DROP TABLE pending_recipient_usage; DROP TABLE pending_recipient_skips; DROP TABLE legacy_sender_rescue");
        state.storage.sql.exec("ALTER TABLE pending_frames DROP COLUMN retention_class");
        state.storage.sql.exec("ALTER TABLE pending_frames DROP COLUMN delivery_order");
        state.storage.sql.exec("ALTER TABLE pending_frames DROP COLUMN encoded_bytes");
        state.storage.sql.exec(
          "INSERT INTO pending_frames VALUES (?, ?, ?, ?, ?, ?)",
          "mobile-migration", "host-migration", "frame-migration-inline", 1, "inline_ciphertext_fixture", NOW,
        );
        state.storage.sql.exec(
          "INSERT INTO pending_frames VALUES (?, ?, ?, ?, ?, ?)",
          "mobile-migration", "host-migration", "frame-migration-chunked", 2, "", NOW,
        );
        state.storage.sql.exec("INSERT INTO pending_frame_chunks VALUES (?, ?, ?, ?)",
                              "mobile-migration", "frame-migration-chunked", 0, "first_chunk_");
        state.storage.sql.exec("INSERT INTO pending_frame_chunks VALUES (?, ?, ?, ?)",
                              "mobile-migration", "frame-migration-chunked", 1, "second_chunk");
      });
    });
    for (let attempt = 0; attempt < 2; attempt += 1) {
      await evictDurableObject(stub);
      await stub.listDevices();
      const result = await runInDurableObject<UserLink, {
        inline: string; chunks: string; bytes: number; frames: number; rows: number;
      }>(stub, (_instance, state) => ({
        inline: state.storage.sql.exec<{ encoded_frame: string }>(
          "SELECT encoded_frame FROM pending_frames WHERE frame_id = ?", "frame-migration-inline",
        ).one().encoded_frame,
        chunks: state.storage.sql.exec<{ encoded_chunk: string }>(
          "SELECT encoded_chunk FROM pending_frame_chunks ORDER BY chunk_index",
        ).toArray().map((row) => row.encoded_chunk).join(""),
        bytes: state.storage.sql.exec<{ encoded_bytes: number }>("SELECT encoded_bytes FROM link_delivery_state").one().encoded_bytes,
        frames: state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM pending_frame_refs").one().count,
        rows: state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM pending_frames WHERE delivery_order > 0").one().count,
      }));
      expect(result).toEqual({
        inline: "inline_ciphertext_fixture", chunks: "first_chunk_second_chunk",
        bytes: new TextEncoder().encode("inline_ciphertext_fixturefirst_chunk_second_chunk").byteLength,
        frames: 2, rows: 2,
      });
    }
  });

  it("keeps the exact readiness shape for clients without additive capabilities", async () => {
    const keys = await registerDevice("mobile-legacy-ready-shape", "mobile", "phone");
    const connection = await connectBuffered("mobile-legacy-ready-shape", keys.privateKey, 707, false);
    try {
      expect(Object.keys(connection.ready).sort()).toEqual([
        "version", "type", "deviceId", "authorizationEpoch",
        "lastInboundSequence", "lastInboundFrameId", "lastAcknowledgedSequence",
      ].sort());
    } finally {
      await connection.dispose();
    }
  });

  it("requires the websocket handshake metadata before device authentication", async () => {
    await registerDevice("device-handshake-metadata", "mobile", "phone");
    const response = await env.USER_LINKS.getByName(ACCOUNT).fetch(
      new Request("https://loopdy-link.internal/connect", {
        headers: {
          Upgrade: "websocket",
          "x-loopdy-link-verified-device": "device-handshake-metadata",
          "x-loopdy-link-verified-epoch": "1",
        },
      }),
    );

    expect(response.status).toBe(426);
    expect(await response.json()).toEqual({ version: 1, error: "socket_handshake_invalid" });
    expect(response.webSocket).toBeNull();
  });

  it("authenticates a signed external websocket request inside the Durable Object", async () => {
    const keys = await registerDevice("device-original-path", "mobile", "phone");
    const request = await signedSocketRequest(
      "device-original-path",
      keys.privateKey,
      "/v1/socket",
      10,
    );
    const response = await worker.fetch(request, env);

    expect(response.status).toBe(101);
    expect(response.webSocket).not.toBeNull();
    response.webSocket!.accept();
    response.webSocket!.close(1000, "done");
  });

  it("keeps legacy clients free of unsolicited readiness frames", async () => {
    const mobileKeys = await registerDevice("legacy-mobile", "mobile", "phone");
    const hostKeys = await registerDevice("legacy-host", "host", "hermes_host");
    const mobile = await connect("legacy-mobile", mobileKeys.privateKey, 11, false);
    const host = await connect("legacy-host", hostKeys.privateKey, 12, true);
    const accepted = nextMessage(mobile);
    const delivered = nextMessage(host);
    const frame = JSON.stringify({
      version: 1,
      type: "frame",
      id: "frame-legacy-capability-0001",
      senderDeviceId: "legacy-mobile",
      senderEpoch: 1,
      sequence: 1,
      ack: 0,
      ciphertext: "ciphertext_legacy_capability_0001",
    });

    mobile.send(frame);

    expect(JSON.parse(await accepted)).toEqual({
      version: 1,
      type: "accepted",
      id: "frame-legacy-capability-0001",
      sequence: 1,
    });
    expect(JSON.parse(await delivered)).toEqual(JSON.parse(frame));

    mobile.close(1000, "done");
    host.close(1000, "done");
  });

  it("rehydrates attachments after eviction and routes one encrypted frame to the granted host", async () => {
    const mobileKeys = await registerDevice("mobile-device", "mobile", "phone");
    const hostKeys = await registerDevice("host-device", "host", "hermes_host");
    const mobile = await connect("mobile-device", mobileKeys.privateKey, 1);
    const host = await connect("host-device", hostKeys.privateKey, 2);
    const stub = env.USER_LINKS.getByName(ACCOUNT);

    const attachment = await runInDurableObject<UserLink, unknown>(stub, (_instance, state) => {
      return state.getWebSockets("device:mobile-device")[0]?.deserializeAttachment();
    });
    expect(attachment).toEqual({
      version: 1,
      deviceId: "mobile-device",
      role: "mobile",
      authorizationEpoch: 1,
      hostGrant: null,
      lastAcknowledgedSequence: 0,
    });

    await evictDurableObject(stub);
    const hostMessage = nextMessage(host);
    const accepted = nextMessage(mobile);
    mobile.send(
      JSON.stringify({
        version: 1,
        type: "frame",
        id: "frame-coordinate-0001",
        senderDeviceId: "mobile-device",
        senderEpoch: 1,
        sequence: 1,
        ack: 0,
        ciphertext: "ciphertext_base64url_0001",
      }),
    );

    expect(JSON.parse(await hostMessage)).toEqual({
      version: 1,
      type: "frame",
      id: "frame-coordinate-0001",
      senderDeviceId: "mobile-device",
      senderEpoch: 1,
      sequence: 1,
      ack: 0,
      ciphertext: "ciphertext_base64url_0001",
    });
    expect(JSON.parse(await accepted)).toEqual({
      version: 1,
      type: "accepted",
      id: "frame-coordinate-0001",
      sequence: 1,
    });

    mobile.close(1000, "done");
    host.close(1000, "done");
  });

  it("routes a serialized encrypted frame at the 4,000,000-character boundary", async () => {
    const mobileKeys = await registerDevice("mobile-device-1", "mobile", "phone");
    const hostKeys = await registerDevice("host-device-1", "host", "hermes_host");
    const mobile = await connect("mobile-device-1", mobileKeys.privateKey, 21);
    const host = await connect("host-device-1", hostKeys.privateKey, 22);
    const delivered = nextMessage(host);
    const mobileOutcome = Promise.race([
      nextMessage(mobile).then((message) => ({ kind: "message" as const, message })),
      nextClose(mobile).then((close) => ({ kind: "close" as const, close })),
    ]);
    const frame = JSON.stringify({
      version: 1,
      type: "frame",
      id: "frame-max-size-000001",
      senderDeviceId: "mobile-device-1",
      senderEpoch: 1,
      sequence: 1,
      ack: 0,
      ciphertext: "x".repeat(3_999_855),
    });

    expect(frame).toHaveLength(4_000_000);
    mobile.send(frame);

    const outcome = await mobileOutcome;
    const routed = outcome.kind === "message" ? await delivered : null;
    mobile.close(1000, "done");
    host.close(1000, "done");

    expect(outcome).toEqual({
      kind: "message",
      message: JSON.stringify({
        version: 1,
        type: "accepted",
        id: "frame-max-size-000001",
        sequence: 1,
      }),
    });
    expect(routed).toBe(frame);
  });

  it("closes a socket for a serialized encrypted frame one character over the boundary", async () => {
    const mobileKeys = await registerDevice("mobile-device-2", "mobile", "phone");
    await registerDevice("host-device-2", "host", "hermes_host");
    const mobile = await connect("mobile-device-2", mobileKeys.privateKey, 23);
    const closed = nextClose(mobile);
    const frame = JSON.stringify({
      version: 1,
      type: "frame",
      id: "frame-max-size-000002",
      senderDeviceId: "mobile-device-2",
      senderEpoch: 1,
      sequence: 1,
      ack: 0,
      ciphertext: "x".repeat(3_999_856),
    });

    expect(frame).toHaveLength(4_000_001);
    mobile.send(frame);

    expect(await closed).toEqual({ code: 4004, reason: "frame rejected" });
  });

  it("broadcasts host responses to every paired mobile without consuming another device's delivery", async () => {
    const firstKeys = await registerDevice("mobile-device-multi-a", "mobile", "phone");
    const secondKeys = await registerDevice("mobile-device-multi-b", "mobile", "phone");
    const hostKeys = await registerDevice("host-device-multi-extended", "host", "hermes_host");
    const first = await connect("mobile-device-multi-a", firstKeys.privateKey, 14);
    const second = await connect("mobile-device-multi-b", secondKeys.privateKey, 15);
    const host = await connect("host-device-multi-extended", hostKeys.privateKey, 16);

    const hostRequest = nextMessage(host);
    const firstAccepted = nextMessage(first);
    first.send(
      JSON.stringify({
        version: 1,
        type: "frame",
        id: "frame-coordinate-multi-request",
        senderDeviceId: "mobile-device-multi-a",
        senderEpoch: 1,
        sequence: 1,
        ack: 0,
        ciphertext: "ciphertext_base64url_multi_request",
      }),
    );
    expect(JSON.parse(await hostRequest)).toMatchObject({
      id: "frame-coordinate-multi-request",
      senderDeviceId: "mobile-device-multi-a",
    });
    expect(JSON.parse(await firstAccepted)).toMatchObject({
      type: "accepted",
      id: "frame-coordinate-multi-request",
    });

    const firstResponse = nextMessage(first);
    const secondResponse = nextMessage(second);
    host.send(
      JSON.stringify({
        version: 1,
        type: "frame",
        id: "frame-coordinate-multi-response",
        senderDeviceId: "host-device-multi-extended",
        senderEpoch: 1,
        sequence: 1,
        ack: 1,
        ciphertext: "ciphertext_base64url_multi_response",
      }),
    );
    expect(JSON.parse(await firstResponse)).toMatchObject({
      type: "frame",
      id: "frame-coordinate-multi-response",
      senderDeviceId: "host-device-multi-extended",
    });
    expect(JSON.parse(await secondResponse)).toMatchObject({
      type: "frame",
      id: "frame-coordinate-multi-response",
      senderDeviceId: "host-device-multi-extended",
    });

    const pending = await runInDurableObject<UserLink, Array<{ device: string; total: number }>>(
      env.USER_LINKS.getByName(ACCOUNT),
      (_instance, state) =>
        state.storage.sql
          .exec<{ recipient_device_id: string; total: number }>(
            `SELECT recipient_device_id, COUNT(*) AS total FROM pending_frames
             WHERE frame_id = ? GROUP BY recipient_device_id ORDER BY recipient_device_id`,
            "frame-coordinate-multi-response",
          )
          .toArray()
          .map((row) => ({ device: row.recipient_device_id, total: row.total })),
    );
    expect(pending).toEqual(expect.arrayContaining([
      { device: "mobile-device-multi-a", total: 1 },
      { device: "mobile-device-multi-b", total: 1 },
    ]));

    for (const mobile of [first, second]) {
      mobile.send(
        JSON.stringify({
          version: 1,
          type: "receipt",
          deviceId: mobile === first ? "mobile-device-multi-a" : "mobile-device-multi-b",
          frameId: "frame-coordinate-multi-response",
          sourceDeviceId: "host-device-multi-extended",
          sequence: 1,
        }),
      );
      expect(JSON.parse(await nextMessage(mobile))).toEqual({
        version: 1,
        type: "receipt.accepted",
        frameId: "frame-coordinate-multi-response",
      });
    }

    const remaining = await runInDurableObject<UserLink, number>(
      env.USER_LINKS.getByName(ACCOUNT),
      (_instance, state) =>
        state.storage.sql
          .exec<{ total: number }>(
            `SELECT COUNT(*) AS total FROM pending_frames
             WHERE frame_id = ? AND recipient_device_id IN (?, ?)`,
            "frame-coordinate-multi-response",
            "mobile-device-multi-a",
            "mobile-device-multi-b",
          )
          .one().total,
    );
    expect(remaining).toBe(0);

    first.close(1000, "done");
    second.close(1000, "done");
    host.close(1000, "done");
  });

  it("does not let one saturated offline mobile disconnect every healthy account peer", async () => {
    await registerDevice("mobile-device-stale-full", "mobile", "phone");
    const healthyKeys = await registerDevice("mobile-device-healthy", "mobile", "phone");
    const hostKeys = await registerDevice("host-device-backlog-safe", "host", "hermes_host");
    const healthy = await connect("mobile-device-healthy", healthyKeys.privateKey, 31);
    const host = await connect("host-device-backlog-safe", hostKeys.privateKey, 32);
    const stub = env.USER_LINKS.getByName(ACCOUNT);

    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      for (let index = 0; index < 512; index += 1) {
        state.storage.sql.exec(
          `INSERT INTO pending_frames (
             recipient_device_id, sender_device_id, frame_id,
             sequence, encoded_frame, created_at
           ) VALUES (?, ?, ?, ?, ?, ?)`,
          "mobile-device-stale-full",
          "host-device-backlog-safe",
          `frame-stale-backlog-${String(index).padStart(4, "0")}`,
          index + 1,
          "{}",
          NOW - 60,
        );
      }
    });

    const accepted = nextMessage(host);
    const delivered = nextMessage(healthy);
    host.send(
      JSON.stringify({
        version: 1,
        type: "frame",
        id: "frame-backlog-safe-response-0001",
        senderDeviceId: "host-device-backlog-safe",
        senderEpoch: 1,
        sequence: 1,
        ack: 0,
        ciphertext: "ciphertext_backlog_safe_response_0001",
      }),
    );

    expect(JSON.parse(await accepted)).toEqual({
      version: 1,
      type: "accepted",
      id: "frame-backlog-safe-response-0001",
      sequence: 1,
    });
    expect(JSON.parse(await delivered)).toMatchObject({
      type: "frame",
      id: "frame-backlog-safe-response-0001",
      senderDeviceId: "host-device-backlog-safe",
    });
    const pending = await runInDurableObject<
      UserLink,
      Array<{ device: string; total: number }>
    >(stub, (_instance, state) =>
      state.storage.sql
        .exec<{ recipient_device_id: string; total: number }>(
          `SELECT recipient_device_id, COUNT(*) AS total FROM pending_frames
           WHERE recipient_device_id IN (?, ?)
           GROUP BY recipient_device_id ORDER BY recipient_device_id`,
          "mobile-device-stale-full",
          "mobile-device-healthy",
        )
        .toArray()
        .map((row) => ({ device: row.recipient_device_id, total: row.total })),
    );
    expect(pending).toEqual([
      { device: "mobile-device-healthy", total: 1 },
      { device: "mobile-device-stale-full", total: 513 },
    ]);

    healthy.close(1000, "done");
    host.close(1000, "done");
  });

  it("preserves accepted durable delivery when an offline replay page is full", async () => {
    await registerDevice("mobile-device-only-full", "mobile", "phone");
    const hostKeys = await registerDevice("host-device-all-full", "host", "hermes_host");
    const host = await connect("host-device-all-full", hostKeys.privateKey, 33);
    const stub = env.USER_LINKS.getByName(ACCOUNT);

    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      for (let index = 0; index < 512; index += 1) {
        state.storage.sql.exec(
          `INSERT INTO pending_frames (
             recipient_device_id, sender_device_id, frame_id,
             sequence, encoded_frame, created_at
           ) VALUES (?, ?, ?, ?, ?, ?)`,
          "mobile-device-only-full",
          "host-device-all-full",
          `frame-only-full-${String(index).padStart(4, "0")}`,
          index + 1,
          "{}",
          NOW - 60,
        );
      }
    });

    const accepted = nextMessage(host);
    host.send(
      JSON.stringify({
        version: 1,
        type: "frame",
        id: "frame-all-full-response-0001",
        senderDeviceId: "host-device-all-full",
        senderEpoch: 1,
        sequence: 1,
        ack: 0,
        ciphertext: "ciphertext_all_full_response_0001",
      }),
    );

    expect(JSON.parse(await accepted)).toEqual({
      version: 1,
      type: "accepted",
      id: "frame-all-full-response-0001",
      sequence: 1,
    });
    const state = await runInDurableObject<
      UserLink,
      { hostSequence: number; pending: number }
    >(stub, (_instance, durableState) => ({
      hostSequence: durableState.storage.sql
        .exec<{ last_inbound_sequence: number }>(
          "SELECT last_inbound_sequence FROM devices WHERE device_id = ?",
          "host-device-all-full",
        )
        .one().last_inbound_sequence,
      pending: durableState.storage.sql
        .exec<{ total: number }>(
          "SELECT COUNT(*) AS total FROM pending_frames WHERE recipient_device_id = ?",
          "mobile-device-only-full",
        )
        .one().total,
    }));
    expect(state).toEqual({ hostSequence: 1, pending: 513 });

    host.close(1000, "done");
  });

  it("acknowledges an exact retry once, rejects a conflicting replay, and closes on revocation", async () => {
    const mobileKeys = await registerDevice("mobile-device-replay", "mobile", "phone");
    const hostKeys = await registerDevice("host-device-replay", "host", "hermes_host");
    const mobile = await connect("mobile-device-replay", mobileKeys.privateKey, 3);
    const host = await connect("host-device-replay", hostKeys.privateKey, 4);
    const firstFrame = JSON.stringify({
      version: 1,
      type: "frame",
      id: "frame-coordinate-replay",
      senderDeviceId: "mobile-device-replay",
      senderEpoch: 1,
      sequence: 1,
      ack: 0,
      ciphertext: "ciphertext_base64url_replay",
    });
    const firstHostMessage = nextMessage(host);
    const firstAccepted = nextMessage(mobile);
    mobile.send(firstFrame);
    await firstHostMessage;
    await firstAccepted;

    const retryAccepted = nextMessage(mobile);
    mobile.send(firstFrame);
    expect(JSON.parse(await retryAccepted)).toEqual({
      version: 1,
      type: "accepted",
      id: "frame-coordinate-replay",
      sequence: 1,
    });

    const replayClose = nextClose(mobile);
    mobile.send(
      JSON.stringify({
        version: 1,
        type: "frame",
        id: "frame-coordinate-conflict",
        senderDeviceId: "mobile-device-replay",
        senderEpoch: 1,
        sequence: 1,
        ack: 0,
        ciphertext: "ciphertext_base64url_conflict",
      }),
    );
    expect(await replayClose).toEqual(expect.objectContaining({ code: 4004 }));

    const hostClose = nextClose(host);
    const stub = env.USER_LINKS.getByName(ACCOUNT);
    await stub.revokeDevice({
      deviceId: "host-device-replay",
      expectedRevision: 1,
      revokedAt: NOW + 1,
    });
    expect(await hostClose).toEqual(expect.objectContaining({ code: 4003 }));
  });

  it("accepts a newer frame when its cumulative acknowledgement is stale", async () => {
    const mobileKeys = await registerDevice("mobile-device-stale-ack", "mobile", "phone");
    const hostKeys = await registerDevice("host-device-stale-ack", "host", "hermes_host");
    const mobile = await connect("mobile-device-stale-ack", mobileKeys.privateKey, 12);
    const host = await connect("host-device-stale-ack", hostKeys.privateKey, 13);

    const firstHostMessage = nextMessage(host);
    const firstAccepted = nextMessage(mobile);
    mobile.send(
      JSON.stringify({
        version: 1,
        type: "frame",
        id: "frame-coordinate-stale-ack-01",
        senderDeviceId: "mobile-device-stale-ack",
        senderEpoch: 1,
        sequence: 1,
        ack: 27,
        ciphertext: "ciphertext_base64url_stale_ack_01",
      }),
    );
    await firstHostMessage;
    await firstAccepted;

    const secondHostMessage = nextMessage(host);
    const secondAccepted = nextMessage(mobile);
    mobile.send(
      JSON.stringify({
        version: 1,
        type: "frame",
        id: "frame-coordinate-stale-ack-02",
        senderDeviceId: "mobile-device-stale-ack",
        senderEpoch: 1,
        sequence: 2,
        ack: 0,
        ciphertext: "ciphertext_base64url_stale_ack_02",
      }),
    );

    expect(JSON.parse(await secondHostMessage)).toEqual(
      expect.objectContaining({
        id: "frame-coordinate-stale-ack-02",
        sequence: 2,
      }),
    );
    expect(JSON.parse(await secondAccepted)).toEqual({
      version: 1,
      type: "accepted",
      id: "frame-coordinate-stale-ack-02",
      sequence: 2,
    });

    mobile.close(1000, "done");
    host.close(1000, "done");
  });

  it("rejects a sender that claims another paired device identity", async () => {
    const mobileKeys = await registerDevice("mobile-device-bound", "mobile", "phone");
    await registerDevice("host-device-bound", "host", "hermes_host");
    const mobile = await connect("mobile-device-bound", mobileKeys.privateKey, 5);
    const close = nextClose(mobile);
    mobile.send(
      JSON.stringify({
        version: 1,
        type: "frame",
        id: "frame-coordinate-bound",
        senderDeviceId: "different-mobile-device",
        senderEpoch: 1,
        sequence: 1,
        ack: 0,
        ciphertext: "ciphertext_base64url_bound",
      }),
    );
    expect(await close).toEqual(expect.objectContaining({ code: 4004 }));
  });

  it("persists an encrypted frame while the host is offline and removes it after receipt", async () => {
    const mobileKeys = await registerDevice("mobile-device-offline", "mobile", "phone");
    const hostKeys = await registerDevice("host-device-offline", "host", "hermes_host");
    const mobile = await connect("mobile-device-offline", mobileKeys.privateKey, 6);
    const accepted = nextMessage(mobile);
    mobile.send(
      JSON.stringify({
        version: 1,
        type: "frame",
        id: "frame-coordinate-offline",
        senderDeviceId: "mobile-device-offline",
        senderEpoch: 1,
        sequence: 1,
        ack: 0,
        ciphertext: "ciphertext_base64url_offline",
      }),
    );
    await accepted;

    const host = await connect("host-device-offline", hostKeys.privateKey, 7);
    const replay = JSON.parse(await nextMessage(host));
    expect(replay).toEqual(
      expect.objectContaining({
        type: "frame",
        id: "frame-coordinate-offline",
        senderDeviceId: "mobile-device-offline",
      }),
    );
    host.send(
      JSON.stringify({
        version: 1,
        type: "receipt",
        deviceId: "host-device-offline",
        frameId: "frame-coordinate-offline",
        sourceDeviceId: "mobile-device-offline",
        sequence: 1,
      }),
    );
    expect(JSON.parse(await nextMessage(host))).toEqual({
      version: 1,
      type: "receipt.accepted",
      frameId: "frame-coordinate-offline",
    });
    const pendingCount = await runInDurableObject<UserLink, number>(
      env.USER_LINKS.getByName(ACCOUNT),
      (_instance, state) =>
        state.storage.sql
          .exec<{ total: number }>(
            "SELECT COUNT(*) AS total FROM pending_frames WHERE recipient_device_id = ?",
            "host-device-offline",
          )
          .one().total,
    );
    expect(pendingCount).toBe(0);
    mobile.close(1000, "done");
    host.close(1000, "done");
  });

  it("reassembles an oversized offline frame after eviction and clears every chunk on receipt", async () => {
    const mobileKeys = await registerDevice("mobile-large-offline", "mobile", "phone");
    const hostKeys = await registerDevice("host-large-offline", "host", "hermes_host");
    const mobile = await connect("mobile-large-offline", mobileKeys.privateKey, 24);
    const acceptedOrClosed = Promise.race([
      nextMessage(mobile).then((message) => ({ kind: "message" as const, message })),
      nextClose(mobile).then((close) => ({ kind: "close" as const, close })),
    ]);
    const frame = JSON.stringify({
      version: 1,
      type: "frame",
      id: "frame-chunk-replay-0001",
      senderDeviceId: "mobile-large-offline",
      senderEpoch: 1,
      sequence: 1,
      ack: 0,
      ciphertext: "x".repeat(2_999_848),
    });

    expect(frame).toHaveLength(3_000_000);
    mobile.send(frame);
    expect(await acceptedOrClosed).toEqual({
      kind: "message",
      message: JSON.stringify({
        version: 1,
        type: "accepted",
        id: "frame-chunk-replay-0001",
        sequence: 1,
      }),
    });

    const stub = env.USER_LINKS.getByName(ACCOUNT);
    const stored = await runInDurableObject<
      UserLink,
      {
        parentCount: number;
        inlineCharacters: number;
        chunkCount: number;
        chunkCharacters: number;
        largestChunkCharacters: number;
      }
    >(stub, (_instance, state) => {
      const parent = state.storage.sql
        .exec<{ total: number; inline_characters: number }>(
          `SELECT COUNT(*) AS total, LENGTH(encoded_frame) AS inline_characters
           FROM pending_frames WHERE recipient_device_id = ? AND frame_id = ?`,
          "host-large-offline",
          "frame-chunk-replay-0001",
        )
        .one();
      const chunks = state.storage.sql
        .exec<{ total: number; characters: number; largest: number }>(
          `SELECT COUNT(*) AS total,
                  COALESCE(SUM(LENGTH(encoded_chunk)), 0) AS characters,
                  COALESCE(MAX(LENGTH(encoded_chunk)), 0) AS largest
           FROM pending_frame_chunks WHERE recipient_device_id = ? AND frame_id = ?`,
          "host-large-offline",
          "frame-chunk-replay-0001",
        )
        .one();
      return {
        parentCount: parent.total,
        inlineCharacters: parent.inline_characters,
        chunkCount: chunks.total,
        chunkCharacters: chunks.characters,
        largestChunkCharacters: chunks.largest,
      };
    });
    expect(stored.parentCount).toBe(1);
    expect(stored.inlineCharacters).toBe(0);
    expect(stored.chunkCount).toBeGreaterThan(1);
    expect(stored.chunkCharacters).toBe(3_000_000);
    expect(stored.largestChunkCharacters).toBeLessThan(2_000_000);

    await evictDurableObject(stub);
    const host = await connect("host-large-offline", hostKeys.privateKey, 25);
    expect(await nextMessage(host)).toBe(frame);

    host.send(
      JSON.stringify({
        version: 1,
        type: "receipt",
        deviceId: "host-large-offline",
        frameId: "frame-chunk-replay-0001",
        sourceDeviceId: "mobile-large-offline",
        sequence: 2,
      }),
    );
    expect(JSON.parse(await nextMessage(host))).toEqual({
      version: 1,
      type: "receipt.accepted",
      frameId: "frame-chunk-replay-0001",
    });
    const retainedAfterMismatchedReceipt = await runInDurableObject<
      UserLink,
      { parentCount: number; chunkCount: number }
    >(stub, (_instance, state) => ({
      parentCount: state.storage.sql
        .exec<{ total: number }>(
          "SELECT COUNT(*) AS total FROM pending_frames WHERE recipient_device_id = ? AND frame_id = ?",
          "host-large-offline",
          "frame-chunk-replay-0001",
        )
        .one().total,
      chunkCount: state.storage.sql
        .exec<{ total: number }>(
          "SELECT COUNT(*) AS total FROM pending_frame_chunks WHERE recipient_device_id = ? AND frame_id = ?",
          "host-large-offline",
          "frame-chunk-replay-0001",
        )
        .one().total,
    }));
    expect(retainedAfterMismatchedReceipt.parentCount).toBe(1);
    expect(retainedAfterMismatchedReceipt.chunkCount).toBeGreaterThan(1);

    host.send(
      JSON.stringify({
        version: 1,
        type: "receipt",
        deviceId: "host-large-offline",
        frameId: "frame-chunk-replay-0001",
        sourceDeviceId: "mobile-large-offline",
        sequence: 1,
      }),
    );
    expect(JSON.parse(await nextMessage(host))).toEqual({
      version: 1,
      type: "receipt.accepted",
      frameId: "frame-chunk-replay-0001",
    });

    const cleared = await runInDurableObject<
      UserLink,
      { parentCount: number; chunkCount: number }
    >(stub, (_instance, state) => ({
      parentCount: state.storage.sql
        .exec<{ total: number }>(
          "SELECT COUNT(*) AS total FROM pending_frames WHERE recipient_device_id = ? AND frame_id = ?",
          "host-large-offline",
          "frame-chunk-replay-0001",
        )
        .one().total,
      chunkCount: state.storage.sql
        .exec<{ total: number }>(
          "SELECT COUNT(*) AS total FROM pending_frame_chunks WHERE recipient_device_id = ? AND frame_id = ?",
          "host-large-offline",
          "frame-chunk-replay-0001",
        )
        .one().total,
    }));
    expect(cleared).toEqual({ parentCount: 0, chunkCount: 0 });

    mobile.close(1000, "done");
    host.close(1000, "done");
  });

  it("clears oversized pending-frame chunks when the recipient is revoked", async () => {
    const mobileKeys = await registerDevice("mobile-large-revoke", "mobile", "phone");
    await registerDevice("host-large-revoke", "host", "hermes_host");
    const mobile = await connect("mobile-large-revoke", mobileKeys.privateKey, 26);
    const acceptedOrClosed = Promise.race([
      nextMessage(mobile).then((message) => ({ kind: "message" as const, message })),
      nextClose(mobile).then((close) => ({ kind: "close" as const, close })),
    ]);
    const frame = JSON.stringify({
      version: 1,
      type: "frame",
      id: "frame-chunk-revoke-0001",
      senderDeviceId: "mobile-large-revoke",
      senderEpoch: 1,
      sequence: 1,
      ack: 0,
      ciphertext: "x".repeat(2_199_849),
    });

    expect(frame).toHaveLength(2_200_000);
    mobile.send(frame);
    expect(await acceptedOrClosed).toEqual({
      kind: "message",
      message: JSON.stringify({
        version: 1,
        type: "accepted",
        id: "frame-chunk-revoke-0001",
        sequence: 1,
      }),
    });

    const stub = env.USER_LINKS.getByName(ACCOUNT);
    const storedChunks = await runInDurableObject<UserLink, number>(stub, (_instance, state) =>
      state.storage.sql
        .exec<{ total: number }>(
          "SELECT COUNT(*) AS total FROM pending_frame_chunks WHERE recipient_device_id = ? AND frame_id = ?",
          "host-large-revoke",
          "frame-chunk-revoke-0001",
        )
        .one().total,
    );
    expect(storedChunks).toBeGreaterThan(1);

    await stub.revokeDevice({
      deviceId: "host-large-revoke",
      expectedRevision: 1,
      revokedAt: NOW + 1,
    });
    const cleared = await runInDurableObject<
      UserLink,
      { parentCount: number; chunkCount: number }
    >(stub, (_instance, state) => ({
      parentCount: state.storage.sql
        .exec<{ total: number }>(
          "SELECT COUNT(*) AS total FROM pending_frames WHERE recipient_device_id = ? AND frame_id = ?",
          "host-large-revoke",
          "frame-chunk-revoke-0001",
        )
        .one().total,
      chunkCount: state.storage.sql
        .exec<{ total: number }>(
          "SELECT COUNT(*) AS total FROM pending_frame_chunks WHERE recipient_device_id = ? AND frame_id = ?",
          "host-large-revoke",
          "frame-chunk-revoke-0001",
        )
        .one().total,
    }));
    expect(cleared).toEqual({ parentCount: 0, chunkCount: 0 });

    mobile.close(1000, "done");
  });

  it("rejects retired Live Activity websocket updates even from a paired host", async () => {
    await registerDevice("mobile-device-live", "mobile", "phone");
    const hostKeys = await registerDevice("host-device-live", "host", "hermes_host");
    const host = await connect("host-device-live", hostKeys.privateKey, 8);
    const closed = nextClose(host);
    host.send(
      JSON.stringify({
        version: 1,
        type: "live_activity.update",
        updateId: "activity-update-live-0001",
        sessionReference: "A".repeat(43),
        phase: "using_tool",
        currentAction: "Checking the weather",
        progress: 48,
        completedSteps: 2,
        activeSubagentCount: 1,
        latestTool: "weather",
        timestamp: NOW,
        expires: NOW + 120,
      }),
    );

    expect(await closed).toEqual(expect.objectContaining({ code: 4004 }));
    host.close(1000, "done");
  });

  it("closes a mobile socket that attempts to author Live Activity state", async () => {
    const mobileKeys = await registerDevice("mobile-device-live-denied", "mobile", "phone");
    await registerDevice("host-device-live-denied", "host", "hermes_host");
    const mobile = await connect("mobile-device-live-denied", mobileKeys.privateKey, 9);
    const closed = nextClose(mobile);
    mobile.send(
      JSON.stringify({
        version: 1,
        type: "live_activity.update",
        updateId: "activity-update-denied-0001",
        sessionReference: "B".repeat(43),
        phase: "thinking",
        currentAction: "Working on your request",
        progress: 10,
        completedSteps: 0,
        activeSubagentCount: 0,
        latestTool: null,
        timestamp: NOW,
        expires: NOW + 120,
      }),
    );
    expect(await closed).toEqual(expect.objectContaining({ code: 4004 }));
  });

  it("logs a stable code without socket metadata when the handshake is rejected", async () => {
    const keys = await registerDevice("device-handshake-rejected", "mobile", "phone");
    const request = await signedSocketRequest(
      "device-handshake-rejected",
      keys.privateKey,
      "/v1/socket",
      11,
    );
    request.headers.set(DEVICE_AUTH_HEADERS.signature, "A".repeat(86));
    const info = vi.spyOn(console, "info").mockImplementation(() => undefined);
    try {
      const response = await worker.fetch(request, env);
      expect(response.status).toBe(403);
      expect(info).toHaveBeenCalledWith("[loopdy-link] socket_rejected: device_signature_invalid");
      expect(info.mock.calls.flat().join(" ")).not.toContain("device-handshake-rejected");
    } finally {
      info.mockRestore();
    }
  });

  it("closes live sockets at accepted deletion before cleanup and preserves the tombstone", async () => {
    const accessToken = "socket-account-deletion-token-with-enough-entropy";
    const hostKeys = await registerDevice("account-delete-live-host", "host", "hermes_host");
    const legacyGrantId = crypto.randomUUID();
    const legacyGrant = {
      grantId: legacyGrantId,
      hostKeyId: "legacy-account-delete-host-key",
      hostPublicKey: "legacy-account-delete-public-key",
      authorizationEpoch: 1,
      profile: "default",
      eventTypes: ["session.completed"],
      createdAt: NOW,
      expiresAt: NOW + 1_800,
      revision: 1,
      provider: "buzzkit",
      subscriberScope: "account",
      state: "active",
    };
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(`INSERT INTO access_sessions(
        token_hash,account_coordinate,authorization_epoch,created_at,expires_at)
        VALUES(?,?,1,?,?)`)
        .bind(await sha256Base64URL(accessToken), ACCOUNT, NOW, NOW + 900),
      env.ACCOUNTS.prepare(`INSERT INTO notification_grants(
        grant_id,account_coordinate,device_id,authorization_epoch,idempotency_key,
        request_digest,public_json,state,revision,created_at,expires_at)
        VALUES(?,?,?,1,?,?,?,'active',1,?,?)`)
        .bind(
          legacyGrantId, ACCOUNT, "account-delete-live-host", crypto.randomUUID(),
          "legacy-account-delete-digest", JSON.stringify(legacyGrant), NOW, NOW + 1_800,
        ),
    ]);
    const host = await connectBuffered("account-delete-live-host", hostKeys.privateKey, 9901);
    const closed = nextClose(host.socket);
    let providerEntered!: () => void;
    const providerStarted = new Promise<void>((resolve) => { providerEntered = resolve; });
    let releaseProvider!: () => void;
    const providerHeld = new Promise<void>((resolve) => { releaseProvider = resolve; });
    let deleteCalls = 0;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
      if (init?.method === "DELETE") {
        deleteCalls += 1;
        if (deleteCalls === 1) {
          providerEntered();
          await providerHeld;
          return Response.json({ success: false, error: { code: "held_failure" } }, { status: 503 });
        }
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
    const deletionRequest = () => new Request("https://link.loopdy.example/v1/accounts/current", {
      method: "DELETE",
      headers: { authorization: `Bearer ${accessToken}` },
    });
    const deletion = worker.fetch(deletionRequest(), targetEnv);
    const providerReached = await Promise.race([
      providerStarted.then(() => true),
      new Promise<false>((resolve) => setTimeout(() => resolve(false), 1_000)),
    ]);
    expect(providerReached).toBe(true);

    expect(await closed).toEqual({ code: 4003, reason: "account deleted" });
    expect(host.socket.readyState).not.toBe(WebSocket.OPEN);
    expect(() => host.socket.send(JSON.stringify(
      durableFixtureFrame("account-delete-live-host", 1, "after-delete"),
    ))).toThrow();
    const stub = env.USER_LINKS.getByName(ACCOUNT);
    await runInDurableObject<UserLink, void>(stub, (instance, state) => {
      expect(state.storage.kv.get("account-deletion-tombstone-v1")).toEqual({ version: 1 });
      expect(() => instance.listDevices()).toThrowError(
        expect.objectContaining({ code: "account_deleted" }),
      );
      expect(state.storage.sql.exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM frame_ids",
      ).one().count).toBe(0);
      expect(() => instance.revokeNotificationGrantAuthority({
        grantId: legacyGrantId,
        credentialId: "account-delete-live-host",
        authorizationEpoch: 1,
        revision: 2,
      })).toThrowError(expect.objectContaining({ code: "account_deleted" }));
      expect(() => instance.retireDeletedAccountNotificationGrantAuthority({
        grantId: legacyGrantId,
        credentialId: "different-account-delete-device",
        authorizationEpoch: 1,
        revision: 2,
      })).toThrowError(expect.objectContaining({ code: "notification_grant_inactive" }));
      expect(state.storage.sql.exec<{ state: string; revision: number }>(
        "SELECT state,revision FROM managed_notification_grants WHERE grant_id=?",
        legacyGrantId,
      ).one()).toEqual({ state: "revoked", revision: 2 });
    });
    expect(await env.ACCOUNTS.prepare(
      "SELECT state,revision FROM notification_grants WHERE grant_id=?",
    ).bind(legacyGrantId).first()).toEqual({ state: "revoked", revision: 2 });

    releaseProvider();
    const failed = await deletion;
    expect(failed.status).toBe(503);
    expect(await failed.json()).toEqual(expect.objectContaining({
      error: "notification_cleanup_unavailable",
    }));
    await evictDurableObject(stub);
    await runInDurableObject<UserLink, void>(stub, (instance, state) => {
      expect(state.storage.kv.get("account-deletion-tombstone-v1")).toEqual({ version: 1 });
      expect(() => instance.registerDevice({
        deviceId: "reinitialized-after-delete",
        publicKey: "unused-public-key",
        role: "mobile",
        kind: "phone",
        encryptedName: "unused-name",
        revision: 1,
        createdAt: NOW,
      })).toThrowError(expect.objectContaining({ code: "account_deleted" }));
    });

    const retry = await worker.fetch(deletionRequest(), targetEnv);
    expect(retry.status).toBe(200);
    expect(await retry.json()).toEqual({ version: 1, state: "deleted" });
    await evictDurableObject(stub);
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      expect(state.storage.kv.get("account-deletion-tombstone-v1")).toEqual({ version: 1 });
      const tables = state.storage.sql.exec<{ name: string }>(
        `SELECT name FROM sqlite_master
         WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT GLOB '_cf_*'`,
      ).toArray();
      for (const { name } of tables) {
        const quoted = `"${name.replaceAll('"', '""')}"`;
        expect(state.storage.sql.exec<{ count: number }>(
          `SELECT COUNT(*) AS count FROM ${quoted}`,
        ).one().count, name).toBe(0);
      }
    });
    await host.dispose();
  });
});

async function registerDevice(
  deviceId: string,
  role: "mobile" | "host",
  kind: "phone" | "hermes_host",
): Promise<{ privateKey: CryptoKey }> {
  const keyPair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const spki = base64url(
    new Uint8Array((await crypto.subtle.exportKey("spki", keyPair.publicKey)) as ArrayBuffer),
  );
  await env.ACCOUNTS.prepare(
    `INSERT INTO device_directory (
       device_id, account_coordinate, public_key_spki, status,
       authorization_epoch, created_at
     ) VALUES (?, ?, ?, 'active', 1, ?)`,
  )
    .bind(deviceId, ACCOUNT, spki, NOW)
    .run();
  await env.USER_LINKS.getByName(ACCOUNT).registerDevice({
    deviceId,
    publicKey: spki,
    role,
    kind,
    encryptedName: `encrypted-${deviceId}`,
    revision: 1,
    createdAt: NOW,
  });
  return { privateKey: keyPair.privateKey };
}

async function signedSocketRequest(
  deviceId: string,
  privateKey: CryptoKey,
  path: string,
  nonce: number,
): Promise<Request> {
  const nonceValue = base64url(new TextEncoder().encode(`socket-nonce-${nonce}-fixture`));
  const canonical = await canonicalDeviceRequest({
    method: "GET",
    path,
    deviceId,
    timestamp: NOW,
    nonce: nonceValue,
    authorizationEpoch: 1,
    body: "",
  });
  const signature = base64url(
    new Uint8Array(
      await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        privateKey,
        new TextEncoder().encode(canonical),
      ),
    ),
  );
  return new Request(`https://link.loopdy.example${path}`, {
    headers: {
      Upgrade: "websocket",
      "Sec-WebSocket-Key": base64url(
        new TextEncoder().encode(`socket-key-${nonce}-fixture-012345678901234567890123`),
      ),
      "Sec-WebSocket-Version": "13",
      [DEVICE_AUTH_HEADERS.deviceId]: deviceId,
      [DEVICE_AUTH_HEADERS.timestamp]: String(NOW),
      [DEVICE_AUTH_HEADERS.nonce]: nonceValue,
      [DEVICE_AUTH_HEADERS.authorizationEpoch]: "1",
      [DEVICE_AUTH_HEADERS.signature]: signature,
    },
  });
}

async function connect(
  deviceId: string,
  privateKey: CryptoKey,
  nonce: number,
  supportsReady = true,
): Promise<WebSocket> {
  const path = "/v1/socket";
  const nonceValue = base64url(new TextEncoder().encode(`socket-nonce-${nonce}-fixture`));
  const canonical = await canonicalDeviceRequest({
    method: "GET",
    path,
    deviceId,
    timestamp: NOW,
    nonce: nonceValue,
    authorizationEpoch: 1,
    body: "",
  });
  const signature = base64url(
    new Uint8Array(
      await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        privateKey,
        new TextEncoder().encode(canonical),
      ),
    ),
  );
  const response = await worker.fetch(
    new Request(`https://link.loopdy.example${path}`, {
      headers: {
        Upgrade: "websocket",
        "Sec-WebSocket-Key": base64url(
          new TextEncoder().encode(`socket-key-${nonce}-fixture-012345678901234567890123`),
        ),
        "Sec-WebSocket-Version": "13",
        [DEVICE_AUTH_HEADERS.deviceId]: deviceId,
        [DEVICE_AUTH_HEADERS.timestamp]: String(NOW),
        [DEVICE_AUTH_HEADERS.nonce]: nonceValue,
        [DEVICE_AUTH_HEADERS.authorizationEpoch]: "1",
        [DEVICE_AUTH_HEADERS.signature]: signature,
        ...(supportsReady ? { "x-loopdy-capabilities": "socket-ready-v1" } : {}),
      },
    }),
    env,
  );
  expect(response.status).toBe(101);
  expect(response.webSocket).not.toBeNull();
  response.webSocket!.accept();
  if (supportsReady) {
    const ready = JSON.parse(await nextMessage(response.webSocket!));
    expect(ready).toMatchObject({
      version: 1,
      type: "socket.ready",
      deviceId,
      authorizationEpoch: 1,
      lastInboundSequence: expect.any(Number),
      lastAcknowledgedSequence: expect.any(Number),
    });
    expect(ready).toHaveProperty("lastInboundFrameId");
  }
  return response.webSocket!;
}

function durableFixtureFrame(senderDeviceId: string, sequence: number, kind: string) {
  return {
    version: 1, type: "frame", id: `frame-${kind}-${String(sequence).padStart(5, "0")}`,
    senderDeviceId, senderEpoch: 1, sequence, ack: 0,
    ciphertext: "opaque_ciphertext_fixture_for_durable_replay",
  };
}

async function connectBuffered(deviceId: string, privateKey: CryptoKey, nonce: number, backpressure = true, directed = false, presentation = false) {
  const request = await signedSocketRequest(deviceId, privateKey, "/v1/socket", nonce);
  request.headers.set("x-loopdy-capabilities", ["socket-ready-v1", ...(backpressure ? ["backpressure-v1"] : []), ...(directed ? ["directed-frames-v1"] : []), ...(presentation ? ["state-backed-presentation-v1"] : [])].join(","));
  const response = await worker.fetch(request, env);
  expect(response.status).toBe(101);
  expect(response.webSocket).not.toBeNull();
  const socket = response.webSocket!;
  const queued: Array<Record<string, unknown>> = [];
  const waiting: Array<{
    resolve: (value: Record<string, unknown>) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }> = [];
  let terminalError: Error | undefined;
  const fail = () => {
    terminalError = new Error("Fixture socket closed or failed");
    for (const waiter of waiting.splice(0)) {
      clearTimeout(waiter.timer);
      waiter.reject(terminalError);
    }
  };
  const onMessage = (event: MessageEvent) => {
    const value: unknown = JSON.parse(String(event.data));
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      fail();
      return;
    }
    const message = value as Record<string, unknown>;
    const waiter = waiting.shift();
    if (waiter) {
      clearTimeout(waiter.timer);
      waiter.resolve(message);
    } else {
      queued.push(message);
    }
  };
  socket.addEventListener("message", onMessage);
  socket.addEventListener("close", fail);
  socket.addEventListener("error", fail);
  const next = (): Promise<Record<string, unknown>> => {
    const value = queued.shift();
    if (value) return Promise.resolve(value);
    if (terminalError) return Promise.reject(terminalError);
    return new Promise((resolve, reject) => {
      const waiter = {
        resolve, reject,
        timer: setTimeout(() => {
          const index = waiting.indexOf(waiter);
          if (index >= 0) waiting.splice(index, 1);
          reject(new Error("Timed out waiting for a fixture socket message"));
        }, 2_000),
      };
      waiting.push(waiter);
    });
  };
  const dispose = async () => {
    if (socket.readyState !== WebSocket.CLOSED) {
      await new Promise<void>((resolve) => {
        const onClose = () => { clearTimeout(timer); resolve(); };
        const timer = setTimeout(() => {
          socket.removeEventListener("close", onClose);
          resolve();
        }, 250);
        socket.addEventListener("close", onClose, { once: true });
        if (socket.readyState === WebSocket.OPEN) socket.close(1000, "fixture complete");
      });
    }
    socket.removeEventListener("message", onMessage);
    socket.removeEventListener("close", fail);
    socket.removeEventListener("error", fail);
    fail();
  };
  socket.accept();
  let ready: Record<string, unknown>;
  try {
    ready = await next();
    expect(ready).toMatchObject({ type: "socket.ready", deviceId, authorizationEpoch: 1 });
  } catch (error) {
    await dispose();
    throw error;
  }
  return { socket, next, dispose, ready };
}

function nextMessage(socket: WebSocket): Promise<string> {
  return new Promise((resolve, reject) => {
    socket.addEventListener("message", (event) => resolve(String(event.data)), { once: true });
    socket.addEventListener("error", () => reject(new Error("socket error")), { once: true });
  });
}

function nextClose(socket: WebSocket): Promise<{ code: number; reason: string }> {
  return new Promise((resolve) => {
    socket.addEventListener(
      "close",
      (event) => resolve({ code: event.code, reason: event.reason }),
      { once: true },
    );
  });
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function sha256Base64URL(value: string): Promise<string> {
  return base64url(new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  ));
}
