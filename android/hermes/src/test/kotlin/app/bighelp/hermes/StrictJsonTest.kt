package app.bighelp.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

/** The parser on its own, for the cases the byte-level decoder's earlier checks make unreachable. */
class StrictJsonTest {
    private fun rejects(text: String) {
        try {
            StrictJson.parse(text)
            fail("Expected '$text' to be malformed")
        } catch (_: StrictJson.Malformed) {
        }
    }

    @Test fun unpairedSurrogateCharactersAreMalformedEvenWhenNotEscaped() {
        rejects("\"\ud800\"")
        rejects("\"\udc00\"")
        rejects("\"\ud800a\"")
        rejects("\"\udc00\ud800\"")
        assertEquals("\"😀\"", StrictJson.parse("\"😀\"").toString())
    }

    @Test fun parserEnforcesItsOwnDepthCeiling() {
        StrictJson.parse("[".repeat(64) + "]".repeat(64))
        rejects("[".repeat(65) + "]".repeat(65))
        rejects("{\"a\":".repeat(65) + "0" + "}".repeat(65))
    }
}
