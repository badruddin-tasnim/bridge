package com.link.clipboardsync

import android.content.Context
import android.content.SharedPreferences

/**
 * Persistent pairing state for the Mac this phone is bridged to.
 */
object BridgePrefs {
    private const val PREFS_NAME = "ClipboardSyncPrefs"
    private const val KEY_HOST = "server_ip"
    private const val KEY_PORT = "server_port"
    private const val KEY_CODE = "pair_code"
    private const val KEY_MAC_NAME = "mac_name"
    private const val KEY_PAIRED = "paired"

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun host(context: Context): String? = prefs(context).getString(KEY_HOST, null)?.ifBlank { null }
    fun port(context: Context): Int = prefs(context).getInt(KEY_PORT, NetworkSyncClient.DEFAULT_PORT)
    fun code(context: Context): String? = prefs(context).getString(KEY_CODE, null)?.ifBlank { null }
    fun macName(context: Context): String? = prefs(context).getString(KEY_MAC_NAME, null)
    fun isPaired(context: Context): Boolean = prefs(context).getBoolean(KEY_PAIRED, false) && code(context) != null

    fun saveCandidate(context: Context, host: String?, port: Int, code: String) {
        prefs(context).edit()
            .putString(KEY_HOST, host ?: "")
            .putInt(KEY_PORT, port)
            .putString(KEY_CODE, code)
            .putBoolean(KEY_PAIRED, false)
            .apply()
    }

    fun saveHost(context: Context, host: String, port: Int) {
        prefs(context).edit().putString(KEY_HOST, host).putInt(KEY_PORT, port).apply()
    }

    fun markPaired(context: Context, macName: String?) {
        prefs(context).edit()
            .putBoolean(KEY_PAIRED, true)
            .putString(KEY_MAC_NAME, macName ?: "Mac")
            .apply()
    }

    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
    }
}
