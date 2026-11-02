package app.bighelp.android.live

import app.bighelp.hermes.chat.ArchiveState
import app.bighelp.hermes.chat.CatalogState
import app.bighelp.hermes.chat.ConversationRef
import app.bighelp.hermes.chat.ConversationState
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** What a retained chat is doing right now, from its own live state and nothing else. */
internal enum class RowStatus { Idle, Working, NeedsYou }

internal data class SessionRowUi(
    val ref: ConversationRef,
    val title: String,
    val agentName: String,
    val preview: String,
    /** Null when the host gave no time (a Bot Chat only the registry names): nothing is invented. */
    val lastActiveEpochSeconds: Double?,
    val status: RowStatus,
    val isBotChat: Boolean,
    val pinned: Boolean,
)

internal object SessionListing {
    /** Pinned first, then newest activity. A chat someone archived on purpose is in Archived chats, not here. */
    fun rows(catalog: CatalogState, conversations: Map<ConversationRef, ConversationState>, search: String): List<SessionRowUi> {
        val query = search.trim()
        val names = catalog.agents.associate { it.id to it.displayName.ifBlank { it.id } }
        return catalog.sessions
            .distinctBy { it.ref }
            .filter { it.archive != ArchiveState.Deliberate }
            .map { session ->
                val live = conversations[session.ref]
                val draft = live?.draft?.trim().orEmpty()
                SessionRowUi(
                    ref = session.ref,
                    title = session.title.ifBlank { if (session.isCanonicalBotChat) "Bot Chat" else "Chat" },
                    agentName = names[session.profile] ?: session.profile,
                    preview = if (draft.isNotEmpty()) "Draft: ${draft.replace('\n', ' ')}" else session.preview.replace('\n', ' '),
                    lastActiveEpochSeconds = session.lastActiveEpochSeconds,
                    status = when {
                        live == null -> RowStatus.Idle
                        live.prompts.isNotEmpty() -> RowStatus.NeedsYou
                        live.running -> RowStatus.Working
                        else -> RowStatus.Idle
                    },
                    isBotChat = session.isCanonicalBotChat,
                    pinned = session.pinned,
                )
            }
            .filter { row ->
                query.isEmpty() || row.title.contains(query, ignoreCase = true) || row.agentName.contains(query, ignoreCase = true) ||
                    row.preview.contains(query, ignoreCase = true)
            }
            .sortedWith(compareByDescending<SessionRowUi> { it.pinned }.thenByDescending { it.lastActiveEpochSeconds ?: Double.NEGATIVE_INFINITY })
    }

    /** "now", "5 min", "3 h", "2 d", then a short date. Empty for an unknown time. */
    fun relativeTime(
        epochSeconds: Double?,
        nowMillis: Long,
        zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault(),
    ): String {
        if (epochSeconds == null) return ""
        val seconds = (nowMillis / 1000.0 - epochSeconds).toLong()
        return when {
            seconds < 60 -> "now"
            seconds < 3_600 -> "${seconds / 60} min"
            seconds < 86_400 -> "${seconds / 3_600} h"
            seconds < 7 * 86_400 -> "${seconds / 86_400} d"
            else -> DateTimeFormatter.ofPattern("MMM d", locale).withZone(zone).format(Instant.ofEpochSecond(epochSeconds.toLong()))
        }
    }
}
