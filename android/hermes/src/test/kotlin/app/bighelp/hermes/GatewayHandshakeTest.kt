package app.bighelp.hermes

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Authentication of the upgrade, the ready gate and the startup sequence over a real WebSocket. */
class GatewayHandshakeTest : GatewayTestSupport() {
    private val handler = ServerRequestHandler { ServerResponse.Result(kotlinx.serialization.json.JsonObject(emptyMap())) }

    @Test fun aBearerUpgradeOffersTheSubprotocolWithAFreshTicketForEverySocket() = runBlocking {
        gateway.negotiatedSubprotocol = "hermes-gateway-v1"
        val client = client(bearer = true)
        client.connect()
        val first = gateway.awaitConnection()
        assertEquals("hermes-gateway-v1, hermes-gateway-ticket.ticket_1", first.request.getHeader("Sec-WebSocket-Protocol"))
        assertEquals("/hermes/api/ws", first.request.path)
        assertNull("A provider token never rides the gateway request", first.request.getHeader("Authorization"))
        assertNull(first.request.getHeader("Cookie"))
        assertNull(first.request.getHeader("X-Hermes-Session-Token"))

        first.drop()
        eventually { gateway.all.size == 2 && client.state.value.isConnected && client.state.value.generation == 2L }
        assertEquals("hermes-gateway-v1, hermes-gateway-ticket.ticket_2", gateway.all[1].request.getHeader("Sec-WebSocket-Protocol"))
        assertEquals("Bearer access-1", gateway.ticketRequests.first())
        client.disconnect()
    }

    @Test fun aTicketedUpgradeMustNegotiateTheGatewaySubprotocol() {
        for (negotiated in listOf(null, "other", "hermes-gateway-ticket.ticket_1")) {
            gateway.negotiatedSubprotocol = negotiated
            val client = client(bearer = true)
            assertKind(HermesException.Kind.InvalidResponse) { client.connect() }
            assertEquals(GatewayConnection.Idle, client.state.value.connection)
        }
    }

    @Test fun aDashboardUpgradeCarriesTheTokenInTheQueryAndTheHeaderAndOffersNoSubprotocol() = runBlocking {
        val client = client()
        client.connect()
        val conn = gateway.awaitConnection()
        assertEquals("/hermes/api/ws?token=dash-token", conn.request.path)
        assertEquals("dash-token", conn.request.getHeader("X-Hermes-Session-Token"))
        assertNull(conn.request.getHeader("Sec-WebSocket-Protocol"))
        assertNull(conn.request.getHeader("Cookie"))
        client.disconnect()
    }

    @Test fun gateHeadersRideTheUpgradeAndEveryHealthRequestAndNoCookieIsSent() = runBlocking {
        val access = AccessHeaders.of(
            gateway.host.endpoint, AccessCredential.proxyBasic("gate-user", "gate-pass"), listOf(CustomHeader.of("X-Gate", "g1")),
        )
        val client = client(access = access)
        client.connect()
        val conn = gateway.awaitConnection()
        assertEquals("Basic Z2F0ZS11c2VyOmdhdGUtcGFzcw==", conn.request.getHeader("Authorization"))
        assertEquals("g1", conn.request.getHeader("X-Gate"))
        assertEquals("dash-token", conn.request.getHeader("X-Hermes-Session-Token"))
        assertNull(conn.request.getHeader("Cookie"))
        val health = gateway.host.callsTo("/api/health").single()
        assertEquals("g1", health.getHeader("X-Gate"))
        client.disconnect()
    }

    @Test fun nothingIsWrittenBeforeGatewayReadyAndPublicRequestsAreRefusedUntilThen() = runBlocking {
        gateway.readyDelayMillis = 400
        val client = client()
        client.setServerRequestHandler("approval", handler)
        val connecting = async(kotlinx.coroutines.Dispatchers.Default) { client.connect() }
        val conn = gateway.awaitConnection()
        assertEquals(GatewayConnection.Connecting, client.state.value.connection)
        assertKind(HermesException.Kind.NotConnected) { client.request("gateway.ping") }
        delay(150)
        assertFalse("No frame before gateway.ready", conn.hasFrame())
        connecting.await()
        assertTrue(conn.firstFrameNanos > conn.readySentNanos)
        client.disconnect()
    }

    @Test fun aServerRequestBeforeReadyIsHandledButItsResponseWaitsForReady() = runBlocking {
        gateway.sendReady = false
        val client = client()
        client.setServerRequestHandler("approval", handler)
        val connecting = async(kotlinx.coroutines.Dispatchers.Default) { client.connect() }
        val conn = gateway.awaitConnection()
        conn.send(ScriptedGateway.requestLine("early-1", "approval", """{"session_id":"s"}"""))
        delay(300)
        assertFalse("The response is deferred until ready", conn.hasFrame())
        conn.event("gateway.ready", """{"heartbeat":true}""")
        connecting.await()
        val response = conn.awaitFrame { it["id"]?.jsonPrimitive?.content == "early-1" }
        assertEquals("""{}""", response["result"].toString())
        assertTrue(conn.firstFrameNanos > 0)
        client.disconnect()
    }

