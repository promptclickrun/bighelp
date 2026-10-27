package app.bighelp.hermes.chat

import app.bighelp.hermes.GatewayClient
import app.bighelp.hermes.GatewayTestSupport
import app.bighelp.hermes.ScriptedGateway
import app.bighelp.hermes.ScriptedHost
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The repository on the real [GatewayClient]: real WebSocket frames from a scripted loopback gateway. This shows
 * what the in-memory fake cannot: that the handlers are registered before the first socket's advertisement, that
 * server requests and their cancellation are matched by the transport, and that a lost receipt on a real socket
 * is never resent across a reconnect.
 */
class GatewayChatIntegrationTest : GatewayTestSupport() {
    private val chatScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val ref = ConversationRef("research", "saved-1")
    private val dropOnSubmit = AtomicBoolean(false)

    @After fun stopChat() { chatScope.cancel() }

    private fun info(): String = """{"profile_name":"research","stored_session_id":"saved-1","model":"m","provider":"p","reasoning_effort":"medium","lazy":false}"""

    private fun wireUpHost() {
        gateway.responder = { conn, frame ->
            val id = frame["id"]?.jsonPrimitive?.content
            when (frame["method"]?.jsonPrimitive?.content) {
                "session.resume" -> conn.result(id!!, """{"session_id":"rt-live","stored_session_id":"saved-1","session_key":"saved-1","resumed":"saved-1","running":false,"messages":[],"messages_omitted":true,"info":${info()}}""")
                "session.activate" -> conn.result(id!!, """{"session_id":"rt-live","session_key":"saved-1","running":false,"messages":[],"messages_omitted":true,"info":${info()}}""")
                "session.events.since" -> conn.result(id!!, """{"epoch":"epoch-1","latest_seq":0,"truncated":false,"events":[],"open_requests":[]}""")
                "prompt.submit" -> if (dropOnSubmit.get()) conn.drop() else conn.result(id!!, """{"status":"streaming","user_row_id":7}""")
                else -> gateway.defaultResponse(conn, frame)
            }
        }
        gateway.host.on("GET", "/api/sessions/saved-1/messages") {
            ScriptedHost.json("""{"session_id":"saved-1","profile":"research","messages":[],"pagination":{"offset":0,"limit":200,"order":"latest","returned":0}}""")
        }
    }

    private suspend fun awaitUntil(message: String, timeoutMillis: Long = 8_000, condition: () -> Boolean) {
        eventually(timeoutMillis, condition)
    }

    private fun ScriptedGateway.Conn.responseTo(id: String): JsonObject? =
        allFrames.map { Json.parseToJsonElement(it).jsonObject }.firstOrNull { it["method"] == null && it["id"]?.jsonPrimitive?.content == id }

