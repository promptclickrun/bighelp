package app.bighelp.hermes

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** What counts as a well-formed frame beyond the shared vectors: JSON grammar, UTF-8 and field types. */
class HermesWireStrictnessTest {
    private fun decode(frame: String) = HermesWire.decode(frame.toByteArray())

    private fun rejects(frame: String, category: String = "invalidResponse") = rejects(frame.toByteArray(), category, frame)

    private fun rejects(bytes: ByteArray, category: String = "invalidResponse", label: String = bytes.contentToString()) {
        try {
            HermesWire.decode(bytes)
            fail("Expected rejection of $label")
        } catch (error: WireException) {
            assertEquals(label, category, error.category)
        }
    }

    private fun result(value: String) = """{"jsonrpc":"2.0","id":"r","result":$value}"""
    private fun eventParams(params: String) = """{"jsonrpc":"2.0","method":"event","params":$params}"""

    @Test fun grammarViolationsRejectTheFrame() {
        listOf(
            """{"jsonrpc":"2.0","id":"r","result":{},}""",                  // trailing comma
            """{"jsonrpc":"2.0","id":"r","result":[1,]}""",
            """{"jsonrpc":"2.0","id":"r","jsonrpc":"2.0","result":{}}""",   // duplicate keys, top level
            """{"jsonrpc":"2.0","id":"r","result":{"a":1,"a":2}}""",         // and nested
            """{"jsonrpc":"2.0","id":"r","id":"s","result":{}}""",
            result("01"), result("+1"), result(".5"), result("1."), result("1e"), result("-"), result("0x10"),
            result("NaN"), result("Infinity"), result("-Infinity"), result("1e999"), result("-1e999"),
            result("'single'"), result("tru"), result("nul"), result("True"),
            result("\"a\tb\""),                                              // raw control character in a string
            result("\"a\\x41\""), result("\"\\u12G4\""), result("\"\\u12\""), result("\"unterminated"),
            result("{} /* comment */"), result("1 2"),
            result("{\"a\" 1}"), result("{\"a\":}"), result("{1:2}"), result("[,]"),
            """{"jsonrpc":"2.0","id":"r","result":{}} x""",                  // trailing text
            """{"jsonrpc":"2.0","id":"r","result":{}}{"jsonrpc":"2.0","id":"s","result":{}}""", // two on one line
            "\u0000" + result("{}"), "\u000b" + result("{}"), "\u00a0" + result("{}"),
            "\ufeff" + result("{}"),                                         // a byte-order mark is not whitespace
        ).forEach { rejects(it) }
    }

    @Test fun legalGrammarIsAccepted() {
        val frame = result("""{"neg":-0,"exp":1E+2,"frac":0.5,"zero":0,"empty":[],"esc":"\/\b\f\n\r\t\"\\","u":"\u00e9\ud83d\ude00"}""")
        val value = (decode(frame).single() as WireMessage.Result).value as JsonObject
        assertEquals("é😀", (value["u"] as JsonPrimitive).content)
        assertEquals("/\b\u000c\n\r\t\"\\", (value["esc"] as JsonPrimitive).content)
    }

    @Test fun integersKeepSixtyFourBitsAndOtherNumbersAreNotIntegers() {
        fun seq(text: String) = (decode(eventParams("""{"type":"n","seq":$text}""")).single() as WireMessage.Event).sequence
        assertEquals(Long.MAX_VALUE, seq("9223372036854775807"))
        assertEquals(Long.MIN_VALUE, seq("-9223372036854775808"))
        assertEquals(0L, seq("-0"))
        listOf("1.0", "1e2", "1E0", "9223372036854775808", "-9223372036854775809", "\"1\"", "null", "true", "[]")
            .forEach { rejects(eventParams("""{"type":"n","seq":$it}""")) }
        // A result value is any JSON value; an integer too large for 64 bits is a finite number, not an error.
        assertEquals("result:r", decode(result("9223372036854775808")).single().classification)
    }

