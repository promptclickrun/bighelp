package app.bighelp.hermes

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Scripted ownership, readiness and admission scenarios. Nothing here opens a socket. */
class HermesConnectionTest {
    private val endpoint = HermesEndpoint.parse("hermes.example/p")
    private val ready = HermesWire.decode(
        """{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"heartbeat":true}}}""".toByteArray(),
    ).single()
    private val notice = HermesWire.decode(
        """{"jsonrpc":"2.0","method":"event","params":{"type":"notice","payload":{}}}""".toByteArray(),
    ).single()
    private val approval = HermesWire.decode(
        """{"jsonrpc":"2.0","id":"s","method":"approval","params":{}}""".toByteArray(),
    ).single()

    private fun capabilities(json: String) = GatewayCapabilities.decode(Json.parseToJsonElement(json))

    private fun readySocket(owners: OwnerState) =
        GatewaySocket.opening(owners.current!!).upgraded().receive(ready)

    private fun admit(socket: GatewaySocket, owners: OwnerState, operation: GatewayOperation) =
        socket.admit(operation, owners)

    // Readiness is not the upgrade

    @Test fun upgradeAloneAllowsNoApplicationWrites() {
        val owners = OwnerState.none.connect(endpoint, "principal-1")
        val connecting = GatewaySocket.opening(owners.current!!)
        val upgraded = connecting.upgraded()
        assertEquals(SocketPhase.Connecting, connecting.phase)
        assertEquals(SocketPhase.Upgraded, upgraded.phase)
        listOf(connecting, upgraded).forEach { socket ->
            assertFalse(socket.canWriteApplicationFrames)
            GatewayOperation.entries.forEach {
                assertEquals(Admission.Refused(Refusal.NotReady), admit(socket, owners, it))
            }
        }
    }

    @Test fun onlyGatewayReadyEndsTheWaitAndOtherMessagesDoNot() {
        val owners = OwnerState.none.connect(endpoint, "principal-1")
        val upgraded = GatewaySocket.opening(owners.current!!).upgraded()
        assertSame(upgraded, upgraded.receive(notice))
        assertSame("Early server requests are processed but do not make the socket ready", upgraded, upgraded.receive(approval))
        val now = upgraded.receive(ready)
        assertEquals(SocketPhase.Ready, now.phase)
        assertTrue(now.canWriteApplicationFrames)
        assertEquals("gateway.ready", now.ready?.type)
        assertEquals(Admission.Admitted, admit(now, owners, GatewayOperation.Read))
    }

    @Test fun readyBeforeTheUpgradeCompletesIsNotAcceptedAndASecondReadyClosesTheSocket() {
        val owners = OwnerState.none.connect(endpoint, "principal-1")
        val connecting = GatewaySocket.opening(owners.current!!)
        assertEquals(SocketPhase.Connecting, connecting.receive(ready).phase)
        val now = readySocket(owners)
        val closed = now.receive(ready)
        assertEquals(SocketPhase.Closed, closed.phase)
        assertFalse(closed.canWriteApplicationFrames)
        assertEquals(Admission.Refused(Refusal.NotReady), admit(closed, owners, GatewayOperation.Read))
        assertEquals("A closed socket cannot become ready again", SocketPhase.Closed, closed.upgraded().receive(ready).phase)
    }

    // Capability is a required Boolean

    @Test fun exclusiveSubmitMustBeAJsonBoolean() {
        assertTrue(capabilities("""{"per_session_exclusive_submit":true,"future":{"x":1}}""").perSessionExclusiveSubmit)
        assertFalse(capabilities("""{"per_session_exclusive_submit":false}""").perSessionExclusiveSubmit)
        listOf(
            "{}", "[]", "null", "true", "\"true\"",
            """{"per_session_exclusive_submit":"true"}""", """{"per_session_exclusive_submit":"false"}""",
            """{"per_session_exclusive_submit":null}""", """{"per_session_exclusive_submit":1}""",
            """{"per_session_exclusive_submit":0}""", """{"per_session_exclusive_submit":[true]}""",
            """{"per_session_exclusive_submit":{"v":true}}""", """{"Per_Session_Exclusive_Submit":true}""",
        ).forEach {
            try {
                capabilities(it)
                fail("Expected $it to fail discovery")
            } catch (error: WireException) {
                assertEquals("invalidResponse", error.category)
            }
        }
    }

    @Test fun submissionNeedsTheGuaranteeButReadsAndControlsDoNot() {
        var owners = OwnerState.none.connect(endpoint, "principal-1")
        val undiscovered = readySocket(owners)
        assertNull(undiscovered.capabilities)
        assertEquals(Admission.Refused(Refusal.CapabilitiesUnknown), admit(undiscovered, owners, GatewayOperation.Submission))
        assertEquals(Admission.Admitted, admit(undiscovered, owners, GatewayOperation.Read))

        val unsafe = undiscovered.discovered(capabilities("""{"per_session_exclusive_submit":false}"""))
        assertEquals(Admission.Refused(Refusal.ExclusiveSubmitUnavailable), admit(unsafe, owners, GatewayOperation.Submission))
        assertEquals(Admission.Admitted, admit(unsafe, owners, GatewayOperation.Read))
        assertEquals(Admission.Admitted, admit(unsafe, owners, GatewayOperation.Control))

        val safe = undiscovered.discovered(capabilities("""{"per_session_exclusive_submit":true}"""))
        GatewayOperation.entries.forEach { assertEquals(Admission.Admitted, admit(safe, owners, it)) }

        // A new connection starts without them: nothing carries over from a retired socket.
        owners = owners.connect(endpoint, "principal-1")
        val replacement = readySocket(owners)
        assertNull(replacement.capabilities)
        assertEquals(Admission.Refused(Refusal.CapabilitiesUnknown), admit(replacement, owners, GatewayOperation.Submission))
    }

