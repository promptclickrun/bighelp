package app.bighelp.hermes.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HistoryRepositoryTest : ChatTestBase() {
    private val host = ChatTestData.host

    private fun ChatRig.rows(ref: ConversationRef) = state(ref).items.filterIsInstance<MessageItem>()

    @Test fun openReadsTheNewestPhysicalPageWithTheDocumentedParametersAndOffersOlderRows() = run {
        val r = rig(config = ChatConfig(turnLimit = 1))
        val ref = r.savedChat(pairs = 30)
        val request = r.host.restRequests.last { it.route.endsWith("/messages") }
        val q = request.query.toMap()
        assertEquals("research", q["profile"])
        assertEquals("40", q["limit"])
        assertEquals("0", q["offset"])
        assertEquals("latest", q["order"])
        assertEquals("true", q["include_compacted"])
        val state = r.awaitState(ref) { it.items.size == 40 }
        assertEquals("Rows keep the host's order", "question 10", (state.items.first() as MessageItem).text)
        assertTrue(state.history.hasOlder)
        assertEquals("Row IDs are the host's physical IDs", true, r.rows(ref).all { it.rowId != null && it.origin == ItemOrigin.Saved })
    }

    @Test fun olderPagesOverlapByOneRowAndStopAtTheStartOfTheChat() = run {
        val r = rig(config = ChatConfig(turnLimit = 1))
        val ref = r.savedChat(pairs = 30) // 60 rows
        r.awaitState(ref) { it.items.size == 40 }
        val loaded = r.repo.loadOlder(ref) as HistoryLoad.Loaded
        assertEquals(20, loaded.addedRows)
        assertFalse(loaded.hasOlder)
        val request = r.host.restRequests.last { it.route.endsWith("/messages") }.query.toMap()
        assertEquals("One overlap row: offset - 1, limit + 1", "39", request["offset"])
        assertEquals("41", request["limit"])
        assertEquals(60, r.state(ref).items.size)
        assertEquals((r.rows(ref).map { it.rowId }), r.rows(ref).map { it.rowId }.sortedBy { it!! })
        assertEquals(HistoryLoad.NothingOlder, r.repo.loadOlder(ref))
    }

    @Test fun aRewrittenOverlapRowRefusesTheMergeAndReloadsTheNewestPage() = run {
        val r = rig(config = ChatConfig(turnLimit = 1))
        val ref = r.savedChat(pairs = 30)
        r.awaitState(ref) { it.items.size == 40 }
        val session = r.host.sessions.getValue(ref.anchor)
        // The host rewrites the row the older page will overlap.
        val index = session.rows.size - 40
        session.rows[index] = kotlinx.serialization.json.JsonObject(session.rows[index] + ("content" to kotlinx.serialization.json.JsonPrimitive("REWRITTEN")))
        val result = r.repo.loadOlder(ref)
        assertEquals(ChatError.Kind.HistoryChanged, (result as HistoryLoad.Failed).error.kind)
        r.awaitState(ref, "reloaded") { it.items.size == 40 && it.items.filterIsInstance<MessageItem>().any { m -> m.text == "REWRITTEN" } }
        assertFalse("Nothing from the failed older page was merged", r.rows(ref).any { it.text == "question 9" })
    }

    @Test fun aWindowThatDoesNotLineUpIsNeverCombined() = run {
        val r = rig(config = ChatConfig(turnLimit = 1))
        val ref = r.savedChat(pairs = 30)
        r.awaitState(ref) { it.items.size == 40 }
        // The host answers the older page with a different session's ID (not in the chat's lineage): refused.
        r.host.failRest = null
        val other = r.host.addSession("research", "stranger") { repeat(60) { addRow("user", "x$it") } }
        r.host.sessions.getValue(ref.anchor).rows.clear()
        r.host.sessions.getValue(ref.anchor).rows += other.rows.map { kotlinx.serialization.json.JsonObject(it + ("session_id" to kotlinx.serialization.json.JsonPrimitive(ref.anchor))) }
        val result = r.repo.loadOlder(ref)
        assertTrue("$result", result is HistoryLoad.Failed)
    }

    @Test fun aStaleCachedSeedIsReplacedByTheCanonicalPageNotDuplicatedOrMerged() = run {
        val store = MemoryChatStore()
        val host = FakeHermesHost()
        val session = host.addSession("research", "s1") { addRow("user", "one"); addRow("assistant", "two"); addRow("user", "three"); addRow("assistant", "four") }
        // A cache from earlier holds only the first two rows.
        val cached = HistoryWindow.fresh(HistoryPage.parse(historyEnvelope(session.rows.take(2), 0, 40, "latest", session = "s1"), "research", 0, 40, "latest"))
        val scope = ConversationScope(ChatTestData.host, "research", "s1")
        store.putCache(RecordKey.history(scope), HistoryCacheCodec.encode(cached))
        val r = rig(host = host, store = store)
        val ref = ConversationRef("research", "s1")
        r.repo.open(ref)
        val state = r.awaitState(ref) { it.phase == ConversationPhase.Ready && it.items.size == 4 }
        assertEquals(listOf("one", "two", "three", "four"), r.rows(ref).map { it.text })
        assertEquals(4, state.history.retainedRows)
    }

    @Test fun savedHistoryNeverReplacesRicherLiveRowsAndTakesOverOnlyOnceItHasCaughtUp() = run {
        val r = rig()
        val ref = r.savedChat(pairs = 1)
        assertTrue(r.repo.send(ref, "stream please") is SendResult.Admitted)
        val rt = r.runtimeOf(ref)
        r.host.emit(rt, "message.start")
        r.host.emit(rt, "message.delta", """{"text":"partial answer"}""")
        r.host.flush()
        r.awaitState(ref) { s -> s.items.any { it is MessageItem && it.text == "partial answer" } }
        // A history read while the turn runs cannot replace the live rows.
        r.repo.reloadHistory(ref)
        assertTrue(r.rows(ref).any { it.text == "partial answer" && it.origin == ItemOrigin.Live })

        // The turn ends but the host has not persisted its reply yet: the live row is kept.
        r.host.emit(rt, "message.complete", """{"text":"final answer"}""")
        r.host.emit(rt, "session.info", """{"running":false}""")
        r.host.flush()
        r.eventually(message = "retired") { r.state(ref).unresolved.isEmpty() }
        r.repo.reloadHistory(ref)
        assertTrue("Saved history lacks the reply, so the live row stays", r.rows(ref).any { it.text == "final answer" })

        // Once the host has saved it, the saved rows take over and nothing is shown twice.
        r.host.sessions.getValue(rt.stored).addRow("assistant", "final answer")
        r.repo.reloadHistory(ref)
        r.eventually(message = "saved rows take over") { r.rows(ref).none { it.origin != ItemOrigin.Saved } }
        assertEquals(1, r.rows(ref).count { it.text == "final answer" })
    }

    @Test fun aHistoryAnswerForAnUnrelatedSessionIsRefusedAndNeverRebindsTheChat() = run {
        val r = rig()
        val ref = r.savedChat(pairs = 2)
        val tip = r.state(ref).identity.storedTip
        r.host.historySessionOverride = "an-unrelated-session"
        val failure = runCatching { r.repo.reloadHistory(ref) }.exceptionOrNull() as ChatException
        assertEquals(ChatError.Kind.HistoryChanged, failure.error.kind)
        assertEquals("The tip moved only on first-hand proof, never on a history read", tip, r.state(ref).identity.storedTip)
        assertEquals(4, r.rows(ref).size)
    }
}
