package app.bighelp.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Every documented ceiling, at the limit and one byte over, in characters of 1 to 4 UTF-8 bytes. */
class HermesWireLimitsTest {
    private val units = listOf("a", "é", "€", "😀")

    /** A string of exactly [bytes] UTF-8 bytes whose bulk is [unit], padded with ASCII. */
    private fun exactly(unit: String, bytes: Int): String {
        val bulk = unit.repeat(bytes / unit.toByteArray().size)
        return bulk + "a".repeat(bytes - bulk.toByteArray().size)
    }

    private fun decode(frame: String) = HermesWire.decode(frame.toByteArray())

    private fun rejects(category: String, frame: String) = rejects(category, frame.toByteArray())

    private fun rejects(category: String, bytes: ByteArray) {
        try {
            HermesWire.decode(bytes)
            fail("Expected $category")
        } catch (error: WireException) {
            assertEquals(category, error.category)
        }
    }

    private fun response(id: String) = """{"jsonrpc":"2.0","id":"$id","result":null}"""
    private fun request(id: String, method: String = "approval") = """{"jsonrpc":"2.0","id":"$id","method":"$method","params":{}}"""
    private fun event(type: String, payload: String = "{}") =
        """{"jsonrpc":"2.0","method":"event","params":{"type":"$type","payload":$payload}}"""
    private fun cancel(id: String = "a", method: String = "clarify", reason: String = "expired") =
        event("request.cancel", """{"id":"$id","method":"$method","reason":"$reason"}""")

    @Test fun idsAreBoundedInUtf8BytesForRequestsAndResponses() {
        units.forEach { unit ->
            val atLimit = exactly(unit, 1_024)
            assertEquals(1_024, atLimit.toByteArray().size)
            assertEquals("result:$atLimit", decode(response(atLimit)).single().classification)
            assertEquals("request:approval", decode(request(atLimit)).single().classification)
            rejects("invalidResponse", response(atLimit + "a"))
            rejects("invalidResponse", request(atLimit + "a"))
        }
    }

    @Test fun methodsAreAsciiAndBoundedAt256() {
        val atLimit = "m".repeat(256)
        assertEquals("request:$atLimit", decode(request("a", atLimit)).single().classification)
        rejects("invalidResponse", request("a", atLimit + "m"))
        // Printable ASCII only: the boundary characters U+0021 and U+007E pass, space, DEL and non-ASCII do not.
        assertEquals("request:!~", decode(request("a", "!~")).single().classification)
        listOf(" ", "\\u007f", "m\\u00e9", "m\\u0001").forEach { rejects("invalidResponse", request("a", "x$it")) }
    }

    @Test fun eventTypesAreBoundedInUtf8Bytes() {
        units.forEach { unit ->
            val atLimit = exactly(unit, 256)
            assertEquals("event:$atLimit", decode(event(atLimit)).single().classification)
            rejects("invalidResponse", event(atLimit + "a"))
        }
    }

    @Test fun cancellationReasonIsBoundedInUtf8Bytes() {
        units.forEach { unit ->
            val atLimit = exactly(unit, 4_096)
            val cancellation = HermesWire.cancellation(decode(cancel(reason = atLimit)).single() as WireMessage.Event)
            assertEquals(atLimit, cancellation.reason)
            rejects("invalidResponse", cancel(reason = atLimit + "a"))
        }
    }

    @Test fun cancellationIdAndMethodAreValidatedLikeRequests() {
        val longestId = exactly("😀", 1_024)
        assertEquals(longestId, HermesWire.cancellation(decode(cancel(id = longestId)).single() as WireMessage.Event).id)
        rejects("invalidResponse", cancel(id = longestId + "a"))
        rejects("invalidResponse", cancel(method = "m".repeat(257)))
        rejects("invalidResponse", cancel(method = "has space"))
    }

    @Test fun cancellationPayloadMustBeExactlyIdMethodReason() {
        listOf(
            """{"id":"a","method":"clarify"}""",
            """{"id":"a","reason":"x"}""",
            """{"method":"clarify","reason":"x"}""",
            """{"id":"a","method":"clarify","reason":"x","extra":1}""",
            """{"id":1,"method":"clarify","reason":"x"}""",
            """{"id":"a","method":null,"reason":"x"}""",
            """{"id":"a","method":"clarify","reason":7}""",
            """{"id":"a","method":"clarify","reason":null}""",
            """{}""",
        ).forEach { rejects("invalidResponse", event("request.cancel", it)) }
        // An event with no payload key at all is a cancellation with no keys.
        rejects("invalidResponse", """{"jsonrpc":"2.0","method":"event","params":{"type":"request.cancel"}}""")
    }

    @Test fun cancellationIsDecodedFromTheEventForTheOwnerToMatch() {
        val message = decode(cancel(id = " é ", method = "approval", reason = "done")).single() as WireMessage.Event
        assertEquals(RequestCancellation(" é ", "approval", "done"), HermesWire.cancellation(message))
        try {
            HermesWire.cancellation(decode(event("notice")).single() as WireMessage.Event)
            fail("A non-cancel event is not a cancellation")
        } catch (error: WireException) {
            assertEquals("invalidResponse", error.category)
        }
    }

