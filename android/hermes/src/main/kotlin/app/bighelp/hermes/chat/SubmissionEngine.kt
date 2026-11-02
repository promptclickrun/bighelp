package app.bighelp.hermes.chat

import app.bighelp.hermes.DispatchOutcome
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.RequestCancelledException
import app.bighelp.hermes.utf8Length
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Admission of a person's message. The rules, in the order they bind:
 *  1. The exact outgoing bytes are journaled, atomically, before anything is written to the socket. A failed write
 *     sends nothing.
 *  2. A `streaming`/`ok` receipt proves admission only; the send stays pending until its own turn's terminal.
 *     `queued`/`steered` receipts hand ownership to Hermes. Neither claims the agent consumed anything.
 *  3. A lost, timed-out, cancelled or malformed receipt keeps the entry, never resends, and is reviewable. The same
 *     text in saved history is not proof.
 *  4. A definite refusal keeps or restores the text; a newer draft is never overwritten by an older send.
 */
internal class SubmissionEngine(private val ctx: ChatContext, private val engine: ConversationEngine) {
    private enum class Effective { NewTurn, Steer, Queue, InterruptAndSend }

    private class Plan(
        val rt: ConversationRuntime,
        val effective: Effective,
        val entry: JournalEntry,
        val binding: Binding,
        val pending: PendingAdmission?,
        val isCommand: Boolean,
        val selection: SlashSelection?,
        val clearsDraft: Boolean,
        var dispatched: Boolean = false,
        var currentMethod: String = entry.method,
    )

    private sealed interface Planned {
        class Go(val plan: Plan) : Planned
        class Stop(val result: SendResult) : Planned
    }

    private sealed interface Outcome {
        class Admitted(val admission: Admission, val retire: Boolean) : Outcome
        class Refused(val code: Int?, val keepEntry: Boolean, val reachedLimit: Boolean, val error: ChatError) : Outcome
        class Uncertain(val error: ChatError) : Outcome
        class NotSent(val error: ChatError) : Outcome
    }

    // ---- send

