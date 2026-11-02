package app.bighelp.hermes.chat

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.rules.Timeout

/** Waits for [this] for a bounded time and fails the test with [message], not with a bare timeout. */
suspend fun <T> kotlinx.coroutines.Deferred<T>.awaitWithin(message: String, timeoutMillis: Long = 5_000): T = try {
    withTimeout(timeoutMillis) { await() }
} catch (e: kotlinx.coroutines.TimeoutCancellationException) {
    throw AssertionError("Timed out waiting for $message")
}

/** One repository over a scripted host and a store, with helpers to wait for asynchronous state. */
internal class ChatRig(
    val host: FakeHermesHost = FakeHermesHost(),
    val store: ChatStore = MemoryChatStore(),
    val config: ChatConfig = ChatConfig(),
) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val repo = HermesChatRepository(host, host, scope, ChatTestData.host, store, config)

    suspend fun eventually(timeoutMillis: Long = 5_000, message: String = "condition", condition: suspend () -> Boolean) {
        try {
            withTimeout(timeoutMillis) { while (!condition()) delay(5) }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("Timed out waiting for $message")
        }
    }

    fun state(ref: ConversationRef): ConversationState = repo.conversations.value.getValue(ref)

    suspend fun awaitState(ref: ConversationRef, message: String = "state", predicate: (ConversationState) -> Boolean): ConversationState {
        eventually(message = message) { repo.conversations.value[ref]?.let(predicate) == true }
        return state(ref)
    }

    /** A new empty chat for [profile], opened and covered. */
    suspend fun newChat(profile: String = "research", request: CreateRequest = CreateRequest()): ConversationRef {
        val outcome = repo.createChat(profile, request)
        val ref = (outcome as? CreateOutcome.Created)?.ref ?: throw AssertionError("create failed: $outcome")
        awaitState(ref, "ready") { it.phase == ConversationPhase.Ready }
        return ref
    }

    /** A saved chat with [rows] user/assistant pairs on the host, opened and covered. */
    suspend fun savedChat(profile: String = "research", pairs: Int = 2, build: FakeHermesHost.Session.() -> Unit = {}): ConversationRef {
        val session = host.addSession(profile) {
            repeat(pairs) { addRow("user", "question $it"); addRow("assistant", "answer $it") }
            build()
        }
        val ref = ConversationRef(profile, session.id)
        repo.open(ref)
        awaitState(ref, "ready") { it.phase == ConversationPhase.Ready }
        return ref
    }

    fun runtimeOf(ref: ConversationRef): FakeHermesHost.Runtime =
        host.runtimes.values.last { it.stored == state(ref).identity.storedTip }

    fun close() {
        repo.close()
        scope.cancel()
    }
}

/** JUnit base: a bounded runtime for every test, and a rig per test. */
abstract class ChatTestBase {
    @get:Rule val timeout: Timeout = Timeout.seconds(60)
    private val rigs = ArrayList<ChatRig>()
    protected val directory: File = Files.createTempDirectory("chat-test").toFile()

    internal fun rig(host: FakeHermesHost = FakeHermesHost(), store: ChatStore = MemoryChatStore(), config: ChatConfig = ChatConfig()): ChatRig =
        ChatRig(host, store, config).also { rigs += it }

    @After fun closeRigs() {
        rigs.forEach { runCatching { it.close() } }
        directory.deleteRecursively()
    }

    protected fun run(block: suspend () -> Unit) { runBlocking { block() } }

    protected fun assertThrowsChat(kind: ChatError.Kind, block: suspend () -> Unit) {
        val e = runCatching { runBlocking { block() } }.exceptionOrNull()
        assertTrue("Expected ChatException($kind) but got $e", e is ChatException)
        assertEquals(kind, (e as ChatException).error.kind)
    }
}
