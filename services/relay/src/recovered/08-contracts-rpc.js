// ../../packages/contracts/src/rpc.ts
var botId = object({ botId: Id });
var ThreadSteerResultSchema = discriminatedUnion("disposition", [
  object({
    ok: literal(true),
    disposition: literal("accepted"),
    clientSendId: string2().uuid().optional(),
    queuedFallback: literal(false).optional()
  }),
  object({
    ok: literal(true),
    disposition: literal("queued"),
    clientSendId: string2().uuid().optional(),
    queuedFallback: literal(true).optional()
  })
]);
var ThreadSendResultSchema = object({
  operationId: Id,
  targetProfile: string2(),
  routed: boolean2(),
  duplicate: boolean2(),
  clientSendId: string2().uuid().optional(),
  identityStatus: literal("unsupported")
});
var appContract = {
  health: oc.output(object({ ok: literal(true), version: string2() })),
  me: oc.output(MeSchema),
  deployment: {
    get: oc.output(DeploymentSettingsSchema),
    update: oc.input(
      object({
        signupsEnabled: boolean2().optional(),
        signupAllowlist: array(string2()).optional()
      })
    ).output(DeploymentSettingsSchema)
  },
  bots: {
    list: oc.output(array(BotSchema)),
    get: oc.input(botId).output(BotSchema),
    describe: oc.input(botId).output(ProfileDetailSchema),
    create: oc.input(CreateBotInput).output(BotSchema),
    update: oc.input(UpdateBotInput).output(BotSchema),
    remove: oc.input(botId).output(object({ ok: literal(true) }))
  },
  threads: {
    listRecent: oc.output(array(HermesRecentSessionSchema)),
    listSessions: oc.input(object({ botId: Id, limit: number2().int().min(1).max(200).optional() })).output(array(HermesSessionSummarySchema)),
    createSession: oc.input(
      object({ botId: Id, title: string2().max(120).optional(), cwd: string2().optional() })
    ).output(ThreadSnapshotSchema),
    selectSession: oc.input(object({ botId: Id, sessionId: Id, refresh: boolean2().optional() })).output(ThreadSnapshotSchema),
    renameSession: oc.input(object({ botId: Id, sessionId: Id, title: string2().min(1).max(160) })).output(object({ id: Id, title: string2() })),
    archiveSession: oc.input(object({ botId: Id, sessionId: Id })).output(object({ id: Id, archived: literal(true) })),
    deleteSession: oc.input(object({ botId: Id, sessionId: Id })).output(object({ id: Id, deleted: literal(true) })),
    fork: oc.input(
      object({
        botId: Id,
        sourceStoredSessionId: Id,
        messageCount: number2().int().positive(),
        targetRowId: string2().min(1),
        sourceFingerprint: string2().min(1),
        targetHistoryIndex: number2().int().nonnegative(),
        title: string2().max(120).optional(),
        idempotencyKey: string2().uuid()
      })
    ).output(ThreadSnapshotSchema),
    get: oc.input(object({ botId: Id, afterSeq: number2().int().min(-1).optional() })).output(ThreadSnapshotSchema),
    delivery: oc.input(object({ botId: Id, deliveryId: Id })).output(ThreadSnapshotSchema),
    subscribe: oc.input(object({ botId: Id, cursor: number2().int().min(-1) })).output(eventIterator(ProductEventSchema)),
    send: oc.input(
      object({
        botId: Id,
        sessionId: Id.optional(),
        text: string2().min(1),
        clientSendId: string2().uuid().optional(),
        clientNonce: string2().optional()
      })
    ).output(ThreadSendResultSchema),
    stop: oc.input(object({ botId: Id, sessionId: Id.optional() })).output(object({ ok: literal(true) })),
    queue: oc.input(
      object({
        botId: Id,
        sessionId: Id.optional(),
        text: string2().min(1),
        clientSendId: string2().uuid().optional()
      })
    ).output(object({ ok: literal(true) })),
    followUp: oc.input(
      object({
        botId: Id,
        sessionId: Id.optional(),
        text: string2().min(1),
        clientSendId: string2().uuid().optional()
      })
    ).output(object({ ok: literal(true) })),
    answer: oc.input(object({ botId: Id, runId: Id, answer: string2().min(1) })).output(object({ ok: literal(true) })),
    steer: oc.input(
      object({
        botId: Id,
        sessionId: Id.optional(),
        text: string2().min(1),
        clientSendId: string2().uuid().optional()
      })
    ).output(ThreadSteerResultSchema),
    regenerate: oc.input(
      object({
        botId: Id,
        text: string2().min(1),
        userOrdinal: number2().int().nonnegative().optional(),
        rowId: number2().int().positive().optional()
      }).refine((value) => value.userOrdinal !== void 0 || value.rowId !== void 0, {
        message: "Regeneration requires a durable row ID or user ordinal"
      })
    ).output(object({ ok: literal(true) })),
    respond: oc.input(
      object({
        botId: Id,
        kind: _enum2(["approval", "clarify"]),
        requestId: string2().min(1),
        questionId: string2().min(1).optional(),
        value: string2()
      })
    ).output(object({ ok: literal(true) })),
    runtime: oc.input(botId).output(HermesAgentRuntimeSchema),
    configureRuntime: oc.input(
      object({
        botId: Id,
        model: string2().min(1).optional(),
        provider: string2().min(1).optional(),
        reasoningEffort: HermesReasoningEffortSchema.optional()
      }).refine(
        (value) => value.model === void 0 && value.provider === void 0 || value.model !== void 0 && value.provider !== void 0,
        { message: "Model and provider must be selected together" }
      )
    ).output(HermesAgentRuntimeSchema)
  },
  work: {
    listBoards: oc.output(object({ boards: array(HermesKanbanBoardSchema) })),
    getBoard: oc.input(object({ board: string2().min(1) })).output(HermesKanbanSnapshotSchema),
    getTask: oc.input(object({ board: string2().min(1), taskId: string2().min(1) })).output(HermesKanbanTaskDetailSchema),
    createTask: oc.input(HermesKanbanTaskCreateSchema).output(object({ task: HermesKanbanTaskSchema, warning: string2().optional() })),
    updateTask: oc.input(HermesKanbanTaskUpdateSchema).output(object({ task: HermesKanbanTaskSchema })),
    listScheduled: oc.output(object({ jobs: array(HermesCronJobSchema) }))
  },
  commands: {
    catalog: oc.input(botId).output(object({ commands: array(HermesCommandCatalogItemSchema), warning: string2() })),
    complete: oc.input(object({ botId: Id, text: string2() })).output(array(HermesSlashCompletionSchema)),
    execute: oc.input(
      object({ botId: Id, invocation: string2().min(1), clientNonce: string2().optional() })
    ).output(HermesCommandResultSchema)
  },
  plugins: {
    install: oc.input(
      object({
        identifier: string2().min(1),
        force: boolean2().optional(),
        enable: boolean2()
      })
    ).output(unknown())
  },
  notifications: {
    registerPush: oc.input(object({ token: string2().min(8).max(512) })).output(object({ ok: literal(true) }))
  }
};

