import { describe, expect, it } from "vitest";
import contract from "../../../contracts/telemetry-v1.json" with { type: "json" };
import { SCHEMA } from "../src/schema.js";

type Spec = { type: string; pattern?: string };

const loose = SCHEMA as unknown as {
  context: Record<string, Record<string, Spec>>;
  events: Record<string, Record<string, { props: Record<string, Spec> }>>;
};

function allSpecs(): Spec[] {
  const specs: Spec[] = [];
  for (const context of Object.values(loose.context)) specs.push(...Object.values(context));
  for (const source of Object.values(loose.events)) {
    for (const event of Object.values(source)) specs.push(...Object.values(event.props));
  }
  return specs;
}

// Every `pattern` string anywhere in the schema, including the named types and the frame entry.
function allPatterns(node: unknown, found: string[] = []): string[] {
  if (Array.isArray(node)) node.forEach((item) => allPatterns(item, found));
  else if (typeof node === "object" && node !== null) {
    for (const [key, value] of Object.entries(node)) {
      if (key === "pattern" && typeof value === "string") found.push(value);
      else allPatterns(value, found);
    }
  }
  return found;
}

describe("telemetry schema", () => {
  it("matches contracts/telemetry-v1.json exactly", () => {
    const { $comment, ...canonical } = contract as Record<string, unknown>;
    expect(typeof $comment).toBe("string");
    expect(JSON.parse(JSON.stringify(SCHEMA))).toEqual(canonical);
  });

  it("anchors every pattern so a partial match can never pass", () => {
    const patterns = allPatterns(SCHEMA);
    expect(patterns.length).toBeGreaterThan(10);
    for (const pattern of patterns) {
      expect(pattern.startsWith("^"), pattern).toBe(true);
      expect(pattern.endsWith("$"), pattern).toBe(true);
      expect(() => new RegExp(pattern)).not.toThrow();
    }
  });

  it("only uses value types the validator knows", () => {
    const known = new Set(["ms", "count", "bool", "version", "code", "uuid", "hexuuid", "frames", "enum", "intEnum", "pattern"]);
    for (const spec of allSpecs()) expect(known.has(spec.type), spec.type).toBe(true);
  });

  it("keeps relay out of the public sources", () => {
    expect(SCHEMA.publicSources).toEqual(["app", "nse", "host"]);
    expect(SCHEMA.rpcOnlySources).toEqual(["relay"]);
    expect(Object.keys(SCHEMA.events).sort()).toEqual(["app", "host", "nse", "relay"]);
  });

  it("bounds the length of every custom pattern", () => {
    for (const spec of allSpecs()) {
      if (spec.type === "pattern") expect(spec.pattern ?? "").toMatch(/\{\d+(,\d+)?\}|\|/);
    }
  });
});
