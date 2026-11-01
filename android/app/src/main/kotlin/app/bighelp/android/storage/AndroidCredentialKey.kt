package app.bighelp.android.storage

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** Device-local, non-exportable key, usable after first unlock without a prompt for background renewal. */
object AndroidCredentialKey : RecordKeyProvider by AndroidKeyStoreRecordKeys("bighelp.credentials.v1")

internal class AndroidKeyStoreRecordKeys(private val alias: String) : RecordKeyProvider {
    @Synchronized
    override fun existing(): SecretKey? {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(alias)) return null
        return store.getKey(alias, null) as? SecretKey
            ?: throw RecordStorageException(StorageProblem.KeyUnavailable)
    }

    @Synchronized
    override fun getOrCreate(): SecretKey {
        existing()?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(
                KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setKeySize(256)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
        }.generateKey()
    }
}