    suspend fun send(ref: ConversationRef, text: String, mode: SendMode, attachments: List<String>, selection: SlashSelection?): SendResult {
        if (text.isBlank()) return notSent(ChatError.Kind.InvalidInput)
        if (utf8Length(text) > ChatStoreLimits.MAXIMUM_MESSAGE_TEXT_BYTES) return notSent(ChatError.Kind.TooLarge)
        if (attachments.size > ChatStoreLimits.MAXIMUM_ATTACHMENT_REFERENCES) return notSent(ChatError.Kind.TooLarge)
        // Planning reserves the admission slot on the serial dispatcher. A caller cancelled just as the plan comes back never sees
        // it, so the plan is also noted here and its slot is freed in that case.
        var reserved: Plan? = null
        val plan = try {
            when (val planned = ctx.onState { plan(ref, text, mode, attachments, selection).also { if (it is Planned.Go) reserved = it.plan } }) {
                is Planned.Stop -> return planned.result
                is Planned.Go -> planned.plan
            }
        } catch (e: CancellationException) {
            reserved?.let { withContext(NonCancellable) { release(it) } }
            throw e
        }
        val rt = plan.rt
        // Until the journal entry is durable, nothing exists but the reserved slot: a cancelled caller only gives it back.
        try {
            try {
                ctx.gateway.prepareForAdmission()
            } catch (e: HermesException) {
                release(plan)
                return SendResult.NotSent(SessionBinder.chatError(e))
            }
            val stillOwner = ctx.onState {
                engine.conversations[plan.rt.ref] === rt && rt.binding == plan.binding && rt.binding?.generation == ctx.gateway.state.value.generation &&
                    !rt.hydrating && !rt.needsRecovery && (plan.pending == null || rt.pending === plan.pending)
            }
            if (!stillOwner) {
                release(plan)
                return SendResult.NotSent(ChatError(ChatError.Kind.NotConnected))
            }

            // Journal first. A write failure, also an oversize record, sends nothing.
            try {
                val ops = ArrayList<StoreOp>()
                ops += StoreOp.Put(RecordKey.journal(rt.scope, plan.entry.id), plan.entry.encode())
                if (plan.clearsDraft) ops += engine.draftOp(rt.scope, "", emptyList())
                engine.commit(ops)
            } catch (e: ChatStoreException) {
                release(plan)
                return SendResult.NotSent(ChatError(if (e.kind == ChatStoreException.Kind.TooLarge) ChatError.Kind.TooLarge else ChatError.Kind.PersistenceFailed))
            }
        } catch (e: CancellationException) {
            withContext(NonCancellable) { release(plan) }
            throw e
        }

        // The entry is durable from here. Whatever happens to the caller, the bookkeeping that follows must complete: a cancelled
        // send that skipped it would leave the admission slot taken, the entry out of reach of review and a second bubble on screen.
        var cancelled: CancellationException? = null
        val shown = uncancellably {
            ctx.onState {
                rt.unresolved += plan.entry
                if (plan.clearsDraft) { rt.draft = ""; rt.draftAttachments = emptyList() }
                rt.reducer.addLocalUser(plan.entry.id, text)
                engine.publish(rt)
            }
        }
        shown.cancellation?.let { cancelled = it }

        val outcome: Outcome = if (cancelled != null) {
            // Cancelled before the frame could be written: nothing was dispatched.
            Outcome.NotSent(ChatError(ChatError.Kind.Cancelled))
        } else try {
            dispatch(plan, text)
        } catch (e: CancellationException) {
            cancelled = e
            // The request itself says how far it got; any other cancellation counts as sent once a frame was begun.
            val sent = if (e is RequestCancelledException) e.dispatch == DispatchOutcome.MayHaveBeenSent else plan.dispatched
            if (sent) Outcome.Uncertain(ChatError(ChatError.Kind.Cancelled)) else Outcome.NotSent(ChatError(ChatError.Kind.Cancelled))
        }
        val settled = uncancellably {
            settle(plan, outcome)
            // One exact-owner recovery so independent new input becomes possible again; the repository's scope runs it, not the caller's.
            if (outcome is Outcome.Uncertain) ctx.scope.launch { recoverAfterLoss(plan) }
        }
        cancelled?.let { throw it }
        settled.cancellation?.let { throw it }
        return when (outcome) {
            is Outcome.Admitted -> SendResult.Admitted(plan.entry.id, outcome.admission)
            is Outcome.Refused -> SendResult.Refused(plan.entry.id, outcome.code, outcome.reachedLimit, outcome.error)
            is Outcome.Uncertain -> SendResult.Uncertain(plan.entry.id, outcome.error)
            is Outcome.NotSent -> SendResult.NotSent(outcome.error)
        }
    }

    private class Uncancelled(val cancellation: CancellationException?)

    /**
     * Runs [block] to the end even when the caller is cancelled. Returning into a cancelled caller rethrows its cancellation
     * after the block has finished; that is reported in the result, not thrown, so the caller can finish what it owes first.
     */
    private suspend fun uncancellably(block: suspend () -> Unit): Uncancelled {
        var finished = false
        try {
            withContext(NonCancellable) { block(); finished = true }
        } catch (e: CancellationException) {
            if (!finished) throw e
            return Uncancelled(e)
        }
        return Uncancelled(null)
    }

    private fun notSent(kind: ChatError.Kind) = SendResult.NotSent(ChatError(kind))

