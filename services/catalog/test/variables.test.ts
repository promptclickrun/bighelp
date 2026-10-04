import { describe, expect, it } from "vitest";
import seed from "../seed/0001_bundled.sql?raw";
import { ValidationError, parseTemplate } from "../src/templates.js";

const instructions = [
  "# {{agent_name}}",
  "",
  "You are {{agent_name}}, a {{agent_role}} for {{user_name}}.",
  "",
  "Operating context: {{operating_context}}",
  "",
  "Tone: {{tone}}. Keep the {{agent_role}} title to the work.",
].join("\n");

const variables = [
  { key: "agent_role", label: "Role", type: "text", required: true, example: "Release coordinator",
    help: "What this agent does for you, in a few words.", maxLength: 80 },
  { key: "operating_context", label: "Where it works", type: "long_text", required: false,
    example: "A two-person studio shipping an iPhone app.", maxLength: 600, whenEmpty: "General work for the user." },
  { key: "tone", label: "Tone", type: "choice", options: ["Warm", "Direct", "Playful"], default: "Direct" },
];

const agent = {
  kind: "agent",
  name: "Field Lead",
  role: "{{agent_role}}",
  vibe: "Confident, practical, quick",
  description: "Turns intent into owners, milestones and decision points.",
  instructions,
  category: "work",
  variables,
};

/** The field a bad template is refused for. */
function refusedField(body: Record<string, unknown>): string {
  try {
    parseTemplate(body);
  } catch (error) {
    if (error instanceof ValidationError) return error.field;
    throw error;
  }
  throw new Error("expected the template to be refused");
}

function withVariable(index: number, change: Record<string, unknown>) {
  return { ...agent, variables: variables.map((variable, at) => (at === index ? { ...variable, ...change } : variable)) };
}

