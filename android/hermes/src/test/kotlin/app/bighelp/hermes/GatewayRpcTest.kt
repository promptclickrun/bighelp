package app.bighelp.hermes

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
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

/** RPC correlation, failures, limits, timeouts and cancellation over a real socket. Nothing is ever resent. */
class GatewayRpcTest : GatewayTestSupport() {
    private suspend fun connected(): Pair<GatewayClient, ScriptedGateway.Conn> {
        val client = client()
        client.connect()
        return client to gateway.awaitConnection()
    }

    private fun method(frame: JsonObject) = frame["method"]!!.jsonPrimitive.content
    private fun id(frame: JsonObject) = frame["id"]!!.jsonPrimitive.content

    @Test fun requestsAreWrittenAsJsonRpcWithUniqueStringIdsAndCorrelatedByExactId() = runBlocking {
        val (client, conn) = connected()
        val first = async(kotlinx.coroutines.Dispatchers.Default) { client.request("profiles.list", params("a" to "1")) }
        val second = async(kotlinx.coroutines.Dispatchers.Default) { client.request("session.usage", params("b" to "2")) }
        val a = conn.awaitMethod("profiles.list")
        val b = conn.awaitMethod("session.usage")
        assertEquals("""{"a":"1"}""", a["params"].toString())
        assertEquals(setOf("jsonrpc", "id", "method", "params"), a.keys)
        assertTrue(id(a) != id(b))
        conn.result(id(b), """{"which":"second"}""") // out of order on purpose
        conn.result(id(a), """{"which":"first"}""")
        assertEquals("first", first.await().jsonObject["which"]!!.jsonPrimitive.content)
        assertEquals("second", second.await().jsonObject["which"]!!.jsonPrimitive.content)
        client.disconnect()
    }

    @Test fun rpcFailuresKeepCodeReasonAndFlattenedWords() = runBlocking {
        val (client, conn) = connected()
        val busy = async(kotlinx.coroutines.Dispatchers.Default) { runCatching { client.request("session.create") } }
        conn.failure(id(conn.awaitMethod("session.create")), 4090, "Active session limit reached", """{"reason":"MAX_CONCURRENT_SESSIONS"}""")
        val limit = busy.await().exceptionOrNull() as HermesException
        assertEquals(HermesException.Kind.ActiveSessionLimit, limit.kind)
        assertEquals(4090L, limit.code)
        assertEquals("MAX_CONCURRENT_SESSIONS", limit.reason)

        val owned = async(kotlinx.coroutines.Dispatchers.Default) { runCatching { client.request("session.resume") } }
        conn.failure(id(conn.awaitMethod("session.resume")), 4090, "Held\nby\tanother‮process", """{"reason":"SESSION_NOT_OWNED"}""")
        val held = owned.await().exceptionOrNull() as HermesException
        assertEquals("Plain 4090 is not the open-chat cap", HermesException.Kind.RpcRejected, held.kind)
        assertEquals("Held by another process", held.refusal)
        assertEquals("SESSION_NOT_OWNED", held.reason)
        assertFalse(held.outcomeUnknown)
        assertEquals("RpcRejected", held.message)
        client.disconnect()
    }

    @Test fun unknownLateAndCollidingRepliesNeverResolveTheWrongRequest() = runBlocking {
        val (client, conn) = connected()
        conn.result("never-sent", """{"x":1}""")
        conn.failure("also-never-sent", 5)
        val pending = async(kotlinx.coroutines.Dispatchers.Default) { client.request("profiles.list") }
        val frame = conn.awaitMethod("profiles.list")
        // A server request that reuses the client's own ID, and a stray response for an open server request ID.
        client.setServerRequestHandler("approval") { ServerResponse.Result(JsonObject(emptyMap())) }
        conn.send(ScriptedGateway.requestLine(id(frame), "approval", """{"session_id":"s"}"""))
        conn.awaitFrame { it["result"] != null && id(it) == id(frame) } // the response to the SERVER request
        assertFalse("The server's request did not complete the client's RPC", pending.isCompleted)
        conn.result(id(frame), """{"real":true}""")
        assertEquals(true, pending.await().jsonObject["real"]!!.jsonPrimitive.content.toBoolean())
        conn.result(id(frame), """{"duplicate":true}""") // late duplicate is ignored
        assertEquals(GatewayConnection.Connected, client.state.value.connection)
        client.disconnect()
    }

