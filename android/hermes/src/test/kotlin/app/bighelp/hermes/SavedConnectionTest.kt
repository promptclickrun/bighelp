package app.bighelp.hermes

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SavedConnectionTest {
    private val endpoint = HermesEndpoint.parse("hermes.example/p")
    private val other = HermesEndpoint.parse("hermes.example/q")

    private fun bearer(access: String = "access-1", refresh: String? = "refresh-1", expires: Long? = 1_900_000_000L,
                       provider: String? = "basic", user: String? = "synthetic-user", at: HermesEndpoint = endpoint) =
        SavedConnection(at, StoredAuth.Bearer(access, refresh, expires), provider, user)

    private fun dashboard(token: String = "dash-1", automatic: Boolean = true, at: HermesEndpoint = endpoint) =
        SavedConnection(at, StoredAuth.DashboardSession(token, automatic), null, null)

    private fun kind(block: () -> Unit) = assertThrows(HermesException::class.java) { block() }.kind

    @Test fun authorityIsTheCanonicalEndpointPlusTheExactPrincipal() {
        assertEquals(CredentialAuthority("https://hermes.example/p", "basic\u001fsynthetic-user"), bearer().authority)
        assertEquals(CredentialAuthority("https://hermes.example/p", "dashboard-session"), dashboard().authority)
        assertNotEquals("A prefix is part of the endpoint", bearer().authority, bearer(at = other).authority)
        assertNotEquals("Case matters: no folding", bearer(user = "User").authority, bearer(user = "user").authority)
        assertNotEquals(bearer(user = "é").authority, bearer(user = "é").authority)
    }

    @Test fun validationAcceptsTheTwoShapesAndRefusesIncompleteOnes() {
        bearer().validate()
        bearer(refresh = null, expires = null).validate()
        dashboard().validate()
        assertEquals(HermesException.Kind.SavedConnectionInvalid, kind { bearer(provider = null).validate() })
        assertEquals(HermesException.Kind.SavedConnectionInvalid, kind { bearer(user = null).validate() })
        assertEquals(HermesException.Kind.SavedConnectionInvalid, kind { bearer(provider = "").validate() })
        assertEquals(HermesException.Kind.SavedConnectionInvalid, kind { bearer(user = " padded ").validate() })
        assertEquals(HermesException.Kind.SavedConnectionInvalid, kind { bearer(provider = "p".repeat(129)).validate() })
        assertEquals(HermesException.Kind.SavedConnectionInvalid, kind { bearer(user = "u".repeat(513)).validate() })
        assertEquals(HermesException.Kind.SavedConnectionInvalid, kind { bearer(user = "a\u0007").validate() })
        assertEquals(HermesException.Kind.InvalidCredentials, kind { bearer(access = "has space").validate() })
        assertEquals(HermesException.Kind.InvalidCredentials, kind { bearer(refresh = "").validate() })
        assertEquals(HermesException.Kind.InvalidCredentials, kind { dashboard(token = "").validate() })
        assertEquals(HermesException.Kind.InvalidCredentials, kind { dashboard(token = "é").validate() })
        assertEquals(
            "A dashboard credential has no provider or user",
            HermesException.Kind.SavedConnectionInvalid,
            kind { SavedConnection(endpoint, StoredAuth.DashboardSession("t", true), "basic", "u").validate() },
        )
    }

    @Test fun secretsNeverAppearInToString() {
        val text = listOf(bearer(access = "ACCESS-SECRET", refresh = "REFRESH-SECRET"), dashboard("DASH-SECRET"))
            .joinToString { it.toString() + it.auth.toString() }
        listOf("ACCESS-SECRET", "REFRESH-SECRET", "DASH-SECRET").forEach { assertFalse(it, it in text) }
    }

    @Test fun equalityIsExactForCompareAndReplace() {
        assertEquals(bearer(), bearer())
        assertEquals(bearer().hashCode(), bearer().hashCode())
        assertNotEquals(bearer(), bearer(access = "access-2"))
        assertNotEquals(bearer(), bearer(refresh = null))
        assertNotEquals(bearer(), bearer(expires = 1L))
        assertNotEquals(dashboard(), dashboard(automatic = false))
    }

    @Test fun theCodecRoundTripsBothShapesAndRevalidatesTheEndpoint() {
        listOf(bearer(), bearer(refresh = null, expires = null), dashboard(), dashboard(automatic = false)).forEach {
            assertEquals(it, SavedConnection.fromBytes(it.toBytes()))
        }
        val privateHttp = HermesEndpoint.parse("http://127.0.0.1:9119", allowPrivateHttp = true)
        val saved = bearer(at = privateHttp)
        assertEquals(saved, SavedConnection.fromBytes(saved.toBytes()))
    }

    @Test fun theCodecRefusesUnknownSchemaChangedBindingOversizeAndGarbage() {
        val good = String(bearer().toBytes(), Charsets.UTF_8)
        fun decode(text: String) = kind { SavedConnection.fromBytes(text.toByteArray()) }
        assertEquals(HermesException.Kind.SavedConnectionInvalid, decode(good.replace("\"schemaVersion\":1", "\"schemaVersion\":2")))
        assertEquals(
            "The record's own endpoint binding must match its endpoint",
            HermesException.Kind.SavedConnectionInvalid,
            decode(good.replace("\"credentialEndpointIdentity\":\"https://hermes.example/p\"", "\"credentialEndpointIdentity\":\"https://hermes.example/q\"")),
        )
        assertEquals(HermesException.Kind.SavedConnectionInvalid, decode("{"))
        assertEquals(HermesException.Kind.SavedConnectionInvalid, decode("[]"))
        assertEquals(
            HermesException.Kind.SavedConnectionInvalid,
            kind { SavedConnection.fromBytes(ByteArray(SavedConnection.MAXIMUM_RECORD_BYTES + 1) { 0x20 }) },
        )
        assertEquals(
            "Plain HTTP that is not opted in stays refused when reading a saved record",
            HermesException.Kind.SavedConnectionInvalid,
            decode(good.replace("https://hermes.example/p", "http://hermes.example/p")),
        )
    }

    @Test fun theCodecToleratesUnknownFieldsFromALaterBuild() {
        val withExtra = String(dashboard().toBytes(), Charsets.UTF_8).replaceFirst("{", "{\"futureField\":{\"a\":1},")
        assertEquals(dashboard(), SavedConnection.fromBytes(withExtra.toByteArray()))
    }

    @Test fun theInMemoryStoreIsACompareAndReplaceStore() = runBlocking {
        val store = InMemoryCredentialStore()
        val first = bearer()
        assertNull(store.load(first.authority))
        store.replace(null, first)
        assertEquals(first, store.load(first.authority))

        assertThrows("Insert-only fails when a record exists", StaleCredentialException::class.java) {
            runBlocking { store.replace(null, bearer(access = "other")) }
        }
        val rotated = bearer(access = "access-2", refresh = "refresh-2")
        assertThrows("A stale expectation never overwrites", StaleCredentialException::class.java) {
            runBlocking { store.replace(bearer(access = "stale"), rotated) }
        }
        assertEquals(first, store.load(first.authority))

        store.replace(first, rotated)
        assertEquals(rotated, store.load(first.authority))
        assertThrows(StaleCredentialException::class.java) { runBlocking { store.delete(first) } }
        assertEquals("A stale delete leaves a newer record", rotated, store.load(first.authority))
        store.delete(rotated)
        assertNull(store.load(first.authority))
        assertTrue(store.load(dashboard().authority) == null)
    }

    @Test fun aReplacementMustKeepTheAuthority() = runBlocking {
        val store = InMemoryCredentialStore()
        store.replace(null, bearer())
        assertThrows(IllegalArgumentException::class.java) {
            runBlocking { store.replace(bearer(), bearer(user = "someone-else")) }
        }
        Unit
    }
}
