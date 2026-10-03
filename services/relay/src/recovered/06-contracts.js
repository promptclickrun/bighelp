// ../../packages/contracts/src/ids.ts
var Id = string2().min(1);
var IsoDate = string2().datetime({ offset: true });
var ActorSchema = object({
  userId: Id,
  workspaceId: Id,
  email: string2().email(),
  isDeploymentOwner: boolean2()
});
var RunStatus = _enum2([
  "queued",
  "leased",
  "running",
  "waiting_input",
  "waiting_takeover",
  "completed",
  "failed",
  "cancelled"
]);
var EffectStatus = _enum2(["intended", "completed", "failed", "ambiguous", "reconciled"]);
var MemoryScope = _enum2(["bot", "user"]);
var SandboxKind = _enum2(["docker", "e2b", "desktop", "fake"]);

// ../../packages/contracts/src/events.ts
var ProductEventType = _enum2([
  "thread.message.created",
  "thread.progress",
  "thread.artifact",
  "thread.ask",
  "thread.choice",
  "thread.meta",
  "thread.computer",
  "thread.subagent",
  "thread.activity",
  "thread.reconciled",
  "run.started",
  "run.checkpointed",
  "run.completed",
  "run.failed",
  "run.cancelled",
  "computer.status",
  "computer.takeover.requested",
  "computer.takeover.granted",
  "computer.takeover.released",
  "memory.revised",
  "routine.created",
  "routine.updated",
  "routine.fired",
  "effect.recorded",
  "effect.reconciled",
  "usage.recorded",
  "bot.spawned",
  "bot.deleted"
]);
var MessageRole = _enum2(["user", "bot", "system"]);
var ClarifyChoiceSchema = object({ id: string2(), label: string2() });
var ClarifyQuestionSchema = object({
  questionId: string2().min(1),
  question: string2().min(1),
  choices: array(ClarifyChoiceSchema),
  multiSelect: boolean2()
});
var MessageBlock = discriminatedUnion("kind", [
  object({ kind: literal("text"), text: string2() }),
  object({
    kind: literal("card"),
    lines: array(object({ k: string2(), v: string2() }))
  }),
  object({
    kind: literal("ask"),
    text: string2(),
    detail: string2().optional(),
    actions: array(object({ id: string2(), label: string2() })).optional()
  }),
  object({
    kind: literal("choice"),
    question: string2(),
    subtitle: string2().optional(),
    options: array(object({ id: string2(), letter: string2(), label: string2() }))
  }),
  object({
    kind: literal("connect"),
    name: string2(),
    initial: string2(),
    color: string2(),
    status: _enum2(["pending", "connected"])
  }),
  object({
    kind: literal("computer"),
    state: string2(),
    text: string2()
  }),
  object({ kind: literal("meta"), text: string2() }),
  object({ kind: literal("progress"), text: string2() }),
  object({ kind: literal("interim"), text: string2() }),
  object({
    kind: literal("reasoning"),
    text: string2(),
    status: _enum2(["running", "complete"])
  }),
  object({
    kind: literal("tool"),
    toolId: string2(),
    name: string2(),
    status: _enum2(["running", "completed", "failed"]),
    detail: string2().optional(),
    progress: string2().optional(),
    args: record(string2(), unknown()).optional(),
    result: unknown().optional()
  }),
  object({
    kind: literal("approval"),
    requestId: string2(),
    text: string2(),
    actions: array(object({ id: string2(), label: string2() }))
  }),
  object({
    kind: literal("clarify"),
    requestId: string2(),
    question: string2(),
    choices: array(ClarifyChoiceSchema),
    multiSelect: boolean2().optional(),
    questions: array(ClarifyQuestionSchema).optional(),
    answers: record(string2(), string2()).optional()
  }),
  object({
    kind: literal("bot_activity"),
    profile: string2(),
    name: string2(),
    status: _enum2(["running", "completed", "failed", "interrupted"]),
    detail: string2(),
    deliveryId: string2().optional(),
    task: string2().optional(),
    result: string2().optional(),
    processId: string2().optional(),
    sessionId: string2().optional()
  }),
  object({
    kind: literal("subagent"),
    agentId: string2(),
    name: string2(),
    task: string2(),
    status: _enum2(["running", "completed", "failed"]),
    progress: string2().optional(),
    result: string2().optional()
  }),
  object({
    kind: literal("child_bot"),
    botId: string2(),
    name: string2(),
    title: string2().optional(),
    status: _enum2(["created", "deleted"])
  })
]);
var ProductEventSchema = object({
  id: Id,
  workspaceId: Id,
  threadId: Id,
  botId: Id,
  seq: number2().int().nonnegative(),
  type: ProductEventType,
  runId: Id.optional(),
  createdAt: string2(),
  payload: record(string2(), unknown())
});
var ThreadMessageSchema = object({
  id: Id,
  threadId: Id,
  seq: number2().int().nonnegative(),
  role: MessageRole,
  sourceRowId: number2().int().positive().optional(),
  blocks: array(MessageBlock),
  runId: Id.optional(),
  createdAt: string2(),
  attribution: object({ senderName: string2(), senderProfile: string2().nullable() }).optional()
});

// ../../packages/contracts/src/hermes-reasoning.ts
var HERMES_REASONING_EFFORTS = [
  "none",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
  "ultra"
];
var HermesReasoningEffortSchema = _enum2(HERMES_REASONING_EFFORTS);
var GPT_REASONING_EFFORTS = HERMES_REASONING_EFFORTS.slice(0, 7);

// ../../packages/contracts/src/profile-appearance.ts
var PROFILE_TAG_SATURATION = 68;
var PROFILE_TAG_LIGHTNESS = 58;
var HERMES_PROFILE_SWATCHES = Array.from(
  { length: 12 },
  (_, index) => `hsl(${index * 30} ${PROFILE_TAG_SATURATION}% ${PROFILE_TAG_LIGHTNESS}%)`
);

