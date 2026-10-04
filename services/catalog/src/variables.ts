// Template variables (docs/TEMPLATE_VARIABLES.md): `{{key}}` placeholders in an agent template's text,
// declared in `variables` so the app can ask for each one in a short form.

import { ValidationError, isRecord } from "./templates.js";

export const VARIABLE_TYPES = ["text", "long_text", "choice", "number"] as const;
export type VariableType = (typeof VARIABLE_TYPES)[number];

/** Filled in by the app itself, so a template uses them without declaring them. */
export const RESERVED_KEYS = ["agent_name", "user_name"] as const;

export const VARIABLE_LIMITS = {
  count: 12,
  label: 40,
  example: 120,
  help: 160,
  whenEmpty: 200,
  option: 60,
  minOptions: 2,
  maxOptions: 12,
  textDefault: 80,
  textMax: 200,
  longTextDefault: 600,
  longTextMax: 4_000,
} as const;

export interface TemplateVariable {
  key: string;
  label: string;
  type: VariableType;
  required: boolean;
  default?: string | number;
  example?: string;
  help?: string;
  maxLength?: number;
  options?: string[];
  allowOther?: boolean;
  min?: number;
  max?: number;
  whenEmpty?: string;
}

const KEY = /^[a-z][a-z0-9_]{0,39}$/;
const PLACEHOLDER = /\{\{([a-z][a-z0-9_]{0,39})\}\}/g;

/** The keys a text uses, in order of first use. */
export function placeholderKeys(text: string): string[] {
  return [...new Set([...text.matchAll(PLACEHOLDER)].map((match) => match[1]!))];
}

/** Text with its placeholders taken out still has `{{` or `}}`: a broken or badly named placeholder. */
export function hasStrayBraces(text: string): boolean {
  const rest = text.replace(PLACEHOLDER, "");
  return rest.includes("{{") || rest.includes("}}");
}

/**
 * Checks an agent template's `variables` against the text that uses them. `texts` are the fields that
 * may hold placeholders (instructions, role, description), by field name. Returns the clean list, or
 * nothing when the template declares none.
 */
export function parseVariables(value: unknown, texts: Record<string, string | undefined>): TemplateVariable[] | undefined {
  const used = new Map<string, string>();
  for (const [field, text] of Object.entries(texts)) {
    if (!text) continue;
    if (hasStrayBraces(text)) {
      throw new ValidationError(field, "Use {{ and }} only around a variable key, like {{agent_role}}.");
    }
    for (const key of placeholderKeys(text)) if (!used.has(key)) used.set(key, field);
  }

  let variables: TemplateVariable[] = [];
  if (value !== undefined && value !== null) {
    if (!Array.isArray(value)) throw new ValidationError("variables", "Send a list of variables.");
    if (value.length > VARIABLE_LIMITS.count) {
      throw new ValidationError("variables", `Use at most ${VARIABLE_LIMITS.count} variables.`);
    }
    const seen = new Set<string>();
    variables = value.map((entry, index) => {
      const variable = parseVariable(entry, `variables[${index}]`);
      if (seen.has(variable.key)) {
        throw new ValidationError(`variables[${index}].key`, `${variable.key} is already in variables.`);
      }
      seen.add(variable.key);
      if (!used.has(variable.key)) {
        throw new ValidationError(`variables[${index}].key`,
          `The text never uses {{${variable.key}}}. Use it or remove it from variables.`);
      }
      return variable;
    });
  }

  const declared = new Set(variables.map((variable) => variable.key));
  for (const [key, field] of used) {
    if ((RESERVED_KEYS as readonly string[]).includes(key) || declared.has(key)) continue;
    throw new ValidationError(field, `{{${key}}} isn't in variables. Add it there or take it out of the text.`);
  }
  return variables.length ? variables : undefined;
}

