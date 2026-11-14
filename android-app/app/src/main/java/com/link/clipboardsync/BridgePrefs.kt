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
    private const val KEY_NOTIF_MASTER_ENABLED = "notif_master_enabled"
    private const val KEY_NOTIF_SYNC_ENABLED = "notif_sync_enabled"
    private const val KEY_MAC_ALERTS_ENABLED = "mac_alerts_enabled"
    private const val KEY_PHONE_VIBRATE_ENABLED = "phone_vibrate_mac_alerts"
    private const val KEY_AUTO_ACCEPT_FILES = "auto_accept_incoming_files"
    private const val KEY_SETTINGS_UPDATED_AT = "settings_updated_at"
    private const val KEY_BLACKLISTED_PACKAGES = "notif_blacklisted_pkgs"
    private const val KEY_CUSTOM_SAVE_TREE_URI = "custom_save_tree_uri"
    private const val KEY_CUSTOM_SAVE_DISPLAY_NAME = "custom_save_display_name"

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun host(context: Context): String? = prefs(context).getString(KEY_HOST, null)?.ifBlank { null }
    fun port(context: Context): Int = prefs(context).getInt(KEY_PORT, NetworkSyncClient.DEFAULT_PORT)
    fun code(context: Context): String? = prefs(context).getString(KEY_CODE, null)?.ifBlank { null }
    fun macName(context: Context): String? = prefs(context).getString(KEY_MAC_NAME, null)
    fun isPaired(context: Context): Boolean = prefs(context).getBoolean(KEY_PAIRED, false) && code(context) != null

    // Master Notification Toggle
    fun isNotifMasterEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_NOTIF_MASTER_ENABLED, true)

    fun setNotifMasterEnabled(context: Context, enabled: Boolean, updateTimestamp: Boolean = true) {
        val editor = prefs(context).edit().putBoolean(KEY_NOTIF_MASTER_ENABLED, enabled)
        if (updateTimestamp) {
            editor.putLong(KEY_SETTINGS_UPDATED_AT, System.currentTimeMillis())
        }
        editor.apply()
    }

    // Sub-option 1: Android Notifications (Phone -> Mac)
    fun isAndroidNotifEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_NOTIF_SYNC_ENABLED, true)

    fun setAndroidNotifEnabled(context: Context, enabled: Boolean, updateTimestamp: Boolean = true) {
        val editor = prefs(context).edit().putBoolean(KEY_NOTIF_SYNC_ENABLED, enabled)
        if (updateTimestamp) {
            editor.putLong(KEY_SETTINGS_UPDATED_AT, System.currentTimeMillis())
        }
        editor.apply()
    }

    // Effective check: Master ON && Android Sub-option ON
    fun isNotificationSyncEnabled(context: Context): Boolean =
        isNotifMasterEnabled(context) && isAndroidNotifEnabled(context)

    fun setNotificationSyncEnabled(context: Context, enabled: Boolean) {
        setAndroidNotifEnabled(context, enabled, updateTimestamp = true)
    }

    // Sub-option 2: Mac Notifications (Mac -> Phone)
    fun isMacNotifEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_MAC_ALERTS_ENABLED, true)

    fun setMacNotifEnabled(context: Context, enabled: Boolean, updateTimestamp: Boolean = true) {
        val editor = prefs(context).edit().putBoolean(KEY_MAC_ALERTS_ENABLED, enabled)
        if (updateTimestamp) {
            editor.putLong(KEY_SETTINGS_UPDATED_AT, System.currentTimeMillis())
        }
        editor.apply()
    }

    // Effective check: Master ON && Mac Sub-option ON
    fun isMacAlertsEnabled(context: Context): Boolean =
        isNotifMasterEnabled(context) && isMacNotifEnabled(context)

    fun setMacAlertsEnabled(context: Context, enabled: Boolean) {
        setMacNotifEnabled(context, enabled, updateTimestamp = true)
    }

    // Phone-Only Setting: Vibrate on Mac Alerts
    fun isPhoneVibrateEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_PHONE_VIBRATE_ENABLED, true)

    fun setPhoneVibrateEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_PHONE_VIBRATE_ENABLED, enabled).apply()
    }

    // Synced Setting: Auto-accept incoming files from paired Mac (defaults to false for security)
    fun isAutoAcceptFilesEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_AUTO_ACCEPT_FILES, false)

    fun setAutoAcceptFilesEnabled(context: Context, enabled: Boolean, updateTimestamp: Boolean = true) {
        val editor = prefs(context).edit().putBoolean(KEY_AUTO_ACCEPT_FILES, enabled)
        if (updateTimestamp) {
            editor.putLong(KEY_SETTINGS_UPDATED_AT, System.currentTimeMillis())
        }
        editor.apply()
    }

    // Phone-Only Setting: Preferred Save Location for received files
    fun getCustomSaveTreeUri(context: Context): String? =
        prefs(context).getString(KEY_CUSTOM_SAVE_TREE_URI, null)?.ifBlank { null }

    fun getCustomSaveDisplayName(context: Context): String? =
        prefs(context).getString(KEY_CUSTOM_SAVE_DISPLAY_NAME, null)?.ifBlank { null }

    fun hasCustomSaveLocation(context: Context): Boolean =
        !getCustomSaveTreeUri(context).isNullOrBlank()

    fun setCustomSaveLocation(context: Context, treeUri: String?, displayName: String?) {
        val editor = prefs(context).edit()
        if (treeUri != null && !displayName.isNullOrBlank()) {
            editor.putString(KEY_CUSTOM_SAVE_TREE_URI, treeUri)
            editor.putString(KEY_CUSTOM_SAVE_DISPLAY_NAME, displayName)
        } else {
            editor.remove(KEY_CUSTOM_SAVE_TREE_URI)
            editor.remove(KEY_CUSTOM_SAVE_DISPLAY_NAME)
        }
        editor.apply()
    }

    fun getSettingsUpdatedAt(context: Context): Long =
        prefs(context).getLong(KEY_SETTINGS_UPDATED_AT, 0L)

    fun setSettingsUpdatedAt(context: Context, ts: Long) {
        prefs(context).edit().putLong(KEY_SETTINGS_UPDATED_AT, ts).apply()
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

    fun clearPairing(context: Context) {
        prefs(context).edit()
            .remove(KEY_HOST)
            .remove(KEY_PORT)
            .remove(KEY_CODE)
            .remove(KEY_MAC_NAME)
            .remove(KEY_PAIRED)
            .apply()
    }

    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
    }
}