// ../../packages/contracts/src/hermes.ts
var HermesProfileNameSchema = string2().regex(/^[a-z0-9][a-z0-9_-]{0,63}$/, "Profile name must be a lowercase slug");
var HermesModelSelectionSchema = object({
  provider: string2(),
  default: string2()
});
var ProfileDetailSchema = object({
  name: HermesProfileNameSchema,
  description: string2(),
  soul: string2(),
  model: HermesModelSelectionSchema,
  skills: array(object({ name: string2(), enabled: boolean2() })),
  toolsets: array(
    object({
      name: string2(),
      label: string2(),
      description: string2(),
      toolCount: number2().int().nonnegative(),
      enabled: boolean2()
    })
  ),
  toolsetsPinned: boolean2(),
  mcpServers: array(object({ name: string2(), enabled: boolean2(), transport: string2() })),
  uiMeta: record(string2(), unknown()),
  avatarData: string2().startsWith("data:image/").nullable()
});
var HermesRuntimeCapabilitySchema = object({
  reasoning: boolean2(),
  fast: boolean2()
});
var HermesRuntimeProviderSchema = object({
  slug: string2().min(1),
  name: string2().min(1),
  models: array(string2().min(1)),
  capabilities: record(string2(), HermesRuntimeCapabilitySchema)
});
var HermesAgentRuntimeSchema = object({
  model: string2(),
  provider: string2(),
  reasoningEffort: union([HermesReasoningEffortSchema, literal("")]),
  providers: array(HermesRuntimeProviderSchema)
});
var HermesSessionSummarySchema = object({
  id: string2().min(1),
  title: string2(),
  preview: string2(),
  startedAt: string2().datetime(),
  lastActiveAt: string2().datetime(),
  active: boolean2(),
  messageCount: number2().int().nonnegative(),
  source: string2()
});
var HermesCommandCatalogItemSchema = object({
  command: string2().startsWith("/"),
  description: string2(),
  category: string2(),
  kind: _enum2(["command", "skill"]),
  usage: number2().optional(),
  origin: string2().optional()
});
var HermesSlashCompletionSchema = object({
  text: string2(),
  display: string2(),
  description: string2(),
  kind: _enum2(["command", "skill"])
});
var HermesCommandResultSchema = discriminatedUnion("kind", [
  object({ kind: literal("output"), text: string2(), warning: string2().optional() }),
  object({
    kind: literal("send"),
    message: string2(),
    notice: string2().optional(),
    display: string2().optional()
  }),
  object({ kind: literal("prefill"), message: string2(), notice: string2().optional() }),
  object({ kind: literal("alias"), target: string2() }),
  object({
    kind: literal("session_transition"),
    action: string2(),
    sessionId: string2().optional()
  })
]);

// ../../packages/contracts/src/domain.ts
var BotSchema = object({
  id: Id,
  workspaceId: Id,
  name: string2(),
  title: string2(),
  description: string2(),
  instructions: string2(),
  color: string2(),
  notifyOnFinish: boolean2(),
  parentBotId: Id.nullable(),
  threadId: Id,
  preview: string2(),
  status: string2(),
  updatedAt: string2(),
  createdAt: string2(),
  isDefault: boolean2(),
  model: string2(),
  provider: string2(),
  skillCount: number2().int().nonnegative(),
  hasAvatar: boolean2(),
  avatarData: string2().startsWith("data:image/").nullable(),
  uiMeta: record(string2(), unknown())
});
var CreateBotInput = object({
  name: HermesProfileNameSchema,
  title: string2().max(160).default(""),
  description: string2().max(4e3).default(""),
  instructions: string2().max(2e4).default(""),
  notifyOnFinish: boolean2().default(true),
  color: string2().optional(),
  soul: string2().max(1e5).optional(),
  model: HermesModelSelectionSchema.optional(),
  cloneFrom: HermesProfileNameSchema.optional(),
  noSkills: boolean2().optional(),
  uiMeta: record(string2(), unknown()).optional(),
  avatarData: string2().startsWith("data:image/").nullable().optional()
});
var UpdateBotInput = object({
  botId: Id,
  name: HermesProfileNameSchema.optional(),
  title: string2().max(160).optional(),
  description: string2().max(4e3).optional(),
  instructions: string2().max(2e4).optional(),
  notifyOnFinish: boolean2().optional(),
  color: string2().optional(),
  soul: string2().max(1e5).optional(),
  model: HermesModelSelectionSchema.optional(),
  disabledSkills: array(string2()).optional(),
  enabledToolsets: array(string2()).optional(),
  enabledMcpServers: array(string2()).optional(),
  uiMeta: record(string2(), unknown()).optional(),
  avatarData: string2().startsWith("data:image/").nullable().optional()
});
var RoutineSchema = object({
  id: Id,
  botId: Id,
  name: string2(),
  prompt: string2(),
  cron: string2(),
  timezone: string2(),
  active: boolean2(),
  notify: boolean2(),
  lastRunAt: string2().nullable(),
  nextRunAt: string2().nullable(),
  createdAt: string2()
});
var CreateRoutineInput = object({
  botId: Id,
  name: string2().min(1).max(80),
  prompt: string2().min(1),
  cron: string2().min(1),
  timezone: string2().default("UTC"),
  notify: boolean2().default(true),
  active: boolean2().default(false)
});
var MemoryDocumentSchema = object({
  id: Id,
  scope: MemoryScope,
  botId: Id.nullable(),
  path: string2(),
  content: string2(),
  revision: number2().int(),
  updatedAt: string2()
});
var ConnectionSchema = object({
  id: Id,
  provider: string2(),
  displayName: string2(),
  status: _enum2(["pending", "connected", "revoked", "error"]),
  capabilities: array(string2()),
  createdAt: string2()
});
var ConnectionCatalogItemSchema = object({
  slug: string2(),
  name: string2(),
  logo: string2().nullable(),
  connected: boolean2(),
  noAuth: boolean2()
});
var CapabilityInstallSchema = object({
  id: Id,
  kind: _enum2(["skill", "plugin", "mcp", "connection"]),
  name: string2(),
  source: string2(),
  version: string2().nullable(),
  digest: string2().nullable(),
  config: record(string2(), unknown()),
  createdAt: string2()
});
var ArtifactSchema = object({
  id: Id,
  botId: Id,
  runId: Id.nullable(),
  name: string2(),
  mimeType: string2(),
  size: number2().int(),
  createdAt: string2()
});
var UsageRecordSchema = object({
  id: Id,
  botId: Id.nullable(),
  runId: Id.nullable(),
  provider: string2(),
  model: string2(),
  inputTokens: number2().int(),
  outputTokens: number2().int(),
  createdAt: string2()
});
var ComputerStatusSchema = object({
  botId: Id,
  kind: SandboxKind,
  state: _enum2(["stopped", "booting", "running", "suspended", "error"]),
  controlHolder: _enum2(["bot", "user", "none"]),
  screenAvailable: boolean2(),
  homeRevision: string2().nullable()
});
var RunSchema = object({
  id: Id,
  botId: Id,
  threadId: Id,
  taskId: Id,
  status: RunStatus,
  trigger: _enum2(["user", "routine", "resume", "follow_up", "spawn"]),
  modelProvider: string2().nullable(),
  modelId: string2().nullable(),
  error: string2().nullable(),
  startedAt: string2().nullable(),
  completedAt: string2().nullable()
});
var ThreadSnapshotSchema = object({
  botId: Id,
  threadId: Id,
  cursor: number2().int().min(-1),
  messages: array(ThreadMessageSchema),
  run: RunSchema.nullable(),
  computer: ComputerStatusSchema,
  running: boolean2(),
  transition: object({
    operationId: string2().uuid(),
    parentSessionId: Id,
    messageCount: number2().int().positive()
  }).optional()
});
var DeploymentSettingsSchema = object({
  ownerUserId: Id.nullable(),
  signupsEnabled: boolean2(),
  signupAllowlist: array(string2())
});
var MeSchema = object({
  userId: Id,
  email: string2().email(),
  name: string2(),
  workspaceId: Id,
  isDeploymentOwner: boolean2()
});
var ExportManifestSchema = object({
  version: literal(1),
  exportedAt: string2(),
  bot: BotSchema.pick({ name: true, title: true, description: true, instructions: true }),
  memory: array(object({ path: string2(), content: string2() })),
  routines: array(RoutineSchema.pick({ name: true, prompt: true, cron: true, timezone: true })),
  files: array(object({ path: string2(), content: string2() })),
  history: array(ThreadMessageSchema)
});

