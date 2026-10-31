package app.bighelp.android.live

import app.bighelp.hermes.chat.ActivityItem
import app.bighelp.hermes.chat.ActivityKind
import app.bighelp.hermes.chat.ActivityLifecycle
import app.bighelp.hermes.chat.ConversationIdentity
import app.bighelp.hermes.chat.ConversationPhase
import app.bighelp.hermes.chat.ConversationRef
import app.bighelp.hermes.chat.ConversationState
import app.bighelp.hermes.chat.ItemOrigin
import app.bighelp.hermes.chat.MessageItem
import app.bighelp.hermes.chat.MessageRole
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TranscriptRowsTest {
    private val ref = ConversationRef("default", "anchor")
    private fun message(id: String, role: MessageRole, text: String, origin: ItemOrigin = ItemOrigin.Saved, rowId: Long? = null,
        complete: Boolean = true, command: Boolean = false, unsupported: Boolean = false) =
        MessageItem(id, role, role.name.lowercase(), text, origin, rowId, complete = complete, isCommandResult = command, hasUnsupportedContent = unsupported)
    private fun state(vararg items: app.bighelp.hermes.chat.TranscriptItem, running: Boolean = false, status: String? = null, stop: Boolean = false) =
        ConversationState(ref, "t", ConversationIdentity(ref, "anchor"), ConversationPhase.Ready, items.toList(), running = running, status = status, stopRequested = stop)

    @Test fun userAndAssistantMessagesKeepTheirOrderAndIds() {
        val rows = TranscriptRows.rows(state(message("a", MessageRole.User, "hi"), message("b", MessageRole.Assistant, "hello")))
        assertEquals(listOf("a", "b"), rows.map { it.key })
        assertTrue(rows.all { it is ChatRow.Message })
    }

    @Test fun anEmptyFinishedMessageIsNotARowButOneWithUnsupportedContentIs() {
        val rows = TranscriptRows.rows(state(
            message("a", MessageRole.Assistant, ""),
            message("b", MessageRole.Assistant, "", unsupported = true),
            message("c", MessageRole.Assistant, "", complete = false),
        ))
        assertEquals(listOf("b"), rows.map { it.key })
    }

    @Test fun onlySavedMessagesWithAHostRowIdCanBeBranched() {
        val rows = TranscriptRows.rows(state(
            message("a", MessageRole.User, "saved", rowId = 7),
            message("b", MessageRole.Assistant, "live", origin = ItemOrigin.Live),
            message("c", MessageRole.User, "local", origin = ItemOrigin.Local),
            message("d", MessageRole.System, "note", rowId = 9),
        )).filterIsInstance<ChatRow.Message>()
        assertEquals(listOf(true, false, false), rows.map { it.canBranch })
    }

    @Test fun systemNotesAndCommandOutputAreNotesNotBubbles() {
        val rows = TranscriptRows.rows(state(message("a", MessageRole.System, "Switched model"), message("b", MessageRole.Assistant, "output", command = true)))
        assertTrue(rows.all { it is ChatRow.Note })
        assertEquals(listOf("Switched model", "output"), rows.map { (it as ChatRow.Note).text })
    }

    @Test fun toolsAndReasoningBecomeActivityRowsAndANoticeBecomesANote() {
        val tool = ActivityItem("t1", ActivityKind.Tool, "read_file", "notes.txt", ActivityLifecycle.Running, origin = ItemOrigin.Live)
        val thinking = ActivityItem("t2", ActivityKind.Reasoning, "Thinking", "step", ActivityLifecycle.Recorded, origin = ItemOrigin.Live)
        val notice = ActivityItem("t3", ActivityKind.Notice, "Context was compacted", null, ActivityLifecycle.Recorded, origin = ItemOrigin.Live)
        val rows = TranscriptRows.rows(state(tool, thinking, notice))
        assertTrue(rows[0] is ChatRow.Activity && rows[1] is ChatRow.Activity)
        assertEquals("Context was compacted", (rows[2] as ChatRow.Note).text)
    }

    @Test fun theWorkingLabelIsTheHostsOwnStatusOrAPlainDefaultAndNothingWhileIdle() {
        assertEquals(null, TranscriptRows.workingLabel(state()))
        assertEquals("Working…", TranscriptRows.workingLabel(state(running = true)))
        assertEquals("Running read_file", TranscriptRows.workingLabel(state(running = true, status = "Running read_file")))
        assertEquals("Stopping…", TranscriptRows.workingLabel(state(running = true, status = "Running read_file", stop = true)))
        assertFalse(TranscriptRows.workingLabel(state(running = true))!!.isBlank())
    }

    @Test fun edgeRowsAddAnEarlierHistoryRowAtTheTopAndTheWorkingLineAtTheEnd() {
        val base = state(message("a", MessageRole.User, "hi"))
        assertEquals(listOf("a"), TranscriptRows.withEdges(base).map { it.key })

        val more = base.copy(history = app.bighelp.hermes.chat.HistoryState(hasOlder = true), running = true, status = "Running read_file")
        val rows = TranscriptRows.withEdges(more)
        assertEquals(listOf("history", "a", "working"), rows.map { it.key })
        assertEquals(false, (rows.first() as ChatRow.History).loading)
        assertEquals("Running read_file", (rows.last() as ChatRow.Working).label)

        val loading = more.copy(history = app.bighelp.hermes.chat.HistoryState(hasOlder = true, loadingOlder = true))
        assertEquals(true, (TranscriptRows.withEdges(loading).first() as ChatRow.History).loading)
    }

    @Test fun aRepeatedItemIdNeverReachesTheListBecauseALazyListCrashesOnADuplicateKey() {
        val rows = TranscriptRows.withEdges(state(
            message("same", MessageRole.User, "first"),
            message("same", MessageRole.Assistant, "second"),
            message("working", MessageRole.Assistant, "an id that looks like the working line"),
            running = true,
        ))
        assertEquals(rows.map { it.key }.distinct(), rows.map { it.key })
        assertEquals("first", (rows.first { it.key == "same" } as ChatRow.Message).item.text)
    }
}
