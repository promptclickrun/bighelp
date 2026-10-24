/** Public status only. Chat titles, agent names and destinations stay on the phone. */
export interface ActivityGroupRow {
  id: string;
  phase: string;
  timestamp: number;
  activeSubagentCount: number;
  latestTool?: string | null;
}

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
  return {
    phase, currentAction: "", progress: 0, completedSteps: 0, activeSubagentCount: 0,
    latestTool: null, timestamp, activeCount, activeRows,
    sessions: ordered.slice(0, 5),
  };
}