    @Test fun aRepositoryBuiltBeforeConnectBacksTheFirstAdvertisementAndMatchesCancellationByIdAndMethod() = runBlocking {
        wireUpHost()
        val authenticator = authenticator()
        val client = GatewayClient(authenticator, chatScope, fast)
        val repo = HermesChatRepository(client, authenticator, chatScope, ChatTestData.host, MemoryChatStore())
        client.connect()
        val conn = gateway.awaitConnection()
        assertEquals("Handlers existed before the socket, so the host's first advertisement was honest", 1, conn.framesWithMethod("client.capabilities").size)

        repo.open(ref)
        awaitUntil("ready") { repo.conversations.value[ref]?.phase == ConversationPhase.Ready && repo.conversations.value[ref]?.sendBlock == null }

        conn.send(ScriptedGateway.requestLine("wire-A", "approval", """{"session_id":"rt-live","request_id":"domain-1","choices":["once","deny"]}"""))
        awaitUntil("prompt shown") { repo.prompts.value.size == 1 }
        val prompt = repo.prompts.value.single()
        assertEquals("wire-A", prompt.wireId)
        assertEquals("domain-1", prompt.domainRequestId)

        // A cancel naming the right ID but another method retires nothing.
        conn.event("request.cancel", """{"id":"wire-A","method":"clarify","reason":"expired"}""")
        delay(300)
        assertEquals(1, repo.prompts.value.size)
        // Answering writes the response with the original wire ID, once.
        assertEquals(PromptResult.Answered, repo.answerPrompt(prompt.id, PromptAnswer.Approve(ApprovalChoice.Once)))
        awaitUntil("response written") { conn.responseTo("wire-A") != null }
        assertEquals("""{"jsonrpc":"2.0","id":"wire-A","result":{"choice":"once","all":false}}""", conn.responseTo("wire-A").toString())

        // The exact ID and method retire the prompt, and no response is ever written for it.
        conn.send(ScriptedGateway.requestLine("wire-B", "approval", """{"session_id":"rt-live","request_id":"domain-2","choices":["once"]}"""))
        awaitUntil("second prompt") { repo.prompts.value.size == 1 }
        conn.event("request.cancel", """{"id":"wire-B","method":"approval","reason":"expired"}""")
        awaitUntil("second prompt retired") { repo.prompts.value.isEmpty() }
        delay(200)
        assertEquals(null, conn.responseTo("wire-B"))

        // A request for a runtime this repository does not hold fails explicitly with -32602.
        conn.send(ScriptedGateway.requestLine("wire-C", "approval", """{"session_id":"nobody","request_id":"d3","choices":["once"]}"""))
        awaitUntil("explicit failure") { conn.responseTo("wire-C") != null }
        assertEquals(-32602L, conn.responseTo("wire-C")!!["error"]!!.jsonObject["code"]!!.jsonPrimitive.content.toLong())
        // An unknown method is the transport's -32601.
        conn.send(ScriptedGateway.requestLine("wire-D", "mcp.setup", """{"session_id":"rt-live"}"""))
        awaitUntil("method not supported") { conn.responseTo("wire-D") != null }
        assertEquals(-32601L, conn.responseTo("wire-D")!!["error"]!!.jsonObject["code"]!!.jsonPrimitive.content.toLong())
        repo.close()
        client.disconnect()
    }

    @Test fun aLostReceiptOnARealSocketIsUncertainAndNeverResentAcrossTheReconnect() = runBlocking {
        wireUpHost()
        val authenticator = authenticator()
        val client = GatewayClient(authenticator, chatScope, fast)
        val repo = HermesChatRepository(client, authenticator, chatScope, ChatTestData.host, MemoryChatStore())
        client.connect()
        val first = gateway.awaitConnection()
        repo.open(ref)
        awaitUntil("ready") { repo.conversations.value[ref]?.sendBlock == null && repo.conversations.value[ref]?.phase == ConversationPhase.Ready }

        dropOnSubmit.set(true)
        val result = repo.send(ref, "please do the thing")
        assertTrue("$result", result is SendResult.Uncertain)
        assertEquals("The journaled entry is the only record of it", 1, repo.conversations.value.getValue(ref).unresolved.size)

        // The client does not reconnect after an uncertain mutation; the owner asks, and nothing is replayed.
        dropOnSubmit.set(false)
        repo.reconnect()
        val second = gateway.awaitConnection()
        awaitUntil("reattached on the new socket") { repo.conversations.value[ref]?.phase == ConversationPhase.Ready && repo.conversations.value[ref]?.sendBlock == null }
        val submits = (first.framesWithMethod("prompt.submit") + second.framesWithMethod("prompt.submit"))
        assertEquals("Exactly one prompt.submit ever left the device", 1, submits.size)
        assertEquals(1, second.framesWithMethod("session.resume").size)
        assertEquals("The new socket advertised again with the handlers re-registered", 1, second.framesWithMethod("client.capabilities").size)
        assertFalse(repo.conversations.value.getValue(ref).unresolved.isEmpty())
        repo.close()
        client.disconnect()
    }
}
