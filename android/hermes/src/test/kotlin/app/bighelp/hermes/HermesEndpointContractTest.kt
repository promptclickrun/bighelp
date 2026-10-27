package app.bighelp.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** The CONNECTION.md §1 rules the basic endpoint tests do not pin down. */
class HermesEndpointContractTest {
    private fun canonical(input: String, allowPrivateHttp: Boolean = false) =
        HermesEndpoint.parse(input, allowPrivateHttp).canonical

    private fun rejects(input: String, allowPrivateHttp: Boolean = false, reason: HermesEndpointException.Reason? = null) {
        try {
            HermesEndpoint.parse(input, allowPrivateHttp)
            fail("Expected rejection of '$input'")
        } catch (error: HermesEndpointException) {
            if (reason != null) assertEquals(input, reason, error.reason)
        }
    }

    @Test fun documentedExampleBuildsEveryRoute() {
        val endpoint = HermesEndpoint.parse("HERMES.EXAMPLE:443/hermes/")
        assertEquals("https://hermes.example/hermes", endpoint.canonical)
        assertEquals("https://hermes.example/hermes/api/status", endpoint.httpUrl("/api/status").toString())
        assertEquals("https://hermes.example/hermes/", endpoint.httpUrl("/").toString())
        assertEquals("wss://hermes.example/hermes/api/ws", endpoint.webSocketUrl)
    }

    @Test fun schemeDefaultsToHttpsAndIsCaseInsensitive() {
        assertEquals("https://hermes.example", canonical("hermes.example"))
        assertEquals("https://hermes.example", canonical("HTTPS://Hermes.Example/"))
        listOf("ftp://h.example", "ws://h.example", "wss://h.example", "file://h.example", "://h.example",
            "https:/h.example", "https:///h.example", "https://", "http s://h.example", "https:h.example")
            .forEach { rejects(it, true) }
    }

    @Test fun defaultPortsDisappearAndOthersStayPartOfTheIdentity() {
        assertEquals("https://h.example", canonical("https://h.example:443"))
        assertEquals("https://h.example:8443", canonical("https://h.example:8443"))
        assertEquals("https://h.example:80", canonical("https://h.example:80"))
        assertEquals("http://hermes", canonical("http://hermes:80", true))
        assertEquals("http://hermes:443", canonical("http://hermes:443", true))
        assertEquals("ws://hermes:8080/p/api/ws", HermesEndpoint.parse("http://hermes:8080/p", true).webSocketUrl)
        assertEquals("https://h.example:65535", canonical("h.example:65535"))
        listOf("h.example:0", "h.example:65536", "h.example:", "h.example:-1", "h.example:+1", "h.example:1 2",
            "h.example:999999", "h.example:80a", "h.example::80", "https://h.example:0x50").forEach { rejects(it) }
    }

    @Test fun pathsPreserveThePrefixAndRejectEverythingAmbiguous() {
        assertEquals("https://h.example/a/b", canonical("h.example/a/b/"))
        assertEquals("https://h.example", canonical("h.example/"))
        assertEquals("https://h.example/a-b_c.d~e", canonical("h.example/a-b_c.d~e"))
        listOf("h.example/a//b", "h.example//", "h.example/a/./b", "h.example/./", "h.example/..", "h.example/a/../b",
            "h.example/%2e%2e", "h.example/a%2fb", "h.example/%41", "h.example/a b", "h.example/ü", "h.example/a:b",
            "h.example/a;b", "h.example/a@b", "h.example/a'b", "h.example/a*b", "h.example/a,b", "h.example/a=b",
            "h.example/a+b", "h.example/a!b", "h.example/a(b)", "h.example/a\\b").forEach { rejects(it) }
    }

    @Test fun credentialsQueryAndFragmentAreRefusedEvenWhenEmpty() {
        listOf("https://@h.example", "https://u@h.example", "https://u:p@h.example", "https://h.example:443@evil.example",
            "https://evil.example\\@h.example", "https://h.example?", "https://h.example/?", "https://h.example/a?x=1",
            "https://h.example#", "https://h.example/#f", "h.example/a#b", "https://h.example/p?next=//evil")
            .forEach { rejects(it, true) }
    }

    @Test fun whitespaceControlsAndNonAsciiAreRefused() {
        listOf("", " ", "\th.example", "h.example\n", "h .example", "h.example\u007f", "h.example\u0000", "hérmes.example",
            "h.example\u00a0", "ｈ.example", "h.example/\u2028", "https://h.example/a\r\n", "h" + "e".repeat(2_048) + ".example")
            .forEach { rejects(it, true) }
    }

