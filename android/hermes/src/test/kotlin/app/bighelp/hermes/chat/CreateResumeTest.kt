package app.bighelp.hermes.chat

import java.io.File
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CreateResumeTest : ChatTestBase() {
    private val host get() = ChatTestData.host

    @Test fun aNewChatSendsTheBighelpSourceAndAPersistedLowercaseKeyAndKeepsItsIdentitiesApart() = run {
        val r = rig()
        var recordStoredBeforeDispatch = false
        r.host.once("session.create") { params ->
            recordStoredBeforeDispatch = r.store.read(RecordKey.creation(host, "research")) != null
            r.host.defaultHandle("session.create", params)
        }
        val ref = r.newChat("research", CreateRequest(title = "Plan"))
        val sent = r.host.calls("session.create").single().params
        assertTrue("The create intent was on disk before session.create was sent", recordStoredBeforeDispatch)
        assertEquals("bighelp", sent["source"].asString)
        assertEquals("research", sent["profile"].asString)
        val key = sent["idempotency_key"].asString!!
        assertEquals(key.lowercase(), key)
        assertTrue(Coordinates.isUuid(key))
        // The routing anchor is the stored ID the chat was born with; the runtime ID is a different coordinate.
        val state = r.state(ref)
        val runtime = r.runtimeOf(ref)
        assertEquals(ref.anchor, state.identity.storedTip)
        assertNotEquals(runtime.id, ref.anchor)
        assertEquals("Empty transcript, nothing invented", emptyList<TranscriptItem>(), state.items)
        assertEquals("A finished create leaves no retained intent", emptyList<PendingCreation>(), r.repo.pendingCreations.value)
        assertNull(r.store.read(RecordKey.creation(host, "research")))
    }

    @Test fun aLostCreateReplyKeepsTheIntentAndARetryUsesTheSameKeyAndGetsTheSameSession() = run {
        val r = rig()
        r.host.loseReplyOnce("session.create", dropSocket = false)
        val first = r.repo.createChat("research")
        val unconfirmed = first as CreateOutcome.Unconfirmed
        assertEquals(ChatError.Kind.CreationUnconfirmed, unconfirmed.error.kind)
        r.eventually { r.repo.pendingCreations.value.size == 1 }
        val key = r.host.calls("session.create").single().params["idempotency_key"].asString

        val retry = r.repo.createChat("research", retryIntent = unconfirmed.intentId)
        val ref = (retry as CreateOutcome.Created).ref
        val keys = r.host.calls("session.create").map { it.params["idempotency_key"].asString }
        assertEquals("Both sends carry the one key", listOf(key, key), keys)
        assertEquals("The host handed back the one session; no duplicate chat", 1, r.host.sessions.size)
        assertEquals(1, r.host.sessions.values.count { it.id == ref.anchor })
        assertEquals(emptyList<PendingCreation>(), r.repo.pendingCreations.value)
    }

    @Test fun aLostCreateNeverBlocksAnIndependentFutureChat() = run {
        val r = rig()
        r.host.timeOutOnce("session.create", applyFirst = false)
        val lost = r.repo.createChat("research") as CreateOutcome.Unconfirmed
        // A plain New Chat is a new logical create with its own key, not a retry of the lost one.
        val independent = r.repo.createChat("research") as CreateOutcome.Created
        val keys = r.host.calls("session.create").map { it.params["idempotency_key"].asString }
        assertEquals(2, keys.toSet().size)
        assertNotEquals(lost.intentId, keys.last())
        assertEquals(ConversationRef("research", independent.ref.anchor), independent.ref)
    }

    @Test fun aRetainedIntentSurvivesAProcessRestartAndIsRetriedUnderTheSameKey() = run {
        val file = File(directory, "store.bin")
        val first = rig(store = FileSnapshotChatStore(file))
        first.host.loseReplyOnce("session.create", dropSocket = false)
        val unconfirmed = first.repo.createChat("research") as CreateOutcome.Unconfirmed
        val key = first.host.calls("session.create").single().params["idempotency_key"].asString
        first.close()

        // The process is gone. A new repository over the same files knows the intent.
        val second = rig(store = FileSnapshotChatStore(file))
        second.eventually(message = "pending creation loaded") { second.repo.pendingCreations.value.isNotEmpty() }
        assertEquals(unconfirmed.intentId, second.repo.pendingCreations.value.single().intentId)
        val created = second.repo.createChat("research", retryIntent = unconfirmed.intentId)
        assertTrue(created is CreateOutcome.Created)
        assertEquals(key, second.host.calls("session.create").single().params["idempotency_key"].asString)
    }

    @Test fun aFailedIntentWriteSendsNoCreate() = run {
        val store = FileSnapshotChatStore(File(directory, "s.bin"))
        val r = rig(store = store)
        store.failNextCommit = ChatStoreException(ChatStoreException.Kind.Unavailable)
        val outcome = r.repo.createChat("research")
        assertEquals(ChatError.Kind.PersistenceFailed, (outcome as CreateOutcome.Failed).error.kind)
        assertEquals("Nothing was dispatched", 0, r.host.count("session.create"))
    }

    @Test fun aChosenModelAndFolderMustBeConfirmedByTheCreateAnswer() = run {
        val r = rig()
        val ok = r.repo.createChat("research", CreateRequest(cwd = "/home/example/p", model = "big-model", provider = "stub-provider", reasoningEffort = "high", fast = false))
        assertTrue(ok is CreateOutcome.Created)
        val params = r.host.calls("session.create").single().params
        assertEquals("/home/example/p", params["cwd"].asString)
        assertEquals(true, params["cwd_explicit"].asBool)
        assertEquals("big-model", params["model"].asString)
        assertEquals("stub-provider", params["provider"].asString)
        assertEquals("high", params["reasoning_effort"].asString)
        assertEquals(false, params["fast"].asBool)

        r.host.ignoreRequestedModel = true
        val wrongModel = r.repo.createChat("research", CreateRequest(model = "big-model", provider = "stub-provider"))
        assertEquals(ChatError.Kind.ModelNotConfirmed, (wrongModel as CreateOutcome.Failed).error.kind)
        r.host.ignoreRequestedModel = false

        // The host reports another folder than the one asked for.
        r.host.once("session.create") { p ->
            val reply = r.host.defaultHandle("session.create", p) as JsonObject
            val info = reply["info"] as JsonObject
            JsonObject(reply + ("info" to JsonObject(info + ("cwd" to kotlinx.serialization.json.JsonPrimitive("/somewhere/else")))))
        }
        val wrongFolder = r.repo.createChat("research", CreateRequest(cwd = "/home/example/p"))
        assertEquals(ChatError.Kind.WorkspaceNotConfirmed, (wrongFolder as CreateOutcome.Failed).error.kind)
    }

    @Test fun onlyAnExplicitRejectionOfCwdExplicitRetriesWithoutItUnderTheSameKey() = run {
        val r = rig()
        r.host.rejectCwdExplicit = true
        val ref = (r.repo.createChat("research", CreateRequest(cwd = "/home/example/p")) as CreateOutcome.Created).ref
        val sends = r.host.calls("session.create")
        assertEquals(2, sends.size)
        assertTrue(sends[0].params.containsKey("cwd_explicit"))
        assertFalse(sends[1].params.containsKey("cwd_explicit"))
        assertEquals(sends[0].params["idempotency_key"], sends[1].params["idempotency_key"])
        assertNotNull(ref)
        // A timeout is not a rejection: no second send.
        val r2 = rig()
        r2.host.timeOutOnce("session.create")
        assertTrue(r2.repo.createChat("research", CreateRequest(cwd = "/home/example/p")) is CreateOutcome.Unconfirmed)
        assertEquals(1, r2.host.count("session.create"))
    }

    @Test fun resumeSendsTheStoredIdTheSourceAndTheDocumentedFlags() = run {
        val r = rig()
        val ref = r.savedChat()
        val resume = r.host.calls("session.resume").single().params
        assertEquals(ref.anchor, resume["session_id"].asString)
        assertEquals("research", resume["profile"].asString)
        assertEquals("bighelp", resume["source"].asString)
        assertEquals(false, resume["close_on_disconnect"].asBool)
        assertEquals(true, resume["defer_history"].asBool)
        assertEquals(true, resume["omit_messages"].asBool)
        val binding = r.state(ref)
        assertNotEquals("Runtime and stored IDs are different coordinates", r.runtimeOf(ref).id, binding.identity.storedTip)
    }

    @Test fun aHostThatRefusesTheLifetimeFieldGetsTheSamePlainResume() = run {
        val r = rig()
        val session = r.host.addSession("research") { addRow("user", "hi") }
        r.host.once("session.resume") { throw app.bighelp.hermes.HermesException(app.bighelp.hermes.HermesException.Kind.RpcRejected, code = 4000) }
        val ref = ConversationRef("research", session.id)
        r.repo.open(ref)
        r.awaitState(ref) { it.phase == ConversationPhase.Ready }
        val resumes = r.host.calls("session.resume")
        assertEquals(2, resumes.size)
        assertFalse(resumes[1].params.containsKey("close_on_disconnect"))
    }

    @Test fun aFailedResumeNeverBecomesACreate() = run {
        val r = rig()
        r.host.rejectOnce("session.resume", 4007)
        val session = r.host.addSession("research")
        val ref = ConversationRef("research", session.id)
        r.repo.open(ref)
        val state = r.awaitState(ref) { it.lastError != null }
        assertEquals(ChatError.Kind.NotOpen, state.lastError!!.kind)
        assertEquals("No create as a resume or reconnect fallback", 0, r.host.count("session.create"))
        assertEquals(ConversationPhase.Suspended, state.phase)
    }

    @Test fun aCompactionSuccessorIsValidatedRebindsTheTipAndKeepsTheRouteAndTheOldAlias() = run {
        val r = rig()
        val old = r.host.addSession("research", "old-tip") { addRow("user", "hi"); addRow("assistant", "hello") }
        val ref = ConversationRef("research", old.id)
        r.repo.open(ref)
        r.repo.updateDraft(ref, "unfinished thought")
        r.host.compact("old-tip", "new-tip")
        // The chat is opened again on a new connection: resume of the old tip answers with the successor.
        r.repo.release(ref)
        r.repo.open(ref)
        val state = r.awaitState(ref) { it.phase == ConversationPhase.Ready && it.identity.storedTip == "new-tip" }
        assertEquals("The route never changes with the tip", ref, state.ref)
        assertEquals(listOf("old-tip"), state.identity.formerStoredIds)
        assertTrue(state.identity.knows("old-tip"))
        assertEquals("The draft stays with the anchor", "unfinished thought", state.draft)
        val history = r.host.restRequests.last { it.route.endsWith("/messages") }
        assertTrue("History reads the successor, not the old tip", history.route.contains("new-tip"))
        // The alias survives a restart.
        val identity = IdentityRecord.decode(r.scopeOf(ref), r.store.read(RecordKey.identity(r.scopeOf(ref)))!!)
        assertEquals("new-tip", identity.storedTip)
        assertEquals(listOf("old-tip"), identity.formerStoredIds)
    }

    @Test fun anEmptyOrInventedIdNeverTargetsADefaultAgent() = run {
        val r = rig()
        assertTrue(r.repo.createChat("", CreateRequest()) is CreateOutcome.Failed)
        assertTrue(r.repo.createChat(" scratch ", CreateRequest()) is CreateOutcome.Failed)
        assertEquals(0, r.host.count("session.create"))
        assertThrowsChat(ChatError.Kind.NotOpen) { r.repo.reloadHistory(ConversationRef("research", "never-opened")) }
    }

    @Test fun theBotChatIsNotCreatedWithoutAnExplicitDecisionAndTheRegistryChatIsResumedByItsRegistryId() = run {
        val r = rig()
        assertEquals(BotChatOutcome.NotCreated, r.repo.openBotChat("research"))
        assertEquals(0, r.host.count("session.create"))
        val bot = r.host.addSession("research", "bot-1") { addRow("user", "hello") }
        r.host.makeCanonical(bot)
        val opened = r.repo.openBotChat("research") as BotChatOutcome.Opened
        assertEquals(ConversationRef("research", "bot-1"), opened.ref)
        r.awaitState(opened.ref) { it.phase == ConversationPhase.Ready }
        assertEquals("bot-1", r.host.calls("session.resume").single().params["session_id"].asString)
    }

    @Test fun theFirstBotChatIsHiddenTitledReadBackFromTheRegistryAndRecoveredByItsOwnIntent() = run {
        val r = rig()
        val outcome = r.repo.openBotChat("research", createIfMissing = true)
        val create = r.host.calls("session.create").single().params
        assertEquals("Bot Chat", create["title"].asString)
        assertEquals(true, create["hidden"].asBool)
        assertEquals(true, create["follow_profile_config"].asBool)
        assertEquals("bighelp", create["source"].asString)
        assertEquals("The title is persisted through session.title", 1, r.host.count("session.title"))
        val opened = outcome as BotChatOutcome.Opened
        assertEquals("The conversation anchors on the registry's chat", r.host.canonicalIds["research"], opened.ref.anchor)
        assertNull("A resolved first creation leaves no retained intent", r.store.read(RecordKey.creation(host, "research")))
        r.awaitState(opened.ref) { it.phase == ConversationPhase.Ready }
    }

    @Test fun aLostFirstBotChatReplyRecoversByItsOwnIntentAndKey() = run {
        val r = rig()
        r.host.loseReplyOnce("session.create", dropSocket = false)
        val lost = r.repo.openBotChat("research", createIfMissing = true)
        assertTrue("$lost", lost is BotChatOutcome.Unconfirmed)
        val recovered = r.repo.openBotChat("research", createIfMissing = true)
        assertTrue("$recovered", recovered is BotChatOutcome.Opened)
        val keys = r.host.calls("session.create").map { it.params["idempotency_key"].asString }
        assertEquals("The recovery re-sends under the first creation's own key", 2, keys.size)
        assertEquals(keys[0], keys[1])
        assertEquals("The host kept one session for that key", 1, r.host.sessions.size)
    }

    @Test fun anUnfinishedFirstBotChatNeverLocksTheAgentOutOfOrdinaryChats() = run {
        val r = rig()
        r.host.timeOutOnce("session.title", applyFirst = false)
        val first = r.repo.openBotChat("research", createIfMissing = true)
        assertTrue("$first", first is BotChatOutcome.Unconfirmed)
        // The title never landed, so the registry has no Bot Chat; an ordinary New Chat is safe and works at once.
        assertTrue(r.repo.createChat("research") is CreateOutcome.Created)
    }

    @Test fun aTitleConflictWinnerIsAdoptedFromTheRegistry() = run {
        val r = rig()
        r.host.once("session.title") {
            val winner = r.host.addSession("research", "winner-1") { addRow("user", "first") }
            r.host.makeCanonical(winner)
            throw app.bighelp.hermes.HermesException(app.bighelp.hermes.HermesException.Kind.RpcRejected, code = 4022)
        }
        val outcome = r.repo.openBotChat("research", createIfMissing = true) as BotChatOutcome.Opened
        assertEquals("winner-1", outcome.ref.anchor)
        assertEquals("The empty chat made for the failed attempt is dropped", 1, r.host.count("session.delete"))
    }
}

internal fun ChatRig.scopeOf(ref: ConversationRef) = ConversationScope(ChatTestData.host, ref.profile, ref.anchor)