// ../../packages/contracts/src/hermes-coordination.ts
var CoordinationEnvelopeSchema = object({
  kind: literal("loopdy.coordination"),
  version: literal(1),
  coordinator: HermesProfileNameSchema,
  collaborators: array(HermesProfileNameSchema).min(1),
  originalAsk: string2().refine((value) => Boolean(value.trim()), "Original ask is required"),
  directive: string2()
});

// ../../packages/contracts/src/hermes-work.ts
var HermesKanbanStatusSchema = _enum2([
  "triage",
  "todo",
  "scheduled",
  "ready",
  "running",
  "blocked",
  "review",
  "done",
  "archived"
]);
var HermesKanbanBoardSchema = object({
  slug: string2().min(1),
  name: string2().min(1),
  description: string2().optional().default(""),
  icon: string2().optional().nullable(),
  color: string2().optional().nullable(),
  is_current: boolean2().optional().default(false),
  counts: record(string2(), number2().int().nonnegative()).optional().default({}),
  total: number2().int().nonnegative().optional().default(0)
});
var HermesKanbanTaskSchema = object({
  id: string2().min(1),
  title: string2().min(1),
  body: string2().optional().nullable(),
  status: HermesKanbanStatusSchema,
  assignee: string2().optional().nullable(),
  tenant: string2().optional().nullable(),
  priority: number2().int().default(0),
  created_at: number2().optional().nullable(),
  started_at: number2().optional().nullable(),
  completed_at: number2().optional().nullable(),
  created_by: string2().optional().nullable(),
  block_reason: string2().optional().nullable(),
  latest_summary: string2().optional().nullable(),
  comment_count: number2().int().nonnegative().optional().default(0),
  link_counts: object({ parents: number2().int(), children: number2().int() }).optional(),
  progress: object({ done: number2().int(), total: number2().int() }).optional().nullable(),
  model_override: string2().optional().nullable(),
  provider_override: string2().optional().nullable(),
  reasoning_effort: string2().optional().nullable(),
  current_step_key: string2().optional().nullable(),
  workflow_template_id: string2().optional().nullable(),
  result: string2().optional().nullable()
});
var HermesKanbanCommentSchema = object({
  id: number2().int(),
  task_id: string2().min(1),
  author: string2().optional().nullable(),
  body: string2(),
  created_at: number2()
});
var HermesKanbanEventSchema = object({
  id: number2().int(),
  task_id: string2().min(1),
  kind: string2().min(1),
  payload: unknown().optional().nullable(),
  created_at: number2(),
  run_id: number2().int().optional().nullable()
});
var HermesKanbanRunSchema = object({
  id: number2().int(),
  task_id: string2().min(1),
  profile: string2().optional().nullable(),
  step_key: string2().optional().nullable(),
  status: string2().optional().nullable(),
  outcome: string2().optional().nullable(),
  summary: string2().optional().nullable(),
  error: string2().optional().nullable(),
  last_heartbeat_at: number2().optional().nullable(),
  started_at: number2().optional().nullable(),
  ended_at: number2().optional().nullable()
});
var HermesKanbanDiagnosticSchema = object({
  kind: string2().min(1),
  severity: string2().min(1),
  title: string2().min(1),
  detail: string2(),
  first_seen_at: number2().optional().default(0),
  last_seen_at: number2().optional().default(0),
  count: number2().int().positive().optional().default(1),
  run_id: number2().int().optional().nullable()
});
var HermesKanbanAttachmentSchema = object({
  id: number2().int(),
  task_id: string2().min(1),
  filename: string2(),
  content_type: string2().optional().nullable(),
  size: number2().int().nonnegative().optional().default(0),
  uploaded_by: string2().optional().nullable(),
  created_at: number2()
});
var HermesKanbanChildResultSchema = object({
  id: string2().min(1),
  title: string2().min(1),
  status: HermesKanbanStatusSchema,
  latest_summary: string2().optional().nullable(),
  result: string2().optional().nullable()
});
var HermesKanbanTaskDetailSchema = object({
  task: HermesKanbanTaskSchema.extend({
    diagnostics: array(HermesKanbanDiagnosticSchema).optional().default([])
  }),
  comments: array(HermesKanbanCommentSchema).default([]),
  events: array(HermesKanbanEventSchema).default([]),
  runs: array(HermesKanbanRunSchema).default([]),
  links: object({ parents: array(string2()), children: array(string2()) }).default({ parents: [], children: [] }),
  attachments: array(HermesKanbanAttachmentSchema).default([]),
  child_results: array(HermesKanbanChildResultSchema).default([])
});
var HermesKanbanColumnSchema = object({
  name: HermesKanbanStatusSchema,
  tasks: array(HermesKanbanTaskSchema)
});
var HermesKanbanSnapshotSchema = object({
  columns: array(HermesKanbanColumnSchema),
  tenants: array(string2()).default([]),
  assignees: array(string2()).default([]),
  latest_event_id: number2().int().default(0),
  now: number2().default(0)
});
var HermesKanbanTaskCreateSchema = object({
  board: string2().min(1),
  title: string2().trim().min(1).max(240),
  body: string2().max(5e4).optional(),
  assignee: string2().max(64).optional(),
  priority: number2().int().min(-100).max(100).optional(),
  triage: boolean2().optional()
});
var HermesKanbanTaskUpdateSchema = object({
  board: string2().min(1),
  taskId: string2().min(1),
  status: _enum2(["triage", "todo", "scheduled", "ready", "blocked", "review", "done", "archived"]).optional(),
  assignee: string2().max(64).optional(),
  priority: number2().int().min(-100).max(100).optional(),
  title: string2().trim().min(1).max(240).optional(),
  body: string2().max(5e4).optional(),
  blockReason: string2().max(2e3).optional(),
  summary: string2().max(5e4).optional()
});
var HermesCronJobSchema = object({
  id: string2().min(1),
  name: string2().optional().nullable(),
  schedule: string2().optional().default(""),
  enabled: boolean2().optional().default(true),
  profile: string2().optional().nullable(),
  deliver: string2().optional().nullable(),
  next_run_at: union([string2(), number2()]).optional().nullable(),
  last_run_at: union([string2(), number2()]).optional().nullable(),
  last_status: string2().optional().nullable(),
  repeat: union([number2().int(), record(string2(), unknown())]).optional().nullable()
});
var HermesRecentSessionSchema = object({
  botId: string2().min(1),
  botName: string2().min(1),
  profile: string2().min(1),
  id: string2().min(1),
  title: string2(),
  preview: string2(),
  startedAt: string2().datetime(),
  lastActiveAt: string2().datetime().optional(),
  active: boolean2().optional(),
  messageCount: number2().int().nonnegative(),
  source: string2(),
  channel: string2().optional(),
  chatType: string2().optional()
});