    @Test fun wholeMessageCeilingCountsBytesNotCharacters() {
        val head = """{"jsonrpc":"2.0","id":"r","result":""""
        val tail = "\"}"
        val body = 4_194_304 - head.length - tail.length
        // 4-byte characters fill the frame with a character count far under the byte ceiling.
        val filler = "😀".repeat(body / 4) + "a".repeat(body % 4)
        val exact = (head + filler + tail).toByteArray()
        assertEquals(4_194_304, exact.size)
        assertTrue(exact.size > (head + filler + tail).length)
        assertEquals(1, HermesWire.decode(exact).size)
        rejects("messageTooLarge", exact + byteArrayOf(' '.code.toByte()))
    }

    @Test fun messageCeilingIsCheckedBeforeAnyParsing() {
        // Not even JSON, but over the ceiling: the size category wins and nothing is parsed.
        rejects("messageTooLarge", ByteArray(4_194_305) { 0xff.toByte() })
    }

    @Test fun nonBlankLineCountIgnoresBlankLines() {
        val one = response("r")
        val padded = List(4_096) { one }.joinToString("\n\n \t\r\n")
        assertEquals(4_096, decode(padded + "\n\n\n").size)
        rejects("messageTooLarge", List(4_097) { one }.joinToString("\n\n"))
    }

    @Test fun nestingDepthCountsTheWholeValueIncludingEnvelopeObjects() {
        fun nested(arrays: Int) = event("deep", """{"x":""" + "[".repeat(arrays) + "0" + "]".repeat(arrays) + "}")
        // Envelope (1) + params (2) + payload (3) + "x" arrays: 61 arrays reach exactly 64 levels.
        assertEquals(1, decode(nested(61)).size)
        rejects("messageTooLarge", nested(62))
        // Objects count like arrays: the envelope plus 63 nested objects is 64 levels.
        fun objects(count: Int) =
            """{"jsonrpc":"2.0","id":"r","result":""" + """{"a":""".repeat(count - 1) + "{}" + "}".repeat(count - 1) + "}"
        assertEquals(1, decode(objects(63)).size)
        rejects("messageTooLarge", objects(64))
    }

    @Test fun bracketsInsideStringsDoNotCountAsDepth() {
        val noisy = "[".repeat(200) + """\"[[""" + "]".repeat(200)
        assertEquals("result:r", decode("""{"jsonrpc":"2.0","id":"r","result":"$noisy"}""").single().classification)
    }

    @Test fun depthIsMeasuredPerLineSoNewlinesResetIt() {
        val deepEnough = """{"jsonrpc":"2.0","id":"r","result":""" + "[".repeat(63) + "0" + "]".repeat(63) + "}"
        assertEquals(3, decode(listOf(deepEnough, deepEnough, deepEnough).joinToString("\n")).size)
    }

    @Test fun anyBadLineRejectsTheWholeMessageWithoutPublishingEarlierOnes() {
        val good = response("first")
        val tooDeep = """{"jsonrpc":"2.0","id":"b","result":""" + "[".repeat(65) + "]".repeat(65) + "}"
        listOf(
            "invalidResponse" to good.toByteArray() + "\n{".toByteArray(),
            "invalidResponse" to good.toByteArray() + "\n".toByteArray() + byteArrayOf(0x7b, 0x22, 0xff.toByte(), 0x22, 0x7d),
            "invalidResponse" to good.toByteArray() + "\n[1]".toByteArray(),
            "messageTooLarge" to (good + "\n" + tooDeep).toByteArray(),
        ).forEach { (category, bytes) -> rejects(category, bytes) }
    }

    @Test fun firstViolationInWireOrderDecidesTheCategory() {
        val bad = "{"
        val one = response("r")
        // An invalid line before the 4,097th object is reported first...
        rejects("invalidResponse", (listOf(bad) + List(4_097) { one }).joinToString("\n"))
        // ...and one after it is never reached.
        rejects("messageTooLarge", (List(4_097) { one } + listOf(bad)).joinToString("\n"))
    }

    @Test fun opaqueIdsKeepTheirExactUtf8Bytes() {
        val composed = "request:é"
        val decomposed = "request:é"
        listOf(composed, decomposed, "😀", "", " lead\ttrail ", "‮").forEach { id ->
            val escaped = id.map { if (it.code < 0x20) "\\u%04x".format(it.code) else it.toString() }.joinToString("")
            val request = decode("""{"jsonrpc":"2.0","id":"$escaped","method":"approval","params":{}}""").single()
                as WireMessage.Request
            assertArrayEquals(id.toByteArray(), request.id.toByteArray())
        }
        val a = decode(request(composed)).single() as WireMessage.Request
        val b = decode(request(decomposed)).single() as WireMessage.Request
        assertTrue("Canonically equivalent IDs must stay distinct", a.id != b.id)
    }
}