    private fun plan(ref: ConversationRef, text: String, mode: SendMode, attachments: List<String>, selection: SlashSelection?): Planned {
        val rt = engine.conversations[ref] ?: return Planned.Stop(notSent(ChatError.Kind.NotOpen))
        val running = rt.reducer.running
        val effective = when (mode) {
            SendMode.Default -> if (running) Effective.Steer else Effective.NewTurn
            SendMode.Steer -> if (running) Effective.Steer else return Planned.Stop(notSent(ChatError.Kind.NoActiveTurn))
            SendMode.Queue -> Effective.Queue
            SendMode.InterruptAndSend -> Effective.InterruptAndSend
        }
        if (attachments.isNotEmpty() && effective != Effective.NewTurn && effective != Effective.Queue) return Planned.Stop(notSent(ChatError.Kind.InvalidInput))
        val isCommand = effective == Effective.NewTurn && text.startsWith("/")
        if (selection != null && (!isCommand || SlashCommandIndex(listOf(selection.command)).selection(text) != selection)) {
            // A chosen command is checked against the current text: an edited message never runs a stale selection.
            return Planned.Stop(notSent(ChatError.Kind.InvalidInput))
        }
        engine.sendBlock(rt, submission = effective != Effective.Steer)?.let { block ->
            return Planned.Stop(SendResult.NotSent(ChatError(if (block == SendBlock.NoLiveSession || block == SendBlock.NotConnected) ChatError.Kind.NotConnected else ChatError.Kind.Conflict), block))
        }
        val binding = rt.binding ?: return Planned.Stop(notSent(ChatError.Kind.NoLiveSession))
        val method = when {
            effective == Effective.InterruptAndSend -> "session.interrupt"
            effective == Effective.Steer -> "session.steer"
            isCommand -> if (selection != null && selection.command.source != CommandSource.Core) "command.dispatch" else "slash.exec"
            else -> "prompt.submit"
        }
        val entry = JournalEntry(ctx.config.random().lowercase(), rt.scope, method, text, text, attachments, ctx.config.clock())
        // The whole frame must fit before anything is journaled; an unsendable message is never recorded as uncertain.
        if (utf8Length(buildParams(binding, text, effective, isCommand, selection, method).toString()) > ChatStoreLimits.MAXIMUM_ENCODED_MESSAGE_BYTES + 16_384) {
            return Planned.Stop(notSent(ChatError.Kind.TooLarge))
        }
        val pending = if (effective == Effective.NewTurn) PendingAdmission(entry, isCommand, binding.generation).also { rt.pending = it } else null
        return Planned.Go(Plan(rt, effective, entry, binding, pending, isCommand, selection, clearsDraft = rt.draft == text))
    }

    /** Frees the reserved slot when nothing was journaled or sent. */
    private suspend fun release(plan: Plan) = ctx.onState {
        if (plan.rt.pending === plan.pending && plan.pending != null) plan.rt.pending = null
        engine.publish(plan.rt)
    }

    private fun buildParams(binding: Binding, text: String, effective: Effective, isCommand: Boolean, selection: SlashSelection?, method: String): JsonObject = buildJsonObject {
        put("session_id", binding.runtimeId); put("profile", binding.profile)
        when {
            effective == Effective.InterruptAndSend -> Unit
            effective == Effective.Steer -> put("text", text)
            isCommand && method == "command.dispatch" -> {
                put("name", selection!!.command.name); put("arg", selection.arguments)
            }
            isCommand -> put("command", text)
            else -> { put("text", text); put("queued", true) }
        }
    }

    // ---- dispatch

    private suspend fun dispatch(plan: Plan, text: String): Outcome {
        val rt = plan.rt
        try {
            return when (plan.effective) {
                Effective.Steer -> {
                    val receipt = call(plan, "session.steer", buildParams(plan.binding, text, Effective.Steer, false, null, "session.steer"))
                    when (receipt.status()) {
                        "queued" -> Outcome.Admitted(Admission.Steered, retire = true)
                        // A definite refusal: Hermes did not take the correction. The text stays the person's.
                        "rejected" -> Outcome.Refused(null, keepEntry = false, reachedLimit = false, error = ChatError(ChatError.Kind.Rejected))
                        else -> Outcome.Uncertain(ChatError(ChatError.Kind.InvalidResponse))
                    }
                }
                Effective.Queue -> queueSubmit(plan, text, plan.entry)
                Effective.InterruptAndSend -> {
                    val stopped = call(plan, "session.interrupt", buildParams(plan.binding, text, Effective.InterruptAndSend, false, null, "session.interrupt"))
                    if (stopped.status() != "interrupted") return Outcome.Uncertain(ChatError(ChatError.Kind.InvalidResponse))
                    // Stop clears the host's old queue; enqueue only after its receipt. Persist the method change first.
                    val next = plan.entry.withMethod("prompt.submit", text)
                    try { engine.commit(listOf(StoreOp.Put(RecordKey.journal(rt.scope, plan.entry.id), next.encode()))) }
                    catch (e: ChatStoreException) { return Outcome.Uncertain(ChatError(ChatError.Kind.PersistenceFailed)) }
                    ctx.onState { replaceEntry(rt, next) }
                    queueSubmit(plan, text, next)
                }
                Effective.NewTurn -> if (plan.isCommand) commandSubmit(plan, text) else streamingSubmit(plan, text)
            }
        } catch (e: HermesException) {
            return classify(e)
        }
        // A cancelled caller (RequestCancelledException) is not an outcome: it reaches send(), which settles and then rethrows it.
    }

