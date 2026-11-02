package com.chaisz.paircast.android.platform

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.chaisz.paircast.core.store.KeyValueStore
import com.chaisz.paircast.core.store.SecureStore

/** Keystore-backed encrypted prefs for the cloud config JSON and the GO-IM session token. */
class EncryptedSecureStore(context: Context) : SecureStore {
    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        "paircast.secure",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    override fun read(key: String): String? = prefs.getString(key, null)
    override fun write(key: String, value: String) = prefs.edit { putString(key, value) }
    override fun delete(key: String) = prefs.edit { remove(key) }
}

/** Plain preferences: subtitle offsets, local block list, UI choices. */
class PrefsKeyValueStore(context: Context) : KeyValueStore {
    private val prefs = context.getSharedPreferences("paircast.prefs", Context.MODE_PRIVATE)

    override fun getString(key: String): String? = prefs.getString(key, null)
    override fun putString(key: String, value: String) = prefs.edit { putString(key, value) }
    override fun remove(key: String) = prefs.edit { remove(key) }
}
