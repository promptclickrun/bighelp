package app.bighelp.hermes.chat

import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The gateway drops the stream of a collector that falls too far behind, and the dropped events are gone. Every chat
 * then has a hole in its transcript that no later event announces, so each must close admission and cover itself again.
 */
class EventOverflowTest : ChatTestBase() {
    @Test fun anOverflowedEventStreamClosesEveryChatAndRecoversEachOneBeforeSendingAgain() = run {
        val r = rig()
        val first = r.savedChat(pairs = 1)
        val second = r.newChat("scratch")
        val gate = CompletableDeferred<Unit>()
        val reached = CompletableDeferred<Unit>()
        r.host.once("session.resume") { p -> reached.complete(Unit); gate.await(); r.host.defaultHandle("session.resume", p) }
        val resumes = r.host.count("session.resume")
        val activations = r.host.count("session.activate")
        val since = r.host.count("session.events.since")

        r.host.overflowEvents()
        reached.awaitWithin("the first chat to be attached again")

        // Nothing is shown as open while the holes are being covered, and nothing can be sent.
        for (ref in listOf(first, second)) {
            r.awaitState(ref, "admission closed") { it.sendBlock != null }
            assertTrue(r.repo.send(ref, "into a hole") is SendResult.NotSent)
        }
        assertEquals(0, r.host.count("prompt.submit"))

        gate.complete(Unit)
        for (ref in listOf(first, second)) r.awaitState(ref, "covered again") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        assertEquals("Each chat was attached again by its stored ID", resumes + 2, r.host.count("session.resume"))
        assertEquals("and ran its recovery bracket once", activations + 2, r.host.count("session.activate"))
        assertEquals(since + 4, r.host.count("session.events.since"))

        // The new subscription carries events again.
        val rt = r.runtimeOf(first)
        r.host.emit(rt, "message.start")
        r.host.emit(rt, "message.delta", """{"text":"after the overflow"}""")
        r.host.flush()
        r.eventually(message = "live events apply after the recovery") {
            r.state(first).items.any { it is MessageItem && it.text == "after the overflow" }
        }
        assertTrue(r.repo.send(second, "now it is open") is SendResult.Admitted)
    }

    @Test fun anOpenQuestionSurvivesAnOverflowBecauseItsSocketDid() = run {
        val r = rig()
        val ref = r.newChat()
        val rt = r.runtimeOf(ref)
        val params = """{"session_id":"${rt.id}","request_id":"domain-1","command":"ls","choices":["once","deny"]}"""
        val asked = r.host.serverRequest(r.scope, "approval", params, id = "wire-1")
        r.eventually(message = "prompt shown") { r.repo.prompts.value.any { it.wireId == "wire-1" } }
        val resumes = r.host.count("session.resume")

        r.host.overflowEvents()
        r.eventually(message = "the chat was attached again") { r.host.count("session.resume") == resumes + 1 }
        r.awaitState(ref, "covered again") { it.phase == ConversationPhase.Ready && it.sendBlock == null }

        assertTrue("The host is still waiting on that socket, so the question is still there", !asked.isCompleted)
        val prompt = r.repo.prompts.value.single { it.wireId == "wire-1" }
        assertEquals(PromptResult.Answered, r.repo.answerPrompt(prompt.id, PromptAnswer.Approve(ApprovalChoice.Once)))
        assertEquals("once", ((asked.awaitWithin("the answer") as app.bighelp.hermes.ServerResponse.Result).value as kotlinx.serialization.json.JsonObject)["choice"].asString)
    }

    @Test fun anAttachAlreadyUnderWayWhenEventsAreDroppedIsReplacedNotJoined() = run {
        val r = rig()
        val ref = r.savedChat(pairs = 1)
        val reached = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<Unit>()
        r.host.once("session.resume") { p -> reached.complete(Unit); gate.await(); r.host.defaultHandle("session.resume", p) }
        val resumes = r.host.count("session.resume")
        val activations = r.host.count("session.activate")

        r.host.dropConnection()
        r.host.newSocket()
        reached.awaitWithin("the socket's attach to reach session.resume")
        // Events are dropped while that attach is still waiting: whatever it reads next cannot vouch for them.
        r.host.overflowEvents()
        r.eventually(message = "a second attach resumed the chat") { r.host.count("session.resume") == resumes + 2 }
        gate.complete(Unit)

        r.awaitState(ref, "covered again") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        r.host.flush()
        assertEquals("The held attach stood down; only the second one ran a recovery bracket", activations + 1, r.host.count("session.activate"))
        assertTrue(r.repo.send(ref, "open again") is SendResult.Admitted)
    }
}