    private suspend fun call(plan: Plan, method: String, params: JsonObject): JsonElement {
        plan.dispatched = true
        plan.currentMethod = method
        return ctx.gateway.request(method, params, generation = plan.binding.generation)
    }

    private fun JsonElement.status(): String? = asObject?.get("status").asString

    /** Ordinary idle send: `prompt.submit{queued:true}`; `streaming`/`ok` admits a live turn, queue statuses transfer ownership. */
    private suspend fun streamingSubmit(plan: Plan, text: String): Outcome {
        val result = call(plan, "prompt.submit", buildParams(plan.binding, text, Effective.NewTurn, false, null, "prompt.submit"))
        return receipt(plan, result, expectsUserRow = true)
    }

    private suspend fun queueSubmit(plan: Plan, text: String, entry: JournalEntry): Outcome {
        val result = call(plan, "prompt.submit", buildParams(plan.binding, text, Effective.NewTurn, false, null, "prompt.submit"))
        return when (result.status()) {
            // The explicit queue path: the host queued it, or the turn had just ended and it started.
            "queued", "streaming" -> Outcome.Admitted(Admission.Queued, retire = true)
            else -> Outcome.Uncertain(ChatError(ChatError.Kind.InvalidResponse))
        }
    }

    private suspend fun receipt(plan: Plan, result: JsonElement, expectsUserRow: Boolean): Outcome {
        val obj = result.asObject
        return when (obj?.get("status").asString) {
            "streaming", "ok" -> {
                val owned = ctx.onState {
                    val rt = plan.rt
                    if (rt.pending !== plan.pending || rt.binding != plan.binding) return@onState false
                    if (expectsUserRow) obj?.get("user_row_id").asLong?.takeIf { it > 0 }?.let(rt.reducer::bindUserRow)
                    val pending = rt.pending!!
                    pending.overlapped = pending.candidateTurns.size > 1
                    pending.select()
                    pending.admitted = true
                    rt.status = "Working"
                    completeIfReady(rt)
                    engine.publish(rt)
                    true
                }
                // The socket changed under this send: the receipt cannot be attributed to a turn here. The entry stays.
                if (!owned) return Outcome.Uncertain(ChatError(ChatError.Kind.NotConnected))
                // The entry stays journaled until its turn's terminal; completeIfReady retires it.
                Outcome.Admitted(Admission.Streaming, retire = false)
            }
            "queued", "steered", "redirected" -> Outcome.Admitted(Admission.Queued, retire = true)
            else -> Outcome.Uncertain(ChatError(ChatError.Kind.InvalidResponse))
        }
    }