// ../../packages/contracts/src/relay.ts
var utf8 = /* @__PURE__ */ __name((value) => new TextEncoder().encode(value), "utf8");
var MAX_SAFE_TIMESTAMP = 9999999999;
var IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;
var TOPIC = /^(?!.*\.push-type\.liveactivity$)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;
var LOWER_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
var B64URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
var P256_PRIME = BigInt("0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff");
var P256_B = BigInt("0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b");
function modP256(value) {
  const remainder = value % P256_PRIME;
  return remainder < 0n ? remainder + P256_PRIME : remainder;
}
__name(modP256, "modP256");
function isP256Point(value) {
  if (value.byteLength !== 65 || value[0] !== 4) return false;
  let x = 0n;
  let y = 0n;
  for (let index = 1; index <= 32; index += 1) x = x << 8n | BigInt(value[index] ?? 0);
  for (let index = 33; index <= 64; index += 1) y = y << 8n | BigInt(value[index] ?? 0);
  if (x >= P256_PRIME || y >= P256_PRIME) return false;
  return modP256(y * y - (x * x * x - 3n * x + P256_B)) === 0n;
}
__name(isP256Point, "isP256Point");
function bytes(...values) {
  const length = values.reduce((sum, value) => sum + value.byteLength, 0);
  const result = new Uint8Array(length);
  let offset = 0;
  for (const value of values) {
    result.set(value, offset);
    offset += value.byteLength;
  }
  return result;
}
__name(bytes, "bytes");
function u32(value) {
  return Uint8Array.of(
    value >>> 24 & 255,
    value >>> 16 & 255,
    value >>> 8 & 255,
    value & 255
  );
}
__name(u32, "u32");
function rotateRight(value, amount) {
  return value >>> amount | value << 32 - amount;
}
__name(rotateRight, "rotateRight");
function relaySha256(input) {
  const constants = Uint32Array.from([
    1116352408,
    1899447441,
    3049323471,
    3921009573,
    961987163,
    1508970993,
    2453635748,
    2870763221,
    3624381080,
    310598401,
    607225278,
    1426881987,
    1925078388,
    2162078206,
    2614888103,
    3248222580,
    3835390401,
    4022224774,
    264347078,
    604807628,
    770255983,
    1249150122,
    1555081692,
    1996064986,
    2554220882,
    2821834349,
    2952996808,
    3210313671,
    3336571891,
    3584528711,
    113926993,
    338241895,
    666307205,
    773529912,
    1294757372,
    1396182291,
    1695183700,
    1986661051,
    2177026350,
    2456956037,
    2730485921,
    2820302411,
    3259730800,
    3345764771,
    3516065817,
    3600352804,
    4094571909,
    275423344,
    430227734,
    506948616,
    659060556,
    883997877,
    958139571,
    1322822218,
    1537002063,
    1747873779,
    1955562222,
    2024104815,
    2227730452,
    2361852424,
    2428436474,
    2756734187,
    3204031479,
    3329325298
  ]);
  const bitLength = input.byteLength * 8;
  const paddedLength = Math.ceil((input.byteLength + 9) / 64) * 64;
  const padded = new Uint8Array(paddedLength);
  padded.set(input);
  padded[input.byteLength] = 128;
  const view = new DataView(padded.buffer);
  view.setUint32(paddedLength - 8, Math.floor(bitLength / 2 ** 32), false);
  view.setUint32(paddedLength - 4, bitLength >>> 0, false);
  const state = Uint32Array.from([
    1779033703,
    3144134277,
    1013904242,
    2773480762,
    1359893119,
    2600822924,
    528734635,
    1541459225
  ]);
  const schedule = new Uint32Array(64);
  for (let offset = 0; offset < paddedLength; offset += 64) {
    for (let index = 0; index < 16; index += 1) {
      schedule[index] = view.getUint32(offset + index * 4, false);
    }
    for (let index = 16; index < 64; index += 1) {
      const earlier = schedule[index - 15] ?? 0;
      const later = schedule[index - 2] ?? 0;
      const small0 = rotateRight(earlier, 7) ^ rotateRight(earlier, 18) ^ earlier >>> 3;
      const small1 = rotateRight(later, 17) ^ rotateRight(later, 19) ^ later >>> 10;
      schedule[index] = (schedule[index - 16] ?? 0) + small0 + (schedule[index - 7] ?? 0) + small1 >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = state;
    for (let index = 0; index < 64; index += 1) {
      const big1 = rotateRight(e ?? 0, 6) ^ rotateRight(e ?? 0, 11) ^ rotateRight(e ?? 0, 25);
      const choice = (e ?? 0) & (f ?? 0) ^ ~(e ?? 0) & (g ?? 0);
      const first2 = (h ?? 0) + big1 + choice + (constants[index] ?? 0) + (schedule[index] ?? 0) >>> 0;
      const big0 = rotateRight(a ?? 0, 2) ^ rotateRight(a ?? 0, 13) ^ rotateRight(a ?? 0, 22);
      const majority = (a ?? 0) & (b ?? 0) ^ (a ?? 0) & (c ?? 0) ^ (b ?? 0) & (c ?? 0);
      const second = big0 + majority >>> 0;
      h = g;
      g = f;
      f = e;
      e = (d ?? 0) + first2 >>> 0;
      d = c;
      c = b;
      b = a;
      a = first2 + second >>> 0;
    }
    const working = [a, b, c, d, e, f, g, h];
    for (let index = 0; index < 8; index += 1) {
      state[index] = (state[index] ?? 0) + (working[index] ?? 0) >>> 0;
    }
  }
  const output = new Uint8Array(32);
  const outputView = new DataView(output.buffer);
  for (let index = 0; index < state.length; index += 1) {
    outputView.setUint32(index * 4, state[index] ?? 0, false);
  }
  return output;
}
__name(relaySha256, "relaySha256");
function relayBase64UrlEncode(input) {
  let result = "";
  for (let offset = 0; offset < input.byteLength; offset += 3) {
    const first2 = input[offset] ?? 0;
    const second = input[offset + 1];
    const third = input[offset + 2];
    const chunk = first2 << 16 | (second ?? 0) << 8 | (third ?? 0);
    result += B64URL_ALPHABET[chunk >>> 18 & 63];
    result += B64URL_ALPHABET[chunk >>> 12 & 63];
    if (second !== void 0) result += B64URL_ALPHABET[chunk >>> 6 & 63];
    if (third !== void 0) result += B64URL_ALPHABET[chunk & 63];
  }
  return result;
}
__name(relayBase64UrlEncode, "relayBase64UrlEncode");
function relayBase64UrlDecode(value) {
  if (!/^[A-Za-z0-9_-]+$/.test(value) || value.length % 4 === 1) {
    throw new Error("Expected canonical unpadded base64url");
  }
  const output = [];
  for (let offset = 0; offset < value.length; offset += 4) {
    const remaining = Math.min(4, value.length - offset);
    const indexes = [0, 0, 0, 0];
    for (let index = 0; index < remaining; index += 1) {
      const position = B64URL_ALPHABET.indexOf(value[offset + index] ?? "");
      if (position < 0) throw new Error("Expected canonical unpadded base64url");
      indexes[index] = position;
    }
    const chunk = (indexes[0] ?? 0) << 18 | (indexes[1] ?? 0) << 12 | (indexes[2] ?? 0) << 6 | (indexes[3] ?? 0);
    output.push(chunk >>> 16 & 255);
    if (remaining >= 3) output.push(chunk >>> 8 & 255);
    if (remaining === 4) output.push(chunk & 255);
  }
  const decoded = Uint8Array.from(output);
  if (relayBase64UrlEncode(decoded) !== value) {
    throw new Error("Expected canonical unpadded base64url");
  }
  return decoded;
}
__name(relayBase64UrlDecode, "relayBase64UrlDecode");
function assertAsciiIdentifier(value, name, maximum = 180) {
  if (typeof value !== "string" || value.length < 1 || value.length > maximum || !IDENTIFIER.test(value)) {
    throw new Error(`${name} must be a printable ASCII protocol identifier`);
  }
  return value;
}
__name(assertAsciiIdentifier, "assertAsciiIdentifier");
function assertTimestamp(value, name) {
  if (!Number.isInteger(value) || value <= 0 || value > MAX_SAFE_TIMESTAMP) {
    throw new Error(`${name} must be a positive bounded integer`);
  }
  return value;
}
__name(assertTimestamp, "assertTimestamp");
function identifier(name, maximum = 180) {
  return external_exports.string().superRefine((value, context) => {
    try {
      assertAsciiIdentifier(value, name, maximum);
    } catch (error51) {
      context.addIssue({ code: "custom", message: error51.message });
    }
  });
}
__name(identifier, "identifier");
function canonicalBase64(name, byteLength, maximumBytes) {
  return external_exports.string().superRefine((value, context) => {
    try {
      const decoded = relayBase64UrlDecode(value);
      if (byteLength !== void 0 && decoded.byteLength !== byteLength) {
        throw new Error(`${name} must decode to ${byteLength} bytes`);
      }
      if (maximumBytes !== void 0 && decoded.byteLength > maximumBytes) {
        throw new Error(`${name} exceeds ${maximumBytes} bytes`);
      }
    } catch (error51) {
      context.addIssue({ code: "custom", message: error51.message });
    }
  });
}
__name(canonicalBase64, "canonicalBase64");
var timestamp = external_exports.number().int().positive().max(MAX_SAFE_TIMESTAMP);
var revision = external_exports.number().int().positive().max(Number.MAX_SAFE_INTEGER);
var idempotencyKey = external_exports.string().regex(LOWER_UUID);
var keyId = canonicalBase64("key ID", 32);
var publicKey = canonicalBase64("P-256 public key", 65).superRefine((value, context) => {
  try {
    const point = relayBase64UrlDecode(value);
    if (point[0] !== 4 || !isP256Point(point)) {
      context.addIssue({ code: "custom", message: "P-256 public key must be uncompressed X9.63" });
    }
  } catch {
  }
});
var displayText = /* @__PURE__ */ __name((name, maximumBytes) => external_exports.string().superRefine((value, context) => {
  if (value !== value.normalize("NFC")) {
    context.addIssue({ code: "custom", message: `${name} must use Unicode NFC` });
  }
  if (utf8(value).byteLength > maximumBytes) {
    context.addIssue({ code: "custom", message: `${name} exceeds ${maximumBytes} UTF-8 bytes` });
  }
}), "displayText");
var RelayAlertEnvelopeV1 = external_exports.strictObject({
  v: external_exports.literal(1),
  kind: external_exports.literal("alert"),
  delivery_id: identifier("delivery_id"),
  event_ref: canonicalBase64("event_ref", 32),
  recipient_key_id: keyId,
  sender_key_id: keyId,
  issued: timestamp,
  expires: timestamp,
  ephemeral_public_key: publicKey,
  salt: canonicalBase64("salt", 32),
  nonce: canonicalBase64("nonce", 12),
  ciphertext: canonicalBase64("ciphertext", void 0, 1200),
  tag: canonicalBase64("tag", 16),
  signature: canonicalBase64("signature", 64)
}).superRefine((value, context) => {
  if (value.expires <= value.issued || value.expires - value.issued > 900) {
    context.addIssue({ code: "custom", message: "Alert expiry must be within 900 seconds" });
  }
});
var RelayDeliveryRequestV1 = external_exports.strictObject({
  device_id: identifier("device_id"),
  envelope: RelayAlertEnvelopeV1,
  idempotency_key: idempotencyKey,
  sound: external_exports.literal(false).optional()
});
var RelayAlertPushContentV1 = external_exports.strictObject({
  version: external_exports.literal(1),
  tenant_id: identifier("tenant_id"),
  device_id: identifier("device_id"),
  envelope: RelayAlertEnvelopeV1
});
var RelayAlertPushPayloadV1 = external_exports.strictObject({
  aps: external_exports.strictObject({
    alert: external_exports.strictObject({
      title: external_exports.literal("Loopdy"),
      body: external_exports.literal("Open Loopdy to review this request.")
    }),
    category: external_exports.literal("LOOPDY_REVIEW"),
    "mutable-content": external_exports.literal(1),
    sound: external_exports.literal("default").optional()
  }),
  loopdy: RelayAlertPushContentV1
}).superRefine((value, context) => {
  if (utf8(relayCanonicalJson(value)).byteLength > 4096) {
    context.addIssue({ code: "custom", message: "Full APNs alert payload exceeds 4096 bytes" });
  }
});
var RelayLinkWakePushPayloadV1 = external_exports.strictObject({
  aps: external_exports.strictObject({
    "content-available": external_exports.literal(1)
  }),
  loopdy_link: external_exports.strictObject({
    version: external_exports.literal(1),
    type: external_exports.literal("wake")
  })
}).superRefine((value, context) => {
  if (utf8(relayCanonicalJson(value)).byteLength > 4096) {
    context.addIssue({ code: "custom", message: "Loopdy Link wake payload exceeds 4096 bytes" });
  }
});
var relaySenderSigningKey = external_exports.strictObject({
  key_id: keyId,
  public_key: publicKey,
  state: external_exports.enum(["current", "previous"]),
  not_before: timestamp,
  not_after: timestamp
}).superRefine((value, context) => {
  if (value.not_after <= value.not_before || value.not_after - value.not_before > 2678400) {
    context.addIssue({
      code: "custom",
      message: "Sender key validity must be positive and at most 31 days"
    });
  }
  if (relayKeyId(relayBase64UrlDecode(value.public_key)) !== value.key_id) {
    context.addIssue({ code: "custom", message: "Sender key ID does not match its public key" });
  }
});
var RelaySenderKeySetResponseV1 = external_exports.strictObject({
  version: external_exports.literal(1),
  revision,
  current: relaySenderSigningKey,
  previous: relaySenderSigningKey.nullable()
}).superRefine((value, context) => {
  if (value.current.state !== "current") {
    context.addIssue({ code: "custom", message: "Current sender key must have current state" });
  }
  if (value.previous !== null) {
    if (value.previous.state !== "previous") {
      context.addIssue({
        code: "custom",
        message: "Previous sender key must have previous state"
      });
    }
    if (value.previous.key_id === value.current.key_id) {
      context.addIssue({
        code: "custom",
        message: "Current and previous sender keys must differ"
      });
    }
    if (value.previous.not_after - value.current.not_before > 604800) {
      context.addIssue({ code: "custom", message: "Sender-key overlap exceeds seven days" });
    }
  }
});
var RelayDeviceRegistrationResponseV1 = external_exports.strictObject({
  version: external_exports.literal(1),
  status: external_exports.enum(["accepted", "duplicate"]),
  tenant_id: identifier("tenant_id"),
  device_id: identifier("device_id"),
  recipient_key_id: keyId,
  revision,
  lease_expires: timestamp,
  sender_key_revision: revision,
  current_sender_key: relaySenderSigningKey,
  previous_sender_key: relaySenderSigningKey.nullable()
}).superRefine((value, context) => {
  if (value.current_sender_key.state !== "current") {
    context.addIssue({ code: "custom", message: "Current sender key must have current state" });
  }
  if (value.previous_sender_key !== null) {
    if (value.previous_sender_key.state !== "previous") {
      context.addIssue({
        code: "custom",
        message: "Previous sender key must have previous state"
      });
    }
    if (value.previous_sender_key.key_id === value.current_sender_key.key_id) {
      context.addIssue({
        code: "custom",
        message: "Current and previous sender keys must differ"
      });
    }
    if (value.previous_sender_key.not_after - value.current_sender_key.not_before > 604800) {
      context.addIssue({ code: "custom", message: "Sender-key overlap exceeds seven days" });
    }
  }
});
var acknowledgedSenderKeys = external_exports.array(keyId).min(1).max(2).superRefine((value, context) => {
  if (new Set(value).size !== value.length) {
    context.addIssue({ code: "custom", message: "Acknowledged sender key IDs must be unique" });
  }
});
var RelaySenderKeyAcknowledgementRequestV1 = external_exports.strictObject({
  version: external_exports.literal(1),
  device_id: identifier("device_id"),
  revision,
  sender_key_revision: revision,
  acknowledged_sender_key_ids: acknowledgedSenderKeys,
  idempotency_key: idempotencyKey
});
var RelayDeviceRegistrationRequestV1 = external_exports.strictObject({
  version: external_exports.literal(1),
  device_id: identifier("device_id"),
  revision,
  issued: timestamp,
  lease_expires: timestamp,
  provider: external_exports.literal("relay"),
  recipient_public_key: publicKey,
  recipient_key_id: keyId,
  push_token: external_exports.string().regex(/^(?:[0-9a-f]{2}){1,256}$/),
  environment: external_exports.enum(["production", "sandbox"]),
  topic: external_exports.string().max(255).regex(TOPIC),
  label: displayText("label", 120),
  groups: external_exports.array(identifier("group", 80)).max(50),
  idempotency_key: idempotencyKey
}).superRefine((value, context) => {
  if (value.lease_expires <= value.issued || value.lease_expires - value.issued > 2592e3) {
    context.addIssue({ code: "custom", message: "Registration lease exceeds 30 days" });
  }
  if (relayKeyId(relayBase64UrlDecode(value.recipient_public_key)) !== value.recipient_key_id) {
    context.addIssue({
      code: "custom",
      message: "recipient_key_id does not match the public key"
    });
  }
});
var RelayDeviceRevokeRequestV1 = external_exports.strictObject({
  version: external_exports.literal(1),
  device_id: identifier("device_id"),
  revision,
  idempotency_key: idempotencyKey
});
var RelayTenantRevokeRequestV1 = external_exports.strictObject({
  version: external_exports.literal(1),
  tenant_id: identifier("tenant_id"),
  revision,
  idempotency_key: idempotencyKey
});
var RelayTenantDeleteRequestV1 = external_exports.strictObject({
  version: external_exports.literal(1),
  tenant_id: identifier("tenant_id"),
  revision,
  confirmation: external_exports.literal("delete"),
  idempotency_key: idempotencyKey
});
var RelayLiveActivityStateV1 = external_exports.strictObject({
  version: external_exports.literal(1),
  kind: external_exports.literal("live_activity"),
  activity_id: identifier("activity_id"),
  session_ref: canonicalBase64("session_ref", void 0, 64),
  phase: external_exports.enum([
    "thinking",
    "waiting",
    "running",
    "using_tool",
    "delegating",
    "responding",
    "completed",
    "failed"
  ]),
  current_action: external_exports.string().min(1).max(96).regex(/^[^\u0000-\u001f\u007f]+$/).optional(),
  progress: external_exports.number().int().min(0).max(100),
  active_session_count: external_exports.number().int().min(0).max(999),
  completed_steps: external_exports.number().int().min(0).max(999).optional(),
  active_subagent_count: external_exports.number().int().min(0).max(99).optional(),
  latest_tool: external_exports.string().min(1).max(64).regex(/^[^\u0000-\u001f\u007f]+$/).nullable().optional(),
  timestamp,
  expires: timestamp
}).superRefine((value, context) => {
  if (value.expires <= value.timestamp || value.expires - value.timestamp > 120) {
    context.addIssue({
      code: "custom",
      message: "Live Activity expiry must be within 120 seconds"
    });
  }
});
var RelayLiveActivityDeliveryRequestV1 = external_exports.strictObject({
  device_id: identifier("device_id"),
  delivery_id: identifier("delivery_id"),
  state: RelayLiveActivityStateV1,
  idempotency_key: idempotencyKey
});
var RelayActivityKitPushPayloadV1 = external_exports.strictObject({
  aps: external_exports.strictObject({
    timestamp,
    event: external_exports.enum(["update", "end"]),
    "content-state": external_exports.strictObject({
      phase: external_exports.enum([
        "thinking",
        "waiting",
        "using_tool",
        "delegating",
        "responding",
        "completed",
        "failed"
      ]),
      currentAction: external_exports.string().min(1).max(96),
      progress: external_exports.number().int().min(0).max(100),
      completedSteps: external_exports.number().int().min(0).max(999),
      activeSubagentCount: external_exports.number().int().min(0).max(99),
      latestTool: external_exports.string().min(1).max(64).nullable().optional(),
      timestamp
    }),
    "stale-date": timestamp,
    "dismissal-date": timestamp.optional()
  })
}).superRefine((value, context) => {
  const aps = value.aps;
  const terminal = aps["content-state"].phase === "completed" || aps["content-state"].phase === "failed";
  if (aps["stale-date"] <= aps.timestamp || aps["stale-date"] - aps.timestamp > 120) {
    context.addIssue({
      code: "custom",
      message: "ActivityKit stale date must be within 120 seconds"
    });
  }
  if (terminal) {
    if (aps.event !== "end" || aps["dismissal-date"] === void 0 || aps["dismissal-date"] < aps.timestamp || aps["dismissal-date"] > aps["stale-date"]) {
      context.addIssue({
        code: "custom",
        message: "Terminal ActivityKit updates must end with a bounded dismissal date"
      });
    }
  } else if (aps.event !== "update" || aps["dismissal-date"] !== void 0) {
    context.addIssue({
      code: "custom",
      message: "Nonterminal ActivityKit updates must not end the activity"
    });
  }
});
var RelayLiveActivityRegistrationRequestV1 = external_exports.strictObject({
  version: external_exports.literal(1),
  activity_id: identifier("activity_id"),
  device_id: identifier("device_id"),
  session_ref: canonicalBase64("session_ref", void 0, 64),
  push_token: external_exports.string().regex(/^(?:[0-9a-f]{2}){1,256}$/),
  environment: external_exports.enum(["production", "sandbox"]),
  topic: external_exports.string().max(255).regex(TOPIC),
  revision,
  timestamp,
  lease_expires: timestamp,
  idempotency_key: idempotencyKey
}).superRefine((value, context) => {
  if (value.lease_expires <= value.timestamp || value.lease_expires - value.timestamp > 28800) {
    context.addIssue({
      code: "custom",
      message: "Live Activity registration lease exceeds eight hours"
    });
  }
});
var RelayLiveActivityRevokeRequestV1 = external_exports.strictObject({
  version: external_exports.literal(1),
  activity_id: identifier("activity_id"),
  revision,
  timestamp,
  idempotency_key: idempotencyKey
});
var relayResponse = /* @__PURE__ */ __name((statuses) => external_exports.strictObject({
  version: external_exports.literal(1),
  status: external_exports.enum(statuses),
  id: identifier("id"),
  revision
}), "relayResponse");
var RelayAcceptedResponseV1 = relayResponse(["accepted", "duplicate"]);
var RelayRevokedResponseV1 = relayResponse(["revoked", "duplicate"]);
var RelayDeletedResponseV1 = relayResponse(["deleted", "duplicate"]);
var RelayHealthResponseV1 = external_exports.strictObject({
  version: external_exports.literal(1),
  status: external_exports.literal("ok")
});
function canonicalValue(value) {
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("Canonical JSON rejects non-finite numbers");
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (typeof value === "object") {
    const result = {};
    for (const key of Object.keys(value).sort()) {
      const item = value[key];
      if (item === void 0) throw new Error("Canonical JSON rejects undefined values");
      result[key] = canonicalValue(item);
    }
    return result;
  }
  throw new Error("Unsupported canonical JSON value");
}
__name(canonicalValue, "canonicalValue");
function relayCanonicalJson(value) {
  return JSON.stringify(canonicalValue(value));
}
__name(relayCanonicalJson, "relayCanonicalJson");
function relayKeyId(publicKeyBytes) {
  if (!isP256Point(publicKeyBytes)) {
    throw new Error("P-256 public key must be a 65-byte uncompressed X9.63 point");
  }
  return relayBase64UrlEncode(relaySha256(publicKeyBytes));
}
__name(relayKeyId, "relayKeyId");
function relayAlertAad(input) {
  assertAsciiIdentifier(input.tenantId, "tenant_id");
  assertAsciiIdentifier(input.deviceId, "device_id");
  assertAsciiIdentifier(input.deliveryId, "delivery_id");
  if (relayBase64UrlDecode(input.eventRef).byteLength !== 32) throw new Error("Invalid event_ref");
  if (relayBase64UrlDecode(input.recipientKeyId).byteLength !== 32)
    throw new Error("Invalid recipient key ID");
  if (relayBase64UrlDecode(input.senderKeyId).byteLength !== 32)
    throw new Error("Invalid sender key ID");
  const issued = assertTimestamp(input.issued, "issued");
  const expires = assertTimestamp(input.expires, "expires");
  if (expires <= issued || expires - issued > 900) {
    throw new Error("Alert expiry must be within 900 seconds");
  }
  return utf8(
    [
      "loopdy-relay-alert-aad-v1",
      input.tenantId,
      input.deviceId,
      input.deliveryId,
      input.eventRef,
      "alert",
      input.recipientKeyId,
      input.senderKeyId,
      String(issued),
      String(expires)
    ].join("\n")
  );
}
__name(relayAlertAad, "relayAlertAad");
function relayAlertSignatureInput(input) {
  if (!isP256Point(input.ephemeralPublicKey)) {
    throw new Error("Ephemeral public key must be a 65-byte uncompressed X9.63 point");
  }
  if (input.salt.byteLength !== 32 || input.nonce.byteLength !== 12 || input.tag.byteLength !== 16) {
    throw new Error("Invalid alert salt, nonce, or tag length");
  }
  if (input.ciphertext.byteLength > 1200) throw new Error("Ciphertext exceeds 1200 bytes");
  return bytes(
    utf8("loopdy-relay-envelope-signature-v1\0"),
    relaySha256(input.aad),
    input.ephemeralPublicKey,
    input.salt,
    input.nonce,
    u32(input.ciphertext.byteLength),
    input.ciphertext,
    input.tag
  );
}
__name(relayAlertSignatureInput, "relayAlertSignatureInput");
function relayRequestSigningInput(input) {
  const method = input.method.toUpperCase();
  if (!/^[A-Z]+$/.test(method)) throw new Error("Invalid request method");
  if (!/^\/[A-Za-z0-9._/-]+$/.test(input.path) || input.path.includes("?") || input.path.includes("#")) {
    throw new Error("Request path must be exact and query-free");
  }
  assertAsciiIdentifier(input.tenantId, "tenant_id");
  assertAsciiIdentifier(input.credentialKeyId, "credential_key_id");
  relayBase64UrlDecode(input.nonce);
  const timestamp2 = assertTimestamp(input.timestamp, "timestamp");
  const digest = Array.from(
    relaySha256(input.body),
    (value) => value.toString(16).padStart(2, "0")
  ).join("");
  return utf8(
    [
      "loopdy-relay-request-v1",
      method,
      input.path,
      input.tenantId,
      input.credentialKeyId,
      String(timestamp2),
      input.nonce,
      digest
    ].join("\n")
  );
}
__name(relayRequestSigningInput, "relayRequestSigningInput");
function validateRelayRequestTimestamp(value, now) {
  const timestamp2 = assertTimestamp(value, "timestamp");
  const current = assertTimestamp(now, "now");
  if (Math.abs(current - timestamp2) > 300) {
    throw new Error("Relay request timestamp is outside the five minute window");
  }
  return timestamp2;
}
__name(validateRelayRequestTimestamp, "validateRelayRequestTimestamp");

