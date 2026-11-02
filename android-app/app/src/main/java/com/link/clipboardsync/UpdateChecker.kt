package com.link.clipboardsync

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.max

/**
 * Checks GitHub Releases (`badruddin-tasnim/bridge`) for newer versions of Bridge.
 *
 * - Notifies users via both an in-app banner (with a cancel/dismiss button) and a system notification.
 * - Respects a 24-hour (1 day) cooldown when dismissed or notified so users are never nagged
 *   more than once in the same day, and re-prompts after 24 hours if still not updated.
 */
object UpdateChecker {
    private const val TAG = "UpdateChecker"
    private const val PREFS_NAME = "BridgeUpdatePrefs"
    private const val GITHUB_LATEST_RELEASE_URL = "https://api.github.com/repos/badruddin-tasnim/bridge/releases/latest"
    private const val FALLBACK_RELEASES_URL = "https://github.com/badruddin-tasnim/bridge/releases/latest"

    private const val KEY_LATEST_VERSION = "latest_version"
    private const val KEY_DOWNLOAD_URL = "download_url"
    private const val KEY_DISMISSED_VERSION = "dismissed_version"
    private const val KEY_DISMISSED_AT = "dismissed_at"
    private const val KEY_LAST_NOTIFIED_VERSION = "last_notified_version"
    private const val KEY_LAST_NOTIFIED_AT = "last_notified_at"
    private const val KEY_LAST_CHECK_AT = "last_check_at"

    private const val ONE_DAY_MS = 24 * 60 * 60 * 1000L
    private const val MIN_CHECK_INTERVAL_MS = 60 * 60 * 1000L // 1 hour minimum between network fetches
    private const val BACKGROUND_POLL_HOURS = 6L

    private const val UPDATE_CHANNEL_ID = "bridge_updates"
    private const val UPDATE_NOTIFICATION_ID = 102

    data class UpdateInfo(
        val version: String,
        val downloadUrl: String
    )

    interface UpdateListener {
        fun onUpdateStateChanged(update: UpdateInfo?)
    }

    private val listeners = CopyOnWriteArrayList<UpdateListener>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    @Volatile
    private var periodicStarted = false

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun addListener(context: Context, listener: UpdateListener) {
        listeners.addIfAbsent(listener)
        listener.onUpdateStateChanged(getVisibleUpdate(context))
    }

    fun removeListener(listener: UpdateListener) {
        listeners.remove(listener)
    }

    /**
     * Starts periodic background update checks (on launch + every 6 hours).
     */
    fun startPeriodicChecks(context: Context) {
        if (periodicStarted) return
        synchronized(this) {
            if (periodicStarted) return
            periodicStarted = true
            val appCtx = context.applicationContext
            scheduler.scheduleWithFixedDelay({
                checkForUpdates(appCtx, forceNetwork = false)
            }, 0, BACKGROUND_POLL_HOURS, TimeUnit.HOURS)
        }
    }

    /**
     * Checks GitHub for the latest release and updates cached state & notifications.
     */
    fun checkForUpdates(context: Context, forceNetwork: Boolean = false) {
        val appCtx = context.applicationContext
        scheduler.execute {
            try {
                val p = prefs(appCtx)
                val now = System.currentTimeMillis()
                val lastCheck = p.getLong(KEY_LAST_CHECK_AT, 0L)

                if (forceNetwork || now - lastCheck >= MIN_CHECK_INTERVAL_MS) {
                    fetchLatestReleaseFromGitHub(appCtx)
                }

                evaluateAndNotify(appCtx)
            } catch (e: Exception) {
                Log.w(TAG, "Update check error: ${e.message}")
            }
        }
    }

    /**
     * Returns the available [UpdateInfo] if a newer version exists AND hasn't been dismissed within the last 24 hours.
     */
    fun getVisibleUpdate(context: Context): UpdateInfo? {
        val p = prefs(context)
        val latestVersion = p.getString(KEY_LATEST_VERSION, null) ?: return null
        val downloadUrl = p.getString(KEY_DOWNLOAD_URL, null) ?: FALLBACK_RELEASES_URL
        val currentVersion = getInstalledVersion(context)

        if (!isNewerVersion(latestVersion, currentVersion)) {
            return null
        }

        if (isDismissedWithinLastDay(p, latestVersion)) {
            return null
        }

        return UpdateInfo(version = latestVersion, downloadUrl = downloadUrl)
    }

    /**
     * Called when the user taps the Cancel (X) button on the update banner.
     * Hides the update notification for 24 hours (1 day), after which it will remind again.
     */
    fun dismissUpdateForToday(context: Context) {
        val p = prefs(context)
        val latestVersion = p.getString(KEY_LATEST_VERSION, null) ?: return
        p.edit()
            .putString(KEY_DISMISSED_VERSION, latestVersion)
            .putLong(KEY_DISMISSED_AT, System.currentTimeMillis())
            .apply()

        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(UPDATE_NOTIFICATION_ID)
        } catch (ignored: Exception) {}