    /** `/command`: `slash.exec` for the typed or core command, `command.dispatch` for a chosen skill, plugin or user one. */
    private suspend fun commandSubmit(plan: Plan, text: String): Outcome {
        val rt = plan.rt
        val dispatchFirst = plan.entry.method == "command.dispatch"
        val first: JsonElement = try {
            call(plan, plan.entry.method, buildParams(plan.binding, text, Effective.NewTurn, true, plan.selection, plan.entry.method))
        } catch (e: HermesException) {
            // 4018 on slash.exec is a refusal before any execution that names command.dispatch; its own clients retry there once.
            if (dispatchFirst || e.kind != HermesException.Kind.RpcRejected || e.code != 4018L) throw e
            val (name, arg) = SlashCommandCatalog.typedDispatch(text)
            val next = plan.entry.withMethod("command.dispatch", text)
            try { engine.commit(listOf(StoreOp.Put(RecordKey.journal(rt.scope, plan.entry.id), next.encode()))) }
            catch (persist: ChatStoreException) {
                // The first route definitely did not run. Without the changed method on disk the fallback is not sent.
                return Outcome.Refused(4018, keepEntry = false, reachedLimit = false, error = ChatError(ChatError.Kind.PersistenceFailed))
            }
            ctx.onState { replaceEntry(rt, next) }
            call(plan, "command.dispatch", buildJsonObject {
                put("session_id", plan.binding.runtimeId); put("profile", plan.binding.profile); put("name", name); put("arg", arg)
            })
        }
        var response = first.asObject ?: JsonObject(emptyMap())
        var expanded = false
        val type = response["type"].asString
        val message = response["message"].asString
        if ((type == "skill" || type == "send") && message != null) {
            // The dispatcher returned an instruction, not a submission. Its exact bytes go once through prompt.submit.
            val next = plan.entry.withMethod("prompt.submit", message)
            try { engine.commit(listOf(StoreOp.Put(RecordKey.journal(rt.scope, plan.entry.id), next.encode()))) }
            catch (persist: ChatStoreException) {
                return Outcome.Refused(null, keepEntry = false, reachedLimit = false, error = ChatError(ChatError.Kind.PersistenceFailed))
            }
            ctx.onState { replaceEntry(rt, next) }
            val accepted = call(plan, "prompt.submit", buildJsonObject {
                put("session_id", plan.binding.runtimeId); put("profile", plan.binding.profile); put("text", message); put("queued", true)
            })
            response = accepted.asObject ?: JsonObject(emptyMap())
            expanded = true
        }
        val status = response["status"].asString
        val output = response["output"].asString
        return when {
            output != null && status != "streaming" && status != "queued" -> {
                ctx.onState {
                    val id = "command:${plan.entry.id}"
                    rt.reducer.removeLocal(plan.entry.id)
                    rt.reducer.addCommandResult(id, output)
                    plan.pending?.let { it.admitted = true; it.terminalSeen = true }
                    completeIfReady(rt)
                    engine.publish(rt)
                }
                Outcome.Admitted(Admission.CommandOutput, retire = false)
            }
            status == "queued" || status == "steered" || status == "redirected" -> Outcome.Admitted(Admission.Queued, retire = true)
            status == "streaming" || status == "ok" -> receipt(plan, JsonObject(response), expectsUserRow = !plan.isCommand || expanded)
            else -> Outcome.Uncertain(ChatError(ChatError.Kind.InvalidResponse))
        }
    }

    private fun classify(e: HermesException): Outcome {
        val code = e.code?.toInt()
        if (code != null && e.kind in setOf(HermesException.Kind.RpcRejected, HermesException.Kind.ActiveSessionLimit)) {
            val limit = e.kind == HermesException.Kind.ActiveSessionLimit
            return when {
                limit || code in KEPT_REFUSALS -> Outcome.Refused(if (limit) 4090 else code, keepEntry = true, reachedLimit = limit, error = SessionBinder.chatError(e))
                code in PROVEN_REJECTIONS -> Outcome.Refused(code, keepEntry = false, reachedLimit = false, error = SessionBinder.chatError(e))
                // An arbitrary host error from a mutation is not proof that nothing was admitted.
                else -> Outcome.Uncertain(SessionBinder.chatError(e))
            }
        }
        if (e.outcomeUnknown) return Outcome.Uncertain(SessionBinder.chatError(e))
        return when (e.kind) {
            HermesException.Kind.NotConnected, HermesException.Kind.ExclusiveSubmitUnavailable, HermesException.Kind.TooManyRequests,
            HermesException.Kind.MessageTooLarge, HermesException.Kind.TimedOut -> Outcome.NotSent(SessionBinder.chatError(e))
            else -> Outcome.Uncertain(SessionBinder.chatError(e))
        }
    }

    // ---- bookkeeping

    private suspend fun settle(plan: Plan, outcome: Outcome) {
        val rt = plan.rt
        when (outcome) {
            is Outcome.Admitted -> if (outcome.retire) { retire(rt, plan.entry.id); ctx.onState { if (rt.pending === plan.pending) rt.pending = null; rt.status = null; engine.publish(rt) } }
            is Outcome.Refused -> {
                val code = outcome.code
                if (outcome.keepEntry) keepRefused(plan, code ?: 0) else retireAndRestore(plan, code)
                ctx.onState {
                    if (code == 4001 || code == 4007) { rt.requiresReattach = true; rt.needsRecovery = true }
                    if (rt.pending === plan.pending) rt.pending = null
                    engine.publish(rt)
                }
            }
            is Outcome.NotSent -> { retireAndRestore(plan, null); ctx.onState { if (rt.pending === plan.pending) rt.pending = null; engine.publish(rt) } }
            is Outcome.Uncertain -> ctx.onState {
                // The entry stays journaled exactly as sent. The slot is freed so independent input is possible after recovery.
                rt.reducer.removeLocal(plan.entry.id)
                if (rt.pending === plan.pending) rt.pending = null
                rt.needsRecovery = true
                rt.lastError = outcome.error
                engine.publish(rt)
            }
        }
    }

