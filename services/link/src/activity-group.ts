/**
 * Public status, plus `sealed`: what the card shows beyond its status (the step in
 * progress, a question, the reply's first lines), encrypted by the host for a key only
 * the phone has. This service keeps and forwards those bytes and never reads them.
 * Chat titles, agent names and destinations stay on the phone.
 */
export interface ActivityGroupRow {
  id: string;
  phase: string;
  timestamp: number;
  activeSubagentCount: number;
  latestTool?: string | null;
  sealed?: string;
}

/** One row's sealed detail: unpadded base64url, at most this long. */
export const SEALED_DETAIL = /^[A-Za-z0-9_-]{38,1200}$/;
/** The content state's share of APNs' payload limit; the rest is the `aps` wrapper and the group ID. */
const CONTENT_STATE_BYTES = 3_600;
const bytes = (value: unknown) => new TextEncoder().encode(JSON.stringify(value)).byteLength;

/** A chat row on a shared card. The app names a row "native-" and the SHA-256 of its chat in hex; the 43-character base64url form is kept for rows registered before that was settled. */
export const NATIVE_ROW_ID = /^native-(?:[0-9a-f]{64}|[A-Za-z0-9_-]{43})$/;

export function activityRowPriority(phase: string): number {
  return phase === "waiting" ? 0 : phase === "failed" ? 2 : phase === "completed" ? 3 : 1;
}

export function aggregateActivityRows(rows: ActivityGroupRow[], timestamp: number) {
  const active = rows.filter((row) => row.phase !== "completed" && row.phase !== "failed");
  const activeCount = active.length;
  // Opaque membership hints let the phone hide completed cached rows that do not
  // fit in sessions. These suffixes are never authority or routing identifiers.
  const activeRows = [...new Set(active.map((row) => row.id.slice(-16)))].sort().slice(0, 64);
  const ordered = [...rows].sort((a, b) => activityRowPriority(a.phase) - activityRowPriority(b.phase)
    || a.id.localeCompare(b.id));
  const phase = activeCount === 0 ? (rows.some((row) => row.phase === "failed") ? "failed" : "completed")
    : ordered.find((row) => row.phase !== "completed" && row.phase !== "failed")?.phase ?? "thinking";
  const state = {
    phase, currentAction: "", progress: 0, completedSteps: 0, activeSubagentCount: 0,
    latestTool: null, timestamp, activeCount, activeRows,
    sessions: ordered.slice(0, 5).map(({ sealed: _, ...row }): ActivityGroupRow => row),
  };
  // Sealed detail goes to the rows in the order the card shows them, while the push still fits.
  let size = bytes(state);
  ordered.slice(0, 5).forEach((row, index) => {
    if (!row.sealed) return;
    const cost = bytes({ sealed: row.sealed }) - 1;
    if (size + cost > CONTENT_STATE_BYTES) return;
    state.sessions[index] = { ...state.sessions[index]!, sealed: row.sealed };
    size += cost;
  });
  return state;
}
