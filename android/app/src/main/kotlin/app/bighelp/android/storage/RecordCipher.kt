package app.bighelp.android.storage

import java.security.GeneralSecurityException
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

enum class StorageProblem { CorruptRecord, RecordTooLarge, KeyUnavailable, DiskUnavailable }

/** Carries a category, never a credential, authority or filesystem path. */
class RecordStorageException(val problem: StorageProblem) : Exception(problem.name)

/** The authority is authenticated too: copying ciphertext to another host never adopts its identity. */
class RecordCipher(private val key: () -> SecretKey) {
    fun encrypt(binding: String, plaintext: ByteArray): ByteArray {
        if (plaintext.size > MAXIMUM_RECORD_BYTES) throw RecordStorageException(StorageProblem.RecordTooLarge)
        val secret = deviceKey()
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secret)
            cipher.updateAAD(binding.toByteArray(Charsets.UTF_8))
            val nonce = cipher.iv
            if (nonce.size != NONCE_BYTES) throw RecordStorageException(StorageProblem.KeyUnavailable)
            return MAGIC + nonce + cipher.doFinal(plaintext)
        } catch (_: GeneralSecurityException) {
            throw RecordStorageException(StorageProblem.KeyUnavailable)
        }
    }

    fun decrypt(binding: String, envelope: ByteArray): ByteArray {
        if (envelope.size > MAXIMUM_ENVELOPE_BYTES) throw RecordStorageException(StorageProblem.RecordTooLarge)
        if (envelope.size < OVERHEAD_BYTES || !envelope.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)) {
            throw RecordStorageException(StorageProblem.CorruptRecord)
        }
        val secret = deviceKey()
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val nonce = envelope.copyOfRange(MAGIC.size, MAGIC.size + NONCE_BYTES)
            cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, nonce))
            cipher.updateAAD(binding.toByteArray(Charsets.UTF_8))
            return cipher.doFinal(envelope, MAGIC.size + NONCE_BYTES, envelope.size - MAGIC.size - NONCE_BYTES)
        } catch (_: AEADBadTagException) {
            throw RecordStorageException(StorageProblem.CorruptRecord)
        } catch (_: GeneralSecurityException) {
            throw RecordStorageException(StorageProblem.KeyUnavailable)
        }
    }

    private fun deviceKey(): SecretKey = try {
        key()
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