function parseVariable(entry: unknown, path: string): TemplateVariable {
  if (!isRecord(entry)) throw new ValidationError(path, "Each variable is an object.");
  const field = (name: string) => `${path}.${name}`;

  const key = entry.key;
  if (typeof key !== "string" || !KEY.test(key)) {
    throw new ValidationError(field("key"),
      "Use lowercase letters, digits and underscores, starting with a letter, at most 40 characters.");
  }
  if ((RESERVED_KEYS as readonly string[]).includes(key)) {
    throw new ValidationError(field("key"), `${key} is filled in automatically. Remove it from variables.`);
  }
  const label = oneLine(entry.label, field("label"), VARIABLE_LIMITS.label);
  if (!label) throw new ValidationError(field("label"), "Give it a label.");
  const type = entry.type;
  if (typeof type !== "string" || !(VARIABLE_TYPES as readonly string[]).includes(type)) {
    throw new ValidationError(field("type"), `Pick one of: ${VARIABLE_TYPES.join(", ")}.`);
  }
  const variable: TemplateVariable = {
    key, label, type: type as VariableType, required: flag(entry.required, field("required")) ?? true,
  };
  const example = oneLine(entry.example, field("example"), VARIABLE_LIMITS.example);
  if (example) variable.example = example;
  const help = oneLine(entry.help, field("help"), VARIABLE_LIMITS.help);
  if (help) variable.help = help;

  only(entry, ["maxLength"], variable.type === "text" || variable.type === "long_text", path, "text and long_text");
  only(entry, ["options", "allowOther"], variable.type === "choice", path, "choice");
  only(entry, ["min", "max"], variable.type === "number", path, "number");

  switch (variable.type) {
    case "text":
    case "long_text": {
      const [fallback, ceiling] = variable.type === "text"
        ? [VARIABLE_LIMITS.textDefault, VARIABLE_LIMITS.textMax]
        : [VARIABLE_LIMITS.longTextDefault, VARIABLE_LIMITS.longTextMax];
      if (entry.maxLength !== undefined) {
        const maxLength = entry.maxLength;
        if (typeof maxLength !== "number" || !Number.isInteger(maxLength) || maxLength < 1 || maxLength > ceiling) {
          throw new ValidationError(field("maxLength"), `Use a whole number from 1 to ${ceiling}.`);
        }
        variable.maxLength = maxLength;
      }
      const limit = variable.maxLength ?? fallback;
      const value = variable.type === "text"
        ? oneLine(entry.default, field("default"), limit)
        : multiLine(entry.default, field("default"), limit);
      if (value) variable.default = value;
      break;
    }
    case "choice": {
      if (!Array.isArray(entry.options)
        || entry.options.length < VARIABLE_LIMITS.minOptions || entry.options.length > VARIABLE_LIMITS.maxOptions) {
        throw new ValidationError(field("options"),
          `Give ${VARIABLE_LIMITS.minOptions} to ${VARIABLE_LIMITS.maxOptions} options.`);
      }
      const options = entry.options.map((option, index) => {
        const text = oneLine(option, `${field("options")}[${index}]`, VARIABLE_LIMITS.option);
        if (!text) throw new ValidationError(`${field("options")}[${index}]`, "Options can't be empty.");
        return text;
      });
      if (new Set(options).size !== options.length) {
        throw new ValidationError(field("options"), "Each option must be different.");
      }
      variable.options = options;
      const allowOther = flag(entry.allowOther, field("allowOther"));
      if (allowOther) variable.allowOther = true;
      const value = oneLine(entry.default, field("default"), VARIABLE_LIMITS.option);
      if (value) {
        if (!options.includes(value) && !allowOther) {
          throw new ValidationError(field("default"), "Use one of the options.");
        }
        variable.default = value;
      }
      break;
    }
    case "number": {
      const min = finite(entry.min, field("min"));
      const max = finite(entry.max, field("max"));
      if (min !== undefined && max !== undefined && min > max) {
        throw new ValidationError(field("max"), "max must be at least min.");
      }
      if (min !== undefined) variable.min = min;
      if (max !== undefined) variable.max = max;
      const value = typeof entry.default === "string" && entry.default.trim()
        ? Number(entry.default.trim())
        : entry.default;
      const number = finite(value, field("default"));
      if (number !== undefined) {
        if ((min !== undefined && number < min) || (max !== undefined && number > max)) {
          throw new ValidationError(field("default"), "Keep the default between min and max.");
        }
        variable.default = number;
      }
      break;
    }
  }

  if (entry.whenEmpty !== undefined && entry.whenEmpty !== null) {
    if (variable.required) {
      throw new ValidationError(field("whenEmpty"), "Only optional variables (required: false) use whenEmpty.");
    }
    const whenEmpty = multiLine(entry.whenEmpty, field("whenEmpty"), VARIABLE_LIMITS.whenEmpty);
    if (whenEmpty) variable.whenEmpty = whenEmpty;
  }
  return variable;
}

/** Fields that belong to other types are refused, so a typo can't quietly do nothing. */
function only(entry: Record<string, unknown>, names: string[], allowed: boolean, path: string, types: string) {
  if (allowed) return;
  for (const name of names) {
    if (entry[name] !== undefined && entry[name] !== null) {
      throw new ValidationError(`${path}.${name}`, `Only ${types} variables use ${name}.`);
    }
  }
}

function flag(value: unknown, field: string): boolean | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "boolean") throw new ValidationError(field, "Use true or false.");
  return value;
}

function finite(value: unknown, field: string): number | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "number" || !Number.isFinite(value)) throw new ValidationError(field, "Use a number.");
  return value;
}

function multiLine(value: unknown, field: string, max: number): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") throw new ValidationError(field, "Must be text.");
  // eslint-disable-next-line no-control-regex
  const cleaned = value.replace(/\r\n?/g, "\n").replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, "").trim();
  if (cleaned.includes("{{") || cleaned.includes("}}")) throw new ValidationError(field, "Can't use {{ or }}.");
  if (cleaned.length > max) throw new ValidationError(field, `Keep it under ${max} characters.`);
  return cleaned || undefined;
}

function oneLine(value: unknown, field: string, max: number): string | undefined {
  const cleaned = multiLine(value, field, max * 2)?.replace(/\s+/g, " ");
  if (cleaned && cleaned.length > max) throw new ValidationError(field, `Keep it under ${max} characters.`);
  return cleaned || undefined;
}