    @Test fun aQueuedResponseCancelledBeforeReadyIsNeverWritten() = runBlocking {
        gateway.sendReady = false
        val client = client()
        client.setServerRequestHandler("approval", handler)
        val connecting = async(kotlinx.coroutines.Dispatchers.Default) { client.connect() }
        val conn = gateway.awaitConnection()
        conn.send(ScriptedGateway.requestLine("early-2", "approval", """{"session_id":"s"}"""))
        delay(300)
        conn.event("request.cancel", """{"id":"early-2","method":"approval","reason":"expired"}""")
        delay(200)
        conn.event("gateway.ready", "{}")
        connecting.await()
        client.request("gateway.ping")
        assertTrue("The cancelled response never left", conn.allFrames.none { """"early-2"""" in it })
        client.disconnect()
    }

    @Test fun theReadyDeadlineClosesTheSocketAndFailsConnectWithATimeout() = runBlocking {
        gateway.sendReady = false
        val client = client(timings = GatewayTimings(readyMillis = 300, reconnectDelaysMillis = listOf(0)))
        val start = System.nanoTime()
        assertKind(HermesException.Kind.TimedOut) { client.connect() }
        assertTrue(System.nanoTime() - start < TimeUnit.SECONDS.toNanos(2))
        eventually { gateway.all.first().closedByClient }
        assertEquals("A connect that never became ready is not retried behind the caller's back", 1, gateway.all.size)
        assertEquals(GatewayConnection.Idle, client.state.value.connection)
        assertEquals(20_000L, GatewayTimings().readyMillis)
    }

    @Test fun theStartupSequenceIsAdvertiseThenHealthThenCapabilities() = runBlocking {
        val client = client()
        client.setServerRequestHandler("approval", handler)
        client.setServerRequestHandler("clarify", handler)
        val state = client.connect()
        assertEquals(listOf("upgrade", "ws:client.capabilities", "http:/api/health", "ws:gateway.capabilities"), gateway.log.toList())
        val conn = gateway.awaitConnection()
        val advertise = conn.framesWithMethod("client.capabilities").single()
        assertEquals("""{"server_requests":true}""", advertise["params"].toString())
        assertTrue(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}").matches(advertise["id"]!!.jsonPrimitive.content))
        assertEquals("2.0", advertise["jsonrpc"]!!.jsonPrimitive.content)
        assertEquals(GatewayConnection.Connected, state.connection)
        assertEquals(SocketPhase.Ready, state.socket!!.phase)
        assertEquals(true, state.capabilities!!.perSessionExclusiveSubmit)
        assertEquals("epoch-1", state.replayEpoch)
        assertTrue(state.heartbeatAdvertised)
        assertEquals("Bearer-less health on a dashboard session", "dash-token",
            gateway.host.callsTo("/api/health").single().getHeader("X-Hermes-Session-Token"))
        assertNotNull(state.owner)
        client.disconnect()
    }

    @Test fun withoutAnyHandlerNothingIsAdvertised() = runBlocking {
        val client = client()
        client.connect()
        assertEquals(listOf("upgrade", "http:/api/health", "ws:gateway.capabilities"), gateway.log.toList())
        client.disconnect()
    }

    @Test fun aHandlerRegisteredAfterConnectAdvertisesOnceOnTheLiveSocket() = runBlocking {
        val client = client()
        client.connect()
        val conn = gateway.awaitConnection()
        client.setServerRequestHandler("approval", handler)
        client.setServerRequestHandler("secret", handler)
        conn.awaitMethod("client.capabilities")
        delay(200)
        assertEquals(1, conn.framesWithMethod("client.capabilities").size)
        client.disconnect()
    }

    @Test fun anOlderHostThatRejectsClientCapabilitiesStillConnects() = runBlocking {
        gateway.responder = { conn, frame ->
            val id = frame["id"]!!.jsonPrimitive.content
            when (frame["method"]!!.jsonPrimitive.content) {
                "client.capabilities" -> conn.failure(id, -32601, "unknown method")
                else -> gateway.defaultResponse(conn, frame)
            }
        }
        val client = client()
        client.setServerRequestHandler("approval", handler)
        assertEquals(GatewayConnection.Connected, client.connect().connection)
        client.disconnect()
    }

    @Test fun anUnhealthyHostFailsConnectAndClosesTheSocket() {
        for (body in listOf("""{"ok":false,"auth_required":false}""", """{"ok":true}""", "{}")) {
            gateway.healthBody = body
            val client = client()
            assertKind(HermesException.Kind.AuthenticationRequired) { client.connect() }
            assertEquals(GatewayConnection.Idle, client.state.value.connection)
        }
        runBlocking { eventually { gateway.all.all { it.closedByClient } } }
    }

    @Test fun exclusiveSubmitFalseKeepsReadsAndControlsButRefusesSubmissionsOffTheWire() = runBlocking {
        gateway.capabilitiesResult = """{"per_session_exclusive_submit":false}"""
        gateway.responder = { conn, frame ->
            val id = frame["id"]!!.jsonPrimitive.content
            when (frame["method"]!!.jsonPrimitive.content) {
                "profiles.list", "session.steer", "session.interrupt", "prompt.submit" -> conn.result(id, """{"status":"streaming"}""")
                else -> gateway.defaultResponse(conn, frame)
            }
        }
        val client = client()
        assertEquals(false, client.connect().capabilities!!.perSessionExclusiveSubmit)
        val conn = gateway.awaitConnection()
        client.request("profiles.list")
        client.request("session.steer", params("session_id" to "s", "text" to "go"))
        client.request("session.interrupt", params("session_id" to "s"))
        for (method in listOf("prompt.submit", "slash.exec", "command.dispatch")) {
            assertKind(HermesException.Kind.ExclusiveSubmitUnavailable) { client.request(method, params("session_id" to "s")) }
        }
        assertKind(HermesException.Kind.ExclusiveSubmitUnavailable) {
            client.request("anything.else", operation = GatewayOperation.Submission)
        }
        assertTrue("Refused submissions never reached the wire", conn.allFrames.none { "prompt.submit" in it || "slash.exec" in it || "command.dispatch" in it })
        client.disconnect()
    }

    @Test fun trueEnablesSubmissionAndMalformedCapabilitiesFailDiscovery() = runBlocking {
        gateway.responder = { conn, frame ->
            val id = frame["id"]!!.jsonPrimitive.content
            if (frame["method"]!!.jsonPrimitive.content == "prompt.submit") conn.result(id, """{"status":"streaming"}""") else gateway.defaultResponse(conn, frame)
        }
        val ok = client()
        ok.connect()
        assertEquals("streaming", ok.request("prompt.submit", params("text" to "hi"))!!.jsonObject["status"]!!.jsonPrimitive.content)
        ok.disconnect()

        for (body in listOf("{}", """{"per_session_exclusive_submit":"true"}""", """{"per_session_exclusive_submit":null}""", "[]", "7")) {
            gateway.capabilitiesResult = body
            val client = client()
            assertKind(HermesException.Kind.InvalidResponse) { client.connect() }
            assertEquals(body, GatewayConnection.Idle, client.state.value.connection)
        }
    }

    @Test fun aSecondGatewayReadyInvalidatesTheConnection() = runBlocking {
        val client = client(timings = fast.let { GatewayTimings(requestMillis = 3_000, reconnectDelaysMillis = listOf(0)) })
        client.connect()
        val conn = gateway.awaitConnection()
        val pending = async(kotlinx.coroutines.Dispatchers.Default) { runCatching { client.request("profiles.list") } }
        conn.awaitMethod("profiles.list")
        conn.event("gateway.ready", "{}")
        val failure = pending.await().exceptionOrNull() as HermesException
        assertTrue(failure.kind == HermesException.Kind.InvalidResponse || failure.kind == HermesException.Kind.Disconnected)
        eventually { conn.closedByClient }
        client.disconnect()
    }

    @Test fun aLateEventConsumerStillSeesTheRetainedReadyOfTheCurrentSocket() = runBlocking {
        val client = client()
        client.connect()
        val late = EventLog(client)
        eventually { late.events.isNotEmpty() }
        assertEquals("gateway.ready", late.events.first().event.type)
        assertEquals(client.state.value.generation, late.events.first().generation)
        assertEquals("epoch-1", late.events.first().event.payload["replay_epoch"]!!.jsonPrimitive.content)
        client.disconnect()
    }

    @Test fun disconnectIsTerminalAndClosesTheSocketAndFailsWaiters() = runBlocking {
        val client = client()
        client.connect()
        val conn = gateway.awaitConnection()
        val waiting = async(kotlinx.coroutines.Dispatchers.Default) { runCatching { client.request("profiles.list") } }
        conn.awaitMethod("profiles.list")
        client.disconnect()
        assertEquals(GatewayConnection.Closed, client.state.value.connection)
        val failure = waiting.await().exceptionOrNull() as HermesException
        assertEquals(HermesException.Kind.Disconnected, failure.kind)
        assertFalse("A read that was cut is not an uncertain mutation", failure.outcomeUnknown)
        eventually { conn.closedByClient }
        assertKind(HermesException.Kind.NotConnected) { client.connect() }
        assertKind(HermesException.Kind.NotConnected) { client.reconnect() }
        assertKind(HermesException.Kind.NotConnected) { client.request("gateway.ping") }
        assertEquals("No automatic reconnect after an explicit disconnect", 1, gateway.all.size)
    }
}
