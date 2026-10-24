import type { CleanEvent } from "./validate.js";

const DEFAULT_ENDPOINT = "https://dc.services.visualstudio.com";
const FORWARD_TIMEOUT_MS = 5_000;
const INSTRUMENTATION_KEY = /^[0-9a-fA-F-]{32,36}$/;

export interface AppInsightsTarget {
  instrumentationKey: string;
  trackUrl: string;
}

export interface Envelope {
  name: "Microsoft.ApplicationInsights.Event";
  time: string;
  iKey: string;
  tags: Record<string, string>;
  data: {
    baseType: "EventData";
    baseData: {
      ver: 2;
      name: string;
      properties: Record<string, string>;
      measurements: Record<string, number>;
    };
  };
}

// Reads `InstrumentationKey=...;IngestionEndpoint=https://...`. Anything else means "not configured".
export function parseConnectionString(value: string | undefined): AppInsightsTarget | null {
  if (!value) return null;
  const parts = new Map<string, string>();
  for (const segment of value.split(";")) {
    const at = segment.indexOf("=");
    if (at <= 0) continue;
    parts.set(segment.slice(0, at).trim().toLowerCase(), segment.slice(at + 1).trim());
  }
  const instrumentationKey = parts.get("instrumentationkey");
  if (!instrumentationKey || !INSTRUMENTATION_KEY.test(instrumentationKey)) return null;

  let base: URL;
  try {
    base = new URL(parts.get("ingestionendpoint") || DEFAULT_ENDPOINT);
  } catch {
    return null;
  }
  if (base.protocol !== "https:" || base.username || base.password) return null;
  const trackUrl = `${base.origin}${base.pathname.replace(/\/+$/, "")}/v2.1/track`;
  return { instrumentationKey, trackUrl };
}

export interface EnvelopeContext {
  source: "app" | "nse" | "host" | "relay";
  id?: string;
  session?: string;
  context?: Record<string, string>;
}

export function buildEnvelopes(
  target: AppInsightsTarget,
  batch: EnvelopeContext,
  events: readonly CleanEvent[],
): Envelope[] {
  const context = batch.context ?? {};
  const tags: Record<string, string> = { "ai.cloud.role": `bighelp-${batch.source}` };
  const tag = (key: string, value: string | undefined) => {
    if (value) tags[key] = value;
  };
  tag("ai.user.id", batch.id);
  tag("ai.session.id", batch.session);
  tag("ai.application.ver", context.appVersion ?? context.pluginVersion);
  tag("ai.device.type", context.deviceClass);
  tag("ai.device.osVersion", context.osVersion);
  // The Worker never forwards a client address. This stops Application Insights from filling one in.
  tags["ai.location.ip"] = "0.0.0.0";
  tags["ai.internal.sdkVersion"] = "bighelp-telemetry:1";

  return events.map((event) => ({
    name: "Microsoft.ApplicationInsights.Event",
    time: new Date(event.t).toISOString(),
    iKey: target.instrumentationKey,
    tags: { ...tags },
    data: {
      baseType: "EventData",
      baseData: {
        ver: 2,
        name: event.name,
        properties: { ...context, ...event.properties },
        measurements: { ...event.measurements },
      },
    },
  }));
}

export async function forwardEnvelopes(target: AppInsightsTarget, envelopes: readonly Envelope[]): Promise<void> {
  if (envelopes.length === 0) return;
  try {
    const response = await fetch(target.trackUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(envelopes),
      signal: AbortSignal.timeout(FORWARD_TIMEOUT_MS),
    });
    await response.body?.cancel();
    // 206 means some envelopes were refused. Either way the client already has its answer.
    if (!response.ok) console.warn("telemetry_forward_rejected", response.status);
  } catch {
    console.warn("telemetry_forward_failed");
  }
}

export function forwardEvents(
  connectionString: string | undefined,
  batch: EnvelopeContext,
  events: readonly CleanEvent[],
): Promise<void> {
  const target = parseConnectionString(connectionString);
  if (!target) {
    console.warn("telemetry_forward_unconfigured");
    return Promise.resolve();
  }
  return forwardEnvelopes(target, buildEnvelopes(target, batch, events));
}
