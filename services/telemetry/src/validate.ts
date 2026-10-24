import { PUBLIC_SOURCES, SCHEMA, type EventSpec, type Source, type ValueSpec } from "./schema.js";

export interface CleanEvent {
  name: string;
  t: number;
  properties: Record<string, string>;
  measurements: Record<string, number>;
}

export interface Batch {
  source: Exclude<Source, "relay">;
  id: string;
  session?: string;
  context: Record<string, string>;
  events: CleanEvent[];
  dropped: number;
}

type Checked =
  | { ok: true; kind: "property"; value: string }
  | { ok: true; kind: "measurement"; value: number }
  | { ok: false };

const REJECT: Checked = { ok: false };
const { limits, types } = SCHEMA;

const EVENTS: Readonly<Record<string, Readonly<Record<string, EventSpec>>>> = SCHEMA.events;
const CONTEXT: Readonly<Record<string, Readonly<Record<string, ValueSpec>>>> = SCHEMA.context;

const patterns = new Map<string, RegExp>();
function regex(pattern: string): RegExp {
  let compiled = patterns.get(pattern);
  if (!compiled) {
    compiled = new RegExp(pattern);
    patterns.set(pattern, compiled);
  }
  return compiled;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function integerIn(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= min && value <= max;
}

function matches(value: unknown, pattern: string): value is string {
  return typeof value === "string" && regex(pattern).test(value);
}

function checkFrames(value: unknown): Checked {
  if (!Array.isArray(value) || value.length > limits.maxFrames) return REJECT;
  const entry = types.frames.entry;
  const clean: { b: string; o: number; n: string }[] = [];
  for (const frame of value) {
    if (!isRecord(frame)) return REJECT;
    const keys = Object.keys(frame);
    if (keys.length !== 3 || !keys.every((key) => key === "b" || key === "o" || key === "n")) return REJECT;
    const { b, o, n } = frame;
    if (!matches(b, types.hexuuid.pattern)) return REJECT;
    if (typeof o !== "number" || !Number.isSafeInteger(o) || o < entry.o.min) return REJECT;
    if (!matches(n, entry.n.pattern)) return REJECT;
    clean.push({ b: b.toLowerCase(), o, n });
  }
  const json = JSON.stringify(clean);
  if (json.length > limits.maxFramesJsonChars) return REJECT;
  return { ok: true, kind: "property", value: json };
}

export function checkValue(spec: ValueSpec, raw: unknown): Checked {
  switch (spec.type) {
    case "ms":
      return integerIn(raw, types.ms.min, types.ms.max) ? { ok: true, kind: "measurement", value: raw } : REJECT;
    case "count":
      return integerIn(raw, types.count.min, types.count.max)
        ? { ok: true, kind: "measurement", value: raw }
        : REJECT;
    case "bool":
      return typeof raw === "boolean" ? { ok: true, kind: "property", value: raw ? "true" : "false" } : REJECT;
    case "version":
    case "code":
    case "uuid":
      return matches(raw, types[spec.type].pattern) ? { ok: true, kind: "property", value: raw } : REJECT;
    case "hexuuid":
      return matches(raw, types.hexuuid.pattern)
        ? { ok: true, kind: "property", value: raw.toLowerCase() }
        : REJECT;
    case "pattern":
      return matches(raw, spec.pattern) ? { ok: true, kind: "property", value: raw } : REJECT;
    case "enum":
      return typeof raw === "string" && spec.values.includes(raw)
        ? { ok: true, kind: "property", value: raw }
        : REJECT;
    case "intEnum":
      return typeof raw === "number" && spec.values.includes(raw)
        ? { ok: true, kind: "measurement", value: raw }
        : REJECT;
    case "frames":
      return checkFrames(raw);
  }
}

export function sanitizeContext(
  source: Exclude<Source, "relay">,
  raw: unknown,
): { context: Record<string, string>; dropped: number } | null {
  if (raw === undefined) return { context: {}, dropped: 0 };
  if (!isRecord(raw)) return null;
  const allowed = CONTEXT[source] ?? {};
  const context: Record<string, string> = {};
  let dropped = 0;
  for (const key of Object.keys(raw)) {
    const spec = Object.hasOwn(allowed, key) ? allowed[key] : undefined;
    const checked = spec ? checkValue(spec, raw[key]) : REJECT;
    if (checked.ok && checked.kind === "property") context[key] = checked.value;
    else dropped += 1;
  }
  return { context, dropped };
}

function sanitizeEvent(
  source: Source,
  raw: unknown,
  now: number,
): { event: CleanEvent; droppedProps: number } | null {
  if (!isRecord(raw)) return null;
  const { name, t, p } = raw;
  if (typeof name !== "string") return null;
  const catalog = EVENTS[source];
  const spec = catalog && Object.hasOwn(catalog, name) ? catalog[name] : undefined;
  if (!spec) return null;
  if (typeof t !== "number" || !Number.isInteger(t)) return null;
  if (t < now - limits.maxAgeMs || t > now + limits.maxFutureMs) return null;
  if (p !== undefined && !isRecord(p)) return null;

  const props = p ?? {};
  const properties: Record<string, string> = {};
  const measurements: Record<string, number> = {};
  let droppedProps = 0;
  for (const key of Object.keys(props)) {
    const propSpec = Object.hasOwn(spec.props, key) ? spec.props[key] : undefined;
    const checked = propSpec ? checkValue(propSpec, props[key]) : REJECT;
    if (!checked.ok) droppedProps += 1;
    else if (checked.kind === "property") properties[key] = checked.value;
    else measurements[key] = checked.value;
  }
  for (const [key, propSpec] of Object.entries(spec.props)) {
    if ("required" in propSpec && propSpec.required && !(key in properties) && !(key in measurements)) {
      return null;
    }
  }
  return { event: { name, t, properties, measurements }, droppedProps };
}

export interface SanitizedEvents {
  events: CleanEvent[];
  dropped: number;
}

export function sanitizeEvents(source: Source, raw: readonly unknown[], now: number): SanitizedEvents {
  const events: CleanEvent[] = [];
  let dropped = 0;
  for (const item of raw) {
    const clean = sanitizeEvent(source, item, now);
    if (!clean) {
      dropped += 1;
      continue;
    }
    // Props dropped from an accepted event count too, so the app can see its own mistakes.
    dropped += clean.droppedProps;
    events.push(clean.event);
  }
  return { events, dropped };
}

export type EnvelopeResult = { ok: true; batch: Batch } | { ok: false };

// A bad envelope rejects the whole batch. Bad events and props inside a good envelope are only dropped.
export function validateBatch(raw: unknown, now: number): EnvelopeResult {
  const invalid: EnvelopeResult = { ok: false };
  if (!isRecord(raw)) return invalid;
  if (raw.version !== SCHEMA.version) return invalid;
  const source = raw.source;
  if (typeof source !== "string" || !(PUBLIC_SOURCES as readonly string[]).includes(source)) return invalid;
  if (!matches(raw.id, types.uuid.pattern)) return invalid;
  if (raw.session !== undefined && !matches(raw.session, types.uuid.pattern)) return invalid;
  const events = raw.events;
  if (!Array.isArray(events) || events.length < limits.minEvents || events.length > limits.maxEvents) {
    return invalid;
  }
  const publicSource = source as Exclude<Source, "relay">;
  const context = sanitizeContext(publicSource, raw.context);
  if (!context) return invalid;

  const clean = sanitizeEvents(publicSource, events, now);
  return {
    ok: true,
    batch: {
      source: publicSource,
      id: raw.id as string,
      ...(raw.session === undefined ? {} : { session: raw.session as string }),
      context: context.context,
      events: clean.events,
      dropped: clean.dropped + context.dropped,
    },
  };
}