    @Test fun invalidMethodsAndOversizeFramesAreRefusedBeforeSending() = runBlocking {
        val (client, conn) = connected()
        for (bad in listOf("", "has space", "tab\t", "é", "m".repeat(257))) {
            assertKind(HermesException.Kind.InvalidResponse) { client.request(bad) }
        }
        val huge = buildJsonObject { put("blob", "x".repeat(GatewayClient.DEFAULT_FRAME_BYTES)) }
        assertKind(HermesException.Kind.MessageTooLarge) { client.request("profiles.list", huge) }
        var nested: kotlinx.serialization.json.JsonElement = JsonObject(emptyMap())
        repeat(70) { nested = buildJsonObject { put("n", nested) } }
        assertKind(HermesException.Kind.MessageTooLarge) { client.request("profiles.list", buildJsonObject { put("deep", nested) }) }
        delay(100)
        assertTrue(conn.framesWithMethod("profiles.list").isEmpty())
        // A larger, explicitly allowed frame (file attachments) still has its own ceiling.
        assertKind(HermesException.Kind.MessageTooLarge) {
            client.request("file.attach", huge, maximumFrameBytes = 1_024)
        }
        client.disconnect()
    }

    @Test fun atMostSixtyFourRequestsArePending() = runBlocking {
        val (client, conn) = connected()
        val pending = (1..64).map { async(kotlinx.coroutines.Dispatchers.Default) { runCatching { client.request("profiles.list", params("n" to "$it")) } } }
        eventually { conn.framesWithMethod("profiles.list").size == 64 }
        assertKind(HermesException.Kind.TooManyRequests) { client.request("profiles.list") }
        conn.framesWithMethod("profiles.list").forEach { conn.result(id(it)) }
        assertTrue(pending.awaitAll().all { it.isSuccess })
        assertEquals(64, conn.framesWithMethod("profiles.list").size)
        client.request("gateway.ping") // the table is free again
        client.disconnect()
    }

    @Test fun onlyOneAttachmentRpcMayBeOutstandingAndItsFrameCeilingIsHigher() = runBlocking {
        gateway.responder = { conn, frame ->
            when (method(frame)) {
                "file.attach" -> Unit // held until the test answers it
                "image.attach_bytes" -> conn.result(id(frame))
                else -> gateway.defaultResponse(conn, frame)
            }
        }
        val (client, conn) = connected()
        val big = buildJsonObject { put("blob", "x".repeat(3 * 1_024 * 1_024)) } // over the 2 MiB ordinary ceiling
        assertKind(HermesException.Kind.MessageTooLarge) { client.request("profiles.list", big) }
        val first = async(kotlinx.coroutines.Dispatchers.Default) {
            runCatching { client.request("file.attach", big, maximumFrameBytes = GatewayClient.ATTACHMENT_FRAME_BYTES) }
        }
        val sent = conn.awaitMethod("file.attach")
        assertKind(HermesException.Kind.TooManyRequests) { client.request("image.attach_bytes", params("a" to "b")) }
        assertKind(HermesException.Kind.MessageTooLarge) {
            client.request("file.attach", big, maximumFrameBytes = GatewayClient.ATTACHMENT_FRAME_BYTES + 1)
        }
        conn.result(id(sent))
        assertTrue(first.await().isSuccess)
        client.request("image.attach_bytes", params("a" to "b")).let { } // free again after the reply
        client.disconnect()
    }

    @Test fun anUnansweredReadTimesOutThenTheSocketIsReplacedByTheAutomaticRecovery() = runBlocking {
        gateway.responder = { conn, frame -> if (method(frame) != "profiles.list") gateway.defaultResponse(conn, frame) }
        val client = client(timings = GatewayTimings(requestMillis = 400, readyMillis = 2_000, reconnectDelaysMillis = listOf(0, 50)))
        client.connect()
        val first = gateway.awaitConnection()
        val failure = assertThrows(HermesException::class.java) { runBlocking { client.request("profiles.list") } }
        assertEquals(HermesException.Kind.TimedOut, failure.kind)
        assertFalse("A read is not an uncertain mutation", failure.outcomeUnknown)
        eventually { first.closedByClient }
        eventually { gateway.all.size == 2 && client.state.value.isConnected }
        assertEquals("The timed-out read was not replayed", 1, first.framesWithMethod("profiles.list").size)
        assertTrue(gateway.all[1].framesWithMethod("profiles.list").isEmpty())
        client.disconnect()
    }

