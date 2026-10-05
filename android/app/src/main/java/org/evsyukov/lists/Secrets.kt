package org.evsyukov.lists

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The WebDAV password, encrypted with a key that never leaves the Android
 * Keystore. Only the ciphertext is written to the app's preferences; the core
 * gets the password in memory after the store is opened.
 */
object Secrets {
    private const val KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "lists.webdav"
    private const val PREFS = "secrets"
    private const val VALUE = "webdav"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).apply { init(spec) }.generateKey()
    }

    fun save(context: Context, password: String?) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (password.isNullOrEmpty()) {
            prefs.edit().remove(VALUE).apply()
            return
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.iv + cipher.doFinal(password.toByteArray())
        // The 12-byte nonce chosen by the keystore goes in front of the ciphertext.
        prefs.edit().putString(VALUE, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    /** Null when nothing is stored or the key is gone (for example after a restore to another device). */
    fun load(context: Context): String? = runCatching {
        val stored = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(VALUE, null) ?: return null
        val sealed = Base64.decode(stored, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, 12))
        String(cipher.doFinal(sealed, 12, sealed.size - 12))
    }.getOrNull()
}
