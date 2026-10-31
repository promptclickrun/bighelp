package app.bighelp.hermes.chat

import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeControlsTest : ChatTestBase() {
    private fun ChatRig.configSets() = host.calls("config.set").map { it.params }

    @Test fun optionsAreReadFromTheLiveRuntimeNotInferredAndCarryTheHostCatalog() = run {
        val r = rig()
        val ref = r.savedChat()
        val options = r.repo.modelOptions(ref)
        assertEquals("stub-model", options.model)
        assertEquals("stub-provider", options.provider)
        assertEquals("medium", options.reasoningEffort)
        assertEquals(listOf("stub-provider", "other-provider"), options.providers.map { it.id })
        assertTrue(options.providers.first().isCurrent)
        assertEquals(false, options.isFast)
        assertEquals("The proof came from activation of this very runtime", r.runtimeOf(ref).id, r.host.calls("session.activate").last().params["session_id"].asString)
    }

    @Test fun aModelChangeIsSessionScopedKeepsReasoningAndIsConfirmedByReadback() = run {
        val r = rig()
        val ref = r.savedChat()
        val change = r.repo.setModel(ref, "big-model", "stub-provider")
        assertEquals(ModelChange.Confirmed("big-model", "stub-provider"), change)
        val sets = r.configSets()
        val model = sets.first { it["key"].asString == "model" }
        assertEquals("big-model --provider stub-provider --session", model["value"].asString)
        assertEquals(r.runtimeOf(ref).id, model["session_id"].asString)
        assertEquals("research", model["profile"].asString)
        // The previous reasoning level is written back for this session only, then read back.
        val reasoning = sets.first { it["key"].asString == "reasoning" }
        assertEquals("medium", reasoning["value"].asString)
        assertEquals("session", reasoning["scope"].asString)
        assertEquals(1, r.host.calls("config.get").size)
        // No call may touch a profile default: every config.set names this runtime.
        assertTrue(sets.all { it["session_id"].asString == r.runtimeOf(ref).id })
        assertEquals("big-model", r.state(ref).runtime.model)
        assertEquals("big-model", r.host.sessions.getValue(ref.anchor).model)
    }

    @Test fun anAlreadyCurrentModelIsConfirmedWithoutAWrite() = run {
        val r = rig()
        val ref = r.savedChat()
        assertEquals(ModelChange.Confirmed("stub-model", "stub-provider"), r.repo.setModel(ref, "stub-model", "stub-provider"))
        assertEquals(0, r.host.count("config.set"))
    }

    @Test fun aDeferredChangeIsNeverReportedAsChangedAndLeavesTheCurrentModelAlone() = run {
        val r = rig()
        val ref = r.savedChat()
        r.host.deferModelChange = true
        val change = r.repo.setModel(ref, "big-model", "stub-provider")
        assertTrue(change is ModelChange.Deferred)
        assertEquals("stub-model", r.host.sessions.getValue(ref.anchor).model)
        assertEquals("No reasoning rewrite on an unconfirmed change", 1, r.configSets().size)
        assertEquals("stub-model", r.repo.modelOptions(ref).model)
    }

    @Test fun anExpensiveModelNeedsAnExplicitYesAndNothingChangedBeforeIt() = run {
        val r = rig()
        val ref = r.savedChat()
        r.host.requireModelConfirmation = true
        val first = r.repo.setModel(ref, "big-model", "stub-provider")
        assertTrue(first is ModelChange.NeedsConfirmation)
        assertEquals("stub-model", r.host.sessions.getValue(ref.anchor).model)
        assertNull(r.configSets().first()["confirm_expensive_model"])
        val confirmed = r.repo.setModel(ref, "big-model", "stub-provider", confirmed = true)
        assertEquals(ModelChange.Confirmed("big-model", "stub-provider"), confirmed)
        assertEquals(true, r.configSets().last { it["key"].asString == "model" }["confirm_expensive_model"].asBool)
    }

    @Test fun aHostThatReportsAnotherModelAfterTheChangeIsNotConfirmed() = run {
        val r = rig()
        val ref = r.savedChat()
        r.host.once("config.set") { p ->
            // The host accepts the call but the session keeps its model.
            kotlinx.serialization.json.JsonObject(mapOf(
                "key" to kotlinx.serialization.json.JsonPrimitive("model"), "scope" to kotlinx.serialization.json.JsonPrimitive("session"),
                "value" to kotlinx.serialization.json.JsonPrimitive("big-model"), "confirm_required" to kotlinx.serialization.json.JsonPrimitive(false),
            ))
        }
        assertThrowsChat(ChatError.Kind.ModelNotConfirmed) { r.repo.setModel(ref, "big-model", "stub-provider") }
        assertEquals("stub-model", r.host.sessions.getValue(ref.anchor).model)
    }

    @Test fun reasoningIsWrittenForTheSessionAndVerifiedByAReadBack() = run {
        val r = rig()
        val ref = r.savedChat()
        r.repo.setReasoning(ref, "high")
        val set = r.configSets().single()
        assertEquals("reasoning", set["key"].asString)
        assertEquals("high", set["value"].asString)
        assertEquals("session", set["scope"].asString)
        assertEquals(r.runtimeOf(ref).id, set["session_id"].asString)
        assertEquals("high", r.state(ref).runtime.reasoningEffort)
        assertThrowsChat(ChatError.Kind.InvalidInput) { r.repo.setReasoning(ref, "turbo") }
        // A readback that disagrees is an unknown outcome.
        r.host.once("config.get") { JsonObject(mapOf("key" to kotlinx.serialization.json.JsonPrimitive("reasoning"), "value" to kotlinx.serialization.json.JsonPrimitive("low"))) }
        assertThrowsChat(ChatError.Kind.OutcomeUnknown) { r.repo.setReasoning(ref, "max") }
    }

    @Test fun fastModeNeedsAnIdleRuntimeAndAModelTheHostSaysSupportsIt() = run {
        val r = rig()
        val ref = r.savedChat()
        assertThrowsChat(ChatError.Kind.Unsupported) { r.repo.setFast(ref, true) }
        assertEquals(0, r.host.count("config.set"))
        r.host.modelOptionRows = jsonObject("""{"model":"stub-model","providers":[{"slug":"stub-provider","name":"Stub","is_current":true,"models":["stub-model"],"capabilities":{"stub-model":{"fast":true}}}]}""")
        r.repo.setFast(ref, true)
        val set = r.configSets().single()
        assertEquals("fast", set["key"].asString)
        assertEquals("fast", set["value"].asString)
        assertEquals("session", set["scope"].asString)
        assertEquals(true, r.repo.modelOptions(ref).isFast)
        // A running turn blocks it.
        assertTrue(r.repo.send(ref, "work") is SendResult.Admitted)
        assertThrowsChat(ChatError.Kind.Conflict) { r.repo.setFast(ref, false) }
    }

    @Test fun yoloIsConfirmedByTheHostsOneOrZero() = run {
        val r = rig()
        val ref = r.newChat()
        r.repo.setYolo(ref, true)
        val set = r.configSets().single()
        assertEquals("yolo", set["key"].asString)
        assertEquals("on", set["value"].asString)
        assertEquals("session", set["scope"].asString)
        r.host.once("config.set") { JsonObject(mapOf("key" to kotlinx.serialization.json.JsonPrimitive("yolo"), "value" to kotlinx.serialization.json.JsonPrimitive("1"))) }
        assertThrowsChat(ChatError.Kind.OutcomeUnknown) { r.repo.setYolo(ref, false) }
    }

    @Test fun aControlNeedsALiveRuntimeAndAnOwnerThatIsStillCurrent() = run {
        val r = rig()
        val ref = r.savedChat()
        r.host.dropConnection()
        r.eventually { r.state(ref).phase == ConversationPhase.Suspended }
        assertThrowsChat(ChatError.Kind.NotConnected) { r.repo.setReasoning(ref, "high") }
        assertEquals("Nothing was written", 0, r.host.count("config.set"))
        r.host.newSocket()
        r.awaitState(ref) { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        // The socket changes while the change is in flight: the late answer is not applied to the new owner.
        r.host.once("config.set") { p ->
            val reply = r.host.defaultHandle("config.set", p)
            r.host.dropConnection()
            r.host.newSocket()
            reply
        }
        // The answer arrived on the replaced socket's watch: it is not applied (the new socket's own recovery reads the host's truth).
        assertThrowsChat(ChatError.Kind.NotConnected) { r.repo.setReasoning(ref, "high") }
    }
}
