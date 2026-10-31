package app.bighelp.android.live

import app.bighelp.hermes.chat.AgentSummary
import app.bighelp.hermes.chat.ArchiveState
import app.bighelp.hermes.chat.CatalogState
import app.bighelp.hermes.chat.ConversationIdentity
import app.bighelp.hermes.chat.ConversationPhase
import app.bighelp.hermes.chat.ConversationRef
import app.bighelp.hermes.chat.ConversationState
import app.bighelp.hermes.chat.PromptContent
import app.bighelp.hermes.chat.PromptState
import app.bighelp.hermes.chat.SessionSummary
import java.time.ZoneOffset
import java.util.Locale
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionListingTest {
    private fun agent(id: String, name: String = id) = AgentSummary(id, name, null, JsonObject(emptyMap()))
    private fun session(
        profile: String, anchor: String, title: String, preview: String = "", last: Double? = null,
        pinned: Boolean = false, archive: ArchiveState = ArchiveState.None, registryOnly: Boolean = false, bot: Boolean = false,
    ) = SessionSummary(
        ConversationRef(profile, anchor), profile, anchor, title, preview, null, last, 1, "bighelp", null, pinned, archive,
        null, null, bot, registryOnly,
    )
    private fun state(ref: ConversationRef, running: Boolean = false, draft: String = "", prompts: List<PromptState> = emptyList()) =
        ConversationState(ref, "t", ConversationIdentity(ref, ref.anchor), ConversationPhase.Ready, running = running, draft = draft, prompts = prompts)
    private val approval = { ref: ConversationRef ->
        PromptState("p", ref, "w", "approval", null, 0, PromptContent.Approval("ls", null, null, emptyList()))
    }

    private val catalog = CatalogState(
        agents = listOf(agent("default", "Scout"), agent("moss", "Moss")),
        sessions = listOf(
            session("default", "a", "Lake weekend", "pack the tent", last = 100.0),
            session("moss", "b", "Router advice", "wifi six", last = 300.0),
            session("default", "c", "Pinned note", last = 50.0, pinned = true),
            session("default", "d", "Old archived", last = 400.0, archive = ArchiveState.Deliberate),
            session("moss", "e", "Swept by idle", last = 10.0, archive = ArchiveState.Automatic),
        ),
    )

    @Test fun pinnedFirstThenNewestActivityAndDeliberatelyArchivedChatsAreNotListed() {
        val rows = SessionListing.rows(catalog, emptyMap(), "")
        assertEquals(listOf("Pinned note", "Router advice", "Lake weekend", "Swept by idle"), rows.map { it.title })
        assertEquals("Moss", rows[1].agentName)
    }

    @Test fun searchMatchesTitleAgentNameAndPreviewIgnoringCase() {
        assertEquals(listOf("Router advice"), SessionListing.rows(catalog, emptyMap(), "ROUTER").map { it.title })
        assertEquals(listOf("Router advice", "Swept by idle"), SessionListing.rows(catalog, emptyMap(), "moss").map { it.title })
        assertEquals(listOf("Lake weekend"), SessionListing.rows(catalog, emptyMap(), "tent").map { it.title })
        assertTrue(SessionListing.rows(catalog, emptyMap(), "nothing like this").isEmpty())
    }

    @Test fun aRegistryOnlyBotChatKeepsItsHonestEmptyFieldsInsteadOfAnInventedTitleOrTime() {
        val bot = CatalogState(agents = listOf(agent("default", "Scout")), sessions = listOf(session("default", "reg", "", registryOnly = true, bot = true)))
        val row = SessionListing.rows(bot, emptyMap(), "").single()
        assertEquals("Bot Chat", row.title)
        assertEquals("", row.preview)
        assertEquals(null, row.lastActiveEpochSeconds)
        assertTrue(row.isBotChat)
    }

    @Test fun statusAndDraftComeOnlyFromTheRetainedConversation() {
        val working = ConversationRef("moss", "b")
        val needs = ConversationRef("default", "a")
        val rows = SessionListing.rows(
            catalog,
            mapOf(working to state(working, running = true), needs to state(needs, draft = "half a thought", prompts = listOf(approval(needs)))),
            "",
        )
        assertEquals(RowStatus.Working, rows.first { it.title == "Router advice" }.status)
        val lake = rows.first { it.title == "Lake weekend" }
        assertEquals("A question for you comes first, then the draft", RowStatus.NeedsYou, lake.status)
        assertEquals("Draft: half a thought", lake.preview)
        assertEquals(RowStatus.Idle, rows.first { it.title == "Pinned note" }.status)
    }

    @Test fun anAgentWithoutANameShowsItsId() {
        val unnamed = CatalogState(agents = emptyList(), sessions = listOf(session("ghost", "x", "Hello")))
        assertEquals("ghost", SessionListing.rows(unnamed, emptyMap(), "").single().agentName)
    }

    @Test fun relativeTimeIsShortAndNeverInventedForAMissingTime() {
        val now = 1_700_000_000_000L
        val at = { secondsAgo: Long -> now / 1000.0 - secondsAgo }
        val format = { seconds: Double? -> SessionListing.relativeTime(seconds, now, ZoneOffset.UTC, Locale.US) }
        assertEquals("", format(null))
        assertEquals("now", format(at(20)))
        assertEquals("5 min", format(at(300)))
        assertEquals("3 h", format(at(3 * 3600 + 10)))
        assertEquals("2 d", format(at(2 * 86_400 + 10)))
        assertEquals("Oct 1", SessionListing.relativeTime(1_696_150_000.0, now, ZoneOffset.UTC, Locale.US))
        assertEquals("A time in the future is not shown as negative", "now", format(at(-500)))
    }

    @Test fun aChatThatTheHostListsTwiceShowsOnce() {
        val twice = CatalogState(agents = listOf(agent("default")), sessions = listOf(session("default", "a", "Same chat"), session("default", "a", "Same chat", registryOnly = true)))
        assertEquals(1, SessionListing.rows(twice, emptyMap(), "").size)
    }
}
