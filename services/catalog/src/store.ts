// D1 reads and writes for templates. Rows hold the validated payload as JSON.

import {
  type TemplateKind, type TemplatePayload, type TemplateSource, type TemplateStatus, titleOf,
} from "./templates.js";

export interface TemplateRow {
  id: string;
  kind: TemplateKind;
  status: TemplateStatus;
  source: TemplateSource;
  payload: string;
  credit_name: string | null;
  submitter_email: string | null;
  submitter_name: string | null;
  submitter_username: string | null;
  status_token_hash: string | null;
  submitter_ip_hash: string | null;
  submitter_github_id: string | null;
  created_at: string;
  updated_at: string;
  reviewed_at: string | null;
  reviewed_by: string | null;
  review_note: string | null;
  sort_key: number;
}

/** A template with its payload parsed, as reviewers see it. */
export function reviewView(row: TemplateRow) {
  const template = toTemplate(row);
  return {
    id: row.id,
    kind: row.kind,
    status: row.status,
    source: row.source,
    title: titleOf(template),
    ...template.payload,
    credit: row.credit_name,
    submitterName: row.submitter_name,
    submitterUsername: row.submitter_username,
    submitterEmail: row.submitter_email,
    submitterGithubId: row.submitter_github_id,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    reviewedAt: row.reviewed_at,
    reviewedBy: row.reviewed_by,
    reviewNote: row.review_note,
  };
}

/** What the app and site get: approved templates only, no emails or review notes. */
export function publicView(row: TemplateRow) {
  const template = toTemplate(row);
  return {
    id: row.id,
    ...template.payload,
    source: row.source,
    ...(row.credit_name ? { credit: row.credit_name } : {}),
    updatedAt: row.updated_at,
  };
}

/** What a submitter sees of their own submissions. */
export function submitterView(row: TemplateRow) {
  return {
    id: row.id,
    kind: row.kind,
    title: titleOf(toTemplate(row)),
    status: row.status,
    reviewNote: row.status === "rejected" ? row.review_note : null,
    createdAt: row.created_at,
  };
}

export function toTemplate(row: TemplateRow): TemplatePayload {
  return { kind: row.kind, payload: JSON.parse(row.payload) } as TemplatePayload;
}

export async function approved(db: D1Database): Promise<TemplateRow[]> {
  const { results } = await db.prepare(
    "SELECT * FROM templates WHERE status = 'approved' ORDER BY kind, sort_key, created_at",
  ).all<TemplateRow>();
  return results;
}

export async function list(
  db: D1Database, filter: { status?: TemplateStatus; kind?: TemplateKind; limit: number },
): Promise<TemplateRow[]> {
  const where: string[] = [];
  const binds: unknown[] = [];
  if (filter.status) { where.push("status = ?"); binds.push(filter.status); }
  if (filter.kind) { where.push("kind = ?"); binds.push(filter.kind); }
  const clause = where.length ? `WHERE ${where.join(" AND ")}` : "";
  const { results } = await db.prepare(
    `SELECT * FROM templates ${clause} ORDER BY created_at DESC LIMIT ?`,
  ).bind(...binds, filter.limit).all<TemplateRow>();
  return results;
}

export async function find(db: D1Database, id: string): Promise<TemplateRow | null> {
  return db.prepare("SELECT * FROM templates WHERE id = ?").bind(id).first<TemplateRow>();
}

/** Submissions whose private status tokens hash to one of these. */
export async function byStatusTokens(db: D1Database, hashes: string[]): Promise<TemplateRow[]> {
  if (!hashes.length) return [];
  const { results } = await db.prepare(
    `SELECT * FROM templates WHERE status_token_hash IN (${hashes.map(() => "?").join(", ")})
     ORDER BY created_at DESC`,
  ).bind(...hashes).all<TemplateRow>();
  return results;
}

