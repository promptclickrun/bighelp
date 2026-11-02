package app.bighelp.hermes.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CatalogRepositoryTest : ChatTestBase() {
    @Test fun refreshReadsProfilesWithSessionsThenEachProfilesPagesWithTheCurrentAppsPolicy() = run {
        val r = rig()
        r.host.addSession("research", "s1", "First") { addRow("user", "hello") }
        val catalog = r.repo.refreshCatalog()
        assertEquals(listOf("research", "scratch"), catalog.agents.map { it.id })
        assertEquals("Research Bot", catalog.agents[0].displayName)
        assertEquals(listOf("s1"), catalog.sessions.map { it.storedId })
        assertEquals("hello", catalog.sessions.single().preview)
        assertEquals(true, r.host.calls("profiles.list").single().params["include_sessions"].asBool)
        val list = r.host.restRequests.filter { it.route == "/api/sessions" }
        assertEquals(2, list.size)
        val query = list[0].query.toMap()
        assertEquals("research", query["profile"])
        assertEquals("100", query["limit"])
        assertEquals("0", query["offset"])
        assertEquals("include", query["archived"])
        assertEquals("created", query["order"])
        assertEquals("tool,kanban,bot_room", query["exclude_sources"])
    }

    @Test fun readingTheCatalogNeverCreatesResumesOrActivatesAChat() = run {
        val r = rig()
        r.host.addSession("research", "s1") { addRow("user", "hi") }
        r.repo.refreshCatalog()
        r.repo.archivedChats()
        r.repo.search("research", "hi")
        assertEquals(0, r.host.count("session.create") + r.host.count("session.resume") + r.host.count("session.activate"))
    }

    @Test fun theHiddenCanonicalBotChatIsMergedFromTheRegistryAndDeliberatelyArchivedChatsAreLeftOut() = run {
        val r = rig()
        val bot = r.host.addSession("research", "bot-1") { addRow("user", "hello bot") }
        r.host.makeCanonical(bot)
        r.host.addSession("research", "kept") { addRow("user", "a") }
        r.host.addSession("research", "gone") { addRow("user", "b"); archived = true }
        r.host.addSession("research", "swept") { addRow("user", "c"); archived = true; autoArchived = true }
        val catalog = r.repo.refreshCatalog()
        val byId = catalog.sessions.associateBy { it.storedId }
        assertFalse("A deliberately archived chat is not in the normal list", "gone" in byId)
        assertEquals("Hermes' idle sweep keeps the chat", ArchiveState.Automatic, byId.getValue("swept").archive)
        assertTrue("kept" in byId)
        val botRow = catalog.sessions.single { it.isCanonicalBotChat }
        assertEquals(ConversationRef("research", "bot-1"), botRow.ref)
        assertTrue("The list hides Bot Chats; only the registry names this one", botRow.isRegistryOnly)
        assertEquals("", botRow.preview)
        assertEquals(null, botRow.lastActiveEpochSeconds)
        // A refresh again keeps it (it used to be dropped by a refresh).
        assertTrue(r.repo.refreshCatalog().sessions.any { it.isCanonicalBotChat })
    }

    @Test fun aRowThatBelongsToTheBotChatLineageAnchorsOnTheRegistryId() = run {
        val r = rig()
        val bot = r.host.addSession("research", "bot-1") { addRow("user", "hello") }
        r.host.makeCanonical(bot)
        r.host.compact("bot-1", "bot-2")
        r.host.sessions.getValue("bot-2").hidden = false
        val catalog = r.repo.refreshCatalog()
        val row = catalog.sessions.single { it.storedId == "bot-2" }
        assertEquals("The route anchor is the registry's id, the transcript tip is the row's own", "bot-1", row.ref.anchor)
        assertEquals("bot-2", row.storedId)
        assertTrue(row.isCanonicalBotChat)
        assertFalse(row.isRegistryOnly)
    }

    @Test fun boundedContinuationFollowsHasMoreAndTheLegacyTotalAndSkipsRepeatedPinnedRows() = run {
        val r = rig()
        repeat(130) { r.host.addSession("research", "s$it") { addRow("user", "m$it") } }
        assertEquals(130, r.repo.refreshCatalog().sessions.size)
        assertEquals(listOf("0", "100"), r.host.restRequests.filter { it.route == "/api/sessions" && it.query.toMap()["profile"] == "research" }.map { it.query.toMap()["offset"] })
        r.host.legacyListEnvelope = true
        assertEquals("The older envelope pages by total", 130, r.repo.refreshCatalog().sessions.size)
    }

    @Test fun oneUnreadableRowHidesOnlyItself() = run {
        val r = rig()
        r.host.addSession("research", "good") { addRow("user", "x") }
        r.host.addSession("research", "bad") { addRow("user", "y"); startedAt = -1.0 }
        val catalog = r.repo.refreshCatalog()
        assertEquals(listOf("good"), catalog.sessions.map { it.storedId })
        assertEquals(null, catalog.error)
    }

    @Test fun aFailedRefreshKeepsTheLastListAndShowsTheError() = run {
        val r = rig()
        r.host.addSession("research", "s1") { addRow("user", "x") }
        r.repo.refreshCatalog()
        r.host.failRest = { it == "/api/sessions" }
        val failed = r.repo.refreshCatalog()
        assertNotNull(failed.error)
        assertEquals(listOf("s1"), failed.sessions.map { it.storedId })
        assertFalse(failed.loading)
    }

    @Test fun anAgentWhoseListTheHostCannotGiveDoesNotHideTheOthers() = run {
        val r = rig()
        r.host.addSession("research", "s1") { addRow("user", "x") }
        r.host.unavailableLists += "scratch"
        val catalog = r.repo.refreshCatalog()
        assertEquals(null, catalog.error)
        assertEquals(listOf("s1"), catalog.sessions.map { it.storedId })
        assertEquals(setOf("scratch"), catalog.agentErrors.keys)
        assertEquals(ChatError.Kind.HostUnavailable, catalog.agentErrors.getValue("scratch").kind)
        assertEquals(listOf("research", "scratch"), catalog.agents.map { it.id })
        // Every agent failing is the whole catalog's problem.
        r.host.unavailableLists += "research"
        assertEquals(ChatError.Kind.HostUnavailable, r.repo.refreshCatalog().error!!.kind)
        // The archived read tolerates it the same way.
        r.host.unavailableLists.remove("research")
        assertEquals(emptyList<SessionSummary>(), r.repo.archivedChats())
    }

    @Test fun archivedChatsAreAPlainReadOfOnlyTheDeliberateOnes() = run {
        val r = rig()
        r.host.addSession("research", "a1", "Archived one") { addRow("user", "x"); archived = true }
        r.host.addSession("research", "a2") { addRow("user", "x"); archived = true; autoArchived = true }
        r.host.addSession("research", "live") { addRow("user", "x") }
        val archived = r.repo.archivedChats()
        assertEquals(listOf("a1"), archived.map { it.storedId })
        assertTrue(r.host.restRequests.any { it.query.toMap()["archived"] == "only" })
    }

    @Test fun searchHonoursTheSourcePolicyAndReturnsSnippets() = run {
        val r = rig()
        r.host.addSession("research", "s1", "Garden notes") { addRow("user", "tomatoes need sun") }
        r.host.addSession("research", "s2", "Other") { addRow("user", "nothing") }
        val results = r.repo.search("research", "tomatoes")
        assertEquals(listOf("s1"), results.map { it.session.storedId })
        assertEquals("tomatoes need sun", results.single().snippet)
        val query = r.host.restRequests.last { it.route == "/api/sessions/search" }.query.toMap()
        assertEquals("tool,kanban,bot_room", query["exclude_sources"])
        assertEquals("20", query["limit"])
        assertThrowsChat(ChatError.Kind.InvalidInput) { r.repo.search("research", "") }
    }
}
