// Template shapes and the validation every submission and reviewer edit passes through.

export const BOARDS = ["feed", "ideas", "goals"] as const;
export const BLUEPRINT_CATEGORIES = ["productivity", "marketing", "content", "personal", "research"] as const;
export const GOAL_CATEGORIES = [
  "health", "relationships", "finance", "career", "interests", "productivity", "other",
] as const;
export const AGENT_CATEGORIES = ["work", "personal", "learning", "creative", "research", "support", "fun"] as const;

export type Board = (typeof BOARDS)[number];
export type BlueprintCategory = (typeof BLUEPRINT_CATEGORIES)[number];
export type GoalCategory = (typeof GOAL_CATEGORIES)[number];
export type AgentCategory = (typeof AGENT_CATEGORIES)[number];
export type TemplateKind = "blueprint" | "agent";
export type TemplateStatus = "pending" | "approved" | "rejected";
export type TemplateSource = "bighelp" | "community";

export interface BlueprintPayload {
  board: Board;
  category: BlueprintCategory;
  text: string;
  /** Goals only: the section the goal belongs in. */
  goalCategory?: GoalCategory;
}

export interface AgentPayload {
  name: string;
  role: string;
  vibe: string;
  /** What it's especially good at, shown on its card. */
  description?: string;
  /** Its personality. `{{agent_name}}` stands for the name the person gives it. */
  instructions: string;
  category: AgentCategory;
  /** SF Symbol for its card. Reviewers set it; submissions can't. */
  symbol?: string;
}

export type TemplatePayload =
  | { kind: "blueprint"; payload: BlueprintPayload }
  | { kind: "agent"; payload: AgentPayload };

export const LIMITS = {
  blueprintText: 1_000,
  name: 40,
  role: 80,
  vibe: 120,
  description: 240,
  instructions: 12_000,
  creditName: 40,
  submitterName: 60,
  username: 39,
  email: 254,
  reviewNote: 1_000,
  symbol: 60,
} as const;

export class ValidationError extends Error {
  constructor(readonly field: string, message: string) {
    super(message);
  }
}

type Fields = Record<string, unknown>;

/** Checks an untrusted body and returns a clean payload. `allowSymbol` is for reviewers only. */
export function parseTemplate(body: unknown, options: { allowSymbol?: boolean } = {}): TemplatePayload {
  if (!isRecord(body)) throw new ValidationError("body", "Send a JSON object.");
  switch (body.kind) {
    case "blueprint":
      return { kind: "blueprint", payload: parseBlueprint(body) };
    case "agent":
      return { kind: "agent", payload: parseAgent(body, options.allowSymbol ?? false) };
    default:
      throw new ValidationError("kind", "Pick blueprint or agent.");
  }
}

function parseBlueprint(body: Fields): BlueprintPayload {
  const board = oneOf(body.board, BOARDS, "board");
  const category = oneOf(body.category, BLUEPRINT_CATEGORIES, "category");
  const text = text_(body.text, "text", LIMITS.blueprintText, 20);
  const payload: BlueprintPayload = { board, category, text };
  if (board === "goals") {
    payload.goalCategory = oneOf(body.goalCategory ?? "other", GOAL_CATEGORIES, "goalCategory");
  }
  return payload;
}

function parseAgent(body: Fields, allowSymbol: boolean): AgentPayload {
  const payload: AgentPayload = {
    name: line(body.name, "name", LIMITS.name, 1),
    role: line(body.role, "role", LIMITS.role, 2),
    vibe: line(body.vibe, "vibe", LIMITS.vibe, 2),
    instructions: text_(body.instructions, "instructions", LIMITS.instructions, 80),
    category: oneOf(body.category, AGENT_CATEGORIES, "category"),
  };
  const description = optionalLine(body.description, "description", LIMITS.description);
  if (description) payload.description = description;
  if (allowSymbol) {
    const symbol = optionalLine(body.symbol, "symbol", LIMITS.symbol);
    if (symbol) {
      if (!/^[a-z0-9.]+$/.test(symbol)) throw new ValidationError("symbol", "Use an SF Symbol name.");
      payload.symbol = symbol;
    }
  }
  return payload;
}

export interface Submitter {
  name: string;
  /** Shown publicly as the template's credit. */
  username: string;
  email: string;
}

/** Who sent a submission. Not verified: it only ties their submissions together for reviewers. */
export function parseSubmitter(body: Fields): Submitter {
  const name = line(body.submitterName, "submitterName", LIMITS.submitterName, 1);
  const username = line(body.username, "username", LIMITS.username, 2).replace(/^@/, "");
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(username)) {
    throw new ValidationError("username", "Use letters, numbers, dots, dashes or underscores.");
  }
  const email = line(body.email, "email", LIMITS.email, 3).toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) throw new ValidationError("email", "That email doesn't look right.");
  return { name, username, email };
}

export function parseCreditName(value: unknown): string | null {
  return optionalLine(value, "creditName", LIMITS.creditName) ?? null;
}

export function parseReviewNote(value: unknown, required: boolean): string | null {
  const note = optionalText(value, "note", LIMITS.reviewNote);
  if (required && !note) throw new ValidationError("note", "Say why, so the submitter knows what to change.");
  return note ?? null;
}

/** The short label used in lists: an agent's name or a blueprint's opening words. */
export function titleOf(template: TemplatePayload): string {
  if (template.kind === "agent") return template.payload.name;
  const text = template.payload.text;
  return text.length > 80 ? `${text.slice(0, 77).trimEnd()}…` : text;
}

export function isRecord(value: unknown): value is Fields {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function oneOf<const T extends readonly string[]>(value: unknown, allowed: T, field: string): T[number] {
  if (typeof value === "string" && (allowed as readonly string[]).includes(value)) return value as T[number];
  throw new ValidationError(field, `Pick one of: ${allowed.join(", ")}.`);
}

/** Multi-line text: trimmed, control characters other than newlines and tabs removed. */
function text_(value: unknown, field: string, max: number, min: number): string {
  const cleaned = optionalText(value, field, max);
  if (!cleaned || cleaned.length < min) {
    throw new ValidationError(field, `Write at least ${min} characters.`);
  }
  return cleaned;
}

function optionalText(value: unknown, field: string, max: number): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") throw new ValidationError(field, "Must be text.");
  // eslint-disable-next-line no-control-regex
  const cleaned = value.replace(/\r\n?/g, "\n").replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, "").trim();
  if (cleaned.length > max) throw new ValidationError(field, `Keep it under ${max} characters.`);
  return cleaned || undefined;
}

/** One line: newlines and runs of spaces collapse to a single space. */
function line(value: unknown, field: string, max: number, min: number): string {
  const cleaned = optionalLine(value, field, max);
  if (!cleaned || cleaned.length < min) throw new ValidationError(field, "This one is required.");
  return cleaned;
}

function optionalLine(value: unknown, field: string, max: number): string | undefined {
  const cleaned = optionalText(value, field, max * 2)?.replace(/\s+/g, " ");
  if (cleaned && cleaned.length > max) throw new ValidationError(field, `Keep it under ${max} characters.`);
  return cleaned || undefined;
}
