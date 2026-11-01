package app.bighelp.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HostStatusTest {
    private fun parse(json: String) = HostStatus.parse(json.toByteArray())

    @Test fun readsTheRequiredBooleanAndKeepsUnknownFlowsAndFields() {
        val status = parse("""{"auth_required":true,"auth_flows":["cookie","future"],"version":"9.9","extra":{"a":[1]}}""")!!
        assertEquals(true, status.authRequired)
        assertEquals(listOf("cookie", "future"), status.authFlows)
        assertEquals(false, status.browserSignIn)
    }

    @Test fun browserSignInNeedsAnAuthRequiredHostAndTheExactFlowName() {
        assertEquals(true, parse("""{"auth_required":true,"auth_flows":["native_pkce"]}""")!!.browserSignIn)
        assertEquals(false, parse("""{"auth_required":false,"auth_flows":["native_pkce"]}""")!!.browserSignIn)
        assertEquals(false, parse("""{"auth_required":true,"auth_flows":["Native_PKCE"]}""")!!.browserSignIn)
    }

    @Test fun missingOrNullFlowsMeanNone() {
        assertEquals(emptyList<String>(), parse("""{"auth_required":false}""")!!.authFlows)
        assertEquals(emptyList<String>(), parse("""{"auth_required":false,"auth_flows":null}""")!!.authFlows)
    }

    @Test fun refusesAnythingThatIsNotTheDocumentedShape() {
        listOf(
            """[]""",
            """{}""",
            """{"auth_required":null}""",
            """{"auth_required":1}""",
            """{"auth_required":"true"}""",
            """{"auth_required":false,"auth_flows":"native_pkce"}""",
            """{"auth_required":false,"auth_flows":[1]}""",
            """{"auth_required":false,"auth_flows":[null]}""",
            """{"auth_required":false,"auth_flows":[""]}""",
            """{"auth_required":false,"auth_flows":["a","a"]}""",
            """{"auth_required":false,"auth_flows":["\ud800"]}""",
            """{"auth_required":false,} """,
            """{"auth_required":false} trailing""",
            """{"auth_required":true,"auth_required":false}""",
            """{"auth_required":false,"a":1,"a":2}""",
        ).forEach { assertNull(it, parse(it)) }
    }

    @Test fun duplicateKeysDeepInsideAreAnotherFieldsBusiness() {
        // Only the fields this client reads have to be unambiguous.
        assertEquals(false, parse("""{"auth_required":false,"other":[{"k":1},{"k":2}]}""")!!.authRequired)
    }

    @Test fun flowCountAndNameLengthAreBounded() {
        val max = (1..32).joinToString(",", "[", "]") { "\"f$it\"" }
        assertEquals(32, parse("""{"auth_required":false,"auth_flows":$max}""")!!.authFlows.size)
        val tooMany = (1..33).joinToString(",", "[", "]") { "\"f$it\"" }
        assertNull(parse("""{"auth_required":false,"auth_flows":$tooMany}"""))

        val longest = "é".repeat(64) // 128 UTF-8 bytes
        assertEquals(listOf(longest), parse("""{"auth_required":false,"auth_flows":["$longest"]}""")!!.authFlows)
        assertNull(parse("""{"auth_required":false,"auth_flows":["${longest}x"]}"""))
    }

    @Test fun theBodyBudgetIsExactlySixteenKibiBytes() {
        val head = """{"auth_required":false,"pad":""""
        val tail = "\"}"
        val fill = HostStatus.MAXIMUM_BYTES - head.length - tail.length
        assertEquals(false, parse(head + "x".repeat(fill) + tail)!!.authRequired)
        assertNull(parse(head + "x".repeat(fill + 1) + tail))
    }

    @Test fun invalidUtf8IsRefused() {
        val bytes = """{"auth_required":false,"note":"""".toByteArray() + byteArrayOf(0xC3.toByte()) + "\"}".toByteArray()
        assertNull(HostStatus.parse(bytes))
    }
}