/** Pending submissions from one email, and how many that email and that network sent since `since`. */
export async function submitterLoad(db: D1Database, email: string, ipHash: string, since: string) {
  const row = await db.prepare(
    `SELECT
       SUM(CASE WHEN submitter_email = ? AND status = 'pending' THEN 1 ELSE 0 END) AS pending,
       SUM(CASE WHEN submitter_email = ? AND created_at >= ? THEN 1 ELSE 0 END) AS byEmail,
       SUM(CASE WHEN submitter_ip_hash = ? AND created_at >= ? THEN 1 ELSE 0 END) AS byNetwork
     FROM templates WHERE submitter_email = ? OR submitter_ip_hash = ?`,
  ).bind(email, email, since, ipHash, since, email, ipHash)
    .first<{ pending: number | null; byEmail: number | null; byNetwork: number | null }>();
  return { pending: row?.pending ?? 0, byEmail: row?.byEmail ?? 0, byNetwork: row?.byNetwork ?? 0 };
}

/** Pending submissions from one GitHub account, and how many it sent since `since`. */
export async function githubLoad(db: D1Database, githubId: string, since: string) {
  const row = await db.prepare(
    `SELECT
       SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) AS pending,
       SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END) AS recent
     FROM templates WHERE submitter_github_id = ?`,
  ).bind(since, githubId).first<{ pending: number | null; recent: number | null }>();
  return { pending: row?.pending ?? 0, recent: row?.recent ?? 0 };
}

/** Community submissions waiting for review, from every submitter. */
export async function pendingCommunityCount(db: D1Database): Promise<number> {
  const row = await db.prepare(
    "SELECT COUNT(*) AS count FROM templates WHERE status = 'pending' AND source = 'community'",
  ).first<{ count: number }>();
  return row?.count ?? 0;
}

export async function insert(
  db: D1Database,
  input: {
    id: string;
    template: TemplatePayload;
    status: TemplateStatus;
    source: TemplateSource;
    creditName: string | null;
    /** Web form submitters give a name and email; agent submitters are known by their GitHub ID. */
    submitter?: {
      name?: string; username: string; email?: string; githubId?: string; statusTokenHash: string; ipHash?: string;
    };
    now: string;
    reviewedBy?: string;
  },
): Promise<void> {
  const reviewed = input.status === "pending" ? null : input.now;
  await db.prepare(
    `INSERT INTO templates (id, kind, status, source, payload, credit_name, submitter_email, submitter_name,
       submitter_username, status_token_hash, submitter_ip_hash, submitter_github_id, created_at, updated_at,
       reviewed_at, reviewed_by, sort_key)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    input.id, input.template.kind, input.status, input.source, JSON.stringify(input.template.payload),
    input.creditName, input.submitter?.email ?? null, input.submitter?.name ?? null,
    input.submitter?.username ?? null, input.submitter?.statusTokenHash ?? null, input.submitter?.ipHash ?? null,
    input.submitter?.githubId ?? null, input.now, input.now, reviewed, input.reviewedBy ?? null, Date.parse(input.now) / 1000,
  ).run();
}

export async function review(
  db: D1Database,
  id: string,
  change: {
    status: TemplateStatus;
    note: string | null;
    reviewer: string;
    now: string;
    template?: TemplatePayload;
    creditName?: string | null;
  },
): Promise<void> {
  const sets = ["status = ?", "review_note = ?", "reviewed_by = ?", "reviewed_at = ?", "updated_at = ?"];
  const binds: unknown[] = [change.status, change.note, change.reviewer, change.now, change.now];
  if (change.template) { sets.push("payload = ?"); binds.push(JSON.stringify(change.template.payload)); }
  if (change.creditName !== undefined) { sets.push("credit_name = ?"); binds.push(change.creditName); }
  await db.prepare(`UPDATE templates SET ${sets.join(", ")} WHERE id = ?`).bind(...binds, id).run();
}

export async function remove(db: D1Database, id: string): Promise<boolean> {
  const result = await db.prepare("DELETE FROM templates WHERE id = ?").bind(id).run();
  return result.meta.changes > 0;
}
