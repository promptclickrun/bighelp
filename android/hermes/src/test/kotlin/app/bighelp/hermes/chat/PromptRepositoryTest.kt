package app.bighelp.hermes.chat

import app.bighelp.hermes.ServerResponse
import java.io.File
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PromptRepositoryTest : ChatTestBase() {
    private suspend fun Deferred<ServerResponse>.response(): ServerResponse = withTimeout(5_000) { await() }

    private fun ServerResponse.result(): JsonObject = (this as ServerResponse.Result).value as JsonObject

    private fun ServerResponse.failureCode(): Long = (this as ServerResponse.Failure).code

    private suspend fun ChatRig.ask(ref: ConversationRef, method: String, params: String, id: String = "wire-1"): Deferred<ServerResponse> {
        val runtime = runtimeOf(ref).id
        val withSession = JsonObject(mapOf("session_id" to kotlinx.serialization.json.JsonPrimitive(runtime)) + jsonObject(params)).toString()
        val deferred = host.serverRequest(scope, method, withSession, id)
        eventually(message = "prompt shown or answered") { repo.prompts.value.any { it.wireId == id } || deferred.isCompleted }
        return deferred
    }

    @Test fun theHandlersAreRegisteredBeforeAnySocketAndAgainBeforeAReconnect() = run {
        val r = rig()
        assertEquals(setOf("approval", "clarify", "secret", "sudo", "vault.code", "vault.save_login", "vault.unlock_prompt"), r.host.handlers.keys)
        r.host.handlers.clear()
        r.repo.reconnect()
        assertEquals("A connection that ended without recovery forgets handlers; the repository registers them again", 7, r.host.handlers.size)
        // A method nobody can fulfil stays unregistered, so the gateway answers it with -32601.
        assertFalse("mcp.setup" in r.host.handlers)
    }

    @Test fun anApprovalIsBoundToTheConversationAndKeepsTheWireIdSeparateFromTheDomainRequestId() = run {
        val r = rig()
        val ref = r.newChat()
        val deferred = r.ask(ref, "approval", """{"request_id":"approval-domain-a","command":"git status","description":"Inspect","tool_name":"terminal","choices":["once","session","always","deny","bogus","once"]}""", id = "server-approval-a")
        val prompt = r.repo.prompts.value.single()
        assertEquals("server-approval-a", prompt.wireId)
        assertEquals("approval-domain-a", prompt.domainRequestId)
        assertNotEquals(prompt.wireId, prompt.domainRequestId)
        assertEquals(ref, prompt.ref)
        val card = prompt.content as PromptContent.Approval
        assertEquals("An unknown or repeated choice is skipped, not fatal", listOf(ApprovalChoice.Once, ApprovalChoice.Session, ApprovalChoice.Always, ApprovalChoice.Deny), card.choices)
        assertEquals("git status", card.command)
        assertEquals(listOf(prompt.id), r.state(ref).prompts.map { it.id })

        assertEquals(PromptResult.Answered, r.repo.answerPrompt(prompt.id, PromptAnswer.Approve(ApprovalChoice.Session)))
        val result = deferred.response().result()
        assertEquals("session", result["choice"].asString)
        assertEquals("Always the one scope offered, never a blanket", false, result["all"].asBool)
        assertTrue(r.repo.prompts.value.isEmpty())
        assertEquals(PromptResult.NoLongerActive, r.repo.answerPrompt(prompt.id, PromptAnswer.Approve(ApprovalChoice.Once)))
    }

    @Test fun anUnofferedChoiceIsInvalidAndLeavesThePromptActionableAndDeclineDenies() = run {
        val r = rig()
        val ref = r.newChat()
        val deferred = r.ask(ref, "approval", """{"request_id":"d1","choices":["once","deny"]}""")
        val prompt = r.repo.prompts.value.single()
        assertTrue(r.repo.answerPrompt(prompt.id, PromptAnswer.Approve(ApprovalChoice.Always)) is PromptResult.Invalid)
        assertEquals(1, r.repo.prompts.value.size)
        assertEquals(PromptResult.Answered, r.repo.declinePrompt(prompt.id))
        val result = deferred.response().result()
        assertEquals("deny", result["choice"].asString)
        assertEquals(false, result["all"].asBool)
    }

    @Test fun malformedAndUnboundRequestsFailExplicitlyAndNeverBecomeCards() = run {
        val r = rig()
        val ref = r.newChat()
        assertEquals(-32602L, r.ask(ref, "approval", """{"choices":["once"]}""", "m1").response().failureCode())
        assertEquals(-32602L, r.ask(ref, "approval", """{"request_id":"x","choices":["unknown"]}""", "m2").response().failureCode())
        assertEquals(-32602L, r.ask(ref, "clarify", """{"question":"a","questions":[{"qid":"q","question":"b"}]}""", "m3").response().failureCode())
        assertEquals(-32602L, r.ask(ref, "sudo", """{"extra":1}""", "m4").response().failureCode())
        assertEquals(-32602L, r.ask(ref, "secret", """{"env_var":"K","prompt":"p","surprise":1}""", "m5").response().failureCode())
        val unbound = r.host.serverRequest(r.scope, "approval", """{"session_id":"runtime-nobody","request_id":"x","choices":["once"]}""", "m6")
        assertEquals("A request for a runtime this repository does not hold is not actionable", -32602L, unbound.response().failureCode())
        assertTrue(r.repo.prompts.value.isEmpty())
        // A method with no handler is the gateway's -32601, never a card (the fake answers as the gateway would).
        assertEquals(-32601L, r.host.serverRequest(r.scope, "mcp.setup", """{"session_id":"x"}""").response().failureCode())
    }

    @Test fun aSingleClarificationAnswersWithAnAnswerStringAndABatchKeepsLockedAnswers() = run {
        val r = rig()
        val ref = r.newChat()
        val single = r.ask(ref, "clarify", """{"question":"Which environment?","choices":["Test","Production"],"multi_select":false}""", "c1")
        val one = r.repo.prompts.value.single { it.wireId == "c1" }
        val content = one.content as PromptContent.Clarification
        assertFalse(content.isBatch)
        assertEquals(PromptResult.Answered, r.repo.answerPrompt(one.id, PromptAnswer.Clarify(mapOf(PromptCenter.SINGLE to "Test"))))
        assertEquals("Test", single.response().result()["answer"].asString)

        val batch = r.ask(ref, "clarify", """{"questions":[{"qid":"environment","question":"Which environment?","choices":["Test","Production"]},{"qid":"checks","question":"Which checks?","choices":["Unit","UI"],"multi_select":true}],"answers":{"environment":"Test"}}""", "c2")
        val two = r.repo.prompts.value.single { it.wireId == "c2" }
        val questions = (two.content as PromptContent.Clarification).questions
        assertEquals("Test", questions[0].lockedAnswer)
        // Missing the second answer: invalid, still actionable.
        assertTrue(r.repo.answerPrompt(two.id, PromptAnswer.Clarify(emptyMap())) is PromptResult.Invalid)
        // A multi-select answer is JSON array text, with at most one custom string.
        assertTrue(r.repo.answerPrompt(two.id, PromptAnswer.Clarify(mapOf("checks" to """["Unit","Other","Another"]"""))) is PromptResult.Invalid)
        assertEquals(PromptResult.Answered, r.repo.answerPrompt(two.id, PromptAnswer.Clarify(mapOf("checks" to """["Unit","UI"]"""))))
        val answers = batch.response().result()["answers"] as JsonObject
        assertEquals("Test", answers["environment"].asString)
        assertEquals("""["Unit","UI"]""", answers["checks"].asString)
    }

    @Test fun aSecureValueIsOneResponseNeverStoredAndClearedAfterUse() = run {
        val store = MemoryChatStore()
        val r = rig(store = store)
        val ref = r.newChat()
        val deferred = r.ask(ref, "secret", """{"env_var":"EXAMPLE_API_KEY","prompt":"Enter the key","metadata":{"source":"agent","label":"Service API key"}}""", "s1")
        val prompt = r.repo.prompts.value.single()
        val card = prompt.content as PromptContent.SecureInput
        assertEquals(SecureKind.Secret, card.kind)
        assertEquals("EXAMPLE_API_KEY", card.envVar)
        assertEquals("Service API key", card.label)
        assertTrue(card.isAgentRequest)
        val secret = "synthetic-secret-value".toCharArray()
        assertEquals(PromptResult.Answered, r.repo.answerPrompt(prompt.id, PromptAnswer.Secure(secret)))
        assertEquals("synthetic-secret-value", deferred.response().result()["value"].asString)
        assertTrue("The caller's array was cleared", secret.all { it == '\u0000' })
        assertTrue(r.repo.prompts.value.isEmpty())
        // A second answer is retired without replay, and its array is cleared too.
        val again = "another-synthetic".toCharArray()
        assertEquals(PromptResult.NoLongerActive, r.repo.answerPrompt(prompt.id, PromptAnswer.Secure(again)))
        assertTrue(again.all { it == '\u0000' })
        // Nothing durable or observable ever held it.
        val blob = r.store.keys(ChatTestData.host, RecordKind.Journal).size + r.store.keys(ChatTestData.host, RecordKind.Draft).size
        assertEquals(0, blob)
        assertFalse(r.state(ref).toString().contains("synthetic-secret-value") || r.repo.prompts.value.toString().contains("synthetic-secret-value"))
    }

    @Test fun declineAndTheOtherSecureKindsRespondWithTheirDocumentedShapes() = run {
        val r = rig()
        val ref = r.newChat()
        val sudo = r.ask(ref, "sudo", "{}", "u1")
        r.repo.declinePrompt(r.repo.prompts.value.single { it.wireId == "u1" }.id)
        assertEquals("", sudo.response().result()["value"].asString)

        val code = r.ask(ref, "vault.code", """{"site":"example.org","hint":"six digits"}""", "u2")
        val codePrompt = r.repo.prompts.value.single { it.wireId == "u2" }
        assertTrue(r.repo.answerPrompt(codePrompt.id, PromptAnswer.Secure("12 34-56 !".toCharArray())) is PromptResult.Invalid)
        assertEquals(PromptResult.Answered, r.repo.answerPrompt(codePrompt.id, PromptAnswer.Secure("12 34-56".toCharArray())))
        assertEquals("123456", code.response().result()["value"].asString)

        val login = r.ask(ref, "vault.save_login", """{"origin":"https://example.org","site":"Example"}""", "u3")
        val loginPrompt = r.repo.prompts.value.single { it.wireId == "u3" }
        assertEquals("https://example.org", (loginPrompt.content as PromptContent.SecureInput).site)
        assertEquals(PromptResult.Answered, r.repo.answerPrompt(loginPrompt.id, PromptAnswer.SaveLogin(" me@example.org ", "pw".toCharArray())))
        val saved = login.response().result()["value"].asString!!
        assertEquals("""{"identifier":"me@example.org","password":"pw"}""", saved)

        val unlock = r.ask(ref, "vault.unlock_prompt", """{"backend":"keychain","display_name":""}""", "u4")
        assertEquals("keychain", (r.repo.prompts.value.single { it.wireId == "u4" }.content as PromptContent.SecureInput).backendName)
        r.repo.declinePrompt(r.repo.prompts.value.single { it.wireId == "u4" }.id)
        assertEquals("", unlock.response().result()["value"].asString)
        assertEquals(-32602L, r.ask(ref, "vault.save_login", """{"origin":"ftp://example.org","site":"x"}""", "u5").response().failureCode())
    }

    @Test fun aCancellationRetiresOnlyThePromptItNamesAndTheGatewayDecidesTheMatchByIdAndMethod() = run {
        val r = rig()
        val ref = r.newChat()
        val first = r.ask(ref, "approval", """{"request_id":"d1","choices":["once"]}""", "dup")
        val second = r.ask(ref, "clarify", """{"question":"Same wire id, other method?"}""", "dup")
        r.eventually(message = "both prompts") { r.repo.prompts.value.size == 2 }
        assertEquals("Two methods may share a wire ID bytes; they are two prompts", 2, r.repo.prompts.value.size)
        // The gateway cancels exactly the handler whose ID and method match: here the clarify one.
        second.cancel()
        r.eventually(message = "clarify retired") { r.repo.prompts.value.size == 1 }
        assertEquals("approval", r.repo.prompts.value.single().method)
        assertFalse(first.isCompleted)
        val remaining = r.repo.prompts.value.single()
        assertEquals(PromptResult.Answered, r.repo.answerPrompt(remaining.id, PromptAnswer.Approve(ApprovalChoice.Once)))
    }

    @Test fun promptsEndWithTheirSocketAndAreNeverRestoredFromAStoredResponse() = run {
        val r = rig()
        val ref = r.newChat()
        val deferred = r.ask(ref, "approval", """{"request_id":"d1","choices":["once"]}""", "gone")
        r.host.dropConnection()
        r.eventually(message = "prompt retired with the socket") { r.repo.prompts.value.isEmpty() }
        assertEquals("Retired: its response is an error that is never written", -32000L, deferred.response().failureCode())
        assertEquals(emptyList<PromptState>(), r.state(ref).prompts)
    }

    @Test fun openRequestsOfTheFinalRecoveryAreRestoredThroughTheOrdinaryHandlerPath() = run {
        val r = rig()
        val ref = r.newChat()
        val rt = r.runtimeOf(ref)
        rt.openRequests += jsonObject("""{"id":"server-question-a","method":"clarify","params":{"session_id":"${rt.id}","question":"Continue?"}}""")
        r.host.dropConnection()
        r.host.newSocket()
        r.awaitState(ref, "recovered") { it.phase == ConversationPhase.Ready && it.sendBlock == null }
        val adopted = r.host.adopted.last()
        assertEquals(rt.id, adopted.second)
        assertEquals("Adopted for the new socket generation", r.host.generation, adopted.third)
        assertEquals(1, (adopted.first as kotlinx.serialization.json.JsonArray).size)
        assertFalse(r.state(ref).legacyPromptHost)
    }

    @Test fun aHostWithoutOpenRequestsIsMarkedLegacyAndOffersNoCards() = run {
        val r = rig()
        r.host.legacyPrompts = true
        val ref = r.newChat()
        assertTrue(r.state(ref).legacyPromptHost)
        assertEquals("No adoption is attempted without the modern field", 0, r.host.adopted.size)
    }
}