    @Test fun capabilitiesCanOnlyBeDiscoveredOnAReadySocket() {
        val owners = OwnerState.none.connect(endpoint, "principal-1")
        val upgraded = GatewaySocket.opening(owners.current!!).upgraded()
        try {
            upgraded.discovered(GatewayCapabilities(true))
            fail("Discovery before gateway.ready is a caller bug")
        } catch (_: IllegalStateException) {
        }
        assertNull(readySocket(owners).closed().capabilities)
    }

    // Retired generations cannot publish

    @Test fun aSupersededSocketIsRefusedEvenThoughItsOwnStateIsReady() {
        val first = OwnerState.none.connect(endpoint, "principal-1")
        val oldSocket = readySocket(first).discovered(GatewayCapabilities(true))
        assertEquals(Admission.Admitted, admit(oldSocket, first, GatewayOperation.Submission))

        val second = first.connect(endpoint, "principal-1")
        assertEquals(1L, first.current!!.generation)
        assertEquals(2L, second.current!!.generation)
        assertTrue(oldSocket.canWriteApplicationFrames)
        GatewayOperation.entries.forEach {
            assertEquals(Admission.Refused(Refusal.StaleOwner), admit(oldSocket, second, it))
        }
        assertFalse(second.accepts(first.current!!))
        assertTrue(second.accepts(second.current!!))
    }

    @Test fun nothingPublishesWhileDisconnectedAndGenerationsNeverRepeat() {
        val first = OwnerState.none.connect(endpoint, "principal-1")
        val gone = first.disconnect()
        assertNull(gone.current)
        assertFalse(gone.accepts(first.current!!))
        assertEquals(Admission.Refused(Refusal.StaleOwner), admit(readySocket(first), gone, GatewayOperation.Read))

        val back = gone.connect(endpoint, "principal-1")
        assertEquals(2L, back.current!!.generation)
        assertNotEquals("The same endpoint and principal again is still a different owner", first.current, back.current)
        assertFalse(back.accepts(first.current!!))
        assertEquals(3L, back.disconnect().disconnect().connect(endpoint, "principal-1").current!!.generation)
    }

    @Test fun endpointAndPrincipalAreBothPartOfWhoOwnsAResult() {
        val owners = OwnerState.none.connect(endpoint, "principal-1")
        val current = owners.current!!
        assertTrue(owners.accepts(current.copy()))
        assertFalse(owners.accepts(current.copy(principal = "principal-2")))
        assertFalse(owners.accepts(current.copy(endpoint = HermesEndpoint.parse("hermes.example/q").canonical)))
        assertFalse(owners.accepts(current.copy(endpoint = HermesEndpoint.parse("hermes.example:8443/p").canonical)))
        assertFalse(owners.accepts(current.copy(generation = current.generation + 1)))
        assertEquals("https://hermes.example/p", current.endpoint)

        // Switching principal on the same endpoint retires the old owner's results.
        val switched = owners.connect(endpoint, "principal-2")
        assertFalse(switched.accepts(current))
    }

    // An unknown dispatch is never resent

    @Test fun aMutationThatMayHaveBeenSentIsUncertainAndNeverRetried() {
        listOf("prompt.submit", "session.create", "session.interrupt", "future.method", "gateway.Ping", "", "session.list ")
            .forEach { method ->
                assertFalse(method, DispatchPolicy.isReadOnly(method))
                assertTrue(method, DispatchPolicy.isUncertain(method, DispatchOutcome.MayHaveBeenSent))
                assertFalse(method, DispatchPolicy.mayRetry(method, DispatchOutcome.MayHaveBeenSent))
                assertTrue("Never sent is safe to issue", DispatchPolicy.mayRetry(method, DispatchOutcome.NotSent))
            }
    }

    @Test fun readsMayBeAskedAgainAndAnsweredRequestsNeverAre() {
        assertEquals(26, DispatchPolicy.readOnlyMethods.size)
        DispatchPolicy.readOnlyMethods.forEach { method ->
            assertFalse(DispatchPolicy.isUncertain(method, DispatchOutcome.MayHaveBeenSent))
            assertTrue(DispatchPolicy.mayRetry(method, DispatchOutcome.MayHaveBeenSent))
            assertTrue(DispatchPolicy.mayRetry(method, DispatchOutcome.NotSent))
        }
        listOf("session.history", "prompt.submit").forEach { method ->
            listOf(DispatchOutcome.ConfirmedResult, DispatchOutcome.ConfirmedRefusal).forEach {
                assertFalse(DispatchPolicy.mayRetry(method, it))
                assertFalse(DispatchPolicy.isUncertain(method, it))
            }
            assertFalse(DispatchPolicy.isUncertain(method, DispatchOutcome.NotSent))
        }
    }
}
