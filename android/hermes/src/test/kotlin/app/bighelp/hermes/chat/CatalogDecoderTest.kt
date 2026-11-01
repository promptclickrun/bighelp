package app.bighelp.hermes.chat

import app.bighelp.hermes.HermesException
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CatalogDecoderTest {
    private fun invalid(block: () -> Unit) {
        val e = runCatching(block).exceptionOrNull()
        assertTrue("Expected InvalidResponse but got $e", e is HermesException && e.kind == HermesException.Kind.InvalidResponse)
    }

    @Test fun profilesKeepOptionalMetadataAndTheCanonicalRegistryIdentity() {
        val agents = CatalogDecoder.profiles(json("""{"profiles":[
            {"name":"research","display_name":"Research Bot","canonical_session":{"id":"bot-1","resolved_id":"bot-1-tip"},"model":"m","future_field":{"a":1}},
            {"name":"scratch","canonical_session":null},
            {"name":"plain","display_name":""}
        ]}"""))
        assertEquals(listOf("research", "scratch", "plain"), agents.map { it.id })
        assertEquals("Research Bot", agents[0].displayName)
        assertEquals("bot-1", agents[0].canonicalChat!!.id)
        assertEquals("bot-1-tip", agents[0].canonicalChat!!.resolvedId)
        assertEquals("future_field survives in the host's own row", "m", agents[0].metadata["model"].asString)
        assertEquals("The ID is the name when the host gives no display name", "scratch", agents[1].displayName)
        assertEquals("plain", agents[2].displayName)
        assertNull(agents[1].canonicalChat)
    }

    @Test fun profilesRefuseDuplicatesOversizeAndMalformedRegistry() {
        invalid { CatalogDecoder.profiles(json("""{"profiles":[{"name":"a"},{"name":"a"}]}""")) }
        invalid { CatalogDecoder.profiles(json("""{"profiles":[{"name":" padded "}]}""")) }
        invalid { CatalogDecoder.profiles(json("""{"profiles":[{"name":"a","canonical_session":{"resolved_id":"x"}}]}""")) }
        invalid { CatalogDecoder.profiles(json("""{"profiles":"nope"}""")) }
        invalid { CatalogDecoder.profiles(json("""{"profiles":[${(1..513).joinToString(",") { """{"name":"p$it"}""" }}]}""")) }
    }

    private fun row(id: String, extra: String = "", profile: String? = "research") =
        """{"id":"$id",${profile?.let { """"profile":"$it",""" } ?: ""}"started_at":1792000000,"title":"T $id","message_count":3$extra}"""

    private fun page(rows: List<String>, offset: Int = 0, limit: Int = 100, envelope: String = "list", hasMore: Boolean = false, total: Int? = null) =
        if (envelope == "list") json("""{"object":"list","data":[${rows.joinToString(",")}],"has_more":$hasMore,"limit":$limit,"offset":$offset${total?.let { ""","total":$it""" } ?: ""}}""")
        else json("""{"sessions":[${rows.joinToString(",")}],"total":${total ?: rows.size},"limit":$limit,"offset":$offset}""")

    @Test fun bothSessionEnvelopesDecodeAndAProfileEchoMustMatchWhenPresent() {
        val newer = CatalogDecoder.sessionPage(page(listOf(row("s1"), row("s2", profile = null))), "research", 0)
        assertEquals(2, newer.rows.size)
        assertEquals(false, newer.hasMore)
        val legacy = CatalogDecoder.sessionPage(page(listOf(row("s1")), envelope = "legacy", total = 250), "research", 0)
        assertNull("The legacy envelope has no has_more", legacy.hasMore)
        assertEquals(250, legacy.total)
        invalid { CatalogDecoder.sessionPage(page(listOf(row("s1", profile = "someone-else"))), "research", 0) }
        invalid { CatalogDecoder.sessionPage(page(listOf(row("s1")), offset = 100), "research", 0) }
        invalid { CatalogDecoder.sessionPage(page(listOf(row("s1")), limit = 50), "research", 0) }
        invalid { CatalogDecoder.sessionPage(json("""{"object":"list","data":[{"title":"no id"}],"has_more":false,"limit":100,"offset":0}"""), "research", 0) }
        invalid { CatalogDecoder.sessionPage(json("""{"object":"list","data":[],"limit":100,"offset":0}"""), "research", 0) }
    }

    @Test fun continuationFollowsHasMoreThenTotalThenAFullPage() {
        fun more(envelope: String) = CatalogDecoder.sessionPage(json(envelope), "research", 0).let { CatalogDecoder.hasMore(it, 0, it.rows.size) }
        assertTrue(more("""{"object":"list","data":[${row("s1")}],"has_more":true,"limit":100,"offset":0}"""))
        assertFalse(more("""{"object":"list","data":[${row("s1")}],"has_more":false,"limit":100,"offset":0}"""))
        assertTrue(more("""{"sessions":[${row("s1")}],"total":101,"limit":100,"offset":0}"""))
        assertFalse(more("""{"sessions":[${row("s1")}],"total":100,"limit":100,"offset":0}"""))
        // A host that sends neither has_more nor total can only be judged by a full page.
        val bare = { count: Int -> SessionPage(List(count) { JsonObject(emptyMap()) }, limit = 100, offset = 0, hasMore = null, total = null) }
        assertTrue(CatalogDecoder.hasMore(bare(100), 0, 100))
        assertFalse(CatalogDecoder.hasMore(bare(99), 0, 99))
    }

    @Test fun aRowBecomesASummaryWithItsAnchorAndNeverInventsMissingFacts() {
        val summary = CatalogDecoder.summary(
            jsonObject(row("s1", """,
                "preview":"hello there","source":"bighelp","cwd":"/home/example/p","pinned":true,"last_active":1792000500""")),
            "research", null,
        )
        assertEquals(ConversationRef("research", "s1"), summary.ref)
        assertEquals("T s1", summary.title)
        assertEquals("hello there", summary.preview)
        assertEquals(1_792_000_500.0, summary.lastActiveEpochSeconds!!, 0.0)
        assertEquals(1_792_000_000.0, summary.startedAtEpochSeconds!!, 0.0)
        assertEquals(3, summary.messageCount)
        assertTrue(summary.pinned)
        assertEquals("/home/example/p", summary.cwd)
        assertFalse(summary.isCanonicalBotChat)
        assertFalse(summary.isRegistryOnly)
        val untitled = CatalogDecoder.summary(jsonObject("""{"id":"s2","profile":"research","started_at":1,"title":""}"""), "research", null)
        assertEquals("Untitled", untitled.title)
        assertEquals("A missing count is zero, not a guess", 0, untitled.messageCount)
        assertEquals("last activity falls back to the start", 1.0, untitled.lastActiveEpochSeconds!!, 0.0)
        invalid { CatalogDecoder.summary(jsonObject("""{"id":"s3","profile":"research","title":"x"}"""), "research", null) } // started_at is required
        invalid { CatalogDecoder.summary(jsonObject("""{"id":"s4","profile":"research","started_at":1,"message_count":-1}"""), "research", null) }
    }

    @Test fun theAnchorIsTheLineageRootAndLineageMustBeConsistent() {
        val compacted = CatalogDecoder.summary(
            jsonObject(row("tip-3", ""","_lineage_root_id":"root-1","_lineage_ids":["root-1","tip-2","tip-3"]""")), "research", null,
        )
        assertEquals("root-1", compacted.ref.anchor)
        assertEquals("tip-3", compacted.storedId)
        assertEquals(listOf("root-1", "tip-2", "tip-3"), compacted.lineageIds)
        invalid { CatalogDecoder.summary(jsonObject(row("tip-3", ""","_lineage_ids":["root-1","tip-2"]""")), "research", null) } // missing its own ID
        invalid { CatalogDecoder.summary(jsonObject(row("tip-3", ""","_lineage_root_id":"zzz","_lineage_ids":["tip-3"]""")), "research", null) }
        invalid { CatalogDecoder.summary(jsonObject(row("tip-3", ""","_lineage_ids":["tip-3","tip-3"]""")), "research", null) }
    }

    @Test fun aRowThatBelongsToTheCanonicalBotChatAnchorsOnTheRegistryId() {
        val canonical = CanonicalChat("bot-1", "bot-1-tip")
        fun anchor(id: String, extra: String = "") = CatalogDecoder.summary(jsonObject(row(id, extra)), "research", canonical)
        assertEquals("bot-1", anchor("bot-1").ref.anchor)
        assertEquals("bot-1", anchor("bot-1-tip").ref.anchor)
        assertEquals("bot-1", anchor("later-tip", ""","_lineage_root_id":"bot-1","_lineage_ids":["bot-1","later-tip"]""").ref.anchor)
        assertTrue(anchor("bot-1").isCanonicalBotChat)
        assertFalse(anchor("other").isCanonicalBotChat)
        assertEquals("other", anchor("other").ref.anchor)
    }

    @Test fun archivedIsDeliberateUnlessHermesIdleSweepMarkedItAutomatic() {
        fun state(extra: String) = CatalogDecoder.summary(jsonObject(row("s1", extra)), "research", null).archive
        assertEquals(ArchiveState.None, state(""))
        assertEquals(ArchiveState.None, state(""","archived":false"""))
        assertEquals(ArchiveState.Deliberate, state(""","archived":true"""))
        assertEquals(ArchiveState.Deliberate, state(""","archived":1"""))
        assertEquals(ArchiveState.Automatic, state(""","archived":true,"auto_archived":true"""))
        assertEquals("An auto flag without an archive is not archived", ArchiveState.None, state(""","auto_archived":true"""))
    }

    @Test fun theListRequestUsesThePolicyOfTheCurrentApp() {
        assertEquals(
            listOf("profile" to "research", "limit" to "100", "offset" to "200", "archived" to "include", "order" to "created",
                "exclude_sources" to "tool,kanban,bot_room"),
            CatalogDecoder.listQuery("research", 200),
        )
    }

    @Test fun aRegistryOnlyBotChatInventsNoTitleTimeOrPreview() {
        val summary = CatalogDecoder.registryOnly("research", CanonicalChat("bot-1", "bot-1-tip"))
        assertEquals(ConversationRef("research", "bot-1"), summary.ref)
        assertTrue(summary.isRegistryOnly && summary.isCanonicalBotChat)
        assertEquals("bot-1-tip", summary.storedId)
        assertEquals("", summary.preview)
        assertNull(summary.startedAtEpochSeconds)
        assertNull(summary.lastActiveEpochSeconds)
        assertEquals("Bot Chat", summary.title)
    }
}
