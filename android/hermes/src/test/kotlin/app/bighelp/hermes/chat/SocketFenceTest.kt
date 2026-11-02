package app.bighelp.hermes.chat

import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A request that names a runtime ID is only valid on the socket that runtime was proved on. The chat plans a send on
 * one socket, awaits a durable write, and only then writes the frame: the socket may have been replaced in between,
 * and the frame must then not leave at all.
 */
class SocketFenceTest : ChatTestBase() {
    @Test fun aSocketReplacedDuringTheJournalWriteSendsNothingAndGivesTheTextBack() = run {
        val store = GatedChatStore()
        val r = rig(store = store)
        val ref = r.newChat()
        store.holdNextJournalWrite()
        val sending = r.scope.async { r.repo.send(ref, "planned on socket one") }
        store.reached.awaitWithin("the journal write to be held")

        r.host.dropConnection()
        r.host.newSocket()
        r.awaitState(ref, "recovered on socket two") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        store.open()

        val result = sending.await()
        assertEquals("No frame carrying a socket-one runtime ID reached socket two", 0, r.host.count("prompt.submit"))
        assertTrue("$result", result is SendResult.NotSent)
        val state = r.awaitState(ref, "text returned") { it.sendBlock == null }
        assertEquals("planned on socket one", state.draft)
        assertTrue(state.unresolved.isEmpty())
        assertTrue("The chat still works on the new socket", r.repo.send(ref, "again") is SendResult.Admitted)
        assertEquals(2, r.host.calls("prompt.submit").single().generation)
    }

    @Test fun everyRuntimeAddressedCallIsFencedToTheSocketItWasPlannedOn() = run {
        val r = rig()
        val ref = r.savedChat(pairs = 2)
        val generation = r.host.generation
        // Controls and session edits.
        r.repo.modelOptions(ref)
        r.repo.setModel(ref, "big-model", "stub-provider")
        r.repo.setReasoning(ref, "high")
        r.repo.setYolo(ref, true)
        r.repo.commands(ref)
        r.repo.rename(ref, "Fenced")
        r.repo.fork(ref, r.host.rowIds(ref.anchor).last())
        r.repo.openBotChat("scratch", createIfMissing = true)
        // Commands, then a turn that is steered and stopped.
        assertTrue(r.repo.send(ref, "/help") is SendResult.Admitted)
        assertTrue(r.repo.send(ref, "/deploy-skill go") is SendResult.Admitted)
        val rt = r.runtimeOf(ref)
        r.host.emit(rt, "message.start")
        r.host.flush()
        r.awaitState(ref, "running") { it.running }
        assertTrue(r.repo.send(ref, "also") is SendResult.Admitted)
        assertEquals(StopResult.Requested, r.repo.stop(ref))

        val addressed = setOf(
            "session.resume", "session.create", "session.activate", "session.events.since", "prompt.submit", "slash.exec", "command.dispatch",
            "session.steer", "session.interrupt", "config.set", "config.get", "model.options", "commands.catalog", "session.title", "session.branch",
        )
        val seen = r.host.requests.map { it.method }.toSet()
        assertTrue("Every kind of call was exercised: ${addressed - seen}", seen.containsAll(addressed))
        val unfenced = r.host.requests.filter { it.method in addressed && it.fence == null }.map { it.method }.distinct()
        assertEquals("Calls sent without a socket fence", emptyList<String>(), unfenced)
        assertTrue(r.host.requests.filter { it.method in addressed }.all { it.fence == generation && it.generation == generation })
    }
}
