package app.bighelp.android.storage

import java.security.GeneralSecurityException
import java.security.ProviderException
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

enum class StorageProblem { CorruptRecord, RecordTooLarge, KeyMissing, KeyUnavailable, DiskUnavailable, InvalidBinding }

/** Carries a category, never a credential, authority or filesystem path. */
class RecordStorageException(val problem: StorageProblem) : Exception(problem.name)

interface RecordKeyProvider {
    fun existing(): SecretKey?
    fun getOrCreate(): SecretKey
}

/** The record binding is authenticated too, so ciphertext cannot be adopted under another key. */
class RecordCipher internal constructor(
    private val keys: RecordKeyProvider,
    private val cipherFactory: () -> Cipher,
) {
    constructor(keys: RecordKeyProvider) : this(keys, { Cipher.getInstance("AES/GCM/NoPadding") })
    constructor(key: () -> SecretKey) : this(object : RecordKeyProvider {
        override fun existing() = key()
        override fun getOrCreate() = key()
    })

    fun encrypt(binding: String, plaintext: ByteArray): ByteArray {
        if (plaintext.size > MAXIMUM_RECORD_BYTES) throw RecordStorageException(StorageProblem.RecordTooLarge)
        val bindingBytes = recordBindingBytes(binding)
        val secret = deviceKey(create = true)
        try {
            val cipher = cipherFactory()
            cipher.init(Cipher.ENCRYPT_MODE, secret)
            cipher.updateAAD(MAGIC)
            cipher.updateAAD(bindingBytes)
            val nonce = cipher.iv
            if (nonce.size != NONCE_BYTES) throw RecordStorageException(StorageProblem.KeyUnavailable)
            return MAGIC + nonce + cipher.doFinal(plaintext)
        } catch (_: GeneralSecurityException) {
            throw RecordStorageException(StorageProblem.KeyUnavailable)
        } catch (_: ProviderException) {
            throw RecordStorageException(StorageProblem.KeyUnavailable)
        }
    }

    fun decrypt(binding: String, envelope: ByteArray): ByteArray {
        if (envelope.size > MAXIMUM_ENVELOPE_BYTES) throw RecordStorageException(StorageProblem.RecordTooLarge)
        if (envelope.size < OVERHEAD_BYTES || !envelope.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)) {
            throw RecordStorageException(StorageProblem.CorruptRecord)
        }
        val bindingBytes = recordBindingBytes(binding)
        val secret = deviceKey(create = false)
        try {
            val cipher = cipherFactory()
            val nonce = envelope.copyOfRange(MAGIC.size, MAGIC.size + NONCE_BYTES)
            cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, nonce))
            cipher.updateAAD(MAGIC)
            cipher.updateAAD(bindingBytes)
            return cipher.doFinal(envelope, MAGIC.size + NONCE_BYTES, envelope.size - MAGIC.size - NONCE_BYTES)
        } catch (_: AEADBadTagException) {
            throw RecordStorageException(StorageProblem.CorruptRecord)
        } catch (_: GeneralSecurityException) {
            throw RecordStorageException(StorageProblem.KeyUnavailable)
        } catch (_: ProviderException) {
            throw RecordStorageException(StorageProblem.KeyUnavailable)
        }
    }

    private fun deviceKey(create: Boolean): SecretKey = try {
        keys.existing() ?: if (create) keys.getOrCreate() else throw RecordStorageException(StorageProblem.KeyMissing)
    } catch (failure: RecordStorageException) {
        throw failure
    } catch (_: Exception) {
        throw RecordStorageException(StorageProblem.KeyUnavailable)
    }

    companion object {
        const val MAXIMUM_RECORD_BYTES = 65_536
        private val MAGIC = "BHCREDS1".toByteArray(Charsets.US_ASCII)
        private const val NONCE_BYTES = 12
        private val OVERHEAD_BYTES = MAGIC.size + NONCE_BYTES + 16
        val MAXIMUM_ENVELOPE_BYTES = MAXIMUM_RECORD_BYTES + OVERHEAD_BYTES
    }
}

internal fun recordBindingBytes(binding: String): ByteArray {
    if (binding.isEmpty() || binding.length > 8_192) throw RecordStorageException(StorageProblem.InvalidBinding)
    val encoded = try {
        Charsets.UTF_8.newEncoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .encode(CharBuffer.wrap(binding))
    } catch (_: CharacterCodingException) {
        throw RecordStorageException(StorageProblem.InvalidBinding)
    }
    if (encoded.remaining() > 8_192) throw RecordStorageException(StorageProblem.InvalidBinding)
    return ByteArray(encoded.remaining()).also(encoded::get)
}
