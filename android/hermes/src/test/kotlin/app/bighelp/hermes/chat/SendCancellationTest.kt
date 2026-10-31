package app.bighelp.hermes.chat

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A screen-scoped caller of `send` is cancelled while its request is in flight (the person leaves the chat). Whatever
 * stage the request had reached, the chat must come out usable: no stuck admission slot, no duplicate bubble, the text
 * reviewable or back in the composer, and one recovery for a send that may have gone out.
 */
class SendCancellationTest : ChatTestBase() {
    private val screens = ArrayList<CoroutineScope>()
    private fun screen() = CoroutineScope(Job() + Dispatchers.Default).also { screens += it }
    @After fun leaveScreens() { screens.forEach { it.cancel() } }

    private fun ChatRig.localRows(ref: ConversationRef) = state(ref).items.filterIsInstance<MessageItem>().filter { it.origin == ItemOrigin.Local }

    @Test fun cancellingASendAfterTheFrameWasWrittenKeepsTheEntryReviewableAndRunsOneRecovery() = run {
        val r = rig()
        val ref = r.newChat()
        val reached = CompletableDeferred<Unit>()
        val never = CompletableDeferred<Unit>()
        r.host.once("prompt.submit") { _ -> reached.complete(Unit); never.await(); throw AssertionError("The receipt never comes") }
        val activations = r.host.count("session.activate")
        val sending = screen().async { r.repo.send(ref, "leave the screen") }
        reached.awaitWithin("the receipt to be awaited")
        r.eventually(message = "optimistic row shown") { r.localRows(ref).size == 1 }

        sending.cancel()
        sending.join()
        assertTrue("The caller's cancellation is passed on, not turned into a result", sending.isCancelled)

        val settled = r.awaitState(ref, "recovered after the cancelled send") { it.sendBlock == null && it.phase == ConversationPhase.Ready }
        assertEquals("The entry is the only representation of the send", 1, settled.unresolved.size)
        assertTrue("No duplicate optimistic bubble next to the entry", r.localRows(ref).isEmpty())
        assertEquals("Exactly one exact-owner recovery ran", activations + 1, r.host.count("session.activate"))
        assertEquals("Nothing is ever resent", 1, r.host.count("prompt.submit"))

        val entry = settled.unresolved.single()
        assertEquals("leave the screen", entry.composerText)
        assertEquals(ReviewResult.Done, r.repo.resolveUnresolved(ref, entry.id, ReviewDecision.RestoreToComposer))
        assertEquals("leave the screen", r.state(ref).draft)
        assertTrue(r.store.keys(ChatTestData.host, RecordKind.Journal, ref.profile, ref.anchor).isEmpty())
        assertTrue("A second send works", r.repo.send(ref, "again") is SendResult.Admitted)
    }

    @Test fun cancellingASendBeforeTheFrameWasWrittenSendsNothingAndGivesTheTextBack() = run {
        val r = rig()
        val ref = r.newChat()
        val hold = r.host.holdBeforeWrite("prompt.submit")
        val sending = screen().async { r.repo.send(ref, "never leaves the phone") }
        hold.reached.awaitWithin("the request to be held")

        sending.cancel()
        sending.join()
        assertTrue(sending.isCancelled)

        val settled = r.awaitState(ref, "slot freed") { it.sendBlock == null }
        assertEquals("Nothing reached the host", 0, r.host.count("prompt.submit"))
        assertTrue("The optimistic row is gone", r.localRows(ref).isEmpty())
        assertEquals("Nothing was sent, so the text is back where the person typed it", "never leaves the phone", settled.draft)
        assertTrue(settled.unresolved.isEmpty())
        assertTrue(r.store.keys(ChatTestData.host, RecordKind.Journal, ref.profile, ref.anchor).isEmpty())
        assertTrue("A second send works", r.repo.send(ref, "again") is SendResult.Admitted)
    }

    @Test fun anUnsentCancelledSendNeverOverwritesANewerDraftAndStaysReviewable() = run {
        val r = rig()
        val ref = r.newChat()
        val hold = r.host.holdBeforeWrite("prompt.submit")
        val sending = screen().async { r.repo.send(ref, "older words") }
        hold.reached.awaitWithin("the request to be held")
        r.repo.updateDraft(ref, "newer words")

        sending.cancel()
        sending.join()

        val settled = r.awaitState(ref, "slot freed") { it.sendBlock == null }
        assertEquals("newer words", settled.draft)
        assertEquals("The unsent text is kept for review instead", "older words", settled.unresolved.single().composerText)
        assertTrue(r.localRows(ref).isEmpty())
        assertEquals(0, r.host.count("prompt.submit"))
    }

    @Test fun cancellingWhileTheJournalIsBeingWrittenFreesTheSlotAndSendsNothing() = run {
        val store = GatedChatStore()
        val r = rig(store = store)
        val ref = r.newChat()
        store.holdNextJournalWrite()
        val sending = screen().async { r.repo.send(ref, "stalled disk") }
        store.reached.awaitWithin("the journal write to be held")

        sending.cancel()
        sending.join()
        store.open()

        r.awaitState(ref, "slot freed") { it.sendBlock == null }
        assertEquals(0, r.host.count("prompt.submit"))
        assertTrue("A second send works", r.repo.send(ref, "again") is SendResult.Admitted)
    }
}
