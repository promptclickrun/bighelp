package app.bighelp.hermes

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Heartbeat pace, liveness, same-owner automatic recovery and re-advertisement. */
class GatewayRecoveryTest : GatewayTestSupport() {
    private val handler = ServerRequestHandler { ServerResponse.Result(JsonObject(emptyMap())) }
    private fun method(frame: JsonObject) = frame["method"]!!.jsonPrimitive.content

    private fun ms(from: Long, to: Long) = TimeUnit.NANOSECONDS.toMillis(to - from)

    @Test fun theHeartbeatHintChoosesThePingPace() = runBlocking {
        val timings = GatewayTimings(heartbeatMillis = 150, pingMillis = 700, pingReplyMillis = 500, reconnectDelaysMillis = listOf(0))
        gateway.readyPayload = """{"heartbeat":true}"""
        val hinted = client(timings = timings)
        hinted.connect()
        val one = gateway.awaitConnection()
        one.awaitMethod("gateway.ping")
        val hintedMillis = ms(one.readySentNanos, System.nanoTime())
        hinted.disconnect()
        assertTrue("heartbeat:true pings at the short pace ($hintedMillis ms)", hintedMillis in 100..600)

        gateway.readyPayload = """{}"""
        val plain = client(timings = timings)
        plain.connect()
        val two = gateway.awaitConnection()
        two.awaitMethod("gateway.ping", 3_000)
        val plainMillis = ms(two.readySentNanos, System.nanoTime())
        plain.disconnect()
        assertTrue("without the hint it pings at the long pace ($plainMillis ms)", plainMillis in 600..2_000)
        assertEquals(15_000L, GatewayTimings().heartbeatMillis)
        assertEquals(20_000L, GatewayTimings().pingMillis)
        assertEquals(15_000L, GatewayTimings().pingReplyMillis)
        assertEquals(4_000L, GatewayTimings().livenessMillis)
        assertEquals(5_000L, GatewayTimings().admissionMillis)
        assertEquals(listOf(0L, 1_000L, 3_000L), GatewayTimings().reconnectDelaysMillis)
    }

    @Test fun anRpcErrorToAPingMeansUnsupportedNotDeadAndStopsTheLoop() = runBlocking {
        gateway.responder = { conn, frame ->
            if (method(frame) == "gateway.ping") conn.failure(frame["id"]!!.jsonPrimitive.content, -32601, "no ping") else gateway.defaultResponse(conn, frame)
        }
        val client = client(timings = GatewayTimings(heartbeatMillis = 100, pingMillis = 100, pingReplyMillis = 500, reconnectDelaysMillis = listOf(0)))
        client.connect()
        val conn = gateway.awaitConnection()
        conn.awaitMethod("gateway.ping")
        delay(600)
        assertEquals("The loop stopped after the host answered", 1, conn.framesWithMethod("gateway.ping").size)
        assertEquals(GatewayConnection.Connected, client.state.value.connection)
        assertEquals(1, gateway.all.size)
        client.disconnect()
    }

    @Test fun anUnansweredPingRetiresTheSocketAndTheRecoveryReplacesIt() = runBlocking {
        gateway.responder = { conn, frame -> if (method(frame) != "gateway.ping") gateway.defaultResponse(conn, frame) }
        val client = client(timings = GatewayTimings(heartbeatMillis = 100, pingMillis = 100, pingReplyMillis = 300, reconnectDelaysMillis = listOf(0, 50)))
        client.connect()
        val first = gateway.awaitConnection()
        eventually(8_000) { first.closedByClient }
        eventually(8_000) { gateway.all.size >= 2 }
        client.disconnect()
    }

    @Test fun verifyLivenessReplacesASilentSocketButNotAnAnsweringOne() = runBlocking {
        val client = client()
        client.connect()
        client.verifyLiveness()
        assertEquals(1, gateway.all.size)

        gateway.responder = { conn, frame -> if (method(frame) != "gateway.ping") gateway.defaultResponse(conn, frame) }
        val before = client.state.value.generation
        client.verifyLiveness()
        eventually { client.state.value.generation > before && client.state.value.isConnected }
        gateway.responder = { conn, frame -> gateway.defaultResponse(conn, frame) }
        client.disconnect()
    }

    @Test fun prepareForAdmissionProvesTheSocketAndWaitsForRecoveryOnce() = runBlocking {
        val client = client()
        client.connect()
        client.prepareForAdmission()
        val conn = gateway.awaitConnection()
        assertEquals(1, conn.framesWithMethod("gateway.ping").size)

        conn.drop()
        // The recovery may be anywhere between "lost" and "replaced"; either way the proof must land on the replacement.
        client.prepareForAdmission()
        eventually { gateway.all.size == 2 }
        assertTrue(client.state.value.isConnected)
        assertTrue("The admission proof landed on the replacement socket", gateway.all[1].framesWithMethod("gateway.ping").isNotEmpty())
        client.disconnect()
    }

