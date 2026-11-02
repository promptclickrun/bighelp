package app.bighelp.android.live

import app.bighelp.hermes.chat.ActivityItem
import app.bighelp.hermes.chat.ActivityKind
import app.bighelp.hermes.chat.ConversationState
import app.bighelp.hermes.chat.ItemOrigin
import app.bighelp.hermes.chat.MessageItem
import app.bighelp.hermes.chat.MessageRole

/** One line of the live transcript. [key] is the repository's own item ID, so a row keeps its identity across every update. */
internal sealed interface ChatRow {
    val key: String

    data class Message(val item: MessageItem, val canBranch: Boolean) : ChatRow {
        override val key get() = item.id
    }

    data class Activity(val item: ActivityItem) : ChatRow {
        override val key get() = item.id
    }

    /** System text, a command's output or a notice: shown quietly, not as a speech bubble. */
    data class Note(override val key: String, val text: String) : ChatRow

    /** The top of the retained history, when the host has older messages to read. */
    data class History(val loading: Boolean) : ChatRow {
        override val key get() = "history"
    }

    /** The end of a running turn: what the host says it is doing. Never a percentage. */
    data class Working(val label: String) : ChatRow {
        override val key get() = "working"
    }
}

internal object TranscriptRows {
    /** Keys must be unique in a lazy list, so a later row with a key already used is dropped (the first is kept). */
    fun rows(state: ConversationState): List<ChatRow> = mapped(state).distinctBy { it.key }

    private fun mapped(state: ConversationState): List<ChatRow> = state.items.mapNotNull { item ->
        when (item) {
            is MessageItem -> when {
                item.role == MessageRole.User || item.role == MessageRole.Assistant -> when {
                    item.isCommandResult -> ChatRow.Note(item.id, item.text)
                    // A reply that has not produced text yet is the working line's business, not an empty bubble.
                    item.text.isEmpty() && !item.hasUnsupportedContent -> null
                    else -> ChatRow.Message(item, canBranch = item.rowId != null && item.origin == ItemOrigin.Saved)
                }
                item.text.isNotBlank() -> ChatRow.Note(item.id, item.text)
                else -> null
            }
            is ActivityItem -> if (item.kind == ActivityKind.Notice) ChatRow.Note(item.id, item.title) else ChatRow.Activity(item)
        }
    }

    /** [rows] with the "earlier messages" row above and the working line below, when they apply. */
    fun withEdges(state: ConversationState): List<ChatRow> = buildList {
        if (state.history.hasOlder) add(ChatRow.History(state.history.loadingOlder))
        addAll(rows(state))
        workingLabel(state)?.let { add(ChatRow.Working(it)) }
    }.distinctBy { it.key }

    /** The host's own status while a turn runs; nothing while idle. Never a percentage. */
    fun workingLabel(state: ConversationState): String? = when {
        !state.running -> null
        state.stopRequested -> "Stopping…"
        else -> state.status?.takeIf { it.isNotBlank() } ?: "Working…"
    }
}
