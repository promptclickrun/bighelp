package app.bighelp.hermes.chat

import app.bighelp.hermes.HermesException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionOperationsTest : ChatTestBase() {
    private fun ChatRig.messages(ref: ConversationRef) = state(ref).items.filterIsInstance<MessageItem>()

    @Test fun renameTitlesTheLiveRuntimeAndReadsTheTitleBack() = run {
        val r = rig()
        val ref = r.savedChat()
        r.repo.rename(ref, "  Garden plan ")
        val call = r.host.calls("session.title").single().params
        assertEquals("Garden plan", call["title"].asString)
        assertEquals(r.runtimeOf(ref).id, call["session_id"].asString)
        assertEquals("Garden plan", r.state(ref).title)
        assertEquals("Garden plan", r.host.sessions.getValue(ref.anchor).title)
        assertThrowsChat(ChatError.Kind.InvalidInput) { r.repo.rename(ref, "   ") }
        assertThrowsChat(ChatError.Kind.InvalidInput) { r.repo.rename(ref, "x".repeat(241)) }
        // A title the host does not confirm is an unknown outcome, never a quiet success.
        r.host.once("session.title") { kotlinx.serialization.json.JsonObject(mapOf("pending" to kotlinx.serialization.json.JsonPrimitive(true), "title" to kotlinx.serialization.json.JsonPrimitive("Other"))) }
        assertThrowsChat(ChatError.Kind.OutcomeUnknown) { r.repo.rename(ref, "Another") }
    }

    @Test fun theBotChatIsUnhiddenBeforeItIsRenamedBecauseHermesRefusesAHiddenOne() = run {
        val r = rig()
        val bot = r.host.addSession("research", "bot-1") { addRow("user", "hello") }
        r.host.makeCanonical(bot)
        val opened = r.repo.openBotChat("research") as BotChatOutcome.Opened
        r.awaitState(opened.ref) { it.phase == ConversationPhase.Ready }
        r.repo.rename(opened.ref, "Our projects")
        val hide = r.host.calls("session.set_hidden").single().params
        assertEquals("bot-1", hide["session_id"].asString)
        assertEquals(false, hide["hidden"].asBool)
        assertEquals(listOf("session.set_hidden", "session.title"), r.host.requests.map { it.method }.filter { it == "session.set_hidden" || it == "session.title" })
    }

    @Test fun archiveAndRestoreUseTheLineageRootAndReadTheFlagBack() = run {
        val r = rig()
        r.host.addSession("research", "root-1", "Plan") { addRow("user", "x") }
        r.host.compact("root-1", "tip-2")
        r.repo.refreshCatalog()
        val row = r.repo.catalog.value.sessions.single()
        assertEquals("root-1", row.ref.anchor)
        r.repo.open(row.ref)
        r.awaitState(row.ref) { it.phase == ConversationPhase.Ready }
        r.repo.archive(row.ref)
        assertEquals("The edit targets the lineage root, not the current tip", "root-1", r.host.calls("session.archive").single().params["session_id"].asString)
        assertTrue(r.repo.catalog.value.sessions.isEmpty())
        assertEquals(listOf("root-1"), r.repo.archivedChats().map { it.ref.anchor })
        r.repo.restore(row.ref)
        assertEquals(false, r.host.calls("session.archive").last().params["archived"].asBool)
        assertEquals(1, r.repo.catalog.value.sessions.size)
    }

    @Test fun anArchiveTheHostDidNotApplyIsAConflictNotASuccess() = run {
        val r = rig()
        val ref = r.savedChat()
        r.host.once("session.archive") { p ->
            // The host says archived:true but its row never changed (a quiet no-op).
            kotlinx.serialization.json.JsonObject(mapOf("archived" to kotlinx.serialization.json.JsonPrimitive(true), "session_key" to kotlinx.serialization.json.JsonPrimitive(ref.anchor)))
        }
        assertThrowsChat(ChatError.Kind.Conflict) { r.repo.archive(ref) }
    }

    @Test fun deleteFindsTheHostRowDeletesItAndClearsEverythingKeptForThatChat() = run {
        val r = rig()
        val ref = r.savedChat()
        r.repo.updateDraft(ref, "leftover draft")
        r.host.timeOutOnce("prompt.submit")
        r.repo.send(ref, "an uncertain one")
        r.repo.refreshCatalog()
        r.runtimeOf(ref).running = false // the host finished with it; an active chat cannot be deleted
        r.repo.delete(ref)
        assertEquals(ref.anchor, r.host.calls("session.delete").single().params["session_id"].asString)
        assertFalse(r.host.sessions.containsKey(ref.anchor))
        assertTrue(r.repo.conversations.value[ref] == null)
        val scope = r.scopeOf(ref)
        assertNull(r.store.read(RecordKey.draft(scope)))
        assertTrue(r.store.keys(ChatTestData.host, RecordKind.Journal, ref.profile, ref.anchor).isEmpty())
        assertTrue(r.repo.catalog.value.sessions.none { it.ref == ref })
    }

    @Test fun deletingAnActiveChatIsRefusedByHermesAndAnAlreadyGoneChatCountsAsDeleted() = run {
        val r = rig()
        val ref = r.savedChat()
        r.host.rejectOnce("session.delete", 4009)
        assertThrowsChat(ChatError.Kind.Rejected) { r.repo.delete(ref) }
        assertTrue("Nothing was forgotten locally", r.repo.conversations.value[ref] != null)
        r.host.rejectOnce("session.delete", 4007)
        r.repo.delete(ref)
        assertTrue(r.repo.conversations.value[ref] == null)
    }

    @Test fun forkReadsTheWholeTranscriptCountsVisibleMessagesAndValidatesTheBranch() = run {
        val r = rig()
        // 130 pairs = 260 rows, more than one 200-row hydration page, so the one-row overlap is exercised.
        val ref = r.savedChat(pairs = 130)
        val through = r.host.sessions.getValue(ref.anchor).rows[201]["id"].asLong!!
        val child = r.repo.fork(ref, through)
        val hydration = r.host.restRequests.filter { it.route.endsWith("/messages") && it.query.toMap()["order"] == "oldest" }
        assertEquals(listOf("0", "199"), hydration.map { it.query.toMap()["offset"] })
        assertEquals(listOf("200", "201"), hydration.map { it.query.toMap()["limit"] })
        val branch = r.host.calls("session.branch").single().params
        assertEquals("Visible messages through the checkpoint", 202, branch["count"].asInt)
        assertEquals("${r.state(ref).title} · Fork", branch["name"].asString)
        assertNotNull(r.repo.conversations.value[child])
        assertTrue(child.anchor != ref.anchor)
        r.awaitState(child) { it.phase == ConversationPhase.Ready }
    }

    @Test fun aForkTheHostAnswersWithTheWrongMessagesIsRefused() = run {
        val r = rig()
        val ref = r.savedChat(pairs = 3)
        val through = r.host.sessions.getValue(ref.anchor).rows[3]["id"].asLong!!
        r.host.once("session.branch") { p ->
            val reply = r.host.defaultHandle("session.branch", p) as kotlinx.serialization.json.JsonObject
            kotlinx.serialization.json.JsonObject(reply + ("message_count" to kotlinx.serialization.json.JsonPrimitive(99)))
        }
        val failure = runCatching { kotlinx.coroutines.runBlocking { r.repo.fork(ref, through) } }.exceptionOrNull()
        assertTrue("$failure", failure is HermesException || failure is ChatException)
        assertThrowsChat(ChatError.Kind.InvalidInput) { r.repo.fork(ref, 424242) }
    }

    @Test fun aTipReportedByTheRuntimeIsAdoptedWithItsOldIdKeptAsARoutingAlias() = run {
        val r = rig()
        val ref = r.savedChat()
        val rt = r.runtimeOf(ref)
        val old = r.state(ref).identity.storedTip
        r.host.emit(rt, "session.info", """{"stored_session_id":"compacted-tip"}""")
        r.host.flush()
        val state = r.awaitState(ref) { it.identity.storedTip == "compacted-tip" }
        assertEquals(ref, state.ref)
        assertTrue(state.identity.knows(old))
        r.eventually(message = "alias persisted") {
            r.store.read(RecordKey.identity(r.scopeOf(ref)))?.let { IdentityRecord.decode(r.scopeOf(ref), it).knows(old) } == true
        }
        r.host.emit(rt, "status.update", """{"kind":"compacted","text":"Done"}""")
        r.host.flush()
        r.awaitState(ref) { it.status == "Compacted" }
    }

    @Test fun aReadForAChatThatWasReleasedAndOpenedAgainNeverAppliesToTheNewOne() = run {
        val r = rig()
        val ref = r.savedChat(pairs = 2)
        val gate = CompletableDeferred<Unit>()
        r.host.holdMessages = gate
        val late = r.scope.launch { runCatching { r.repo.reloadHistory(ref) } }
        r.eventually(message = "request in flight") { r.host.restRequests.count { it.route.endsWith("/messages") } >= 2 }
        r.repo.release(ref)
        r.host.holdMessages = null
        r.host.sessions.getValue(ref.anchor).addRow("user", "added while the old read was in flight")
        r.repo.open(ref)
        r.awaitState(ref) { it.phase == ConversationPhase.Ready && it.items.size == 5 }
        gate.complete(Unit)
        late.join()
        assertEquals("The old read could not shrink or replace the new owner's rows", 5, r.state(ref).items.size)
    }
}