    @Test fun malformedUtf8RejectsTheWholeMessageEvenInBlankOrIgnoredPlaces() {
        val prefix = """{"jsonrpc":"2.0","id":"r","result":"""".toByteArray()
        val suffix = "\"}".toByteArray()
        listOf(
            byteArrayOf(0xff.toByte()),                                 // never valid
            byteArrayOf(0xc0.toByte(), 0x80.toByte()),                  // overlong NUL
            byteArrayOf(0xe0.toByte(), 0x80.toByte(), 0xaf.toByte()),   // overlong slash
            byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte()),   // UTF-8 encoded surrogate
            byteArrayOf(0xf4.toByte(), 0x90.toByte(), 0x80.toByte(), 0x80.toByte()), // above U+10FFFF
            byteArrayOf(0xe2.toByte(), 0x82.toByte()),                  // truncated euro sign
            byteArrayOf(0x80.toByte()),                                 // stray continuation byte
        ).forEach { rejects(prefix + it + suffix) }
        // A multibyte sequence cut by a newline is malformed too; it cannot borrow the next line's bytes.
        rejects(prefix + byteArrayOf(0xe2.toByte(), 0x0a) + suffix)
    }

    @Test fun escapedUnpairedSurrogatesCannotBecomeIds() {
        listOf("\\ud800", "\\udc00", "\\ud800x", "\\ud800\\u0041", "\\udc00\\ud800", "\\ud83d")
            .forEach { rejects("""{"jsonrpc":"2.0","id":"$it","result":null}""") }
        val pair = decode("""{"jsonrpc":"2.0","id":"\ud83d\ude00","result":null}""").single() as WireMessage.Result
        assertEquals("😀", pair.id)
        // Keys obey the same rule.
        rejects(result("""{"\ud800":1}"""))
    }

    @Test fun envelopeFieldsHaveExactTypes() {
        listOf(
            """{"jsonrpc":2.0,"id":"r","result":{}}""",
            """{"jsonrpc":null,"id":"r","result":{}}""",
            """{"jsonrpc":"2.0","id":"r","method":null,"params":{}}""",
            """{"jsonrpc":"2.0","id":"r","method":"approval","params":"x"}""",
            """{"jsonrpc":"2.0","id":"r","method":"approval","params":1}""",
            """{"jsonrpc":"2.0","id":"r","method":"approval","params":{},"error":null}""",
            """{"jsonrpc":"2.0","id":"r","error":null}""",
            """{"jsonrpc":"2.0","id":"r","error":[]}""",
            """{"jsonrpc":"2.0","id":"r","error":{}}""",
            """{"jsonrpc":"2.0","id":"r","error":{"code":1.5}}""",
            """{"jsonrpc":"2.0","id":"r","error":{"code":null}}""",
            """{"jsonrpc":"2.0","id":"r","error":{"code":1},"result":null}""",
            """{"jsonrpc":"2.0","id":"r","result":{},"params":null}""",
            eventParams("""{"type":"n","payload":"x"}"""),
            eventParams("""{"type":"n","session_id":false}"""),
            eventParams("""{"type":7}"""),
            eventParams("null"), eventParams("[]"), eventParams("\"x\""),
            """{"jsonrpc":"2.0","method":"event"}""",
            """{"jsonrpc":"2.0","method":"event","id":null,"params":{"type":"n"}}""",
            """{"jsonrpc":"2.0","method":"event","params":{"type":"n"},"result":null}""",
        ).forEach { rejects(it) }
    }

    @Test fun eventsKeepTheirCoordinatesPayloadDefaultsAndFutureMetadata() {
        val event = decode(eventParams("""{"type":"future","session_id":"runtime-é","seq":-3,"extra":{"k":[1]}}""")).single()
            as WireMessage.Event
        assertEquals("runtime-é", event.sessionID)
        assertEquals(-3L, event.sequence)
        assertTrue(event.payload.isEmpty())
        assertTrue("extra" in event.parameters && "type" in event.parameters)

        val noCoordinates = decode(eventParams("""{"type":"n","session_id":null,"payload":{"k":1}}""")).single()
            as WireMessage.Event
        assertNull(noCoordinates.sessionID)
        assertNull(noCoordinates.sequence)
        assertEquals(setOf("k"), noCoordinates.payload.keys)
    }

    @Test fun serverRequestsDefaultParamsAndAcceptUnknownMethods() {
        val absent = decode("""{"jsonrpc":"2.0","id":"s","method":"future.method"}""").single() as WireMessage.Request
        val nullParams = decode("""{"jsonrpc":"2.0","id":"s","method":"secret","params":null}""").single() as WireMessage.Request
        assertTrue(absent.params.isEmpty() && nullParams.params.isEmpty())
        assertEquals("request:future.method", absent.classification)
    }

    @Test fun failuresKeepCodeMachineReasonAndASafeMessageSeparately() {
        fun failure(error: String) = decode("""{"jsonrpc":"2.0","id":"r","error":$error}""").single() as WireMessage.Failure

        val busy = failure("""{"code":4090,"message":"Busy","data":{"reason":"MAX_CONCURRENT_SESSIONS"}}""")
        assertEquals(4090L, busy.code)
        assertEquals("MAX_CONCURRENT_SESSIONS", busy.reason)
        assertEquals("Busy", busy.message)

        val bare = failure("""{"code":-32601}""")
        assertNull(bare.reason)
        assertNull(bare.message)
        // Anything that is not a string reason is no reason; code 4090 alone is not the session limit.
        assertNull(failure("""{"code":4090,"data":{"reason":7}}""").reason)
        assertNull(failure("""{"code":4090,"data":"MAX_CONCURRENT_SESSIONS"}""").reason)
        assertEquals(Long.MIN_VALUE, failure("""{"code":-9223372036854775808}""").code)

        // Hermes' words become one plain line: breaks, control and bidi characters turn into spaces.
        assertEquals("one two three four", failure("""{"code":1,"message":"one\ntwo\u202ethree  four"}""").message)
        assertNull(failure("""{"code":1,"message":" \n\t\u200b "}""").message)
        val long = failure("""{"code":1,"message":"${"x".repeat(400)}"}""").message!!
        assertEquals(280, long.codePointCount(0, long.length))
        assertTrue(long.endsWith("…"))
        val emoji = failure("""{"code":1,"message":"${"😀".repeat(400)}"}""").message!!
        assertEquals(280, emoji.codePointCount(0, emoji.length))
    }
}
