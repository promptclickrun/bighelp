import type { PushTargetEnv } from "./push-targets.js";

export type PushSendState = "sending" | "sent" | "queued" | "buzzkit";

export const PUSH_SEND_RETENTION_SECONDS = 86_400;
/** A claim that never finished (the Worker was cut off) can be taken over after this. */
export const PUSH_SEND_STALE_SECONDS = 60;

export type PushSendClaim =
  | { status: "claimed" }
  /** Sent, or waiting in the retry queue. Nothing more to do. */
  | { status: "duplicate"; state: "sent" | "queued" }
  /** Another request is sending it right now. The caller should be told to try again. */
  | { status: "in_flight" }
  /** An earlier attempt gave this message to BuzzKit, which deduplicates by its own key. */
  | { status: "buzzkit" };

/**
 * Claims the right to send one message directly. A second claim for the same
 * key is not a second send: it is a duplicate, still in flight, or already with
 * BuzzKit. A claim that stalled, or whose record expired, can be taken over.
 */
export async function claimPushSend(
  env: PushTargetEnv,
  installationId: string,
  dedupeKey: string,
  apnsId: string,
  now: number,
): Promise<PushSendClaim> {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const result = await env.ACCOUNTS.prepare(`INSERT INTO push_sends(
        dedupe_key,installation_id,apns_id,state,created_at,expires_at)
      VALUES(?,?,?,'sending',?,?)
      ON CONFLICT(dedupe_key) DO UPDATE SET
        installation_id=excluded.installation_id,apns_id=excluded.apns_id,state='sending',
        created_at=excluded.created_at,expires_at=excluded.expires_at
      WHERE push_sends.expires_at<=? OR (push_sends.state='sending' AND push_sends.created_at<=?)`)
      .bind(dedupeKey, installationId, apnsId, now, now + PUSH_SEND_RETENTION_SECONDS,
        now, now - PUSH_SEND_STALE_SECONDS).run();
    if (result.meta.changes === 1) return { status: "claimed" };
    const row = await env.ACCOUNTS.prepare("SELECT state FROM push_sends WHERE dedupe_key=?")
      .bind(dedupeKey).first<{ state: PushSendState }>();
    // No row means it was released between the two reads, so claim again.
    if (!row) continue;
    if (row.state === "sending") return { status: "in_flight" };
    if (row.state === "buzzkit") return { status: "buzzkit" };
    return { status: "duplicate", state: row.state };
  }
  return { status: "in_flight" };
}

export async function finishPushSend(
  env: PushTargetEnv,
  dedupeKey: string,
  state: "sent" | "queued",
): Promise<void> {
  await env.ACCOUNTS.prepare("UPDATE push_sends SET state=? WHERE dedupe_key=?")
    .bind(state, dedupeKey).run();
}

/** Records that this message is going to BuzzKit, so a repeat goes there too. */
export async function handPushSendToBuzzKit(env: PushTargetEnv, dedupeKey: string): Promise<void> {
  await env.ACCOUNTS.prepare("UPDATE push_sends SET state='buzzkit' WHERE dedupe_key=?")
    .bind(dedupeKey).run();
}

/** Lets the host try again. Used when nothing was sent and nothing will be. */
export async function releasePushSend(env: PushTargetEnv, dedupeKey: string): Promise<void> {
  await env.ACCOUNTS.prepare("DELETE FROM push_sends WHERE dedupe_key=?").bind(dedupeKey).run();
}

export async function pushSendState(env: PushTargetEnv, dedupeKey: string): Promise<PushSendState | null> {
  const row = await env.ACCOUNTS.prepare("SELECT state FROM push_sends WHERE dedupe_key=?")
    .bind(dedupeKey).first<{ state: PushSendState }>();
  return row?.state ?? null;
}
