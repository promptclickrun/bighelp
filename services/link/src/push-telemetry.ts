export type RelayProps = Record<string, string | number | boolean>;

export interface RelayEvent {
  name: string;
  /** Unix milliseconds. */
  t: number;
  p: RelayProps;
}

interface TelemetryBinding {
  relay?: (events: RelayEvent[]) => Promise<void>;
}

/**
 * Sends relay events to the telemetry Worker over its service binding. They
 * hold fixed codes and counts only, never tokens, IDs or message text. The
 * binding is optional and every failure is swallowed: telemetry must not change
 * whether or how a push is delivered.
 */
export function emitRelayEvents(
  env: { TELEMETRY?: unknown },
  ctx: Pick<ExecutionContext, "waitUntil"> | undefined,
  events: RelayEvent[],
): void {
  const binding = env.TELEMETRY as TelemetryBinding | undefined;
  if (!binding || typeof binding.relay !== "function" || events.length === 0) return;
  let pending: Promise<void>;
  try {
    pending = Promise.resolve(binding.relay(events)).then(() => undefined, () => undefined);
  } catch {
    return;
  }
  try { ctx?.waitUntil(pending); } catch { /* the request is already over */ }
}

export function relayEvent(name: string, props: RelayProps): RelayEvent {
  return { name, t: Date.now(), p: props };
}

/** A lowercase code of letters, digits and underscores, at most 64 long. */
export function safeCode(value: string, fallback = "error"): string {
  const code = value.toLowerCase().replace(/[^a-z0-9_]/g, "_").slice(0, 64);
  return code || fallback;
}

/** One line for the Worker log: a fixed event and code, never a token or ID. */
export function logPush(event: string, code: string): void {
  console.info(`[loopdy-link] push_${event}: ${safeCode(code)}`);
}
