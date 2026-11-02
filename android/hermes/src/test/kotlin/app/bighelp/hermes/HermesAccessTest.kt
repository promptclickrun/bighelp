package app.bighelp.hermes

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Gate credentials and proxy headers are independent typed values with the contract's reserved names. */
class HermesAccessTest {
    private val https = HermesEndpoint.parse("hermes.example/p")
    private val privateHttp = HermesEndpoint.parse("http://192.168.1.5:9119", allowPrivateHttp = true)

    @Test fun cloudflareAccessTrimsAndSendsBothHeaders() {
        val credential = AccessCredential.cloudflareAccess("  id.access  ", " secret-1 \n")
        assertEquals(
            mapOf("CF-Access-Client-Id" to "id.access", "CF-Access-Client-Secret" to "secret-1"),
            credential.headers(),
        )
    }

    @Test fun cloudflareAccessRefusesEmptyLongAndSpacedValues() {
        listOf("" to "s", "i" to "", "has space" to "s", "i" to "x".repeat(513), "i" to "tab\there", "é" to "s").forEach {
            val e = assertThrows(HermesException::class.java) { AccessCredential.cloudflareAccess(it.first, it.second) }
            assertEquals(HermesException.Kind.InvalidAccessCredentials, e.kind)
        }
        AccessCredential.cloudflareAccess("i".repeat(512), "s".repeat(512))
    }

    @Test fun cloudflareAccessIsHttpsOnly() {
        val credential = AccessCredential.cloudflareAccess("i", "s")
        assertTrue(credential.canSend(https))
        assertFalse(credential.canSend(privateHttp))
        assertThrows(HermesException::class.java) { AccessHeaders.of(privateHttp, credential, emptyList()) }
    }

    @Test fun proxyBasicEncodesUtf8WithTrimmedUserAndPreservedPasswordSpaces() {
        val credential = AccessCredential.proxyBasic("  ünï  ", "  pa ss  ")
        val expected = Base64.getEncoder().encodeToString("ünï:  pa ss  ".toByteArray(Charsets.UTF_8))
        assertEquals(mapOf("Authorization" to "Basic $expected"), credential.headers())
        assertTrue("Basic auth may go to an approved private HTTP address", credential.canSend(privateHttp))
        AccessHeaders.of(privateHttp, credential, emptyList())
    }

    @Test fun proxyBasicBounds() {
        listOf("" to "p", "a:b" to "p", "a\u0001" to "p", "u" to "", "u" to "p".repeat(513), "u" to "p\n", "u".repeat(257) to "p")
            .forEach {
                val e = assertThrows(HermesException::class.java) { AccessCredential.proxyBasic(it.first, it.second) }
                assertEquals(HermesException.Kind.InvalidAccessCredentials, e.kind)
            }
        AccessCredential.proxyBasic("u".repeat(256), "p".repeat(512))
    }

    @Test fun customHeadersAcceptTokenNamesAndTrimValues() {
        val header = CustomHeader.of(" X-Access-Id ", "  value é\t1  ")
        assertEquals("X-Access-Id", header.name)
        assertEquals("value é\t1", header.value)
    }

    @Test fun customHeadersRefuseReservedNamesCaseInsensitively() {
        listOf(
            "Host", "authorization", "Proxy-Authorization", "COOKIE", "Content-Type", "Content-Length",
            "Content-Encoding", "Transfer-Encoding", "Connection", "Upgrade", "Keep-Alive", "TE", "Expect", "Accept",
            "Accept-Encoding", "Cache-Control", "Range", "If-Match", "If-None-Match", "Origin",
            "Sec-WebSocket-Protocol", "sec-fetch-mode", "X-Loopdy-Request-ID", "X-Hermes-Session-Token",
            "CF-Access-Client-Id", "cf-access-anything",
        ).forEach {
            val e = assertThrows(it, CustomHeaderException::class.java) { CustomHeader.of(it, "v") }
            assertEquals(it, CustomHeaderException.Problem.Reserved, e.problem)
        }
    }

    @Test fun customHeaderNameAndValueBounds() {
        listOf("", "has space", "colon:name", "né", "x".repeat(129)).forEach {
            assertEquals(CustomHeaderException.Problem.InvalidName, assertThrows(CustomHeaderException::class.java) {
                CustomHeader.of(it, "v")
            }.problem)
        }
        listOf("", "   ", "a\r\nInjected: 1", "a\u0000", "a\u007f", "x".repeat(4_097)).forEach {
            assertEquals(CustomHeaderException.Problem.InvalidValue, assertThrows(CustomHeaderException::class.java) {
                CustomHeader.of("X-Ok", it)
            }.problem)
        }
        CustomHeader.of("x".repeat(128), "v".repeat(4_096))
    }

    @Test fun customHeaderListIsBoundedAndCaseInsensitivelyUnique() {
        val sixteen = (1..16).map { "X-H$it" to "v" }
        assertEquals(16, CustomHeader.list(sixteen).size)
        assertEquals(
            CustomHeaderException.Problem.TooMany,
            assertThrows(CustomHeaderException::class.java) { CustomHeader.list(sixteen + ("X-H17" to "v")) }.problem,
        )
        assertEquals(
            CustomHeaderException.Problem.Duplicate,
            assertThrows(CustomHeaderException::class.java) { CustomHeader.list(listOf("X-A" to "1", "x-a" to "2")) }.problem,
        )
        assertTrue("Blank rows are ignored", CustomHeader.list(listOf("" to "", "  " to " ")).isEmpty())
    }

    @Test fun accessHeadersCombineCredentialAndCustomHeadersAndRedactTheirSecrets() {
        val headers = AccessHeaders.of(
            https,
            AccessCredential.cloudflareAccess("id", "very-secret"),
            listOf(CustomHeader.of("X-Gate", "gate-secret")),
        )
        assertEquals(
            mapOf("CF-Access-Client-Id" to "id", "CF-Access-Client-Secret" to "very-secret", "X-Gate" to "gate-secret"),
            headers.values,
        )
        assertTrue(AccessHeaders.none.values.isEmpty())
        listOf(headers.toString(), AccessCredential.cloudflareAccess("id", "very-secret").toString()).forEach {
            assertFalse(it, "very-secret" in it || "gate-secret" in it)
        }
        assertNull(AccessHeaders.none.values["Authorization"])
    }
}
