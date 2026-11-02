package app.bighelp.hermes.chat

import app.bighelp.hermes.GatewayClient
import app.bighelp.hermes.GatewayConnection
import app.bighelp.hermes.HermesAuthenticator
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.InMemoryCredentialStore
import app.bighelp.hermes.OkHttpHermesHttp
import app.bighelp.hermes.SignInInput
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.Timeout

/**
 * The repository against a real stock Hermes with a scripted local model (the disposable open host; no AI spend).
 * Skipped unless `BIGHELP_E2E_CREDENTIALS` names the private credentials file, which is read at run time and never
 * printed. Only the open host is used, so the password host's pending-authorization quota is untouched.
 *
 * This is protocol-level JVM evidence: not Android, not an emulator or device, not real inference.
 */
class RealHostChatTest {
    @get:Rule val timeout: Timeout = Timeout.seconds(180)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val closeables = mutableListOf<AutoCloseable>()
    private val clients = mutableListOf<GatewayClient>()
    private val repositories = mutableListOf<HermesChatRepository>()
    private lateinit var origin: String
    private lateinit var project: String
    private val computer = ChatTestData.host.computerId

    @Before fun requireHost() {
        val path = System.getenv("BIGHELP_E2E_CREDENTIALS")
        assumeTrue("Set BIGHELP_E2E_CREDENTIALS to run against the disposable hosts", path != null && File(path).isFile)
        val open = Json.parseToJsonElement(File(path!!).readText()).jsonObject["hosts"]!!.jsonObject["open"]!!.jsonObject
        origin = open["proxy_origin"]!!.jsonPrimitive.content
        project = open["project"]!!.jsonPrimitive.content
    }

    @After fun cleanup() = runBlocking {
        repositories.forEach { runCatching { it.close() } }
        clients.forEach { runCatching { it.disconnect() } }
        scope.cancel()
        closeables.forEach { runCatching { it.close() } }
    }

    /** One owner as the app builds it: authenticator, client, repository first, then connect. */
    private suspend fun owner(store: ChatStore = MemoryChatStore()): HermesChatRepository {
        val endpoint = HermesEndpoint.parse(origin, allowPrivateHttp = true)
        val authenticator = HermesAuthenticator(endpoint, OkHttpHermesHttp(endpoint), InMemoryCredentialStore()).also { closeables += it }
        authenticator.signIn(SignInInput.Dashboard)
        val client = GatewayClient(authenticator, scope).also { clients += it }
        val host = HostScope(computer, endpoint.canonical, authenticator.savedConnection!!.principal)
        val repo = HermesChatRepository(client, authenticator, scope, host, store).also { repositories += it }
        assertEquals(GatewayConnection.Connected, client.connect().connection)
        authenticator.commit()
        return repo
    }

    private suspend fun eventually(message: String, timeoutMillis: Long = 60_000, condition: () -> Boolean) {
        try { withTimeout(timeoutMillis) { while (!condition()) delay(100) } } catch (e: kotlinx.coroutines.TimeoutCancellationException) { throw AssertionError("Timed out waiting for $message") }
    }

    private suspend fun HermesChatRepository.newChat(title: String): ConversationRef {
        val outcome = createChat("default", CreateRequest(cwd = project, title = title))
        val ref = (outcome as? CreateOutcome.Created)?.ref ?: throw AssertionError("create failed: $outcome")
        eventually("ready") { conversations.value[ref]?.phase == ConversationPhase.Ready }
        return ref
    }

    private fun HermesChatRepository.texts(ref: ConversationRef) = conversations.value.getValue(ref).items.filterIsInstance<MessageItem>().map { it.text }

    @Test fun createSendStreamPersistAndReopenOnAFreshSocketAgainstARealHost() = runBlocking {
        val repo = owner()
        val catalog = repo.refreshCatalog()
        assertNull(catalog.error)
        assertTrue(catalog.agents.map { it.id }.containsAll(listOf("default", "moss", "cobalt")))
        // A profile with no session store yet answers 503; that must not hide the others.
        assertFalse("default" in catalog.agentErrors)
        println("REAL-HOST catalog: agents=${catalog.agents.size} agentErrors=${catalog.agentErrors.mapValues { it.value.kind }}")

        val ref = repo.newChat("Synthetic repository check")
        val result = repo.send(ref, "hello from the Android chat repository")
        assertEquals(Admission.Streaming, (result as SendResult.Admitted).admission)
        eventually("the owned terminal retires the journal entry") { repo.conversations.value.getValue(ref).unresolved.isEmpty() }
        eventually("the final reply, once") { repo.texts(ref).count { it.contains("Direct streaming fixture complete.") } == 1 }
        eventually("saved rows take over from the live ones") {
            val items = repo.conversations.value.getValue(ref).items.filterIsInstance<MessageItem>()
            items.size == 2 && items.all { it.origin == ItemOrigin.Saved && it.rowId != null }
        }
        assertEquals("hello from the Android chat repository", repo.texts(ref).first())
        val state = repo.conversations.value.getValue(ref)
        assertFalse(state.running)
        assertNull(state.sendBlock)
        println("REAL-HOST chat: legacyPromptHost=${state.legacyPromptHost} runtimeModelKnown=${state.runtime.model != null} items=${state.items.map { it::class.simpleName }}")

        // A second owner on a new socket opens the same stored chat: resume by stored ID, the recovery bracket, saved history.
        val second = owner()
        val reopened = second.open(ref)
        eventually("reopened chat ready") { second.conversations.value[ref]?.phase == ConversationPhase.Ready && second.conversations.value[ref]?.sendBlock == null }
        eventually("reopened history") { second.texts(ref).size == 2 }
        assertEquals(repo.texts(ref), second.texts(ref))
        assertNull(second.conversations.value.getValue(ref).lastError)
        println("REAL-HOST reopen: phase=${second.conversations.value.getValue(ref).phase} rows=${second.texts(ref).size} initialPhase=${reopened.phase}")
    }