        notifyListenersOnMain(null)
    }

    private fun isDismissedWithinLastDay(p: SharedPreferences, version: String): Boolean {
        val dismissedVer = p.getString(KEY_DISMISSED_VERSION, null) ?: return false
        val dismissedAt = p.getLong(KEY_DISMISSED_AT, 0L)
        if (dismissedVer != version) return false
        return (System.currentTimeMillis() - dismissedAt) < ONE_DAY_MS
    }

    private fun fetchLatestReleaseFromGitHub(context: Context) {
        var conn: HttpURLConnection? = null
        try {
            val url = URL(GITHUB_LATEST_RELEASE_URL)
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 8000
                readTimeout = 8000
                setRequestProperty("Accept", "application/vnd.github+json")
                setRequestProperty("User-Agent", "Bridge-Android-App")
            }

            if (conn.responseCode == HttpURLConnection.HTTP_OK) {
                val body = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { it.readText() }
                val json = JSONObject(body)
                val rawTag = json.optString("tag_name", "").trim()
                val cleanVersion = rawTag.removePrefix("v").removePrefix("V").trim()
                if (cleanVersion.isNotEmpty()) {
                    var targetUrl = json.optString("html_url", FALLBACK_RELEASES_URL)
                    val assets = json.optJSONArray("assets")
                    if (assets != null) {
                        for (i in 0 until assets.length()) {
                            val asset = assets.optJSONObject(i) ?: continue
                            val name = asset.optString("name", "")
                            val browserUrl = asset.optString("browser_download_url", "")
                            if (name.endsWith(".apk", ignoreCase = true) && browserUrl.isNotEmpty()) {
                                targetUrl = browserUrl
                                break
                            }
                        }
                    }

                    if (!isTrustedGitHubUrl(targetUrl)) {
                        targetUrl = FALLBACK_RELEASES_URL
                    }

                    prefs(context).edit()
                        .putString(KEY_LATEST_VERSION, cleanVersion)
                        .putString(KEY_DOWNLOAD_URL, targetUrl)
                        .putLong(KEY_LAST_CHECK_AT, System.currentTimeMillis())
                        .apply()

                    Log.d(TAG, "Fetched latest GitHub release: v$cleanVersion")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to query GitHub releases: ${e.message}")
        } finally {
            conn?.disconnect()
        }
    }

    private fun evaluateAndNotify(context: Context) {
        val visibleUpdate = getVisibleUpdate(context)
        notifyListenersOnMain(visibleUpdate)

        if (visibleUpdate != null) {
            val p = prefs(context)
            val now = System.currentTimeMillis()
            val lastNotifiedVer = p.getString(KEY_LAST_NOTIFIED_VERSION, null)
            val lastNotifiedAt = p.getLong(KEY_LAST_NOTIFIED_AT, 0L)

            // Show system notification at most once per day
            val shouldPostSystemNotif = (lastNotifiedVer != visibleUpdate.version) ||
                    (now - lastNotifiedAt >= ONE_DAY_MS)

            if (shouldPostSystemNotif) {
                postSystemUpdateNotification(context, visibleUpdate)
                p.edit()
                    .putString(KEY_LAST_NOTIFIED_VERSION, visibleUpdate.version)
                    .putLong(KEY_LAST_NOTIFIED_AT, now)
                    .apply()
            }
        }
    }

    private fun postSystemUpdateNotification(context: Context, update: UpdateInfo) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    UPDATE_CHANNEL_ID,
                    "App Updates",
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "Notifies you when a new version of Bridge is released on GitHub"
                }
                nm.createNotificationChannel(channel)
            }

            val openIntent = Intent(Intent.ACTION_VIEW, Uri.parse(update.downloadUrl)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val pendingOpen = PendingIntent.getActivity(
                context,
                201,
                openIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            val notification = NotificationCompat.Builder(context, UPDATE_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Bridge v${update.version} is available")
                .setContentText("Tap to download the latest update from GitHub.")
                .setAutoCancel(true)
                .setContentIntent(pendingOpen)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()

            nm.notify(UPDATE_NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to post update notification: ${e.message}")
        }
    }

    private fun notifyListenersOnMain(update: UpdateInfo?) {
        mainHandler.post {
            for (l in listeners) {
                try { l.onUpdateStateChanged(update) } catch (ignored: Exception) {}
            }
        }
    }

    fun getInstalledVersion(context: Context): String {
        return try {
            val pInfo = context.packageManager.getPackageInfo(context.packageName, 0)
            pInfo.versionName ?: "1.0.0"
        } catch (e: Exception) {
            "1.0.0"
        }
    }

    /**
     * Compares two semantic version strings (e.g. "1.1.0" vs "1.0").
     * Trailing zeros are normalized so "1.0" == "1.0.0" and "1.1" > "1.0.0".
     */
    fun isNewerVersion(remote: String, current: String): Boolean {
        val rParts = parseVersionParts(remote)
        val cParts = parseVersionParts(current)
        val len = max(rParts.size, cParts.size)
        for (i in 0 until len) {
            val r = if (i < rParts.size) rParts[i] else 0
            val c = if (i < cParts.size) cParts[i] else 0
            if (r > c) return true
            if (r < c) return false
        }
        return false
    }

    private fun isTrustedGitHubUrl(url: String): Boolean {
        return url.startsWith("https://github.com/badruddin-tasnim/bridge/") ||
                url.startsWith("https://objects.githubusercontent.com/")
    }

    private fun parseVersionParts(version: String): List<Int> {
        val clean = version.trim()
            .removePrefix("v")
            .removePrefix("V")
            .substringBefore("-")
            .substringBefore("+")
        return clean.split(".")
            .map { it.trim().toIntOrNull() ?: 0 }
    }
}