describe("template variables", () => {
  it("keeps a template's variables, with required filled in", () => {
    const template = parseTemplate(agent);
    expect(template.kind).toBe("agent");
    if (template.kind !== "agent") return;
    expect(template.payload.role).toBe("{{agent_role}}");
    expect(template.payload.variables).toEqual([
      { ...variables[0] },
      { ...variables[1] },
      { key: "tone", label: "Tone", type: "choice", required: true, options: ["Warm", "Direct", "Playful"],
        default: "Direct" },
    ]);
  });

  it("leaves templates without variables as they are", () => {
    const plain = { ...agent, role: "Lead", instructions: "You are {{agent_name}}. Help {{user_name}} plan the week ahead, one small and honest step at a time.",
      variables: undefined };
    const template = parseTemplate(plain);
    expect(template.kind === "agent" && "variables" in template.payload).toBe(false);
    expect(parseTemplate({ ...plain, variables: [] }).payload).not.toHaveProperty("variables");
  });

  it("refuses a key the text uses but variables don't declare, naming the field that uses it", () => {
    expect(refusedField({ ...agent, variables: variables.slice(1) })).toBe("role");
    expect(refusedField({ ...agent, role: "Lead", variables: variables.slice(1) })).toBe("instructions");
    expect(refusedField({ ...agent, description: "Good at {{deadlines}} and more." })).toBe("description");
  });

  it("refuses a declared key the text never uses", () => {
    expect(refusedField({ ...agent, variables: [...variables, { key: "budget", label: "Budget", type: "number" }] }))
      .toBe("variables[3].key");
  });

  it("refuses reserved, badly named and repeated keys", () => {
    expect(refusedField(withVariable(0, { key: "agent_name" }))).toBe("variables[0].key");
    expect(refusedField(withVariable(0, { key: "user_name" }))).toBe("variables[0].key");
    expect(refusedField(withVariable(0, { key: "Agent Role" }))).toBe("variables[0].key");
    expect(refusedField(withVariable(0, { key: "1role" }))).toBe("variables[0].key");
    expect(refusedField(withVariable(0, { key: `a${"b".repeat(40)}` }))).toBe("variables[0].key");
    expect(refusedField({ ...agent, variables: [...variables, variables[2]] })).toBe("variables[3].key");
  });

  it("refuses stray braces and placeholders with spaces or capitals", () => {
    expect(refusedField({ ...agent, instructions: `${instructions}\nUse {{ agent_role }} here.` })).toBe("instructions");
    expect(refusedField({ ...agent, instructions: `${instructions}\nUse {{Role}} here.` })).toBe("instructions");
    expect(refusedField({ ...agent, instructions: `${instructions}\nA lone }} here.` })).toBe("instructions");
    expect(refusedField({ ...agent, name: "{{agent_name}}" })).toBe("name");
    expect(refusedField({ ...agent, vibe: "Calm {{tone}}" })).toBe("vibe");
  });

  it("checks each field's limits", () => {
    expect(refusedField({ ...agent, variables: "agent_role" })).toBe("variables");
    const thirteen = Array.from({ length: 13 }, (_, index) => ({ key: `v${index}`, label: `V${index}`, type: "text" }));
    expect(refusedField({ ...agent, instructions: thirteen.map((v) => `{{${v.key}}}`).join(" ").padEnd(90, "."),
      role: "Lead", variables: thirteen })).toBe("variables");
    expect(refusedField(withVariable(0, { label: "" }))).toBe("variables[0].label");
    expect(refusedField(withVariable(0, { label: "x".repeat(41) }))).toBe("variables[0].label");
    expect(refusedField(withVariable(0, { type: "date" }))).toBe("variables[0].type");
    expect(refusedField(withVariable(0, { required: "yes" }))).toBe("variables[0].required");
    expect(refusedField(withVariable(0, { example: "x".repeat(121) }))).toBe("variables[0].example");
    expect(refusedField(withVariable(0, { help: "x".repeat(161) }))).toBe("variables[0].help");
    expect(refusedField(withVariable(0, { maxLength: 201 }))).toBe("variables[0].maxLength");
    expect(refusedField(withVariable(0, { maxLength: 0 }))).toBe("variables[0].maxLength");
    expect(refusedField(withVariable(1, { maxLength: 4001 }))).toBe("variables[1].maxLength");
    expect(parseTemplate(withVariable(1, { maxLength: 4000 }))).toBeTruthy();
    expect(refusedField(withVariable(0, { default: "x".repeat(81) }))).toBe("variables[0].default");
    expect(refusedField(withVariable(0, { default: "Use {{tone}}" }))).toBe("variables[0].default");
    expect(refusedField(withVariable(1, { whenEmpty: "x".repeat(201) }))).toBe("variables[1].whenEmpty");
    expect(refusedField(withVariable(0, { whenEmpty: "Anything" }))).toBe("variables[0].whenEmpty");
    expect(refusedField(withVariable(0, { options: ["A", "B"] }))).toBe("variables[0].options");
    expect(refusedField(withVariable(0, { min: 1 }))).toBe("variables[0].min");
  });

  it("checks choices and numbers", () => {
    expect(refusedField(withVariable(2, { options: ["Warm"] }))).toBe("variables[2].options");
    expect(refusedField(withVariable(2, { options: Array.from({ length: 13 }, (_, i) => `O${i}`) })))
      .toBe("variables[2].options");
    expect(refusedField(withVariable(2, { options: ["Warm", "x".repeat(61)] }))).toBe("variables[2].options[1]");
    expect(refusedField(withVariable(2, { options: ["Warm", "Warm"] }))).toBe("variables[2].options");
    expect(refusedField(withVariable(2, { default: "Grumpy" }))).toBe("variables[2].default");
    expect(parseTemplate(withVariable(2, { default: "Grumpy", allowOther: true }))).toBeTruthy();
    expect(refusedField(withVariable(2, { maxLength: 20 }))).toBe("variables[2].maxLength");

    const number = { key: "tone", label: "Team size", type: "number", min: 1, max: 50, default: 4 };
    const template = parseTemplate({ ...agent, variables: [variables[0], variables[1], number] });
    expect(template.payload).toMatchObject({ variables: [{}, {}, { type: "number", min: 1, max: 50, default: 4 }] });
    expect(refusedField({ ...agent, variables: [variables[0], variables[1], { ...number, default: 60 }] }))
      .toBe("variables[2].default");
    expect(refusedField({ ...agent, variables: [variables[0], variables[1], { ...number, min: 9, max: 2 }] }))
      .toBe("variables[2].max");
    expect(refusedField({ ...agent, variables: [variables[0], variables[1], { ...number, min: "1" }] }))
      .toBe("variables[2].min");
    expect(refusedField({ ...agent, variables: [variables[0], variables[1], { ...number, options: ["A", "B"] }] }))
      .toBe("variables[2].options");
  });

  it("passes every agent in the seed", () => {
    const agents = [...seed.matchAll(/VALUES \('[^']+', 'agent', 'approved', 'bighelp', '((?:[^']|'')*)'/g)]
      .map((match) => JSON.parse(match[1]!.replace(/''/g, "'")) as Record<string, unknown>);
    expect(agents.length).toBeGreaterThanOrEqual(15);
    for (const payload of agents) {
      expect(() => parseTemplate({ ...payload, kind: "agent" }, { allowSymbol: true })).not.toThrow();
    }
  });
});