    @Test fun hostNamesFollowDnsLabelRulesWithoutNumericAliases() {
        assertEquals("https://xn--bcher-kva.example", canonical("XN--BCHER-KVA.EXAMPLE"))
        assertEquals("https://a-b.example", canonical("a-b.example"))
        assertEquals("https://1e3.example", canonical("1e3.example"))
        val label = "a".repeat(63)
        assertEquals("https://$label.example", canonical("$label.example"))
        listOf("${label}a.example", "-a.example", "a-.example", "a..example", ".example", "a_b.example", "a b.example",
            "a.example.", "a.", "[a.example]", "${"a".repeat(62)}.".repeat(5) + "example",
            // Numeric aliases and malformed dotted quads
            "127.1", "127.0.1", "0x7f.0.0.1", "0x7f000001", "2130706433", "017700000001", "1.2.3", "1.2.3.4.5", "256.1.1.1",
            "010.0.0.1", "1.2.3.04", "1.2.3.4.", ".1.2.3.4", "0x1", "0X7F000001", "1..2.3",
        ).forEach { rejects(it, true) }
        assertEquals("https://0.0.0.0", canonical("0.0.0.0"))
        assertEquals("https://8.8.8.8:8080", canonical("8.8.8.8:8080"))
    }

    @Test fun ipv6LiteralsAreBracketedLowercasedAndNeverResolved() {
        assertEquals("https://[::1]", canonical("[::1]"))
        assertEquals("https://[::1]", canonical("::1"))
        assertEquals("https://[fd7a:115c:a1e0::1]:8443/p", canonical("[FD7A:115C:A1E0::1]:8443/p/"))
        assertEquals("https://[fd7a:115c:a1e0::1]", canonical("FD7A:115C:A1E0::1"))
        assertEquals("https://[::ffff:1.2.3.4]", canonical("[::ffff:1.2.3.4]"))
        assertEquals("https://[1:2:3:4:5:6:7:8]", canonical("[1:2:3:4:5:6:7:8]"))
        assertEquals("https://[1:2:3:4:5:6:7::]", canonical("[1:2:3:4:5:6:7::]"))
        assertEquals("wss://[::1]:9/p/api/ws", HermesEndpoint.parse("[::1]:9/p").webSocketUrl)
        assertEquals("https://[::1]:9/p/api/x", HermesEndpoint.parse("[::1]:9/p").httpUrl("/api/x").toString())
        // A bare literal has no way to carry a port, so "::1:8080" is the address ::1:8080, not port 8080.
        assertEquals("https://[::1:8080]", canonical("::1:8080"))
        listOf("[::1", "::1]", "[::1]x", "[::1]:", "[::1]:0", "[[::1]]", "[]", "[:::1]", "[1::2::3]", "[1:2:3:4:5:6:7:8:9]",
            "[1:2:3:4:5:6:7::8]", "[1:2:3:4:5:6:7:8::]", "[12345::]", "[g::1]", "[1.2.3.4]", "[example.com]", "[::1.2.3]",
            "[::01.2.3.4]", "[1.2.3.4::]", "[::1%25en0]", "[::1%en0]", "[fe80::1%25en0]", "::1%en0", "[ ::1]",
            "[::ﬀ]", "1:2:3::4::", "::1/path:x@y", "https://::1", "https://::1:80").forEach { rejects(it, true) }
    }

    @Test fun plainHttpNeedsOptInAndASyntacticallyPrivateHost() {
        val rejectedWithoutOptIn = HermesEndpointException.Reason.PlaintextNotAllowed
        rejects("http://hermes", false, rejectedWithoutOptIn)
        rejects("http://example.com", true, rejectedWithoutOptIn)
        rejects("http://192.0.2.1", true, rejectedWithoutOptIn)
        rejects("http://h.example/%", true, HermesEndpointException.Reason.InvalidEndpoint)

        listOf(
            "127.0.0.1", "127.255.255.254", "10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.255",
            "192.168.0.1", "192.168.255.255", "100.64.0.1", "100.127.255.255", "169.254.1.1",
            "[::1]", "[0:0:0:0:0:0:0:1]", "[fc00::1]", "[fdff:ffff::1]", "[fd7a:115c:a1e0::1]", "[FD7A::1]",
            "hermes", "HERMES", "localhost", "printer.local", "nas.lan", "box.internal", "r.home.arpa", "app.intranet",
            "x.corp", "pc.localdomain", "x.private", "app.localhost", "a.b.local", "bot.ts.net", "x.y.ts.net",
            "bot.beta.tailscale.net", "local", "xlocal",
        ).forEach { assertEquals("http://${it.lowercase()}", canonical("http://$it", true)) }

        listOf(
            "172.15.255.255", "172.32.0.1", "100.63.255.255", "100.128.0.1", "192.167.0.1", "192.169.0.1", "11.0.0.1",
            "9.255.255.255", "169.253.1.1", "126.0.0.1", "128.0.0.1", "1.1.1.1", "0.0.0.0", "255.255.255.255",
            "[::]", "[::2]", "[::ffff:127.0.0.1]", "[::ffff:10.0.0.1]", "[fe80::1]", "[fe00::1]", "[fb00::1]", "[fe00::]",
            "[2001:db8::1]", "[1::1]", "[::1:0]", "[100::1]",
            "example.com", "hermes.example.com", "127.0.0.1.example.com", "hermes.lan.example.com", "example-ts.net",
            "ts.net", "tailscale.net", "beta.tailscale.net", "x.localhost.com", "x.corpus", "my.home.arpa.evil.com",
            "xts.net", "bot.ts.net.evil.com",
        ).forEach { rejects("http://$it", true, HermesEndpointException.Reason.PlaintextNotAllowed) }
    }

