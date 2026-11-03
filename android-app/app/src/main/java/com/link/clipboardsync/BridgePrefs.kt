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
    private const val KEY_NOTIF_SYNC_ENABLED = "notif_sync_enabled"
    private const val KEY_MAC_ALERTS_ENABLED = "mac_alerts_enabled"
    private const val KEY_BLACKLISTED_PACKAGES = "notif_blacklisted_pkgs"

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun host(context: Context): String? = prefs(context).getString(KEY_HOST, null)?.ifBlank { null }
    fun port(context: Context): Int = prefs(context).getInt(KEY_PORT, NetworkSyncClient.DEFAULT_PORT)
    fun code(context: Context): String? = prefs(context).getString(KEY_CODE, null)?.ifBlank { null }
    fun macName(context: Context): String? = prefs(context).getString(KEY_MAC_NAME, null)
    fun isPaired(context: Context): Boolean = prefs(context).getBoolean(KEY_PAIRED, false) && code(context) != null

    fun isNotificationSyncEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_NOTIF_SYNC_ENABLED, true)

    fun setNotificationSyncEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_NOTIF_SYNC_ENABLED, enabled).apply()
    }

    fun isMacAlertsEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_MAC_ALERTS_ENABLED, true)

    fun setMacAlertsEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_MAC_ALERTS_ENABLED, enabled).apply()
    }

    fun getBlacklistedPackages(context: Context): Set<String> =
        prefs(context).getStringSet(KEY_BLACKLISTED_PACKAGES, emptySet()) ?: emptySet()

    fun isAppBlacklisted(context: Context, packageName: String): Boolean =
        getBlacklistedPackages(context).contains(packageName)

    fun setAppBlacklisted(context: Context, packageName: String, blacklisted: Boolean) {
        val current = HashSet(getBlacklistedPackages(context))
        if (blacklisted) current.add(packageName) else current.remove(packageName)
        prefs(context).edit().putStringSet(KEY_BLACKLISTED_PACKAGES, current).apply()
    }

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