    @Test fun aTimedOutMutationIsATypedUncertainOutcomeAndNeverResent() = runBlocking {
        gateway.responder = { conn, frame -> if (method(frame) != "session.interrupt") gateway.defaultResponse(conn, frame) }
        val client = client(timings = GatewayTimings(requestMillis = 400, readyMillis = 2_000, reconnectDelaysMillis = listOf(0)))
        client.connect()
        val first = gateway.awaitConnection()
        val failure = assertThrows(HermesException::class.java) { runBlocking { client.request("session.interrupt", params("session_id" to "s")) } }
        assertEquals(HermesException.Kind.TimedOut, failure.kind)
        assertTrue(failure.outcomeUnknown)
        eventually { gateway.all.size == 2 && client.state.value.isConnected }
        assertEquals(1, first.framesWithMethod("session.interrupt").size)
        assertTrue("Never resent on the replacement socket", gateway.all[1].framesWithMethod("session.interrupt").isEmpty())
        client.disconnect()
    }

    @Test fun cancellingASentRequestIsLocalOnlyTheFrameIsNotRecalledOrResentAndTheConnectionStays() = runBlocking {
        gateway.responder = { conn, frame ->
            when (method(frame)) {
                "prompt.submit" -> Unit // the host works on it silently
                "profiles.list" -> conn.result(id(frame))
                else -> gateway.defaultResponse(conn, frame)
            }
        }
        val (client, conn) = connected()
        val call = async(kotlinx.coroutines.Dispatchers.Default) { client.request("prompt.submit", params("text" to "hello")) }
        conn.awaitMethod("prompt.submit")
        call.cancel()
        assertThrows(CancellationException::class.java) { runBlocking { call.await() } }
        delay(300)
        assertEquals("The one frame stays at exactly one", 1, conn.framesWithMethod("prompt.submit").size)
        assertEquals("Cancelling is not an interrupt and does not drop the socket", 1, gateway.all.size)
        assertEquals(GatewayConnection.Connected, client.state.value.connection)
        client.request("profiles.list").let { } // the same connection still works
        assertTrue(DispatchPolicy.isUncertain("prompt.submit", DispatchOutcome.MayHaveBeenSent))
        client.disconnect()
    }

    @Test fun theCancelledCoroutineSeesTheDispatchOutcome() = runBlocking {
        gateway.responder = { conn, frame -> if (method(frame) != "prompt.submit") gateway.defaultResponse(conn, frame) }
        val (client, conn) = connected()
        var seen: Throwable? = null
        val job = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default).async(kotlinx.coroutines.Dispatchers.Default) {
            try {
                client.request("prompt.submit", params("text" to "hello"))
            } catch (e: CancellationException) {
                seen = e
                throw e
            }
        }
        conn.awaitMethod("prompt.submit")
        job.cancel()
        eventually { seen != null }
        assertEquals(DispatchOutcome.MayHaveBeenSent, (seen as RequestCancelledException).dispatch)
        client.disconnect()
    }

    @Test fun aSocketClosedDuringAMutationFailsItAsUncertainAndNeverReconnectsOnItsOwn() = runBlocking {
        gateway.responder = { conn, frame ->
            if (method(frame) == "prompt.submit") conn.drop() else gateway.defaultResponse(conn, frame)
        }
        val (client, first) = connected()
        val failure = assertThrows(HermesException::class.java) { runBlocking { client.request("prompt.submit", params("text" to "hello")) } }
        assertEquals(HermesException.Kind.Disconnected, failure.kind)
        assertTrue("Possibly accepted: typed uncertain", failure.outcomeUnknown)
        delay(500)
        assertEquals("No automatic reconnect hides an uncertain mutation", 1, gateway.all.size)
        assertEquals(GatewayConnection.Idle, client.state.value.connection)
        assertTrue(client.state.value.lastFailure != null)

        gateway.responder = { conn, frame -> gateway.defaultResponse(conn, frame) }
        assertEquals(GatewayConnection.Connected, client.reconnect().connection)
        val second = gateway.awaitConnection()
        assertEquals(2, gateway.all.size)
        assertTrue("The explicit reconnect never replays the lost submit", second.framesWithMethod("prompt.submit").isEmpty())
        assertEquals(1, first.framesWithMethod("prompt.submit").size)
        client.disconnect()
    }

    @Test fun requestsDuringNoConnectionFailWithoutSending() = runBlocking {
        val client = client()
        assertKind(HermesException.Kind.NotConnected) { client.request("profiles.list") }
        assertEquals(0, gateway.all.size)
        assertNull(client.state.value.owner)
    }
}
