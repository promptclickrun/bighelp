package app.bighelp.hermes

import org.junit.Assert.*
import org.junit.Test

class HermesEndpointTest {
    @Test fun normalizesIdentityAndPreservesDeploymentPrefix() {
        val endpoint = HermesEndpoint.parse("HERMES.EXAMPLE:443/hermes/")
        assertEquals("https://hermes.example/hermes", endpoint.canonical)
        assertEquals("https://hermes.example/hermes/api/status", endpoint.httpUrl("/api/status").toString())
        assertEquals("wss://hermes.example/hermes/api/ws", endpoint.webSocketUrl)
    }

    @Test fun privateHttpRequiresBothOptInAndPrivateSyntax() {
        listOf("127.0.0.1", "10.2.3.4", "100.64.0.1", "hermes", "bot.ts.net", "[::1]").forEach {
            rejects("http://$it")
            assertTrue(HermesEndpoint.parse("http://$it", true).canonical.startsWith("http://"))
        }
        listOf("example.com", "127.0.0.1.example.com", "example-ts.net", "8.8.8.8", "[fe80::1]").forEach {
            rejects("http://$it", true)
        }
    }

    @Test fun rejectsCredentialSmugglingTraversalAndAmbiguousAddresses() {
        listOf(" https://hermes.example", "https://u:p@hermes.example", "https://hermes.example/?token=x",
            "https://hermes.example/#x", "https://hermes.example/a/../b", "https://hermes.example/%2e",
            "https://hermes.example//a", "https://hermes.example:", "https://hermes.example:65536",
            "https://127.1", "https://0x7f000001", "https://2130706433", "https://host.", "https://host\\evil"
        ).forEach { rejects(it, true) }
        val endpoint = HermesEndpoint.parse("hermes.example/prefix")
        listOf("https://other.example", "//evil", "/a/../b", "/api/x?q=1", "/%2f").forEach {
            try { endpoint.httpUrl(it); fail(it) } catch (_: IllegalArgumentException) { }
        }
    }

    private fun rejects(input: String, allowPrivateHttp: Boolean = false) {
        try { HermesEndpoint.parse(input, allowPrivateHttp); fail(input) } catch (_: IllegalArgumentException) { }
    }
}