    private suspend fun retire(rt: ConversationRuntime, entryId: String) {
        try {
            engine.commit(listOf(StoreOp.Delete(RecordKey.journal(rt.scope, entryId))))
            ctx.onState { rt.unresolved.removeAll { it.id == entryId }; engine.publish(rt) }
        } catch (e: ChatStoreException) {
            ctx.onState { rt.needsRecovery = true; rt.status = "The retained submission could not be cleared. Review it before sending again."; engine.publish(rt) }
        }
    }

    private suspend fun keepRefused(plan: Plan, code: Int) {
        val rt = plan.rt
        val refused = plan.entry.refused(code)
        try {
            engine.commit(listOf(StoreOp.Put(RecordKey.journal(rt.scope, plan.entry.id), refused.encode())))
            ctx.onState { replaceEntry(rt, refused); rt.reducer.removeLocal(plan.entry.id) }
        } catch (e: ChatStoreException) {
            // The earlier durable entry stays as it was; nothing is retired or resent.
            ctx.onState { rt.needsRecovery = true; rt.status = "The refusal could not be saved. The original submission is retained."; rt.reducer.removeLocal(plan.entry.id) }
        }
    }

    /** Nothing was admitted: the entry goes, and its text returns to an empty composer. A newer draft keeps its place and the entry is kept unsent instead. */
    private suspend fun retireAndRestore(plan: Plan, code: Int?) {
        val rt = plan.rt
        val restore = ctx.onState { rt.draft.isEmpty() && rt.draftAttachments.isEmpty() }
        if (!restore) { keepRefused(plan, code ?: 0); return }
        try {
            val ops = listOf(
                StoreOp.Delete(RecordKey.journal(rt.scope, plan.entry.id)),
                engine.draftOp(rt.scope, plan.entry.composerText, plan.entry.attachments),
            )
            engine.commit(ops)
            ctx.onState {
                rt.unresolved.removeAll { it.id == plan.entry.id }
                rt.reducer.removeLocal(plan.entry.id)
                if (rt.draft.isEmpty()) { rt.draft = plan.entry.composerText; rt.draftAttachments = plan.entry.attachments }
            }
        } catch (e: ChatStoreException) {
            ctx.onState { rt.reducer.removeLocal(plan.entry.id) }
        }
    }

    private fun replaceEntry(rt: ConversationRuntime, entry: JournalEntry) {
        val index = rt.unresolved.indexOfFirst { it.id == entry.id }
        if (index >= 0) rt.unresolved[index] = entry else rt.unresolved += entry
    }

    /** One exact-owner recovery so independent new input becomes possible again. It leaves the original entry untouched and resends nothing. */
    private suspend fun recoverAfterLoss(plan: Plan) {
        val generation = plan.binding.generation
        val live = ctx.gateway.state.value
        if (live.generation != generation || live.connection != app.bighelp.hermes.GatewayConnection.Connected) return
        runCatching { engine.recover(plan.rt, generation) }
    }

    // ---- terminal settlement (serial)

    /** Retires the send once it is admitted and its own turn ended; an overlapping or failed-unreported turn keeps the entry for review. */
    fun completeIfReady(rt: ConversationRuntime) {
        val pending = rt.pending ?: return
        if (!pending.admitted || !pending.terminalSeen) return
        val reportedFailure = pending.selectedTurn != null && rt.reducer.failedTurnId == pending.selectedTurn
        rt.pending = null
        if (!pending.overlapped && (!pending.pendingTurnFailed || reportedFailure)) {
            retireLater(rt, pending.entry.id)
        } else {
            // The entry stays for review. One exact-owner recovery makes independent input possible again.
            rt.needsRecovery = true
            val generation = rt.binding?.generation
            if (generation != null) ctx.scope.launch { if (ctx.gateway.state.value.generation == generation) runCatching { engine.recover(rt, generation) } }
        }
    }

    fun retireAfterReplay(rt: ConversationRuntime, entryId: String) = retireLater(rt, entryId)

