package app.bighelp.hermes.chat

import app.bighelp.hermes.GatewayConnection
import app.bighelp.hermes.GatewayEvent
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.WireMessage
import app.bighelp.hermes.utf8Length
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Owns every open conversation: applying live events in order, attaching a stored chat to a runtime, the
 * recovery bracket after any reconnect, canonical history and the durable drafts and journal. All mutable state
 * is confined to the serial dispatcher; requests to the host are awaited outside it and every result is
 * re-checked against the owner (registered runtime, socket generation, hydration token) before it is applied.
 */
internal class ConversationEngine(
    private val ctx: ChatContext,
    private val binder: SessionBinder,
) {
    val conversations = LinkedHashMap<ConversationRef, ConversationRuntime>()
    private val mutableStates = MutableStateFlow<Map<ConversationRef, ConversationState>>(emptyMap())
    val states: StateFlow<Map<ConversationRef, ConversationState>> = mutableStates.asStateFlow()
    val historyCache = HistoryWindowCache()
    lateinit var prompts: PromptCenter
    lateinit var submissions: SubmissionEngine

    private val rowLimit get() = minOf(400, ctx.config.turnLimit * 40)

    // ---- publishing

    fun publish(rt: ConversationRuntime) {
        mutableStates.value = mutableStates.value + (rt.ref to snapshot(rt))
    }

    fun publishAll() {
        mutableStates.value = conversations.mapValues { snapshot(it.value) }
    }

    fun snapshot(rt: ConversationRuntime): ConversationState {
        val savedIds = rt.saved?.rows?.mapTo(HashSet()) { it.id }.orEmpty()
        val live = rt.reducer.items.filter { !(it is MessageItem && it.rowId != null && it.rowId in savedIds) }
        return ConversationState(
            ref = rt.ref, title = rt.title, identity = rt.identity, phase = rt.phase, items = rt.savedItems + live,
            running = rt.reducer.running, status = rt.status, runtime = rt.runtimeInfo, draft = rt.draft,
            draftAttachments = rt.draftAttachments, sendBlock = sendBlock(rt),
            unresolved = rt.unresolved.map { UnresolvedSubmission(it.id, it.method, it.composerText, it.attachments, it.createdAtMillis, it.rejectionCode) },
            prompts = prompts.statesFor(rt.ref),
            history = HistoryState(rt.saved?.nextOffset != null, rt.loadingOlder, rt.saved?.rows?.size ?: 0),
            stopRequested = rt.stopRequested, legacyPromptHost = rt.legacyPromptHost, lastError = rt.lastError,
        )
    }

    /** Why a new message cannot be admitted now; null when it can. Steering a running turn stays open while a send is pending. */
    fun sendBlock(rt: ConversationRuntime): SendBlock? {
        val gateway = ctx.gateway.state.value
        val binding = rt.binding
        return when {
            rt.phase == ConversationPhase.Opening -> SendBlock.Opening
            gateway.connection != GatewayConnection.Connected -> SendBlock.NotConnected
            binding == null || rt.requiresReattach -> SendBlock.NoLiveSession
            binding.generation != gateway.generation -> SendBlock.NotConnected
            rt.hydrating -> SendBlock.CatchingUp
            rt.needsRecovery -> SendBlock.RecoveryRequired
            gateway.capabilities?.perSessionExclusiveSubmit != true -> SendBlock.HostLacksExclusiveSubmit
            rt.pending != null && !rt.reducer.running -> SendBlock.PendingAdmission
            rt.unresolved.size >= ChatStoreLimits.MAXIMUM_UNRESOLVED_ENTRIES -> SendBlock.TooManyUnresolved
            else -> null
        }
    }

    // ---- durable work

    /** Commits [ops] atomically. The in-memory change that goes with them is applied by the caller only after this returns. */
    suspend fun commit(ops: List<StoreOp>) = ctx.store.commit(ops)

    fun draftOp(scope: ConversationScope, text: String, attachments: List<String>): StoreOp =
        if (text.isEmpty() && attachments.isEmpty()) StoreOp.Delete(RecordKey.draft(scope))
        else StoreOp.Put(RecordKey.draft(scope), DraftRecord(scope, text, attachments, ctx.config.clock()).encode())

    private suspend fun loadDurable(scope: ConversationScope, hint: SessionSummary?): Triple<ConversationIdentity, DraftRecord?, List<JournalEntry>> {
        val identity = ctx.store.read(RecordKey.identity(scope))?.let { runCatching { IdentityRecord.decode(scope, it) }.getOrNull() }
            ?: ConversationIdentity(scope.ref, hint?.storedId ?: scope.anchor, lineageRootId = hint?.lineageRootId, lineageIds = hint?.lineageIds,
                canonicalRegistryId = if (hint?.isCanonicalBotChat == true) scope.anchor else binder.canonical[scope.profile]?.id?.takeIf { it == scope.anchor })
        val draft = ctx.store.read(RecordKey.draft(scope))?.let { runCatching { DraftRecord.decode(scope, it) }.getOrNull() }
        val entries = ctx.store.keys(ctx.host, RecordKind.Journal, scope.profile, scope.anchor).mapNotNull { key ->
            ctx.store.read(key)?.let { bytes -> runCatching { JournalEntry.decode(scope, key.entry!!, bytes) }.getOrNull() }
        }.sortedBy { it.createdAtMillis }
        return Triple(identity, draft, entries)
    }

    // ---- open and attach

    /** Registers [ref], loads its durable draft, journal and identity, and attaches it when the socket is ready. */
    suspend fun open(ref: ConversationRef, hint: SessionSummary?): ConversationRuntime {
        ctx.onState { conversations[ref] }?.let { existing ->
            // A chat whose recovery failed, or that lost its socket, is attached again by opening it; a healthy one is left alone.
            val healthy = existing.phase == ConversationPhase.Ready && !existing.needsRecovery && !existing.requiresReattach &&
                existing.binding?.generation == ctx.gateway.state.value.generation
            if (!healthy) attach(existing)
            return existing
        }
        val scope = ctx.conversationScope(ref)
        val (identity, draft, entries) = loadDurable(scope, hint)
        val rt = ConversationRuntime(scope, identity, hint?.title ?: "Chat")
        rt.draft = draft?.text.orEmpty()
        rt.draftAttachments = draft?.attachments.orEmpty()
        rt.unresolved += entries
        // A previous run's pending sends are unresolved by definition: they may or may not have reached the host.
        val registered = ctx.onState {
            conversations[ref]?.let { return@onState it }
            conversations[ref] = rt
            publish(rt)
            null
        }
        if (registered != null) return registered
        seedFromCache(rt)
        attach(rt)
        return rt
    }

    /** A stored copy of the newest page, shown at once. It never replaces anything once live events advanced the cursor. */
    private suspend fun seedFromCache(rt: ConversationRuntime) {
        val bytes = ctx.store.read(RecordKey.history(rt.scope)) ?: return
        val cached = runCatching { HistoryCacheCodec.decode(bytes) }.getOrNull() ?: return
        ctx.onState {
            if (rt.saved == null && rt.reducer.lastSequence == 0L && !rt.reducer.hasLiveEvents) {
                setSaved(rt, cached, persist = false)
                publish(rt)
            }
        }
    }

    /** Resume by stored ID on the current socket and recover coverage. Failure leaves the transcript and marks the chat suspended. */
    suspend fun attach(rt: ConversationRuntime) {
        val state = ctx.gateway.state.value
        if (state.connection != GatewayConnection.Connected) {
            ctx.onState { suspendLocal(rt, ConversationPhase.Suspended); publish(rt) }
            return
        }
        val generation = state.generation
        ctx.onState {
            rt.hydrating = true; rt.phase = if (rt.hasRecovered) ConversationPhase.Recovering else ConversationPhase.Opening
            rt.lastError = null; publish(rt)
        }
        try {
            val tip = ctx.onState { rt.identity.storedTip }
            val attached = binder.resume(rt.scope.profile, tip)
            val proceed = ctx.onState {
                if (conversations[rt.ref] !== rt || ctx.gateway.state.value.generation != generation) return@onState false
                val before = rt.binding
                if (attached.storedId != rt.identity.storedTip) {
                    if (!IdentityAdoption.accepts(rt.identity, attached.storedId, IdentityAdoption.Evidence.ResumeOfCurrentTip)) throw ChatException(ChatError.Kind.InvalidResponse)
                    rt.identity = rt.identity.withTip(attached.storedId)
                }
                // Sequence numbers belong to one runtime: another runtime's cursor never advances this one.
                if (before != null && before.runtimeId != attached.runtimeId) rt.reducer.resetCursor("", 0)
                rt.binding = Binding(attached.runtimeId, attached.storedId, generation, null, rt.scope.profile)
                rt.requiresReattach = false
                applyInfo(rt, attached.info)
                true
            }
            if (!proceed) return
            persistIdentity(rt)
            recover(rt, generation)
        } catch (e: ChatException) {
            fail(rt, e.error)
        } catch (e: HermesException) {
            fail(rt, SessionBinder.chatError(e).let { if (e.kind == HermesException.Kind.RpcRejected && (e.code == 4007L || e.code == 404L)) ChatError(ChatError.Kind.NotOpen, e.kind, e.code, e.reason) else it })
        } catch (e: app.bighelp.hermes.RequestCancelledException) {
            fail(rt, ChatError(ChatError.Kind.Cancelled))
            return
        }
        // Reading saved history is not part of coverage: a failure here leaves the chat usable, with the error shown.
        try {
            refreshNewest(rt)
        } catch (e: ChatException) {
            ctx.onState { rt.lastError = e.error; publish(rt) }
        } catch (e: HermesException) {
            ctx.onState { rt.lastError = SessionBinder.chatError(e); publish(rt) }
        }
    }

    private suspend fun fail(rt: ConversationRuntime, error: ChatError) {
        ctx.onState {
            rt.hydrating = false
            rt.heldEvents = ArrayList()
            rt.lastError = error
            if (rt.phase != ConversationPhase.Ready) rt.phase = ConversationPhase.Suspended
            rt.needsRecovery = true
            publish(rt)
        }
    }

    private fun persistIdentityLater(rt: ConversationRuntime) { ctx.scope.launch { persistIdentity(rt) } }

    private suspend fun persistIdentity(rt: ConversationRuntime) {
        val identity = ctx.onState { rt.identity }
        if (identity.storedTip == rt.scope.anchor && identity.formerStoredIds.isEmpty() && identity.lineageIds == null && identity.canonicalRegistryId == null) return
        runCatching { ctx.store.commit(listOf(StoreOp.Put(RecordKey.identity(rt.scope), IdentityRecord(rt.scope, identity).encode()))) }
    }

    private fun applyInfo(rt: ConversationRuntime, info: JsonObject) {
        rt.runtimeInfo = rt.runtimeInfo.merged(
            RuntimeInfo(info["model"].asString, info["provider"].asString, info["reasoning_effort"].asString, info["service_tier"].asString,
                info["cwd"].asString, info["lazy"].asBool),
        )
    }

    // ---- connection changes

    /** Synchronous with the `gateway.ready` that announces a new socket: close admission before any later event applies. */
    fun onSocketReady(generation: Long) {
        for (rt in conversations.values) {
            if (rt.binding?.generation == generation && !rt.requiresReattach) continue
            suspendLocal(rt, ConversationPhase.Recovering)
            rt.hydrating = true
        }
        publishAll()
    }

    /** Re-attaches every retained conversation on the new socket, once it is fully connected. */
    suspend fun reattachAll(generation: Long) {
        val targets = ctx.onState { conversations.values.filter { !(it.binding?.generation == generation && !it.requiresReattach) } }
        for (rt in targets) {
            if (ctx.gateway.state.value.generation != generation) return
            attach(rt)
        }
    }

    fun onDisconnected() {
        for (rt in conversations.values) suspendLocal(rt, ConversationPhase.Suspended)
        publishAll()
    }

    /** A conversation just created: bound from the create answer itself, then covered like any other. */
    suspend fun adoptCreated(ref: ConversationRef, attached: Attached, title: String): ConversationRuntime {
        val generation = ctx.gateway.state.value.generation
        val scope = ctx.conversationScope(ref)
        val rt = ConversationRuntime(scope, ConversationIdentity(ref, attached.storedId), title)
        ctx.onState {
            conversations[ref] = rt
            rt.binding = Binding(attached.runtimeId, attached.storedId, generation, null, scope.profile)
            rt.hydrating = true
            applyInfo(rt, attached.info)
            publish(rt)
        }
        try {
            recover(rt, generation)
        } catch (e: ChatException) { fail(rt, e.error) } catch (e: HermesException) { fail(rt, SessionBinder.chatError(e)) }
        return rt
    }

    /**
     * Revokes transport authority, not the visible transcript: held events are dropped, prompts retire, and an
     * already confirmed admission keeps its evidence so an exact replay of its terminal can settle it later.
     */
    fun suspendLocal(rt: ConversationRuntime, phase: ConversationPhase) {
        rt.pending?.let { pending ->
            if (pending.admitted && !pending.overlapped) pending.selectedTurn?.let { rt.acceptedEvidence = AcceptedEvidence(pending.entry.id, it, rt.reducer.epoch) }
            rt.needsRecovery = true
        }
        rt.pending = null
        rt.phase = phase
        rt.hydrating = false
        rt.heldEvents = ArrayList()
        rt.heldOverflow = false
        rt.stopRequested = false
        prompts.retireFor(rt.ref)
        rt.status = null
    }

    // ---- events

    fun onEvent(gatewayEvent: GatewayEvent) {
        val event = gatewayEvent.event
        when (event.type) {
            "gateway.ready" -> onSocketReady(gatewayEvent.generation)
            "session.reclaimed" -> reclaim(event, gatewayEvent.generation)
            else -> {
                if (gatewayEvent.generation != ctx.gateway.state.value.generation) return
                val runtime = event.sessionID ?: return
                val rt = conversations.values.firstOrNull { it.binding?.runtimeId == runtime && it.binding?.generation == gatewayEvent.generation } ?: return
                if (rt.hydrating) {
                    if (rt.heldEvents.size >= HELD_EVENT_LIMIT) rt.heldOverflow = true else rt.heldEvents += event
                    return
                }
                apply(rt, event, replaying = false)
                publish(rt)
            }
        }
    }

    /** `session.reclaimed`: revoke the writer first. Only the exact owner (both payload IDs and, if present, the outer ID) matches. */
    private fun reclaim(event: WireMessage.Event, generation: Long) {
        val payload = event.payload
        if (payload.keys != setOf("session_id", "stored_session_id", "reason")) return
        val runtime = payload["session_id"].asString ?: return
        val stored = payload["stored_session_id"].asString ?: return
        if (event.sessionID != null && event.sessionID != runtime) return
        val rt = conversations.values.firstOrNull { it.binding?.runtimeId == runtime && it.binding?.generation == generation && it.identity.knows(stored) } ?: return
        rt.requiresReattach = true
        suspendLocal(rt, ConversationPhase.Suspended)
        rt.status = "Hermes ended this live session. Reopen it before sending."
        publish(rt)
    }

    /** Applies one event of this runtime. [replaying] marks recovery replay: it settles state but is not new live activity. */
    fun apply(rt: ConversationRuntime, event: WireMessage.Event, replaying: Boolean) {
        val change = rt.reducer.accept(event)
        if (change.ignored) return
        if (rt.liveBaselineRowId < 0 && (change.started || rt.reducer.items.isNotEmpty())) rt.liveBaselineRowId = rt.saved?.rows?.maxOfOrNull { it.id } ?: 0
        change.storedIdReport?.let { report -> adoptReportedTip(rt, report) }
        change.runtime?.let { rt.runtimeInfo = rt.runtimeInfo.merged(it) }
        change.title?.let { rt.title = it }
        change.status?.let { rt.status = it }
        if (change.compaction == CompactionSignal.Compacted) rt.status = "Compacted"
        val pending = rt.pending
        if (event.type == "message.start") pending?.turnFailed = false
        if (event.type == "error" || change.terminalError != null) pending?.turnFailed = true
        if (pending != null && event.type == "message.start") {
            if (pending.candidateTurns.size < 2 && rt.reducer.turnId !in pending.candidateTurns) pending.candidateTurns += rt.reducer.turnId
            pending.select()
        }
        if (change.failedBeforeStart && pending != null && pending.candidateTurns.isEmpty()) pending.candidateTurns += rt.reducer.turnId
        if (change.terminal) {
            rt.status = null
            rt.stopRequested = false
            if (pending != null && rt.reducer.turnId in pending.candidateTurns) {
                pending.settledTurns[rt.reducer.turnId] = pending.turnFailed
                pending.select()
                submissions.completeIfReady(rt)
            }
            rt.acceptedEvidence?.let { evidence ->
                if (event.sequence != null && evidence.epoch == rt.reducer.epoch && evidence.turnId == rt.reducer.turnId && pending?.turnFailed != true) {
                    submissions.retireAfterReplay(rt, evidence.entryId)
                    rt.acceptedEvidence = null
                    rt.needsRecovery = false
                }
            }
        }
        if (!replaying) change.persistedTurn?.let { rt.reducer.bindRows(it) }
        // The host's saved history is the truth once a turn ends: read the newest page again (live rows stay until it has caught up).
        if (!replaying && change.terminal) refreshHistoryLater(rt)
        if (change.errorEvent) rt.status = "Hermes reported a turn error."
    }

    private fun refreshHistoryLater(rt: ConversationRuntime) {
        val generation = rt.binding?.generation ?: return
        ctx.scope.launch {
            if (ctx.gateway.state.value.generation != generation) return@launch
            try {
                refreshNewest(rt)
            } catch (e: ChatException) {
                ctx.onState { rt.lastError = e.error; publish(rt) }
            } catch (e: HermesException) {
                ctx.onState { rt.lastError = SessionBinder.chatError(e); publish(rt) }
            }
        }
    }

    private fun adoptReportedTip(rt: ConversationRuntime, report: String) {
        if (report == rt.identity.storedTip) return
        if (!IdentityAdoption.accepts(rt.identity, report, IdentityAdoption.Evidence.RuntimeReport)) return
        rt.identity = rt.identity.withTip(report)
        rt.binding = rt.binding?.copy(storedId = report)
        persistIdentityLater(rt)
    }

    // ---- recovery

    /**
     * The bracket: replay since the cursor, activation, replay since that, then reconcile. Admission reopens only
     * when every held live event extends the accepted cursor without a gap. Never resumes or resends a prompt.
     */
    suspend fun recover(rt: ConversationRuntime, generation: Long) {
        val profile = rt.scope.profile
        val (runtimeId, hint, checkpoint, knownEpoch) = ctx.onState {
            val binding = rt.binding ?: throw ChatException(ChatError.Kind.NoLiveSession)
            if (binding.generation != generation) throw ChatException(ChatError.Kind.NotConnected)
            rt.hydrating = true
            Quad(binding.runtimeId, ctx.gateway.state.value.replayEpoch ?: rt.reducer.epoch, rt.reducer.lastSequence, rt.reducer.epoch)
        }
        var succeeded = false
        try {
            val before = eventsSince(runtimeId, if (hint == knownEpoch) checkpoint else 0)
            val snapshot = binder.activate(profile, runtimeId)
            ctx.onState { requireCurrent(rt, generation, runtimeId) }
            val attached = validatedActivation(snapshot, runtimeId, profile)
            val tail = eventsSince(runtimeId, before.latest)
            if (tail.epoch != before.epoch) throw invalidResponse()
            ctx.onState { requireCurrent(rt, generation, runtimeId) }
            val modern = tail.openRequests != null
            if (tail.openRequests != null && tail.openRequests !is JsonArray) throw invalidResponse()
            if (modern) ctx.gateway.adoptOpenRequests(tail.openRequests!!, runtimeId, generation)
            val exact = before.epoch == knownEpoch && checkpoint > 0 && before.truncated == false && tail.truncated == false
            ctx.onState {
                requireCurrent(rt, generation, runtimeId)
                rt.legacyPromptHost = !modern
                applyInfo(rt, attached.info)
                if (attached.storedId != rt.identity.storedTip && IdentityAdoption.accepts(rt.identity, attached.storedId, IdentityAdoption.Evidence.RuntimeReport)) {
                    rt.identity = rt.identity.withTip(attached.storedId)
                }
                rt.binding = rt.binding?.copy(storedId = attached.storedId, epoch = before.epoch)
                if (exact) {
                    replay(rt, before.events)
                    replay(rt, tail.events)
                    val tailOwnsLiveness = tail.events.any {
                        it.type == "message.start" || it.type == "message.delta" || (it.type == "session.info" && it.payload["running"].asBool != null)
                    }
                    if (!tailOwnsLiveness) snapshotLifecycle(rt, attached)
                } else {
                    // No complete ring: adopt the activation as source detail, never double-append an unknown overlap.
                    if (rt.reducer.epoch != before.epoch) rt.reducer.resetCursor(before.epoch, 0)
                    rt.reducer.seedRunning(attached.running == true)
                    if (before.latest != tail.latest) {
                        tail.events.filter { it.type == "session.info" || it.type == "message.start" }.forEach { replay(rt, listOf(it)) }
                    }
                    rt.reducer.seedCheckpoint(tail.latest)
                    rt.needsHistoryReseed = attached.running != true
                    if (attached.running != true && rt.pending != null) {
                        // A replacement snapshot cannot prove admission of a lost RPC: keep the journal entry untouched.
                        rt.needsRecovery = true
                        rt.pending = null
                    }
                }
                if (!replayHeld(rt)) throw ChatException(ChatError.Kind.NotConnected, HermesException.Kind.TooManyRequests)
                rt.needsRecovery = false
                rt.hydrating = false
                rt.hasRecovered = true
                rt.phase = ConversationPhase.Ready
                rt.status = null
                publish(rt)
            }
            succeeded = true
        } catch (e: Throwable) {
            ctx.onState {
                // A recovery that belongs to a socket that has since been replaced must not touch the newer owner's state.
                if (!succeeded && rt.binding?.generation == generation && ctx.gateway.state.value.generation == generation) {
                    // Keep admission closed and the held events for the next catch-up.
                    rt.needsRecovery = true
                    rt.hydrating = false
                }
            }
            throw e
        }
    }

    private class Quad<A, B, C, D>(val a: A, val b: B, val c: C, val d: D) {
        operator fun component1() = a
        operator fun component2() = b
        operator fun component3() = c
        operator fun component4() = d
    }

    private class Replay(val epoch: String, val latest: Long, val truncated: Boolean?, val events: List<WireMessage.Event>, val openRequests: JsonElement?)

    private suspend fun eventsSince(runtimeId: String, lastSeen: Long): Replay {
        val result = ctx.gateway.request("session.events.since", buildJsonObject { put("session_id", runtimeId); put("last_seen", lastSeen) }).asObject ?: throw invalidResponse()
        val epoch = result["epoch"].asString ?: throw invalidResponse()
        val latest = result["latest_seq"].asLong?.takeIf { it >= 0 } ?: throw invalidResponse()
        val events = (result["events"].asArray ?: JsonArray(emptyList())).mapNotNull { frame ->
            // Stock events.since returns params dictionaries, not envelopes; accept either.
            val params = frame.asObject?.get("params").asObject ?: frame.asObject ?: return@mapNotNull null
            val type = params["type"].asString ?: return@mapNotNull null
            WireMessage.Event(type, params["session_id"].asString, params["payload"].asObject ?: JsonObject(emptyMap()), params["seq"].asLong, params)
        }.sortedBy { it.sequence ?: 0 }
        return Replay(epoch, latest, result["truncated"].asBool, events, result["open_requests"])
    }

    private fun validatedActivation(snapshot: JsonObject, runtimeId: String, profile: String): Attached {
        if (snapshot["session_id"].asString != runtimeId || snapshot["running"].asBool == null) throw invalidResponse()
        val stored = snapshot["session_key"].asString?.takeIf { Coordinates.isValid(it) } ?: throw invalidResponse()
        val info = snapshot["info"].asObject ?: JsonObject(emptyMap())
        info["profile_name"]?.let { if (it.asString != profile) throw invalidResponse() }
        info["stored_session_id"]?.let { if (it.asString != stored) throw invalidResponse() }
        return Attached(runtimeId, stored, snapshot["running"].asBool, info, info["model"].asString, info["cwd"].asString)
    }

    private fun requireCurrent(rt: ConversationRuntime, generation: Long, runtimeId: String) {
        val binding = rt.binding
        if (conversations[rt.ref] !== rt || binding == null || binding.generation != generation || binding.runtimeId != runtimeId ||
            ctx.gateway.state.value.generation != generation
        ) throw ChatException(ChatError.Kind.NotConnected)
    }

    private fun replay(rt: ConversationRuntime, events: List<WireMessage.Event>) {
        for (event in events.sortedBy { it.sequence ?: 0 }) apply(rt, event, replaying = true)
    }

    /** The activation's `running` is the newest liveness observation unless the replay tail carried its own. */
    private fun snapshotLifecycle(rt: ConversationRuntime, attached: Attached) {
        val info = JsonObject(attached.info + ("running" to JsonPrimitive(attached.running == true)))
        apply(rt, WireMessage.Event("session.info", rt.binding?.runtimeId, info, null), replaying = true)
        if (attached.running != true) rt.needsHistoryReseed = true
    }

    /** Opens admission only if every event held during recovery extends the cursor with no gap or duplicate. */
    private fun replayHeld(rt: ConversationRuntime): Boolean {
        if (rt.heldOverflow || rt.heldEvents.any { it.sequence == null }) return false
        val checkpoint = rt.reducer.lastSequence
        val pending = rt.heldEvents.filter { (it.sequence ?: 0) > checkpoint }.sortedBy { it.sequence }
        if (!pending.withIndex().all { (index, event) -> event.sequence == checkpoint + index + 1 }) return false
        rt.hydrating = false
        rt.heldEvents = ArrayList()
        rt.heldOverflow = false
        pending.forEach { apply(rt, it, replaying = false) }
        return true
    }

    // ---- history

    private fun pathIdentifier(id: String): String {
        if (id.isEmpty() || utf8Length(id) > 512 || id == "." || id == ".." || !id.all { it.isLetterOrDigit() && it.code < 128 || it in "-_.:" }) throw ChatException(ChatError.Kind.InvalidResponse)
        return id
    }

    /** Reads the newest page and refreshes the retained window; a result for a stale owner or token is discarded. */
    suspend fun refreshNewest(rt: ConversationRuntime) {
        val token = ctx.onState { ++rt.historyToken }
        val stored = ctx.onState { rt.identity.storedTip }
        val limit = rowLimit
        val envelope = ctx.rest.get("/api/sessions/${pathIdentifier(stored)}/messages", historyQuery(rt.scope.profile, limit, 0, "latest"))
        val page = HistoryPage.parse(envelope, rt.scope.profile, 0, limit, "latest")
        ctx.onState {
            if (conversations[rt.ref] !== rt || rt.historyToken != token) return@onState
            if (!acceptStored(rt, page.storedId)) throw ChatException(ChatError.Kind.HistoryChanged)
            val window = HistoryWindow.refreshed(rt.saved, page)
            setSaved(rt, window, persist = true)
            reconcileLive(rt)
            rt.needsHistoryReseed = false
            publish(rt)
        }
    }

    private fun acceptStored(rt: ConversationRuntime, returned: String): Boolean {
        if (returned == rt.identity.storedTip) return true
        if (!IdentityAdoption.accepts(rt.identity, returned, IdentityAdoption.Evidence.HistoryResponse)) return false
        rt.identity = rt.identity.withTip(returned)
        rt.binding = rt.binding?.copy(storedId = returned)
        persistIdentityLater(rt)
        return true
    }

    suspend fun loadOlder(ref: ConversationRef): HistoryLoad {
        val rt = ctx.onState { conversations[ref] } ?: return HistoryLoad.Failed(ChatError(ChatError.Kind.NotOpen))
        val (window, token) = ctx.onState {
            val held = rt.saved
            if (held?.nextOffset == null || rt.loadingOlder) return@onState null to 0L
            rt.loadingOlder = true; publish(rt)
            held to ++rt.historyToken
        }
        if (window == null) return HistoryLoad.NothingOlder
        try {
            val offset = window.nextOffset!!
            val limit = rowLimit + 1
            val envelope = ctx.rest.get("/api/sessions/${pathIdentifier(window.storedId)}/messages", historyQuery(rt.scope.profile, limit, offset - 1, "latest"))
            val page = HistoryPage.parse(envelope, rt.scope.profile, offset - 1, limit, "latest")
            return ctx.onState {
                if (conversations[ref] !== rt || rt.historyToken != token || rt.saved !== window) return@onState HistoryLoad.Failed(ChatError(ChatError.Kind.Cancelled))
                val merged = HistoryWindow.prepended(window, page)
                setSaved(rt, merged, persist = true)
                publish(rt)
                HistoryLoad.Loaded(merged.rows.size - window.rows.size, merged.nextOffset != null)
            }
        } catch (e: ChatException) {
            if (e.error.kind == ChatError.Kind.HistoryChanged) {
                // A shifted or rewritten window is never merged: start over from the newest page.
                ctx.onState { rt.saved = null; historyCache.remove(ref) }
                runCatching { refreshNewest(rt) }
            }
            return HistoryLoad.Failed(e.error)
        } catch (e: HermesException) {
            return HistoryLoad.Failed(SessionBinder.chatError(e))
        } finally {
            ctx.onState { rt.loadingOlder = false; publish(rt) }
        }
    }

    private fun historyQuery(profile: String, limit: Int, offset: Int, order: String) =
        listOf("profile" to profile, "limit" to limit.toString(), "offset" to offset.toString(), "order" to order, "include_compacted" to "true")

    fun setSaved(rt: ConversationRuntime, window: HistoryWindow, persist: Boolean) {
        rt.saved = window
        rt.savedItems = HistoryProjection.project(window.rows).items
        historyCache.put(rt.ref, window)
        if (persist) {
            val bytes = HistoryCacheCodec.encode(window)
            ctx.scope.launch { ctx.store.putCache(RecordKey.history(rt.scope), bytes) }
        }
    }

    /**
     * Drops live rows once saved history holds what they showed: only when it has rows newer than when the live
     * activity began, and, if the live tail carried an assistant reply, an assistant row among them. Otherwise the
     * richer live rows stay and a later refresh tries again.
     */
    private fun reconcileLive(rt: ConversationRuntime) {
        if (rt.reducer.running || rt.pending != null) return
        val live = rt.reducer.items
        if (live.isEmpty()) { rt.liveBaselineRowId = -1; return }
        val rows = rt.saved?.rows ?: return
        val baseline = rt.liveBaselineRowId.coerceAtLeast(0)
        val newer = rows.filter { it.id > baseline && it.isVisible }
        if (newer.isEmpty()) return
        val needsAssistant = live.any { it is MessageItem && it.role == MessageRole.Assistant }
        if (needsAssistant && newer.none { it.role == "assistant" }) return
        rt.reducer.clearItems()
        rt.liveBaselineRowId = -1
    }

    // ---- misc

    fun byRuntime(runtimeId: String, generation: Long): ConversationRuntime? =
        conversations.values.firstOrNull { it.binding?.runtimeId == runtimeId && it.binding?.generation == generation }

    companion object {
        const val HELD_EVENT_LIMIT = 16_384
    }
}

internal fun RuntimeInfo.merged(patch: RuntimeInfo) = RuntimeInfo(
    patch.model ?: model, patch.provider ?: provider, patch.reasoningEffort ?: reasoningEffort, patch.serviceTier ?: serviceTier,
    patch.cwd ?: cwd, patch.lazy ?: lazy,
)