    @Test fun routesAreAppOwnedRelativePathsOnly() {
        val endpoint = HermesEndpoint.parse("h.example:8443/p")
        assertEquals("https://h.example:8443/p/api/sessions/abc:1_x-y.z~", endpoint.httpUrl("/api/sessions/abc:1_x-y.z~").toString())
        assertEquals("https://h.example:8443/p/api/files/", endpoint.httpUrl("/api/files/").toString())
        listOf(
            "", "api/x", "x", "https://h.example/p/api/x", "http://evil", "//evil", "//", "/a//b", "/./x", "/x/.", "/..", "/x/../y",
            "/x?q=1", "/x?", "/x#f", "/x#", "/x%2f", "/x%", "/x\\y", "\\x", "/x y", "/x\ty", "/x\ny", "/é", "/x\u0000", "/x\u007f",
            "/x\"y", "/x<y", "/x>y", "/x{y}", "/x|y", "/x^y", "/x`y", "/x[y]", "@evil", "/x\u2028",
        ).forEach { route ->
            try {
                endpoint.httpUrl(route)
                fail("Expected route '$route' to be refused")
            } catch (error: HermesEndpointException) {
                assertEquals(HermesEndpointException.Reason.InvalidRoute, error.reason)
            }
        }
        // Every accepted route stays under the exact origin and prefix.
        val url = endpoint.httpUrl("/api/x")
        assertEquals("h.example", url.host)
        assertEquals(8443, url.port)
        assertTrue(url.path.startsWith("/p/"))
    }

    @Test fun canonicalFormParsesBackToItself() {
        listOf(
            "HERMES.EXAMPLE:443/hermes/", "h.example:8443/a/b/", "[FD7A::1]:80/p", "::1", "http://Hermes.LAN:80/x/",
            "http://[::1]:8080", "https://8.8.8.8", "http://100.64.0.1/p/q",
        ).forEach { input ->
            val first = HermesEndpoint.parse(input, true)
            val again = HermesEndpoint.parse(first.canonical, true)
            assertEquals(input, first.canonical, again.canonical)
            assertEquals(input, first, again)
            assertEquals(first.webSocketUrl, again.webSocketUrl)
        }
    }

    @Test fun identityIncludesSchemePortPrefixAndTheOptIn() {
        val base = HermesEndpoint.parse("https://h.example/a")
        assertEquals(base, HermesEndpoint.parse("H.EXAMPLE:443/a/"))
        assertEquals(base.hashCode(), HermesEndpoint.parse("H.EXAMPLE:443/a/").hashCode())
        assertNotEquals(base, HermesEndpoint.parse("https://h.example/b"))
        assertNotEquals(base, HermesEndpoint.parse("https://h.example:8443/a"))
        assertNotEquals(base, HermesEndpoint.parse("https://h.example"))
        assertNotEquals(base, HermesEndpoint.parse("https://h.example/a", allowPrivateHttp = true))
        assertNotEquals(HermesEndpoint.parse("http://hermes", true), HermesEndpoint.parse("https://hermes", true))
    }

    @Test fun failuresAreIllegalArgumentsThatNeverEchoTheInput() {
        val secret = "https://user:hunter2@h.example/?token=abc"
        try {
            HermesEndpoint.parse(secret)
            fail("credentials must be refused")
        } catch (error: IllegalArgumentException) {
            assertTrue(!(error.message ?: "").contains("hunter2") && !(error.message ?: "").contains("abc"))
        }
    }
}