    private fun retireLater(rt: ConversationRuntime, entryId: String) {
        ctx.scope.launch { retire(rt, entryId) }
    }

    // ---- stop, draft, review

    suspend fun stop(ref: ConversationRef): StopResult {
        val target = ctx.onState {
            val rt = engine.conversations[ref] ?: return@onState null
            val binding = rt.binding
            if (binding == null || binding.generation != ctx.gateway.state.value.generation || rt.requiresReattach) return@onState null
            rt to binding
        } ?: return StopResult.Refused(ChatError(ChatError.Kind.NotConnected))
        val (rt, binding) = target
        return try {
            val result = ctx.gateway.request("session.interrupt", buildJsonObject { put("session_id", binding.runtimeId); put("profile", binding.profile) }, generation = binding.generation)
            if (result.status() != "interrupted") return StopResult.Uncertain(ChatError(ChatError.Kind.InvalidResponse))
            ctx.onState { if (rt.binding == binding) { rt.stopRequested = true; rt.status = "Stop requested"; engine.publish(rt) } }
            StopResult.Requested
        } catch (e: HermesException) {
            if (e.outcomeUnknown) StopResult.Uncertain(SessionBinder.chatError(e)) else StopResult.Refused(SessionBinder.chatError(e))
        } catch (e: RequestCancelledException) {
            if (e.dispatch == DispatchOutcome.MayHaveBeenSent) StopResult.Uncertain(ChatError(ChatError.Kind.Cancelled)) else StopResult.Refused(ChatError(ChatError.Kind.Cancelled))
        }
    }

    suspend fun updateDraft(ref: ConversationRef, text: String, attachments: List<String>): DraftResult {
        if (utf8Length(text) > ChatStoreLimits.MAXIMUM_MESSAGE_TEXT_BYTES || attachments.size > ChatStoreLimits.MAXIMUM_ATTACHMENT_REFERENCES) {
            return DraftResult.NotSaved(ChatError(ChatError.Kind.TooLarge))
        }
        val rt = ctx.onState { engine.conversations[ref] } ?: return DraftResult.NotSaved(ChatError(ChatError.Kind.NotOpen))
        return try {
            engine.commit(listOf(engine.draftOp(rt.scope, text, attachments)))
            ctx.onState { rt.draft = text; rt.draftAttachments = attachments; engine.publish(rt) }
            DraftResult.Saved
        } catch (e: ChatStoreException) {
            DraftResult.NotSaved(ChatError(if (e.kind == ChatStoreException.Kind.TooLarge) ChatError.Kind.TooLarge else ChatError.Kind.PersistenceFailed))
        }
    }

    suspend fun review(ref: ConversationRef, entryId: String, decision: ReviewDecision): ReviewResult {
        val (rt, entry) = ctx.onState {
            val rt = engine.conversations[ref] ?: return@onState null
            val entry = rt.unresolved.firstOrNull { it.id == entryId } ?: return@onState null
            if (rt.pending?.entry?.id == entryId) return@onState null
            rt to entry
        } ?: return ReviewResult.NotFound
        val restoring = decision == ReviewDecision.RestoreToComposer
        if (restoring && !ctx.onState { rt.draft.isEmpty() && rt.draftAttachments.isEmpty() }) return ReviewResult.ComposerNotEmpty
        return try {
            val ops = ArrayList<StoreOp>()
            ops += StoreOp.Delete(RecordKey.journal(rt.scope, entryId))
            if (restoring) ops += engine.draftOp(rt.scope, entry.composerText, entry.attachments)
            engine.commit(ops)
            ctx.onState {
                rt.unresolved.removeAll { it.id == entryId }
                if (restoring) { rt.draft = entry.composerText; rt.draftAttachments = entry.attachments }
                engine.publish(rt)
            }
            ReviewResult.Done
        } catch (e: ChatStoreException) {
            ReviewResult.Failed(ChatError(ChatError.Kind.PersistenceFailed))
        }
    }

    companion object {
        /** A definite refusal Hermes sends before admission that revokes or limits the session; the entry is kept as unsent. */
        val KEPT_REFUSALS = setOf(4001, 4007, 4090)

        /** Validation and ownership rejections that precede prompt admission: non-admission is established. */
        val PROVEN_REJECTIONS = setOf(4002, 4004, 4009, 4010, 4030, 4130)
    }
}
