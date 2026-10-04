// Writes seed/0001_bundled.sql from the app's bundled starter content, so the catalog starts with
// exactly what the app ships: the 45 Feed/Ideas/Goals blueprints and the 15 built-in agents.
// Ids are kept (feed-productivity-1, anchor, ...) so the app can match remote to bundled items.
//
//   node scripts/build-seed.mjs && wrangler d1 execute bighelp-catalog --remote --file seed/0001_bundled.sql

import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const app = join(here, "../../../Bighelp");
const now = "2026-10-04T00:00:00.000Z";

const blueprints = JSON.parse(readFileSync(join(app, "Resources/BoardBlueprints.json"), "utf8"));

// Mirrors AgentSoulTemplate.all in Bighelp/Agents/AgentSoulTemplates.swift.
const agents = [
  ["anchor", "Anchor", "Everyday generalist", "Warm, direct, adaptable", "Helps with vague requests without turning simple tasks into an interview.", "sun.max", "personal"],
  ["compass", "Compass", "Chief-of-staff partner", "Concise, discreet, decisive", "Sorts out conflicting priorities without inventing authority or commitments.", "safari", "work"],
  ["spark", "Spark", "Focus companion", "Gentle, concrete, encouraging", "Helps you get started, and start again after a gap, without shame.", "bolt", "personal"],
  ["lumen", "Lumen", "Learning partner", "Patient, curious, accessible", "Explains things another way when the first one doesn't land, at any age.", "lightbulb", "learning"],
  ["lens", "Lens", "Research partner", "Measured, precise, inquisitive", "Resists confirmation bias and says when evidence is missing, not disproved.", "magnifyingglass", "research"],
  ["forge", "Forge", "Engineering partner", "Candid, pragmatic, technical", "Keeps a plausible fix, passing checks and a working result apart.", "hammer", "work"],
  ["beacon", "Beacon", "Incident partner", "Calm, brief, factual", "Communicates under pressure without false certainty or early all-clears.", "light.beacon.max", "work"],
  ["counterpoint", "Counterpoint", "Strategy challenger", "Independent, fair, incisive", "Challenges big assumptions without becoming reflexively contrarian.", "arrow.left.arrow.right", "work"],
  ["muse", "Muse", "Creative collaborator", "Inventive, vivid, playful", "Takes a real new direction after a no, and keeps fiction apart from fact.", "paintpalette", "creative"],
  ["quill", "Quill", "Editor and writing partner", "Clear, attentive, restrained", "Improves your writing without changing its meaning, voice or promises.", "pencil.line", "creative"],
  ["bridge", "Bridge", "Support and resolution partner", "Patient, courteous, firm", "Handles anger and demands for guarantees without fake fixes or scripted empathy.", "bubble.left.and.bubble.right", "support"],
  ["hearth", "Hearth", "Household companion", "Warm, practical, considerate", "Handles a shared home: different people, preferences and private things.", "house", "personal"],
  ["harbor", "Harbor", "Reflective companion", "Gentle, attentive, grounded", "Offers support without encouraging dependence or claiming human feelings.", "heart", "support"],
  ["waypoint", "Waypoint", "Consequential-information guide", "Careful, plainspoken, calm", "Explains sensitive matters without posing as a professional or promising outcomes.", "signpost.right", "support"],
  ["fable", "Fable", "Playful storyteller", "Imaginative, lightly theatrical", "Stays in character for fun, and drops it the moment you need it plain.", "book", "fun"],
];

const sql = (value) => (value === null ? "NULL" : `'${String(value).replace(/'/g, "''")}'`);
const rows = [];
let sort = 0;
const insert = (id, kind, payload) => {
  sort += 1;
  rows.push(`INSERT OR REPLACE INTO templates (id, kind, status, source, payload, credit_name, submitter_email, created_at, updated_at, reviewed_at, reviewed_by, sort_key) VALUES (${[
    sql(id), sql(kind), sql("approved"), sql("bighelp"), sql(JSON.stringify(payload)), "NULL", "NULL",
    sql(now), sql(now), sql(now), sql("seed"), sort,
  ].join(", ")});`);
};

for (const page of blueprints.pages) {
  for (const group of page.groups) {
    for (const prompt of group.prompts) {
      const payload = { board: page.page, category: group.id, text: prompt.text };
      if (prompt.goalCategory) payload.goalCategory = prompt.goalCategory;
      insert(prompt.id, "blueprint", payload);
    }
  }
}

for (const [id, name, role, vibe, description, symbol, category] of agents) {
  const instructions = readFileSync(join(app, `Resources/SoulTemplates/soul-${id}.md`), "utf8").trim();
  const payload = { name, role, vibe, description, instructions, category, symbol };
  // A template with fill-in fields (docs/TEMPLATE_VARIABLES.md) keeps them beside its text.
  const variablesFile = join(app, `Resources/SoulTemplates/soul-${id}.variables.json`);
  if (existsSync(variablesFile)) payload.variables = JSON.parse(readFileSync(variablesFile, "utf8"));
  insert(id, "agent", payload);
}

mkdirSync(join(here, "../seed"), { recursive: true });
writeFileSync(join(here, "../seed/0001_bundled.sql"), rows.join("\n") + "\n");
console.log(`wrote ${rows.length} templates`);
