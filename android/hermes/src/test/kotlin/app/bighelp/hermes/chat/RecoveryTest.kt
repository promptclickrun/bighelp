package app.bighelp.hermes.chat

import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RecoveryTest : ChatTestBase() {
    private fun ChatRig.messages(ref: ConversationRef) = state(ref).items.filterIsInstance<MessageItem>()

    /** A sent message whose turn is running, with some text streamed (the client has seen sequence 2). */
    private suspend fun ChatRig.streaming(ref: ConversationRef, text: String = "Hello"): FakeHermesHost.Runtime {
        assertTrue(repo.send(ref, "go") is SendResult.Admitted)
        val rt = runtimeOf(ref)
        host.emit(rt, "message.start")
        host.emit(rt, "message.delta", """{"text":"$text"}""")
        host.flush()
        awaitState(ref) { s -> s.items.any { it is MessageItem && it.text == text } }
        return rt
    }

    @Test fun aNewSocketClosesAdmissionAtOnceThenResumesByStoredIdAndRecoversInTheDocumentedOrder() = run {
        val r = rig()
        val ref = r.savedChat()
        val gate = CompletableDeferred<Unit>()
        r.host.once("session.resume") { p -> gate.await(); r.host.defaultHandle("session.resume", p) }
        val before = r.host.requests.size
        r.host.dropConnection()
        r.host.newSocket()
        r.host.flush()
        // The socket is ready but the chat has no coverage yet: no send is admitted.
        val blocked = r.state(ref)
        assertTrue("Admission is closed while recovering: ${blocked.sendBlock}", blocked.sendBlock != null)
        val refused = r.repo.send(ref, "too early")
        assertTrue(refused is SendResult.NotSent)
        assertEquals(0, r.host.count("prompt.submit"))
        gate.complete(Unit)
        r.awaitState(ref, "ready again") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        val after = r.host.requests.drop(before).map { it.method + "@" + it.generation }
        assertEquals(listOf("session.resume@2", "session.events.since@2", "session.activate@2", "session.events.since@2"), after.filter { !it.startsWith("gateway") && !it.startsWith("client") }.take(4))
        assertEquals("Never a create as a reconnect fallback", 0, r.host.count("session.create"))
    }

    @Test fun anExactReplayRestoresWhatWasMissedOnceAndSettlesAConfirmedAdmissionByItsOwnTerminal() = run {
        val r = rig()
        val ref = r.newChat()
        val rt = r.streaming(ref)
        assertEquals(1, r.state(ref).unresolved.size)
        r.host.dropConnection()
        // While away the host finished the turn; the client saw none of it.
        r.host.emitSilently(rt, "message.delta", """{"text":" there"}""")
        r.host.sessions.getValue(rt.stored).addRow("assistant", "Hello there")
        r.host.emitSilently(rt, "message.complete", """{"text":"Hello there"}""")
        rt.running = false
        r.host.emitSilently(rt, "session.info", """{"running":false}""")
        r.host.newSocket()
        r.awaitState(ref, "recovered") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        r.eventually(message = "reply appears exactly once") { r.messages(ref).count { it.text == "Hello there" } == 1 }
        assertEquals("The exact same-epoch terminal replay settles the admitted send", 0, r.state(ref).unresolved.size)
        assertEquals(1, r.host.count("prompt.submit"))
    }

    @Test fun anIdleSnapshotWithoutReplayCannotSettleASendWhoseAdmissionWasNeverConfirmed() = run {
        val r = rig()
        val ref = r.newChat()
        r.host.loseReplyOnce("prompt.submit", dropSocket = true)
        assertTrue(r.repo.send(ref, "maybe") is SendResult.Uncertain)
        val rt = r.runtimeOf(ref)
        rt.running = false // the host went idle without any evidence about our message
        r.host.newSocket()
        r.awaitState(ref) { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        assertEquals("An idle snapshot is not proof either way", 1, r.state(ref).unresolved.size)
        assertEquals(1, r.host.count("prompt.submit"))
    }

    @Test fun aGapInTheLiveEventsKeepsAdmissionClosedInsteadOfGuessing() = run {
        val r = rig()
        val ref = r.newChat()
        val rt = r.runtimeOf(ref)
        r.host.dropConnection()
        var tails = 0
        repeat(2) {
            r.host.once("session.events.since") { p ->
                val reply = r.host.defaultHandle("session.events.since", p)
                if (++tails == 2) {
                    // A live event is lost (never delivered) and the next one arrives while the chat is catching up.
                    r.host.emitSilently(rt, "message.delta", """{"text":"lost"}""")
                    r.host.emit(rt, "message.delta", """{"text":"after the gap"}""")
                    // Wait until the client has taken the event in (held, because recovery is still running).
                    r.host.flush()
                }
                reply
            }
        }
        r.host.newSocket()
        val failed = r.awaitState(ref, "recovery refused the gap") { it.lastError != null }
        assertTrue(failed.sendBlock != null)
        assertTrue(failed.phase != ConversationPhase.Ready)
        assertEquals(0, r.host.count("prompt.submit"))
        assertFalse("Nothing from the uncovered span is shown", r.messages(ref).any { it.text.contains("after the gap") })
        // Opening again recovers from a clean cursor.
        r.repo.open(ref)
        r.awaitState(ref, "ready again") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
    }

    @Test fun aChangedEpochKeepsTheRichRowsAndRestartsTheCursorFromTheFinalReplay() = run {
        val r = rig()
        val ref = r.newChat()
        val rt = r.streaming(ref, "partial")
        r.host.dropConnection()
        r.host.newSocket("epoch-2")
        r.awaitState(ref, "recovered") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        assertEquals("The live row survives the epoch change", "partial", r.messages(ref).last { it.role == MessageRole.Assistant }.text)
        // The cursor now follows the new epoch's sequence: the next event continues the same row.
        r.host.emit(rt, "message.delta", """{"text":" more"}""")
        r.host.flush()
        r.eventually(message = "continued") { r.messages(ref).last { it.role == MessageRole.Assistant }.text == "partial more" }
    }

    @Test fun eventsFromAnOlderSocketNeverApplyToANewerOne() = run {
        val r = rig()
        val ref = r.newChat()
        val rt = r.streaming(ref)
        r.host.dropConnection()
        r.host.newSocket()
        r.awaitState(ref) { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        r.host.emit(rt, "message.delta", """{"text":" STALE"}""", gen = 1)
        r.host.flush()
        assertFalse(r.messages(ref).any { it.text.contains("STALE") })
    }

    @Test fun aReapedRuntimeIsResumedByStoredIdAndItsCursorStartsOver() = run {
        val r = rig()
        val ref = r.newChat()
        val old = r.streaming(ref)
        r.host.dropConnection()
        r.host.runtimes.remove(old.id) // Hermes reaped the app's runtime after the socket went
        r.host.newSocket()
        r.awaitState(ref, "reattached") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        val fresh = r.runtimeOf(ref)
        assertNotEquals("A new runtime ID is a new coordinate", old.id, fresh.id)
        r.host.emit(fresh, "message.start")
        r.host.emit(fresh, "message.delta", """{"text":"new runtime"}""")
        r.host.flush()
        r.eventually(message = "events of the new runtime apply from sequence one") { r.messages(ref).any { it.text == "new runtime" } }
    }

    @Test fun aReclaimRevokesTheWriterAtOnceButOnlyForTheExactOwner() = run {
        val r = rig()
        val ref = r.newChat()
        val creates = r.host.count("session.create")
        val rt = r.runtimeOf(ref)
        val tip = r.state(ref).identity.storedTip
        // Wrong stored ID, wrong outer session: not this chat.
        r.host.emit(rt, "session.reclaimed", """{"session_id":"${rt.id}","stored_session_id":"someone-else","reason":"idle"}""")
        r.host.flush()
        assertEquals(ConversationPhase.Ready, r.state(ref).phase)
        r.host.emit(rt, "session.reclaimed", """{"session_id":"${rt.id}","stored_session_id":"$tip","reason":"idle"}""")
        r.host.flush()
        val revoked = r.awaitState(ref) { it.phase == ConversationPhase.Suspended }
        assertEquals(SendBlock.NoLiveSession, revoked.sendBlock)
        assertEquals(ChatError.Kind.NotConnected, (r.repo.send(ref, "hi") as SendResult.NotSent).error.kind)
        // Opening again reattaches by the stored ID.
        r.repo.open(ref)
        r.awaitState(ref, "reattached") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        assertEquals(creates, r.host.count("session.create"))
    }

    @Test fun aLostSocketSuspendsEveryChatAndKeepsTheirTranscripts() = run {
        val r = rig()
        val a = r.savedChat(pairs = 1)
        val b = r.newChat("scratch")
        val items = r.state(a).items
        r.host.dropConnection()
        r.eventually(message = "suspended") { r.state(a).phase == ConversationPhase.Suspended && r.state(b).phase == ConversationPhase.Suspended }
        assertEquals(items, r.state(a).items)
        assertEquals(SendBlock.NotConnected, r.state(a).sendBlock)
        r.host.newSocket()
        r.awaitState(a) { it.phase == ConversationPhase.Ready }
        r.awaitState(b) { it.phase == ConversationPhase.Ready }
    }

    @Test fun aLateFailureOfAnOldSocketsRecoveryNeverClosesAdmissionOfTheNewOwner() = run {
        val r = rig()
        val ref = r.newChat()
        val gate = CompletableDeferred<Unit>()
        val entered = CompletableDeferred<Unit>()
        // The recovery that follows a lost send starts on socket 1 and stalls in its first replay request.
        r.host.timeOutOnce("prompt.submit")
        r.host.once("session.events.since") { _ ->
            entered.complete(Unit)
            gate.await()
            throw app.bighelp.hermes.HermesException(app.bighelp.hermes.HermesException.Kind.TimedOut)
        }
        assertTrue(r.repo.send(ref, "stalls the old recovery") is SendResult.Uncertain)
        entered.await()
        r.host.dropConnection()
        r.host.newSocket()
        r.awaitState(ref, "ready on the new socket") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        gate.complete(Unit) // the old recovery now fails, late
        kotlinx.coroutines.delay(400)
        val state = r.state(ref)
        assertEquals(ConversationPhase.Ready, state.phase)
        assertEquals("The new owner is still open for input", null, state.sendBlock)
        // Not just the published snapshot: admission itself is still open.
        assertTrue(r.repo.send(ref, "the new owner still works") is SendResult.Admitted)
    }
}
