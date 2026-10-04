// Agent submissions: GitHub identity, install tokens and bans.
//
// The plugin signs the person in with GitHub's device flow and sends the GitHub token here once. We read the
// numeric user ID, then drop the GitHub token and issue our own install token (only its hash is stored).

/** The parts of GitHub's `GET /user` we use. */
export interface GitHubUser {
  id: string;
  login: string;
  createdAt: Date;
}

/** Looks up who a GitHub token belongs to; null when GitHub doesn't accept it. Injectable for tests. */
export type GitHubLookup = (token: string) => Promise<GitHubUser | null>;

export interface AgentInstall {
  github_id: string;
  github_login: string;
}

/** Old installs beyond this many per GitHub ID are dropped on sign-in, so the table stays small. */
const MAX_INSTALLS_PER_ACCOUNT = 20;

export async function githubUser(token: string): Promise<GitHubUser | null> {
  const response = await fetch("https://api.github.com/user", {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "bighelp-catalog",
      "X-GitHub-Api-Version": "2022-11-28",
    },
  });
  if (response.status === 401 || response.status === 403) return null;
  if (!response.ok) throw new Error(`github ${response.status}`);
  const body = await response.json<{ id?: unknown; login?: unknown; created_at?: unknown }>();
  if (typeof body.id !== "number" || typeof body.login !== "string" || typeof body.created_at !== "string") {
    throw new Error("github user shape");
  }
  const createdAt = new Date(body.created_at);
  if (Number.isNaN(createdAt.getTime())) throw new Error("github user created_at");
  return { id: String(body.id), login: body.login, createdAt };
}

export async function isBanned(db: D1Database, githubId: string): Promise<boolean> {
  return (await db.prepare("SELECT 1 FROM banned_github_ids WHERE github_id = ?").bind(githubId).first()) !== null;
}

export async function addInstall(db: D1Database, user: GitHubUser, tokenHash: string, now: string): Promise<void> {
  await db.batch([
    db.prepare(
      "INSERT INTO agent_installs (token_hash, github_id, github_login, created_at, last_used_at) VALUES (?, ?, ?, ?, ?)",
    ).bind(tokenHash, user.id, user.login, now, now),
    // People rename accounts: keep every install's credit name current.
    db.prepare("UPDATE agent_installs SET github_login = ? WHERE github_id = ?").bind(user.login, user.id),
    db.prepare(
      `DELETE FROM agent_installs WHERE github_id = ? AND token_hash NOT IN (
         SELECT token_hash FROM agent_installs WHERE github_id = ? ORDER BY created_at DESC LIMIT ?)`,
    ).bind(user.id, user.id, MAX_INSTALLS_PER_ACCOUNT),
  ]);
}

/** The install a token belongs to, unless its account is banned. Marks it used. */
export async function installFor(db: D1Database, tokenHash: string, now: string): Promise<AgentInstall | null> {
  const install = await db.prepare(
    `SELECT github_id, github_login FROM agent_installs
     WHERE token_hash = ? AND github_id NOT IN (SELECT github_id FROM banned_github_ids)`,
  ).bind(tokenHash).first<AgentInstall>();
  if (install) {
    await db.prepare("UPDATE agent_installs SET last_used_at = ? WHERE token_hash = ?").bind(now, tokenHash).run();
  }
  return install;
}

export async function removeInstall(db: D1Database, tokenHash: string): Promise<boolean> {
  const result = await db.prepare("DELETE FROM agent_installs WHERE token_hash = ?").bind(tokenHash).run();
  return result.meta.changes > 0;
}

/** Bans an account: its installs stop working now and it can't sign in again until unbanned. */
export async function ban(db: D1Database, githubId: string, reviewer: string, note: string | null, now: string) {
  const [, removed] = await db.batch([
    db.prepare(
      `INSERT INTO banned_github_ids (github_id, banned_at, banned_by, note) VALUES (?, ?, ?, ?)
       ON CONFLICT (github_id) DO UPDATE SET banned_at = excluded.banned_at, banned_by = excluded.banned_by,
         note = excluded.note`,
    ).bind(githubId, now, reviewer, note),
    db.prepare("DELETE FROM agent_installs WHERE github_id = ?").bind(githubId),
  ]);
  return { githubId, banned: true, installsRemoved: removed?.meta.changes ?? 0 };
}

export async function unban(db: D1Database, githubId: string) {
  const result = await db.prepare("DELETE FROM banned_github_ids WHERE github_id = ?").bind(githubId).run();
  return { githubId, banned: false, changed: result.meta.changes > 0 };
}
