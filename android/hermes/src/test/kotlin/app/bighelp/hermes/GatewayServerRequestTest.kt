package app.bighelp.hermes

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Server-to-client requests: handlers, exact ownership of replies, opaque IDs, bounds and cancellation. */
class GatewayServerRequestTest : GatewayTestSupport() {
    private val empty = JsonObject(emptyMap())
    private fun idOf(frame: JsonObject) = frame["id"]!!.jsonPrimitive.content

    private suspend fun connected(): Pair<GatewayClient, ScriptedGateway.Conn> {
        val client = client()
        client.setServerRequestHandler("approval") { ServerResponse.Result(buildJsonObject { put("choice", "once"); put("all", false) }) }
        client.connect()
        return client to gateway.awaitConnection()
    }

    private fun serverRequest(id: String, method: String = "approval", params: String = """{"session_id":"s"}""") =
        ScriptedGateway.requestLine(id, method, params)

    /** The response frame for a server request ID (it has `result` or `error`, no `method`); frames may arrive in any order. */
    private fun ScriptedGateway.Conn.response(id: String): JsonObject {
        val deadline = System.nanoTime() + 5_000_000_000L
        while (System.nanoTime() < deadline) {
            allFrames.map { Json.parseToJsonElement(it).jsonObject }
                .firstOrNull { it["method"] == null && it["id"]?.jsonPrimitive?.content == id }?.let { return it }
            Thread.sleep(10)
        }
        throw AssertionError("No response for server request '$id'")
    }

    @Test fun aRegisteredHandlerAnswersWithTheSameIdAsAResponseEnvelope() = runBlocking {
        val (client, conn) = connected()
        conn.send(serverRequest("srv-1"))
        val response = conn.response("srv-1")
        assertEquals("""{"jsonrpc":"2.0","id":"srv-1","result":{"choice":"once","all":false}}""", response.toString())
        assertFalse("A response is never a new request", response.containsKey("method"))
        client.disconnect()
    }

    @Test fun anUnknownMethodGetsMethodNotFoundNeverABlankApproval() = runBlocking {
        val (client, conn) = connected()
        for (method in listOf("secret", "sudo", "vault.unlock_prompt", "terminal.read", "window.read", "preview.read", "tour", "mcp.setup")) {
            conn.send(serverRequest("unk-$method", method))
            val response = conn.response("unk-$method")
            assertEquals(
                """{"jsonrpc":"2.0","id":"unk-$method","error":{"code":-32601,"message":"Method not supported by this client"}}""",
                response.toString(),
            )
        }
        client.disconnect()
    }

    @Test fun handlerDecisionsComeFromTheHandlerAndCarryTheSocketGeneration() = runBlocking {
        val client = client()
        val seen = CopyOnWriteArrayList<IncomingServerRequest>()
        client.setServerRequestHandler("clarify") { request ->
            seen += request
            ServerResponse.Result(buildJsonObject { put("answer", request.params["question"]!!.jsonPrimitive.content.uppercase()) })
        }
        client.connect()
        val conn = gateway.awaitConnection()
        conn.send(serverRequest("c1", "clarify", """{"session_id":"s","question":"which?"}"""))
        assertEquals("""{"answer":"WHICH?"}""", conn.response("c1")["result"].toString())
        assertEquals(client.state.value.generation, seen.single().generation)
        assertEquals("c1", seen.single().id)
        assertEquals("clarify", seen.single().method)
        client.disconnect()
    }

    @Test fun idsAreOpaqueBytesIncludingEmptyWhitespaceAndCanonicallyEquivalentOnes() = runBlocking {
        val client = client()
        val calls = ConcurrentHashMap<String, Int>()
        client.setServerRequestHandler("approval") { request ->
            calls.merge(request.id, 1, Int::plus)
            ServerResponse.Result(empty)
        }
        client.connect()
        val conn = gateway.awaitConnection()
        val ids = listOf("", " ", " padded ", "é", "é", "UPPER", "upper", "a b")
        ids.forEach { conn.send(serverRequest(it)) }
        ids.forEach { assertEquals(it, it, conn.response(it)["id"]!!.jsonPrimitive.content) }
        assertEquals("Every distinct byte sequence was its own request", ids.size, calls.size)
        assertTrue(calls.values.all { it == 1 })
        client.disconnect()
    }

