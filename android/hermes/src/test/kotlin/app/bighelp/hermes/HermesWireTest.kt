package app.bighelp.hermes

import java.io.File
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class HermesWireTest {
    @Test fun sharedContractVectors() {
        val vectors = Json.parseToJsonElement(File(System.getProperty("hermes.wireVectors")).readText()).jsonObject
        val cases = vectors.getValue("cases").jsonArray
        assertEquals(55, cases.size)
        cases.forEach { element ->
            val case = element.jsonObject
            val name = case.getValue("id").jsonPrimitive.content
            val expected = case.getValue("expected").jsonArray.map { it.jsonPrimitive.content }
            try {
                val actual = HermesWire.decode(case.getValue("frame").jsonPrimitive.content.toByteArray())
                assertEquals(name, expected, actual.map { it.classification })
            } catch (error: WireException) {
                // The vectors spell a rejection "reject:<category>"; tests elsewhere use the bare category.
                assertEquals(name, expected, listOf("reject:${error.category}"))
            }
        }
    }

    @Test fun generatedLimitsUseUtf8BytesAndWholeEnvelopeDepth() {
        fun result(id: String) = """{"jsonrpc":"2.0","id":"$id","result":null}"""
        assertEquals(1, HermesWire.decode(result("é".repeat(512)).toByteArray()).size)
        rejects("invalidResponse", result("é".repeat(512) + "a"))
        val one = result("r")
        assertEquals(4096, HermesWire.decode(List(4096) { one }.joinToString("\n").toByteArray()).size)
        rejects("messageTooLarge", List(4097) { one }.joinToString("\n"))
        val base = """{"jsonrpc":"2.0","id":"r","result":"""
        assertEquals(1, HermesWire.decode((base + "[".repeat(63) + "0" + "]".repeat(63) + "}").toByteArray()).size)
        rejects("messageTooLarge", base + "[".repeat(64) + "0" + "]".repeat(64) + "}")
        // Pad a small valid frame instead, to isolate the entire-message byte ceiling.
        val exact = one + " ".repeat(4_194_304 - one.toByteArray().size)
        assertEquals(1, HermesWire.decode(exact.toByteArray()).size)
        rejects("messageTooLarge", exact + " ")
    }

    @Test fun preservesOpaqueIdsAndMachineRefusalReason() {
        val request = HermesWire.decode("""{"jsonrpc":"2.0","id":" é ","method":"approval","params":{}}""".toByteArray()).single() as WireMessage.Request
        assertEquals(" é ", request.id)
        val refusal = HermesWire.decode("""{"jsonrpc":"2.0","id":"r","error":{"code":4090,"message":"Busy","data":{"reason":"SESSION_NOT_OWNED"}}}""".toByteArray()).single() as WireMessage.Failure
        assertEquals("SESSION_NOT_OWNED", refusal.reason)
    }

    private fun rejects(category: String, frame: String) {
        try {
            HermesWire.decode(frame.toByteArray())
            fail("Expected $category")
        } catch (error: WireException) {
            assertEquals(category, error.category)
        }
    }
}
