package app.bighelp.hermes.chat

import app.bighelp.hermes.HermesException
import java.io.File
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SendFlowTest : ChatTestBase() {
    private val hostScope = ChatTestData.host

    private suspend fun ChatRig.journalKeys(ref: ConversationRef) = store.keys(hostScope, RecordKind.Journal, ref.profile, ref.anchor)

    private fun ChatRig.messages(ref: ConversationRef) = state(ref).items.filterIsInstance<MessageItem>()

    /** Starts a turn and makes the client observe it running (the reply is not finished). */
    private suspend fun ChatRig.startRunning(ref: ConversationRef, text: String = "go"): FakeHermesHost.Runtime {
        assertTrue(repo.send(ref, text) is SendResult.Admitted)
        val rt = runtimeOf(ref)
        host.emit(rt, "message.start")
        host.flush()
        awaitState(ref, "running") { it.running }
        return rt
    }

    @Test fun theExactBytesAreJournaledBeforeDispatchAndTheStreamingReceiptStaysPendingUntilTheOwnedTerminal() = run {
        val r = rig()
        val ref = r.newChat()
        var journaledDuringDispatch = -1
        r.host.once("prompt.submit") { params ->
            journaledDuringDispatch = r.journalKeys(ref).size
            r.host.defaultHandle("prompt.submit", params)
        }
        val result = r.repo.send(ref, "hello  world")
        assertEquals(Admission.Streaming, (result as SendResult.Admitted).admission)
        assertEquals("The entry was on disk when the method was dispatched", 1, journaledDuringDispatch)
        val sent = r.host.calls("prompt.submit").single().params
        assertEquals("hello  world", sent["text"].asString)
        assertEquals(true, sent["queued"].asBool)
        assertEquals("research", sent["profile"].asString)
        assertEquals(r.runtimeOf(ref).id, sent["session_id"].asString)
        assertEquals("The local UUID is never sent to Hermes", setOf("session_id", "profile", "text", "queued"), sent.keys)

        // The receipt proved admission only: the entry stays, and a second ordinary send is closed.
        assertEquals(1, r.state(ref).unresolved.size)
        assertEquals(SendBlock.PendingAdmission, r.state(ref).sendBlock)

        val rt = r.runtimeOf(ref)
        val userRow = r.host.sessions.getValue(rt.stored).rows.last()["id"].asLong!!
        r.host.emit(rt, "message.start")
        r.host.emit(rt, "message.delta", """{"text":"Hi "}""")
        r.host.emit(rt, "message.delta", """{"text":"there."}""")
        val assistant = r.host.sessions.getValue(rt.stored).addRow("assistant", "Hi there.")
        r.host.emit(rt, "message.complete", """{"text":"Hi there.","persisted_turn":{"user_row_id":$userRow,"final_assistant_row_id":$assistant}}""")
        r.host.flush()
        val mid = r.awaitState(ref) { it.items.any { item -> item is MessageItem && item.text == "Hi there." } }
        assertEquals("A segment final is not the end of the turn: the entry is still held", 1, mid.unresolved.size)
        assertTrue(mid.running)

        r.host.emit(rt, "session.info", """{"running":false}""")
        r.host.flush()
        r.eventually(message = "entry retired at the terminal") { r.state(ref).unresolved.isEmpty() && r.journalKeys(ref).isEmpty() }
        // The submit's return value is never appended as a second reply; saved history takes over from the live rows.
        r.eventually(message = "history caught up") { r.messages(ref).all { it.origin == ItemOrigin.Saved } && r.messages(ref).size == 2 }
        assertEquals(listOf("hello  world", "Hi there."), r.messages(ref).map { it.text })
        assertNull(r.state(ref).sendBlock)
    }

    @Test fun aFailedJournalWriteSendsNothingAndLeavesTheComposerAlone() = run {
        val store = FileSnapshotChatStore(File(directory, "s.bin"))
        val r = rig(store = store)
        val ref = r.newChat()
        r.repo.updateDraft(ref, "important words")
        store.failNextCommit = ChatStoreException(ChatStoreException.Kind.QuotaExceeded)
        val result = r.repo.send(ref, "important words")
        assertEquals(ChatError.Kind.PersistenceFailed, (result as SendResult.NotSent).error.kind)
        assertEquals("Nothing reached the socket", 0, r.host.count("prompt.submit"))
        assertEquals("important words", r.state(ref).draft)
        assertNull("The slot is free again", r.state(ref).sendBlock)
        assertTrue(r.repo.send(ref, "important words") is SendResult.Admitted)
    }

    @Test fun eventsThatBeatTheReceiptStillSettleTheRightTurn() = run {
        val r = rig()
        val ref = r.newChat()
        r.host.beforeReceipt = { rt ->
            r.host.emit(rt, "message.start")
            r.host.emit(rt, "message.delta", """{"text":"early"}""")
            r.host.flush()
        }
        assertTrue(r.repo.send(ref, "hi") is SendResult.Admitted)
        val rt = r.runtimeOf(ref)
        assertEquals("early", r.messages(ref).last { it.role == MessageRole.Assistant }.text)
        assertEquals(1, r.state(ref).unresolved.size)
        r.host.emit(rt, "session.info", """{"running":false}""")
        r.host.flush()
        r.eventually(message = "retired") { r.state(ref).unresolved.isEmpty() }
    }

    @Test fun twoOverlappingStartsKeepTheEntryForReviewInsteadOfGuessingWhichTurnWasOurs() = run {
        val r = rig()
        val ref = r.newChat()
        r.host.beforeReceipt = { rt ->
            r.host.emit(rt, "message.start")
            r.host.emit(rt, "session.info", """{"running":false}""")
            r.host.emit(rt, "message.start")
            r.host.flush()
        }
        assertTrue(r.repo.send(ref, "hi") is SendResult.Admitted)
        val rt = r.runtimeOf(ref)
        r.host.emit(rt, "session.info", """{"running":false}""")
        r.host.flush()
        r.eventually(message = "recovery after the ambiguous overlap") { r.state(ref).sendBlock == null }
        assertEquals("Ambiguous: the entry is kept, not retired by a stranger's final", 1, r.state(ref).unresolved.size)
    }

    @Test fun aSendWhileATurnRunsSteersByDefaultAndQueueUsesThePromptSubmitPath() = run {
        val r = rig()
        val ref = r.newChat()
        val rt = r.startRunning(ref)
        val steer = r.repo.send(ref, "also check the tests")
        assertEquals(Admission.Steered, (steer as SendResult.Admitted).admission)
        val steerCall = r.host.calls("session.steer").single().params
        assertEquals("also check the tests", steerCall["text"].asString)
        assertEquals(rt.id, steerCall["session_id"].asString)
        assertEquals(listOf("also check the tests"), rt.steers)
        r.eventually(message = "steer receipt retired its entry") { r.state(ref).unresolved.size == 1 }

        val queued = r.repo.send(ref, "then this", mode = SendMode.Queue)
        assertEquals(Admission.Queued, (queued as SendResult.Admitted).admission)
        val queueCall = r.host.calls("prompt.submit").last().params
        assertEquals("then this", queueCall["text"].asString)
        assertEquals(true, queueCall["queued"].asBool)
        assertEquals(1, r.host.count("session.steer"))
    }

    @Test fun steerNeedsAnObservedRunningTurnAndNeverBecomesANewOne() = run {
        val r = rig()
        val ref = r.newChat()
        val result = r.repo.send(ref, "late correction", mode = SendMode.Steer)
        assertEquals(ChatError.Kind.NoActiveTurn, (result as SendResult.NotSent).error.kind)
        assertEquals(0, r.host.count("session.steer") + r.host.count("prompt.submit"))
        assertTrue(r.journalKeys(ref).isEmpty())
    }

    @Test fun aRejectedSteerIsADefiniteRefusalAndTheTextComesBack() = run {
        val r = rig()
        val ref = r.newChat()
        r.startRunning(ref)
        r.host.once("session.steer") { buildJsonObject { put("status", "rejected") } }
        val result = r.repo.send(ref, "nope")
        assertTrue(result is SendResult.Refused)
        assertEquals("nope", r.state(ref).draft)
        assertEquals("Only the first send's entry remains", 1, r.state(ref).unresolved.size)
    }

    @Test fun stopNeedsTheInterruptedReceiptAndTheTurnEndsOnlyWhenTheHostSaysSo() = run {
        val r = rig()
        val ref = r.newChat()
        val rt = r.startRunning(ref)
        assertEquals(StopResult.Requested, r.repo.stop(ref))
        assertTrue(r.host.runtimes.getValue(rt.id).interruptRequested)
        val stopped = r.awaitState(ref) { it.stopRequested }
        assertTrue("Still running until running:false arrives", stopped.running)
        r.host.emit(rt, "session.info", """{"running":false}""")
        r.host.flush()
        val ended = r.awaitState(ref) { !it.running }
        assertFalse(ended.stopRequested)

        r.startRunning(ref, "again")
        r.host.once("session.interrupt") { buildJsonObject { put("status", "nothing") } }
        assertTrue(r.repo.stop(ref) is StopResult.Uncertain)
    }

    @Test fun interruptAndSendQueuesOnlyAfterTheStopReceiptAndNeverRetriesALostStop() = run {
        val r = rig()
        val ref = r.newChat()
        r.startRunning(ref)
        var methodWhenQueued: String? = null
        r.host.once("prompt.submit") { params ->
            methodWhenQueued = r.journalKeys(ref).map { key -> JournalEntry.decode(r.scopeOf(ref), key.entry!!, r.store.read(key)!!) }
                .single { it.text == "replace the plan" }.method
            r.host.defaultHandle("prompt.submit", params)
        }
        val done = r.repo.send(ref, "replace the plan", mode = SendMode.InterruptAndSend)
        assertTrue(done is SendResult.Admitted)
        assertEquals(listOf("session.interrupt", "prompt.submit"), r.host.requests.map { it.method }.filter { it == "session.interrupt" || it == "prompt.submit" }.takeLast(2))
        assertEquals("The journal's method moved to prompt.submit before it was sent", "prompt.submit", methodWhenQueued)

        // A lost stop receipt stops the sequence: the message is not queued and nothing is retried.
        val other = r.newChat("scratch")
        r.startRunning(other, "work")
        r.host.timeOutOnce("session.interrupt")
        val submitsBefore = r.host.count("prompt.submit")
        val lost = r.repo.send(other, "next", mode = SendMode.InterruptAndSend)
        assertTrue(lost is SendResult.Uncertain)
        assertEquals(submitsBefore, r.host.count("prompt.submit"))
        assertEquals("session.interrupt", r.state(other).unresolved.single { it.composerText == "next" }.method)
    }

    @Test fun aLostReceiptKeepsTheEntryNeverResendsAndTheReplyStillArrives() = run {
        val r = rig()
        val ref = r.newChat()
        r.host.loseReplyOnce("prompt.submit", dropSocket = true)
        val result = r.repo.send(ref, "please help")
        val entryId = (result as SendResult.Uncertain).entryId
        assertEquals(1, r.state(ref).unresolved.size)

        r.host.newSocket()
        r.awaitState(ref, "recovered after reconnect") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        val rt = r.runtimeOf(ref)
        r.host.streamReply(rt, "Of course.")
        r.host.flush()
        r.eventually(message = "reply visible") { r.messages(ref).any { it.text == "Of course." } }

        assertEquals("The send is never repeated, on any socket", 1, r.host.count("prompt.submit"))
        val unresolved = r.state(ref).unresolved
        assertEquals("Neither an idle snapshot, a reply nor the same text in saved history proves it was admitted", listOf(entryId), unresolved.map { it.id })
        assertEquals("please help", unresolved.single().composerText)
        assertNull("Independent input is possible again", r.state(ref).sendBlock)
        assertEquals(ReviewResult.Done, r.repo.resolveUnresolved(ref, entryId, ReviewDecision.Discard))
        assertTrue(r.journalKeys(ref).isEmpty())
        assertEquals("Reviewing is not sending", 1, r.host.count("prompt.submit"))
    }

    @Test fun anUnknownSteerNeverDisablesIndependentInput() = run {
        val r = rig()
        val ref = r.newChat()
        r.startRunning(ref)
        r.host.timeOutOnce("session.steer")
        assertTrue(r.repo.send(ref, "steer me") is SendResult.Uncertain)
        r.eventually(message = "recovery") { r.state(ref).sendBlock == null }
        assertEquals(1, r.host.count("session.steer"))
        val queued = r.repo.send(ref, "independent", mode = SendMode.Queue)
        assertTrue("$queued", queued is SendResult.Admitted)
    }

    @Test fun explicitRefusalsKeepTheTextUnsentWithTheirCode() = run {
        val r = rig()
        val ref = r.newChat()
        r.host.rejectOnce("prompt.submit", 4001)
        val stale = r.repo.send(ref, "first")
        assertEquals(4001, (stale as SendResult.Refused).rejectionCode)
        assertEquals(4001, r.state(ref).unresolved.single().rejectionCode)
        assertEquals("A stale runtime closes sending until the chat is reattached", SendBlock.NoLiveSession, r.state(ref).sendBlock)
        r.repo.open(ref)
        r.awaitState(ref, "reattached") { it.sendBlock == null }

        r.host.rejectOnce("prompt.submit", 4090, "MAX_CONCURRENT_SESSIONS")
        val full = r.repo.send(ref, "second") as SendResult.Refused
        assertTrue(full.reachedSessionLimit)
        assertEquals(4090, full.rejectionCode)
        r.host.rejectOnce("prompt.submit", 4090)
        val owned = r.repo.send(ref, "third") as SendResult.Refused
        assertFalse("4090 without the reason is another process owning the chat", owned.reachedSessionLimit)
        assertEquals(3, r.state(ref).unresolved.count { it.rejectionCode != null })
    }

    @Test fun aProvenInputRejectionRestoresTheTextAndANewerDraftIsNeverOverwritten() = run {
        val r = rig()
        val ref = r.newChat()
        r.host.rejectOnce("prompt.submit", 4002)
        val refused = r.repo.send(ref, "bad input")
        assertEquals(4002, (refused as SendResult.Refused).rejectionCode)
        assertEquals("The empty composer got its text back", "bad input", r.state(ref).draft)
        assertTrue("and no entry lingers", r.state(ref).unresolved.isEmpty())

        // The person kept typing while the send was in flight: that newer text wins, the older one is kept unsent.
        r.repo.updateDraft(ref, "A")
        r.host.once("prompt.submit") { _ ->
            r.repo.updateDraft(ref, "B, typed meanwhile")
            throw HermesException(HermesException.Kind.RpcRejected, code = 4002)
        }
        r.repo.send(ref, "A")
        val state = r.state(ref)
        assertEquals("B, typed meanwhile", state.draft)
        assertEquals("A", state.unresolved.single().composerText)
        assertEquals(4002, state.unresolved.single().rejectionCode)
    }

    @Test fun aNewerDraftSurvivesTheRetirementOfAnOlderSend() = run {
        val r = rig()
        val ref = r.newChat()
        r.repo.updateDraft(ref, "send me")
        assertTrue(r.repo.send(ref, "send me") is SendResult.Admitted)
        assertEquals("The sent text left the composer atomically with the journal write", "", r.state(ref).draft)
        r.repo.updateDraft(ref, "next thought")
        val rt = r.runtimeOf(ref)
        r.host.streamReply(rt, "Done.")
        r.host.flush()
        r.eventually(message = "retired") { r.state(ref).unresolved.isEmpty() }
        assertEquals("next thought", r.state(ref).draft)
        assertEquals("next thought", DraftRecord.decode(r.scopeOf(ref), r.store.read(RecordKey.draft(r.scopeOf(ref)))!!).text)
    }

    @Test fun anUncertainSendSurvivesAProcessRestartAndCanBeRestoredToTheComposer() = run {
        val file = File(directory, "s.bin")
        val first = rig(store = FileSnapshotChatStore(file))
        val ref = first.newChat()
        first.host.loseReplyOnce("prompt.submit", dropSocket = true)
        val entryId = (first.repo.send(ref, "do the thing") as SendResult.Uncertain).entryId
        first.close()

        val second = rig(host = FakeHermesHost().also { it.addSession("research", ref.anchor) }, store = FileSnapshotChatStore(file))
        second.repo.open(ref)
        val reopened = second.awaitState(ref, "entry loaded after restart") { it.unresolved.isNotEmpty() }
        assertEquals(entryId, reopened.unresolved.single().id)
        assertEquals("prompt.submit", reopened.unresolved.single().method)
        assertEquals("do the thing", reopened.unresolved.single().composerText)
        second.awaitState(ref) { it.phase == ConversationPhase.Ready }
        assertEquals(ReviewResult.Done, second.repo.resolveUnresolved(ref, entryId, ReviewDecision.RestoreToComposer))
        assertEquals("do the thing", second.state(ref).draft)
        assertEquals("Reviewing is not resending", 0, second.host.count("prompt.submit"))
        assertTrue(second.journalKeys(ref).isEmpty())
    }

    @Test fun restoringNeverOverwritesANewerDraft() = run {
        val r = rig()
        val ref = r.newChat()
        r.host.timeOutOnce("prompt.submit")
        val entry = (r.repo.send(ref, "old words") as SendResult.Uncertain).entryId
        r.repo.updateDraft(ref, "new words")
        assertEquals(ReviewResult.ComposerNotEmpty, r.repo.resolveUnresolved(ref, entry, ReviewDecision.RestoreToComposer))
        assertEquals("new words", r.state(ref).draft)
        assertEquals(1, r.state(ref).unresolved.size)
    }

    @Test fun aReceiptThatOutlivesItsSocketIsNotAttributedToTheNewOne() = run {
        val r = rig()
        val ref = r.newChat()
        r.host.once("prompt.submit") { params ->
            val receipt = r.host.defaultHandle("prompt.submit", params)
            r.host.dropConnection()
            r.host.newSocket()
            r.host.flush()
            receipt
        }
        val result = r.repo.send(ref, "hello")
        assertTrue("$result", result is SendResult.Uncertain)
        assertEquals("The entry stays reviewable", 1, r.state(ref).unresolved.size)
        r.awaitState(ref, "recovered") { it.phase == ConversationPhase.Ready }
        assertEquals(1, r.host.count("prompt.submit"))
    }

    @Test fun anUnsendableMessageIsRefusedBeforeAnythingIsJournaled() = run {
        val r = rig()
        val ref = r.newChat()
        assertEquals(ChatError.Kind.InvalidInput, (r.repo.send(ref, "   ") as SendResult.NotSent).error.kind)
        assertEquals(ChatError.Kind.TooLarge, (r.repo.send(ref, "x".repeat(ChatStoreLimits.MAXIMUM_MESSAGE_TEXT_BYTES + 1)) as SendResult.NotSent).error.kind)
        // Valid UTF-8 size but escapes beyond one frame.
        assertEquals(ChatError.Kind.TooLarge, (r.repo.send(ref, "\u0001".repeat(400_000)) as SendResult.NotSent).error.kind)
        assertEquals(ChatError.Kind.NotOpen, (r.repo.send(ConversationRef("research", "nothing"), "hi") as SendResult.NotSent).error.kind)
        assertTrue(r.journalKeys(ref).isEmpty())
        assertEquals(0, r.host.count("prompt.submit"))
    }

    @Test fun aHostWithoutTheExclusiveSubmitGuaranteeNeverAdmitsATurn() = run {
        val r = rig()
        val ref = r.newChat()
        r.host.changeExclusiveSubmit(false)
        r.eventually { r.state(ref).sendBlock == SendBlock.HostLacksExclusiveSubmit }
        val result = r.repo.send(ref, "hi")
        assertEquals(SendBlock.HostLacksExclusiveSubmit, (result as SendResult.NotSent).block)
        assertEquals(0, r.host.count("prompt.submit"))
        assertTrue(r.journalKeys(ref).isEmpty())
    }
}
