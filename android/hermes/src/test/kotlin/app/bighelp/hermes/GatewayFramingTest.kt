package app.bighelp.hermes

import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Whole-message atomic decoding and strictly ordered delivery over a real socket. */
class GatewayFramingTest : GatewayTestSupport() {
    private fun id(frame: kotlinx.serialization.json.JsonObject) = frame["id"]!!.jsonPrimitive.content

    private suspend fun connected(timings: GatewayTimings = fast): Triple<GatewayClient, ScriptedGateway.Conn, EventLog> {
        val client = client(timings = timings)
        val log = EventLog(client)
        client.connect()
        return Triple(client, gateway.awaitConnection(), log)
    }

    @Test fun oneMessageWithManyEntriesIsDeliveredInWireOrder() = runBlocking {
        val (client, conn, log) = connected()
        client.setServerRequestHandler("approval") { ServerResponse.Result(kotlinx.serialization.json.JsonObject(emptyMap())) }
        val pending = async(kotlinx.coroutines.Dispatchers.Default) { client.request("profiles.list") }
        val frame = conn.awaitMethod("profiles.list")
        val batch = listOf(
            ScriptedGateway.eventLine("a.first", "{}", seq = 1),
            """{"jsonrpc":"2.0","id":${ScriptedGateway.quote(id(frame))},"result":{"done":true}}""",
            ScriptedGateway.eventLine("b.second", "{}", seq = 2),
            ScriptedGateway.requestLine("order-1", "approval"),
            ScriptedGateway.eventLine("c.third", "{}", seq = 3),
        ).joinToString("\n")
        conn.send(batch)
        assertEquals(true, pending.await().jsonObject["done"]!!.jsonPrimitive.content.toBoolean())
        eventually { log.types().contains("c.third") }
        assertEquals(listOf("gateway.ready", "a.first", "b.second", "c.third"), log.types())
        assertEquals(listOf(1L, 2L, 3L), log.events.filter { it.event.sequence != null }.map { it.event.sequence })
        conn.awaitFrame { it["method"] == null && id(it) == "order-1" }
        client.disconnect()
    }

    @Test fun aBadLineAnywhereInTheMessageAppliesNothingFromIt() = runBlocking {
        val (client, conn, log) = connected(GatewayTimings(requestMillis = 3_000, reconnectDelaysMillis = listOf(0)))
        val pending = async(kotlinx.coroutines.Dispatchers.Default) { runCatching { client.request("profiles.list") } }
        val frame = conn.awaitMethod("profiles.list")
        conn.send(
            ScriptedGateway.eventLine("must.not.publish") + "\n" +
                """{"jsonrpc":"2.0","id":${ScriptedGateway.quote(id(frame))},"result":{"late":true}}""" + "\n" +
                """{"jsonrpc":"2.0","method":"event","params":{"type":"x","payload":[1]}}""",
        )
        val failure = pending.await().exceptionOrNull() as HermesException
        assertFalse("The valid first lines were not applied", failure.kind == HermesException.Kind.RpcRejected)
        assertFalse(log.types().contains("must.not.publish"))
        eventually { conn.closedByClient }
        client.disconnect()
    }

    @Test fun anOversizeMessageClosesTheConnection() = runBlocking {
        val (client, conn, log) = connected(GatewayTimings(requestMillis = 3_000, reconnectDelaysMillis = listOf(0)))
        conn.send(ScriptedGateway.eventLine("huge", """{"blob":"${"x".repeat(HermesWire.MAXIMUM_MESSAGE_BYTES)}"}"""))
        eventually { conn.closedByClient }
        assertFalse(log.types().contains("huge"))
        client.disconnect()
    }

    @Test fun binaryMessagesAreJsonBytesToo() = runBlocking {
        val (client, conn, log) = connected()
        conn.sendBinary(ScriptedGateway.eventLine("from.binary", "{}", seq = 9))
        eventually { log.types().contains("from.binary") }
        client.disconnect()
    }

    @Test fun nonGatewayLinesAreProtocolErrors() = runBlocking {
        for (bad in listOf("""{"jsonrpc":"2.0","id":7,"result":{}}""", """[{"jsonrpc":"2.0","id":"a","result":{}}]""", "not json", """{"jsonrpc":"1.0","method":"event","params":{"type":"x"}}""", """{"jsonrpc":"2.0","method":"notify","params":{}}""")) {
            val (client, conn, _) = connected(GatewayTimings(reconnectDelaysMillis = listOf(0)))
            conn.send(bad)
            eventually { conn.closedByClient }
            client.disconnect()
        }
    }

    @Test fun manyEventsAcrossMessagesKeepTheirOrderForASlowConsumer() = runBlocking {
        val client = client()
        val seen = java.util.concurrent.CopyOnWriteArrayList<Long>()
        val collector = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default).async(kotlinx.coroutines.Dispatchers.Default) {
            client.events.collect { e ->
                e.event.sequence?.let { seen += it }
                if (it_slow(e)) delay(2)
            }
        }
        eventually { client.subscriberCount == 1 }
        client.connect()
        val conn = gateway.awaitConnection()
        repeat(300) { conn.send(ScriptedGateway.eventLine("tick", "{}", seq = it.toLong())) }
        eventually(10_000) { seen.size == 300 }
        assertEquals((0L until 300L).toList(), seen.toList())
        collector.cancel()
        client.disconnect()
    }

    @Test fun aCollectorTooFarBehindFailsInsteadOfGrowingWithoutBound() = runBlocking {
        val client = client()
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val seen = java.util.concurrent.atomic.AtomicInteger()
        var failure: Throwable? = null
        val collector = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default).async {
            try {
                client.events.collect { gate.await(); seen.incrementAndGet() }
            } catch (e: HermesException) {
                failure = e
            }
        }
        eventually { client.subscriberCount == 1 }
        client.connect()
        val conn = gateway.awaitConnection()
        repeat(GatewayClient.EVENT_BUFFER + 200) { conn.send(ScriptedGateway.eventLine("flood", "{}", seq = it.toLong())) }
        eventually { client.subscriberCount == 0 } // the overflowing subscriber was dropped, not the connection
        assertEquals(GatewayConnection.Connected, client.state.value.connection)
        gate.complete(Unit)
        collector.await()
        assertEquals(HermesException.Kind.TooManyRequests, (failure as HermesException).kind)
        assertTrue("It saw what fit, in order, and no more", seen.get() in 1..(GatewayClient.EVENT_BUFFER + 1))
        client.disconnect()
    }

    private fun it_slow(event: GatewayEvent) = event.event.sequence?.rem(10) == 0L

    @Test fun eventsAreOnlyDeliveredToSubscribersWhileTheyCollect() = runBlocking {
        val client = client()
        client.connect()
        val conn = gateway.awaitConnection()
        conn.event("before.subscribe", "{}", seq = 1)
        delay(150)
        val late = EventLog(client)
        eventually { late.events.isNotEmpty() }
        conn.event("after.subscribe", "{}", seq = 2)
        eventually { late.types().contains("after.subscribe") }
        assertEquals(listOf("gateway.ready", "after.subscribe"), late.types())
        client.disconnect()
    }
}
