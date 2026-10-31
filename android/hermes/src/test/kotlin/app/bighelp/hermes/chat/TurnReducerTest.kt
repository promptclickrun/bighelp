package app.bighelp.hermes.chat

import app.bighelp.hermes.WireMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TurnReducerTest {
    private val runtime = "runtime-a"
    private var seq = 0L

    private fun event(type: String, payload: String = "{}", sequence: Long? = ++seq): WireMessage.Event =
        WireMessage.Event(type, runtime, jsonObject(payload), sequence)

    private fun TurnReducer.feed(type: String, payload: String = "{}", sequence: Long? = ++seq) = accept(event(type, payload, sequence))

    private fun reducer() = TurnReducer("epoch-1")

    private fun TurnReducer.messages() = items.filterIsInstance<MessageItem>()
    private fun TurnReducer.activities() = items.filterIsInstance<ActivityItem>()

    @Test fun deltasBuildOneStreamingAssistantRowThatTheFinalReplaces() {
        val r = reducer()
        r.feed("message.start")
        assertTrue(r.running)
        r.feed("message.delta", """{"text":"Hel"}""")
        r.feed("message.delta", """{"text":"lo"}""")
        val streaming = r.messages().single()
        assertEquals("Hello", streaming.text)
        assertFalse(streaming.complete)
        assertEquals(ItemOrigin.Live, streaming.origin)
        r.feed("message.complete", """{"text":"Hello there."}""")
        val final = r.messages().single()
        assertEquals("The final text replaces the accumulated deltas", "Hello there.", final.text)
        assertTrue(final.complete)
        assertEquals("A segment keeps one stable ID", streaming.id, final.id)
    }

    @Test fun aMessageCompleteIsASegmentFinalAndOnlyRunningFalseEndsTheTurn() {
        val r = reducer()
        r.feed("message.start")
        r.feed("message.delta", """{"text":"x"}""")
        val complete = r.feed("message.complete", """{"text":"x"}""")
        assertFalse("A segment final does not end the turn", complete.terminal)
        assertTrue(r.running)
        val ended = r.feed("session.info", """{"running":false}""")
        assertTrue(ended.terminal)
        assertFalse(r.running)
        val again = r.feed("session.info", """{"running":false}""")
        assertFalse("running false after not running is not a second terminal", again.terminal)
    }

    @Test fun anInterimSealsOneSegmentAndTheNextTextStartsAnother() {
        val r = reducer()
        r.feed("message.start")
        r.feed("message.delta", """{"text":"Let me check."}""")
        r.feed("message.interim", """{"text":"Let me check."}""")
        r.feed("message.delta", """{"text":"Done."}""")
        val rows = r.messages()
        assertEquals(listOf("Let me check.", "Done."), rows.map { it.text })
        assertEquals(listOf(true, false), rows.map { it.complete })
        assertEquals(2, rows.map { it.id }.toSet().size)
        assertTrue("Both stay inside the same running turn", r.running)
    }

    @Test fun reasoningIsAnActivityThatTextSealsAndALaterPhaseIsANewOne() {
        val r = reducer()
        r.feed("message.start")
        r.feed("reasoning.delta", """{"text":"think "}""")
        r.feed("reasoning.delta", """{"text":"more"}""")
        val first = r.activities().single()
        assertEquals(ActivityKind.Reasoning, first.kind)
        assertEquals("think more", first.detail)
        assertEquals(ActivityLifecycle.Running, first.lifecycle)
        r.feed("message.delta", """{"text":"answer"}""")
        assertEquals(ActivityLifecycle.Succeeded, r.activities().single().lifecycle)
        r.feed("reasoning.delta", """{"text":"second thought"}""")
        val phases = r.activities()
        assertEquals(2, phases.size)
        assertEquals("second thought", phases[1].detail)
        // reasoning.available is the assistant body preview, not model reasoning.
        r.feed("reasoning.available", """{"text":"preview"}""")
        assertEquals(2, r.activities().size)
    }

    @Test fun spinnerAndPreannouncementAreStatusOnlyAndMakeNoRows() {
        val r = reducer()
        r.feed("message.start")
        val thinking = r.feed("thinking.delta", """{"text":"  pondering  ","rendered":null,"verbose":false}""")
        assertEquals("pondering", thinking.status)
        val generating = r.feed("tool.generating", """{"name":"terminal"}""")
        assertEquals("Preparing terminal", generating.status)
        assertTrue(r.items.isEmpty())
        // An extra key makes the typed auxiliary payload malformed: ignored, never a row.
        val bad = r.feed("thinking.delta", """{"text":"x","surprise":1}""")
        assertNull(bad.status)
        assertTrue(r.items.isEmpty())
    }

    @Test fun toolsUpsertByIdKeepTheirOriginalArgumentsAndMapExplicitFailure() {
        val r = reducer()
        r.feed("message.start")
        r.feed("tool.start", """{"tool_id":"t1","name":"terminal","context":"ls","args":{"command":"ls"}}""")
        assertEquals(ActivityLifecycle.Running, r.activities().single().lifecycle)
        r.feed("tool.progress", """{"tool_id":"t1","summary":"working"}""")
        r.feed("tool.complete", """{"tool_id":"t1","result":{"files":["a"]},"duration_s":1.5}""")
        val done = r.activities().single()
        assertEquals(ActivityLifecycle.Succeeded, done.lifecycle)
        assertEquals("terminal", done.title)
        assertEquals("""{"command":"ls"}""", done.arguments)
        assertEquals("""{"files":["a"]}""", done.result)
        r.feed("tool.start", """{"tool_id":"t2","name":"x"}""")
        r.feed("tool.complete", """{"tool_id":"t2","status":"error"}""")
        assertEquals(ActivityLifecycle.Failed, r.activities()[1].lifecycle)
        r.feed("tool.start", """{"tool_id":"t3"}""")
        r.feed("tool.complete", """{"tool_id":"t3","status":"cancelled"}""")
        assertEquals(ActivityLifecycle.Cancelled, r.activities()[2].lifecycle)
        // No tool_id: not joinable to a later call, so it is ignored.
        val before = r.activities().size
        r.feed("tool.start", """{"name":"anonymous"}""")
        assertEquals(before, r.activities().size)
    }

    @Test fun aTurnEndSettlesAnUnfinishedToolAsRecordedNotSuccessful() {
        val r = reducer()
        r.feed("message.start")
        r.feed("tool.start", """{"tool_id":"t1","name":"terminal"}""")
        val end = r.feed("session.info", """{"running":false}""")
        assertTrue(end.terminal)
        assertEquals(ActivityLifecycle.Recorded, r.activities().single().lifecycle)
    }

    @Test fun staleAndDuplicateSequencesAreIgnoredAndTheCursorAdvancesFirst() {
        val r = reducer()
        r.feed("message.start", sequence = 10)
        r.feed("message.delta", """{"text":"a"}""", sequence = 11)
        assertEquals(11, r.lastSequence)
        val stale = r.feed("message.delta", """{"text":"STALE"}""", sequence = 11)
        assertTrue(stale.ignored)
        val older = r.feed("message.delta", """{"text":"OLDER"}""", sequence = 3)
        assertTrue(older.ignored)
        assertEquals("a", r.messages().single().text)
        // An event without a sequence is applied and leaves the cursor alone.
        r.feed("message.delta", """{"text":"b"}""", sequence = null)
        assertEquals("ab", r.messages().single().text)
        assertEquals(11, r.lastSequence)
    }

    @Test fun theTurnIdentityIsTheEpochAndTheSequenceOfItsStart() {
        val r = reducer()
        r.feed("message.start", sequence = 21)
        assertEquals("epoch-1:21", r.turnId)
        r.feed("session.info", """{"running":false}""", sequence = 22)
        r.feed("message.start", sequence = 40)
        assertEquals("epoch-1:40", r.turnId)
    }

    @Test fun aFailedFinalBeforeAnyStartIsItsOwnFailedTurnAndNotTheLastOnesReply() {
        val r = reducer()
        r.feed("message.start")
        r.feed("message.delta", """{"text":"earlier answer"}""")
        r.feed("session.info", """{"running":false}""")
        val earlier = r.turnId
        val failed = r.feed("message.complete", """{"status":"error","text":"The provider is busy.","failure_reason":"overloaded","error_surface":{"layer":"provider","code":"overloaded","retryable":true,"provider_label":"Example Provider"}}""")
        assertTrue(failed.failedBeforeStart)
        assertTrue(failed.terminal)
        assertTrue(r.turnId != earlier)
        assertEquals("overloaded", failed.turnFailure!!.code)
        assertEquals("Example Provider", failed.turnFailure!!.providerLabel)
        assertTrue(failed.turnFailure!!.retryable)
        assertEquals(r.turnId, r.failedTurnId)
        assertEquals("earlier answer", r.messages().first().text)
        assertEquals("The provider is busy.", r.messages().last().text)
    }

    @Test fun aReusedFinalSettlesTheSealedAnswerInsteadOfPaintingACopy() {
        val r = reducer()
        r.feed("message.start")
        r.feed("message.delta", """{"text":"All done."}""")
        r.feed("message.interim", """{"text":"All done."}""")
        r.feed("tool.start", """{"tool_id":"t","name":"memory"}""")
        r.feed("tool.complete", """{"tool_id":"t"}""")
        val settled = r.feed("message.complete", """{"text":"All done.","response_reused":true}""")
        assertEquals("The reused final adds no second copy", 1, r.messages().size)
        assertTrue(settled.settledAnswer)
        assertTrue(r.messages().single().complete)
    }

    @Test fun theHostsSavedRowIdsBindOptimisticRowsNeverByText() {
        val r = reducer()
        r.addLocalUser("local-1", "hello")
        r.feed("message.start")
        r.feed("message.delta", """{"text":"hi"}""")
        val change = r.feed("message.complete", """{"text":"hi","persisted_turn":{"user_row_id":101,"final_assistant_row_id":102}}""")
        assertEquals(101L, change.persistedTurn!!.userRowId)
        assertEquals(102L, change.persistedTurn!!.finalAssistantRowId)
        r.bindRows(change.persistedTurn!!)
        val rows = r.messages()
        assertEquals(listOf(101L, 102L), rows.map { it.rowId })
        assertEquals(listOf(ItemOrigin.Local, ItemOrigin.Live), rows.map { it.origin })
        // A second binding for the same rows changes nothing.
        r.bindRows(change.persistedTurn!!)
        assertEquals(listOf(101L, 102L), r.messages().map { it.rowId })
    }

    @Test fun sessionInfoReportsTheStoredTipTheModelTheTitleAndTheServiceTier() {
        val r = reducer()
        val info = r.feed("session.info", """{"running":true,"stored_session_id":"tip-2","model":"m","provider":"p","reasoning_effort":"high","service_tier":"fast","title":"A title","cwd":"/work"}""")
        assertEquals("tip-2", info.storedIdReport)
        assertEquals("m", info.runtime!!.model)
        assertEquals("p", info.runtime!!.provider)
        assertEquals("high", info.runtime!!.reasoningEffort)
        assertEquals("fast", info.runtime!!.serviceTier)
        assertEquals("/work", info.runtime!!.cwd)
        assertEquals("A title", info.title)
        assertTrue("running:true starts a turn the reducer did not see start", r.running)
        assertEquals("Renamed", r.feed("session.title", """{"title":"Renamed"}""").title)
    }

    @Test fun compactionIsReadFromTheHostsStatusKindsOnly() {
        val r = reducer()
        assertEquals(CompactionSignal.Compressing, r.feed("status.update", """{"kind":"compressing","text":"Compressing…"}""").compaction)
        assertEquals(CompactionSignal.Compacting, r.feed("status.update", """{"kind":"compacting","text":"Compacting"}""").compaction)
        assertEquals(CompactionSignal.Compacted, r.feed("status.update", """{"kind":"compacted","text":"Done"}""").compaction)
        assertNull(r.feed("status.update", """{"kind":"other","text":"x"}""").compaction)
        assertNull("A malformed status update is ignored", r.feed("status.update", """{"kind":"compacted"}""").compaction)
    }

    @Test fun anEpochChangeRestartsTheCursorWithoutDroppingTheRichRows() {
        val r = reducer()
        r.feed("message.start", sequence = 5)
        r.feed("message.delta", """{"text":"kept"}""", sequence = 6)
        r.resetCursor("epoch-2", 0)
        assertEquals("epoch-2", r.epoch)
        assertEquals(0, r.lastSequence)
        assertEquals("kept", r.messages().single().text)
        r.feed("message.delta", """{"text":"!"}""", sequence = 1)
        assertEquals("kept!", r.messages().single().text)
    }

    @Test fun turnIdsStayUniqueWhenAnotherRuntimeOfTheSameEpochRestartsItsSequence() {
        val r = reducer()
        r.feed("message.start", sequence = 1)
        val first = r.turnId
        r.feed("message.delta", """{"text":"old answer"}""", sequence = 2)
        // Reattached to a new runtime of the same host epoch: its sequence numbers start over at one.
        r.resetCursor("epoch-1", 0)
        r.feed("message.start", sequence = 1)
        assertFalse("A turn of another runtime never reuses an older turn's ID", first == r.turnId)
        r.feed("message.delta", """{"text":"new answer"}""", sequence = 2)
        assertEquals(listOf("old answer", "new answer"), r.messages().map { it.text })
    }

    @Test fun anErrorEventMarksTheTurnFailedWithoutEndingIt() {
        val r = reducer()
        r.feed("message.start")
        val error = r.feed("error", """{"message":"oops"}""")
        assertTrue(error.errorEvent)
        assertTrue(r.running)
    }

    @Test fun subagentEventsNeedARealSubagentOrChildSessionId() {
        val r = reducer()
        r.feed("message.start")
        r.feed("subagent.start", """{"goal":"search"}""")
        assertTrue(r.items.isEmpty())
        r.feed("subagent.start", """{"subagent_id":"s1","goal":"search"}""")
        r.feed("subagent.text", """{"subagent_id":"s1","text":"found "}""")
        r.feed("subagent.text", """{"subagent_id":"s1","text":"it"}""")
        val running = r.activities().single()
        assertEquals(ActivityKind.Subagent, running.kind)
        assertEquals("search", running.title)
        assertEquals("found it", running.detail)
        r.feed("subagent.complete", """{"subagent_id":"s1","summary":"done"}""")
        assertEquals(ActivityLifecycle.Succeeded, r.activities().single().lifecycle)
        // A turn end does not settle a subagent: it keeps its own lifecycle.
        r.feed("subagent.start", """{"subagent_id":"s2"}""")
        r.feed("session.info", """{"running":false}""")
        assertEquals(ActivityLifecycle.Running, r.activities().last().lifecycle)
    }
}