    @Test fun aLostSocketIsReplacedWithAFreshHandshakeAndHandlersSurviveWithoutReplayingReads() = runBlocking {
        gateway.responder = { conn, frame -> if (method(frame) != "profiles.list") gateway.defaultResponse(conn, frame) }
        val client = client(bearer = true)
        gateway.negotiatedSubprotocol = "hermes-gateway-v1"
        client.setServerRequestHandler("approval", handler)
        val events = EventLog(client)
        val first = run { client.connect(); gateway.awaitConnection() }
        val generation = client.state.value.generation
        val owner = client.state.value.owner
        val read = async(kotlinx.coroutines.Dispatchers.Default) { runCatching { client.request("profiles.list") } }
        first.awaitMethod("profiles.list")
        first.drop()
        val failure = read.await().exceptionOrNull() as HermesException
        assertFalse("A cut read is a plain failure", failure.outcomeUnknown)

        eventually { gateway.all.size == 2 && client.state.value.isConnected && client.state.value.generation > generation }
        val second = gateway.all[1]
        assertNotEquals("A fresh single-use ticket", first.request.getHeader("Sec-WebSocket-Protocol"), second.request.getHeader("Sec-WebSocket-Protocol"))
        eventually { second.framesWithMethod("client.capabilities").size == 1 }
        eventually { second.framesWithMethod("gateway.capabilities").size == 1 }
        assertTrue(second.framesWithMethod("profiles.list").isEmpty())
        assertNotEquals("A new owner generation per socket", owner, client.state.value.owner)
        assertEquals(owner!!.principal, client.state.value.owner!!.principal)
        assertEquals(2, events.types().count { it == "gateway.ready" })
        assertEquals(listOf(generation, client.state.value.generation), events.events.filter { it.event.type == "gateway.ready" }.map { it.generation })
        client.disconnect()
    }

    @Test fun aSuccessfulRecoveryKeepsTheHandlersSoTheNextLossAdvertisesAgain() = runBlocking {
        val client = client(timings = GatewayTimings(readyMillis = 1_000, requestMillis = 3_000, reconnectDelaysMillis = listOf(0, 100, 100)))
        client.setServerRequestHandler("approval", handler)
        client.connect()
        gateway.awaitConnection().drop()
        eventually { gateway.all.size == 2 && client.state.value.connection == GatewayConnection.Connected }
        delay(400) // longer than every remaining recovery delay: the finished recovery must not run on
        assertEquals(GatewayConnection.Connected, client.state.value.connection)
        assertEquals("Exactly one replacement socket", 2, gateway.all.size)
        gateway.all[1].drop()
        eventually { gateway.all.size == 3 && client.state.value.connection == GatewayConnection.Connected }
        eventually { gateway.all[2].framesWithMethod("client.capabilities").size == 1 }
        assertEquals(1, gateway.all[1].framesWithMethod("client.capabilities").size)
        client.disconnect()
    }

    @Test fun whenEveryRecoveryAttemptFailsTheClientGoesIdleAndForgetsItsHandlers() = runBlocking {
        val client = client(timings = GatewayTimings(readyMillis = 1_000, reconnectDelaysMillis = listOf(0, 30, 30)))
        client.setServerRequestHandler("approval", handler)
        client.connect()
        val first = gateway.awaitConnection()
        gateway.acceptLimit = 1
        first.drop()
        eventually { client.state.value.connection == GatewayConnection.Idle && client.state.value.lastFailure != null }
        assertEquals("Initial socket plus three refused attempts", 4, gateway.host.callsTo("/api/ws").size)
        gateway.acceptLimit = Int.MAX_VALUE
        client.connect()
        val third = gateway.awaitConnection()
        delay(200)
        assertTrue("Handlers were cleared, so nothing is advertised", third.framesWithMethod("client.capabilities").isEmpty())
        client.disconnect()
    }

    @Test fun anAbruptTcpCloseIsDetectedAsALoss() = runBlocking {
        val client = client(timings = GatewayTimings(readyMillis = 500, reconnectDelaysMillis = listOf(0, 30)))
        client.connect()
        gateway.awaitConnection()
        gateway.host.server.shutdown() // every accepted socket is closed without a WebSocket close
        eventually { client.state.value.connection == GatewayConnection.Idle && client.state.value.lastFailure != null }
        client.disconnect()
    }

    @Test fun serverInitiatedCloseIsALossAndRecovers() = runBlocking {
        val client = client()
        client.connect()
        val first = gateway.awaitConnection()
        first.close(1001)
        eventually { gateway.all.size == 2 && client.state.value.isConnected }
        client.disconnect()
    }

    @Test fun aSecondSimultaneousConnectJoinsTheFirstInsteadOfOpeningAnotherSocket() = runBlocking {
        gateway.readyDelayMillis = 300
        val client = client()
        val a = async(kotlinx.coroutines.Dispatchers.Default) { client.connect() }
        val b = async(kotlinx.coroutines.Dispatchers.Default) { client.connect() }
        a.await(); b.await()
        assertEquals(1, gateway.all.size)
        assertEquals("The second call is a no-op once connected", 1, client.connect().generation)
        client.disconnect()
    }
}