    @Test fun clarifyApprovalAndSecureInputReachTheRepositoryAndAreAnsweredOrDeclined() = runBlocking {
        val repo = owner()

        val question = repo.newChat("Synthetic question")
        assertTrue(repo.send(question, "question test") is SendResult.Admitted)
        eventually("clarify prompt") { repo.prompts.value.any { it.method == "clarify" } }
        val clarify = repo.prompts.value.first { it.method == "clarify" }
        val questions = (clarify.content as PromptContent.Clarification).questions
        assertEquals(PromptResult.Answered, repo.answerPrompt(clarify.id, PromptAnswer.Clarify(questions.associate { it.id to "Alpha" })))
        eventually("question turn ends") { repo.conversations.value.getValue(question).unresolved.isEmpty() && repo.prompts.value.isEmpty() }

        val approval = repo.newChat("Synthetic approval")
        assertTrue(repo.send(approval, "approval test") is SendResult.Admitted)
        eventually("approval prompt") { repo.prompts.value.any { it.method == "approval" } }
        val card = repo.prompts.value.first { it.method == "approval" }
        assertTrue((card.content as PromptContent.Approval).choices.contains(ApprovalChoice.Deny))
        assertTrue(card.domainRequestId != null && card.domainRequestId != card.wireId)
        assertEquals(PromptResult.Answered, repo.declinePrompt(card.id))
        eventually("approval turn ends") { repo.conversations.value.getValue(approval).unresolved.isEmpty() && repo.prompts.value.isEmpty() }
        assertTrue("The denied approval left the disposable directory in place", File(project, "approval-only-delete").isDirectory)

        // A numbered fixture no earlier run can have answered; it is declined, so nothing is ever stored.
        val secure = repo.newChat("Synthetic secure input")
        assertTrue(repo.send(secure, "secure input test 3") is SendResult.Admitted)
        eventually("secure prompt") { repo.prompts.value.any { it.method == "secret" } }
        val secret = repo.prompts.value.first { it.method == "secret" }
        assertEquals("SECURE_INPUT_FIXTURE_3", (secret.content as PromptContent.SecureInput).envVar)
        assertEquals(PromptResult.Answered, repo.declinePrompt(secret.id))
        eventually("secure turn ends") { repo.conversations.value.getValue(secure).unresolved.isEmpty() && repo.prompts.value.isEmpty() }
        println("REAL-HOST prompts: clarify, approval and secret raised, answered over the wire; secret declined")
    }

    @Test fun anActiveTurnSteersAndTheFinalReplyShowsTheCorrection() = runBlocking {
        val repo = owner()
        val ref = repo.newChat("Synthetic steer")
        assertTrue(repo.send(ref, "long tool test") is SendResult.Admitted)
        eventually("the turn is observed running") { repo.conversations.value.getValue(ref).running }
        val steer = repo.send(ref, "A synthetic steer")
        assertEquals(Admission.Steered, (steer as SendResult.Admitted).admission)
        eventually("the turn ends and its entries retire") { !repo.conversations.value.getValue(ref).running && repo.conversations.value.getValue(ref).unresolved.isEmpty() }
        eventually("the reply reflects the steer") { repo.texts(ref).any { it.contains("A synthetic steer") && it != "A synthetic steer" } }
    }

    @Test fun renameArchiveRestoreForkSearchAndModelOptionsAgainstTheRealHost() = runBlocking {
        val repo = owner()
        val ref = repo.newChat("Synthetic edits")
        assertTrue(repo.send(ref, "hello for the catalog") is SendResult.Admitted)
        eventually("turn ends") { repo.conversations.value.getValue(ref).unresolved.isEmpty() && !repo.conversations.value.getValue(ref).running }
        repo.refreshCatalog()
        assertTrue(repo.catalog.value.sessions.any { it.ref == ref || it.storedId == ref.anchor })
        // Hermes keeps titles unique, so each run names its chat afresh.
        val title = "Synthetic renamed ${java.util.UUID.randomUUID()}"
        repo.rename(ref, title)
        assertEquals(title, repo.conversations.value.getValue(ref).title)
        val found = repo.search("default", "catalog")
        println("REAL-HOST search: results=${found.size}")
        val modelResult = runCatching { repo.modelOptions(ref) }
        println("REAL-HOST modelOptions: ${modelResult.map { "ok providers=${it.providers.size}" }.getOrElse { "failed ${(it as? ChatException)?.error ?: it::class.simpleName}" }}")
        repo.archive(ref)
        assertTrue(repo.archivedChats().any { it.storedId == ref.anchor || it.ref == ref })
        repo.restore(ref)
        assertTrue(repo.catalog.value.sessions.any { it.storedId == ref.anchor || it.ref == ref })

        // Fork through the assistant's reply: the whole transcript is read, the host's count and messages are checked.
        val through = repo.conversations.value.getValue(ref).items.filterIsInstance<MessageItem>().last().rowId!!
        val child = repo.fork(ref, through)
        eventually("the fork is open") { repo.conversations.value[child]?.phase == ConversationPhase.Ready }
        assertTrue(child.anchor != ref.anchor)

        // Hermes refuses to delete a chat that is open on its gateway; nothing is forgotten locally when it does.
        val refused = runCatching { repo.delete(ref) }.exceptionOrNull() as ChatException
        assertEquals(ChatError.Kind.Rejected, refused.error.kind)
        println("REAL-HOST delete while open: code=${refused.error.code}")
        assertTrue(repo.conversations.value[ref] != null)
    }
}
