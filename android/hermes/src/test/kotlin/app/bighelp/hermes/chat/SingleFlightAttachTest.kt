package app.bighelp.hermes.chat

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** One conversation is attached and recovered by at most one flight per socket, however many screens ask. */
class SingleFlightAttachTest : ChatTestBase() {
    @Test fun openingARecoveringChatTwiceJoinsTheAttachThatIsAlreadyRunning() = run {
        val r = rig()
        val ref = r.savedChat(pairs = 1)
        val reached = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<Unit>()
        r.host.once("session.resume") { p -> reached.complete(Unit); gate.await(); r.host.defaultHandle("session.resume", p) }
        val resumes = r.host.count("session.resume")
        val activations = r.host.count("session.activate")
        val since = r.host.count("session.events.since")

        r.host.dropConnection()
        r.host.newSocket()
        reached.awaitWithin("the socket's own attach to reach session.resume")
        val screens = listOf(r.scope.async { r.repo.open(ref) }, r.scope.async { r.repo.open(ref) })
        kotlinx.coroutines.delay(150) // time for a second and third attach to start, if they are going to
        gate.complete(Unit)
        screens.awaitAll()

        r.awaitState(ref, "ready again") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        assertEquals("One resume for the new socket", resumes + 1, r.host.count("session.resume"))
        assertEquals("One activation", activations + 1, r.host.count("session.activate"))
        assertEquals("One recovery bracket (two replay reads)", since + 2, r.host.count("session.events.since"))
        assertTrue(r.repo.send(ref, "works").let { it is SendResult.Admitted })
    }

    @Test fun anAttachForAnOlderSocketIsNeverJoinedByAnOpenOnTheNewerOne() = run {
        val r = rig()
        val ref = r.savedChat(pairs = 1)
        val reached = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<Unit>()
        r.host.once("session.resume") { p -> reached.complete(Unit); gate.await(); r.host.defaultHandle("session.resume", p) }
        r.host.dropConnection()
        r.host.newSocket()
        reached.awaitWithin("the first socket's attach to reach session.resume")
        // The socket moves on before the held attach answers.
        r.host.dropConnection()
        r.host.newSocket()
        val opened = r.scope.async { r.repo.open(ref) }
        gate.complete(Unit)
        opened.await()
        val ready = r.awaitState(ref, "ready on the newest socket") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        assertEquals(ConversationPhase.Ready, ready.phase)
        assertTrue("The chat is bound to the newest socket and can send", r.repo.send(ref, "on the third").let { it is SendResult.Admitted })
        assertEquals(3, r.host.calls("prompt.submit").single().generation)
    }

    @Test fun aReopenWhileTheRecoveryAfterALostSendRunsJoinsThatBracket() = run {
        val r = rig()
        val ref = r.newChat()
        val reached = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<Unit>()
        r.host.timeOutOnce("prompt.submit")
        r.host.once("session.events.since") { p -> reached.complete(Unit); gate.await(); r.host.defaultHandle("session.events.since", p) }
        val resumes = r.host.count("session.resume")
        val activations = r.host.count("session.activate")

        assertTrue(r.repo.send(ref, "lost receipt") is SendResult.Uncertain)
        reached.awaitWithin("the recovery after the lost send to start")
        val reopened = r.scope.async { r.repo.open(ref) }
        kotlinx.coroutines.delay(150) // time for a second bracket to start, if it is going to
        gate.complete(Unit)
        reopened.await()

        r.awaitState(ref, "covered") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        assertEquals("The reopen resumed the chat once", resumes + 1, r.host.count("session.resume"))
        assertEquals("and the two callers shared one recovery bracket", activations + 1, r.host.count("session.activate"))
        assertEquals("The lost send was never repeated", 1, r.host.count("prompt.submit"))
    }
}
