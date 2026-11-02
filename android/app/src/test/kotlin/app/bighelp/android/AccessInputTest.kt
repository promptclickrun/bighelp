package app.bighelp.android

import app.bighelp.android.live.AccessSetup
import app.bighelp.hermes.AccessCredential
import app.bighelp.hermes.HermesEndpoint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AccessInputTest {
    private fun invalid(input: AccessInput) = (input.build() as AccessBuild.Invalid).problem

    @Test fun nothingEnteredIsNoGate() {
        assertEquals(AccessSetup.None, (AccessInput().build() as AccessBuild.Ok).setup)
        assertTrue(AccessInput(headers = listOf("" to "", " " to " ")).build() is AccessBuild.Ok)
    }

    @Test fun eachKindBuildsTheMatchingCredentialAndHeaders() {
        val cloudflare = (AccessInput(AccessKind.Cloudflare, "cf-id-0123", "cf-secret-0123").build() as AccessBuild.Ok).setup
        assertEquals(AccessCredential.Kind.CloudflareAccess, cloudflare.credential!!.kind)
        val proxy = (AccessInput(AccessKind.ProxyLogin, "gate-user", "gate-pass", listOf("X-Access-Id" to "synthetic")).build() as AccessBuild.Ok).setup
        assertEquals(AccessCredential.Kind.ProxyBasic, proxy.credential!!.kind)
        assertEquals(listOf("X-Access-Id"), proxy.custom.map { it.name })
        val endpoint = HermesEndpoint.parse("https://gated.example.test")
        assertEquals(setOf("Authorization", "X-Access-Id"), proxy.headers(endpoint).values.keys)
    }

    @Test fun eachMistakeHasItsOwnPlainProblem() {
        assertEquals(AccessProblem.Credential, invalid(AccessInput(AccessKind.Cloudflare, "has space", "x")))
        assertEquals(AccessProblem.Credential, invalid(AccessInput(AccessKind.ProxyLogin, "a:b", "pw")))
        assertEquals(AccessProblem.Credential, invalid(AccessInput(AccessKind.ProxyLogin, "", "")))
        assertEquals(AccessProblem.HeaderName, invalid(AccessInput(headers = listOf("bad name" to "v"))))
        assertEquals(AccessProblem.HeaderReserved, invalid(AccessInput(headers = listOf("Authorization" to "v"))))
        assertEquals(AccessProblem.HeaderValue, invalid(AccessInput(headers = listOf("X-One" to ""))))
        assertEquals(AccessProblem.HeaderDuplicate, invalid(AccessInput(headers = listOf("X-One" to "1", "x-one" to "2"))))
        assertEquals(AccessProblem.TooManyHeaders, invalid(AccessInput(headers = (1..17).map { "X-H$it" to "v" })))
    }

    @Test fun theDefaultNameOfAComputerIsItsHostWithoutPortOrPrefix() {
        assertEquals("hermes.example.com", defaultComputerName(HermesEndpoint.parse("https://hermes.example.com/prefix")))
        assertEquals("192.168.1.20", defaultComputerName(HermesEndpoint.parse("http://192.168.1.20:9119", allowPrivateHttp = true)))
    }
}