    @Test fun aDuplicateOpenIdIsIgnoredNoSecondDecisionNoSecondResponse() = runBlocking {
        val client = client()
        val release = CompletableDeferred<Unit>()
        val invocations = AtomicInteger()
        client.setServerRequestHandler("approval") { invocations.incrementAndGet(); release.await(); ServerResponse.Result(empty) }
        client.connect()
        val conn = gateway.awaitConnection()
        conn.send(serverRequest("dup"))
        conn.send(serverRequest("dup"))
        conn.send(serverRequest("dup", params = """{"session_id":"other"}"""))
        delay(250)
        assertEquals(1, invocations.get())
        release.complete(Unit)
        conn.response("dup")
        delay(250)
        assertEquals("Exactly one response", 1, conn.allFrames.count { """"id":"dup"""" in it && """"result"""" in it })
        client.disconnect()
    }

    @Test fun atMostSixtyFourOpenRequestsAndTheNextOneIsIgnored() = runBlocking {
        val client = client()
        val release = CompletableDeferred<Unit>()
        val handled = CopyOnWriteArrayList<String>()
        client.setServerRequestHandler("approval") { handled += it.id; release.await(); ServerResponse.Result(empty) }
        client.connect()
        val conn = gateway.awaitConnection()
        repeat(64) { conn.send(serverRequest("open-$it")) }
        eventually { handled.size == 64 }
        conn.send(serverRequest("overflow"))
        delay(250)
        assertFalse("The 65th was never handled", "overflow" in handled)
        release.complete(Unit)
        eventually { conn.allFrames.count { it.contains(""""result"""") && it.contains("open-") } == 64 }
        assertTrue("and never answered", conn.allFrames.none { """"id":"overflow"""" in it })
        conn.send(serverRequest("after-room"))
        conn.response("after-room")
        client.disconnect()
    }

    @Test fun aMatchingCancelCancelsTheHandlerAndNothingIsSentEvenIfItFinishesLate() = runBlocking {
        val client = client()
        val cancelled = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<Unit>()
        client.setServerRequestHandler("approval") {
            try {
                gate.await()
                ServerResponse.Result(empty)
            } catch (e: kotlinx.coroutines.CancellationException) {
                cancelled.complete(Unit)
                throw e
            }
        }
        client.connect()
        val conn = gateway.awaitConnection()
        conn.send(serverRequest("k1"))
        delay(150)
        conn.event("request.cancel", """{"id":"k1","method":"approval","reason":"expired"}""")
        cancelled.await()
        gate.complete(Unit)
        delay(250)
        assertTrue(conn.allFrames.none { """"id":"k1"""" in it })
        // The ID is free again after retirement.
        conn.send(serverRequest("k1"))
        client.disconnect()
    }

    @Test fun aCancelForAnotherMethodOrIdCannotRetireAPrompt() = runBlocking {
        val client = client()
        val gate = CompletableDeferred<Unit>()
        val cancelled = AtomicInteger()
        client.setServerRequestHandler("approval") {
            try { gate.await(); ServerResponse.Result(empty) } catch (e: kotlinx.coroutines.CancellationException) { cancelled.incrementAndGet(); throw e }
        }
        client.connect()
        val conn = gateway.awaitConnection()
        conn.send(serverRequest("m1"))
        delay(150)
        conn.event("request.cancel", """{"id":"m1","method":"clarify","reason":"wrong method"}""")
        conn.event("request.cancel", """{"id":"other","method":"approval","reason":"wrong id"}""")
        delay(250)
        assertEquals(0, cancelled.get())
        gate.complete(Unit)
        conn.response("m1")
        client.disconnect()
    }

    @Test fun aMalformedCancelIsAFramingErrorAndClosesTheConnection() = runBlocking {
        val client = client(timings = GatewayTimings(readyMillis = 2_000, reconnectDelaysMillis = listOf(0)))
        client.setServerRequestHandler("approval") { ServerResponse.Result(empty) }
        client.connect()
        val conn = gateway.awaitConnection()
        conn.event("request.cancel", """{"id":"m1","method":"approval","reason":"x","extra":1}""")
        eventually { conn.closedByClient }
        client.disconnect()
    }

    @Test fun aHandlerThatFailsAnswersWithAnInternalErrorNotSilenceOrAFakeApproval() = runBlocking {
        val client = client()
        client.setServerRequestHandler("approval") { throw IllegalStateException("boom /private/path") }
        client.connect()
        val conn = gateway.awaitConnection()
        conn.send(serverRequest("boom"))
        val response = conn.response("boom")
        assertEquals(-32603L, response["error"]!!.jsonObject["code"]!!.jsonPrimitive.content.toLong())
        assertTrue("private" !in response.toString())
        assertNull(response["result"])
        client.disconnect()
    }

    @Test fun aResponseThatCannotBeEncodedWithinLimitsBecomesAConstantError() = runBlocking {
        val client = client()
        client.setServerRequestHandler("approval") { ServerResponse.Result(JsonPrimitive("x".repeat(2 * 1_024 * 1_024 + 10))) }
        client.setServerRequestHandler("clarify") { ServerResponse.Failure(1, "") }
        client.connect()
        val conn = gateway.awaitConnection()
        conn.send(serverRequest("big"))
        assertEquals("""{"jsonrpc":"2.0","id":"big","error":{"code":-32603,"message":"Client could not encode the response"}}""", conn.response("big").toString())
        conn.send(serverRequest("empty", "clarify"))
        assertEquals(-32603L, conn.response("empty")["error"]!!.jsonObject["code"]!!.jsonPrimitive.content.toLong())
        client.disconnect()
    }

    @Test fun aResponseCompletingAfterTheSocketChangedIsNeverSentToTheReplacement() = runBlocking {
        val client = client()
        val gate = CompletableDeferred<Unit>()
        client.setServerRequestHandler("approval") { try { gate.await() } catch (e: kotlinx.coroutines.CancellationException) { awaitCancellation() }; ServerResponse.Result(empty) }
        client.connect()
        val first = gateway.awaitConnection()
        first.send(serverRequest("stale"))
        delay(150)
        first.drop()
        eventually { gateway.all.size == 2 && client.state.value.isConnected }
        gate.complete(Unit)
        delay(300)
        assertTrue(gateway.all.flatMap { it.allFrames }.none { """"id":"stale"""" in it })
        client.disconnect()
    }

    @Test fun openRequestsFromARecoverySnapshotAreValidatedWholeThenAdoptedThroughTheSameHandlers() = runBlocking {
        val (client, conn) = connected()
        val generation = client.state.value.generation
        fun rows(vararg row: String) = Json.parseToJsonElement("[${row.joinToString()}]")
        val good = """{"id":"adopt-1","method":"approval","params":{"session_id":"rt-1"}}"""
        val wrongRuntime = """{"id":"adopt-2","method":"approval","params":{"session_id":"rt-2"}}"""
        val extraKey = """{"id":"adopt-3","method":"approval","params":{"session_id":"rt-1"},"extra":1}"""
        val noParams = """{"id":"adopt-4","method":"approval"}"""

        for (bad in listOf(rows(good, wrongRuntime), rows(good, extraKey), rows(good, noParams), JsonPrimitive("x"), JsonArray(List(65) { Json.parseToJsonElement(good.replace("adopt-1", "n$it")) }))) {
            assertThrows(HermesException::class.java) { runBlocking { client.adoptOpenRequests(bad, "rt-1", generation) } }
        }
        delay(150)
        assertTrue("Nothing from a rejected snapshot was adopted", conn.allFrames.none { "adopt-" in it })
        assertThrows(HermesException::class.java) { runBlocking { client.adoptOpenRequests(rows(good), "rt-1", generation + 1) } }

        client.adoptOpenRequests(rows(good), "rt-1", generation)
        assertEquals("""{"jsonrpc":"2.0","id":"adopt-1","result":{"choice":"once","all":false}}""", conn.response("adopt-1").toString())
        client.disconnect()
    }
}
