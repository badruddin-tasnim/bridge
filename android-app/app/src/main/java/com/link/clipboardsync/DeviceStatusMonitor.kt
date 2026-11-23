package com.link.clipboardsync

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.BatteryManager
import org.json.JSONObject

/**
 * Tracks live phone telemetry (battery, ringer mode, DND state, Find My Phone ringing)
 * and pushes encrypted device_status updates to the connected Mac over TCP :8765.
 */
object DeviceStatusMonitor {
    @Volatile private var lastSentSnapshot: DeviceSnapshot? = null
    @Volatile private var statusReceiver: BroadcastReceiver? = null

    data class BatterySnapshot(
        val level: Int,
        val isCharging: Boolean
    )

    data class DeviceSnapshot(
        val batteryLevel: Int?,
        val isCharging: Boolean,
        val ringerMode: String,
        val isDndEnabled: Boolean,
        val hasDndPermission: Boolean,
        val isRingingPhone: Boolean
    )

    fun parseBatteryIntent(intent: Intent?): BatterySnapshot? {
        if (intent == null) return null
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0) return null

        val percent = ((level * 100f) / scale).toInt().coerceIn(0, 100)
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
        val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL ||
            plugged != 0
        return BatterySnapshot(level = percent, isCharging = isCharging)
    }

    fun readBatterySnapshot(context: Context): BatterySnapshot? {
        val intent = context.applicationContext.registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        )
        parseBatteryIntent(intent)?.let { return it }

        val bm = context.applicationContext.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            ?: return null
        val capacity = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        if (capacity !in 0..100) return null
        return BatterySnapshot(level = capacity, isCharging = bm.isCharging)
    }

    fun readDeviceSnapshot(context: Context, batteryOverride: BatterySnapshot? = null): DeviceSnapshot {
        val appCtx = context.applicationContext
        val battery = batteryOverride ?: readBatterySnapshot(appCtx)
        return DeviceSnapshot(
            batteryLevel = battery?.level,
            isCharging = battery?.isCharging ?: false,
            ringerMode = PhoneControlManager.getRingerModeString(appCtx),
            isDndEnabled = PhoneControlManager.isDndEnabled(appCtx),
            hasDndPermission = PhoneControlManager.hasDndPermission(appCtx),
            isRingingPhone = PhoneControlManager.isRinging
        )
    }

    fun buildDeviceStatusJson(snapshot: BatterySnapshot): String {
        return JSONObject().apply {
            put("type", "device_status")
            put("batteryLevel", snapshot.level)
            put("isCharging", snapshot.isCharging)
        }.toString()
    }

    fun buildDeviceStatusJson(snapshot: DeviceSnapshot): String {
        return JSONObject().apply {
            put("type", "device_status")
            if (snapshot.batteryLevel != null) {
                put("batteryLevel", snapshot.batteryLevel)
                put("isCharging", snapshot.isCharging)
            }
            put("ringerMode", snapshot.ringerMode)
            put("isDndEnabled", snapshot.isDndEnabled)
            put("hasDndPermission", snapshot.hasDndPermission)
            put("isRingingPhone", snapshot.isRingingPhone)
        }.toString()
    }

    fun register(context: Context) {
        val appCtx = context.applicationContext
        if (statusReceiver != null) return

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent?) {
                val batteryOverride = if (intent?.action == Intent.ACTION_BATTERY_CHANGED) {
                    parseBatteryIntent(intent)
                } else {
                    null
                }
                val snapshot = readDeviceSnapshot(appCtx, batteryOverride)
                sendIfChanged(snapshot)
            }
        }
        statusReceiver = receiver
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(AudioManager.RINGER_MODE_CHANGED_ACTION)
            addAction(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
        }
        appCtx.registerReceiver(receiver, filter)
    }

    fun unregister(context: Context) {
        val receiver = statusReceiver ?: return
        statusReceiver = null
        try {
            context.applicationContext.unregisterReceiver(receiver)
        } catch (_: Exception) {}
        lastSentSnapshot = null
    }

    fun sendCurrentStatus(context: Context, force: Boolean = true) {
        val snapshot = readDeviceSnapshot(context)
        if (force) {
            lastSentSnapshot = snapshot
            ClipboardSyncManager.networkClient?.sendRawJson(buildDeviceStatusJson(snapshot))
        } else {
            sendIfChanged(snapshot)
        }
    }

    private fun sendIfChanged(snapshot: DeviceSnapshot) {
        val client = ClipboardSyncManager.networkClient ?: return
        if (!client.isConnected()) return
        if (snapshot == lastSentSnapshot) return

        lastSentSnapshot = snapshot
        client.sendRawJson(buildDeviceStatusJson(snapshot))
    }
}
