import { describe, expect, it } from "vitest";
import { parseTemplate } from "../src/templates.js";

// The repo's catalog/ directory is published as-is by scripts/catalog-sync.py, so every file must pass the
// same checks the Worker applies to a reviewer's template. A bad file fails the pull request, not the sync.
const files = import.meta.glob<string>("../../../catalog/**/*.{json,md}", { query: "?raw", import: "default", eager: true });

const at = (path: string) => path.replace("../../../catalog/", "");
const json = (path: string) => JSON.parse(files[path]!) as Record<string, unknown>;

describe("catalog/ in the repo", () => {
  const agents = Object.keys(files).filter((path) => path.endsWith("/template.json"));
  const blueprints = Object.keys(files).filter((path) => path.includes("/blueprints/"));

  it("holds templates", () => {
    expect(agents.length).toBeGreaterThan(0);
    expect(blueprints.length).toBeGreaterThan(0);
  });

  it.each(agents.map((path) => [at(path), path]))("%s passes the Worker's agent checks", (_name, path) => {
    const instructions = files[path.replace("template.json", "instructions.md")];
    expect(instructions, "instructions.md beside template.json").toBeTypeOf("string");
    expect(() => parseTemplate({ ...json(path), kind: "agent", instructions }, { allowSymbol: true })).not.toThrow();
  });

  it.each(blueprints.map((path) => [at(path), path]))("%s passes the Worker's blueprint checks", (name, path) => {
    const blueprint = json(path);
    expect(blueprint.board, "board matches its folder").toBe(name.split("/")[1]);
    expect(() => parseTemplate({ ...blueprint, kind: "blueprint" })).not.toThrow();
  });

  it("gives every template its own id", () => {
    const ids = [...agents, ...blueprints].map((path) => json(path).id);
    expect(new Set(ids).size).toBe(ids.length);
  });
});
