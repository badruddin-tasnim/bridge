package com.link.clipboardsync

import android.content.Context
import android.util.Log
import java.util.concurrent.CopyOnWriteArrayList

object ClipboardSyncManager {
    private const val TAG = "ClipboardSyncManager"
    private const val MAX_HISTORY = 20

    data class HistoryItem(val text: String, val outgoing: Boolean, val timestamp: Long)

    interface HistoryListener {
        fun onHistoryChanged()
    }

    @Volatile
    var networkClient: NetworkSyncClient? = null

    @Volatile
    var lastSentHash: String = ""

    @Volatile
    var lastReceivedHash: String = ""

    @Volatile
    var isInternalMutation: Boolean = false

    val history = CopyOnWriteArrayList<HistoryItem>()
    private val historyListeners = CopyOnWriteArrayList<HistoryListener>()

    fun addHistoryListener(l: HistoryListener) { historyListeners.addIfAbsent(l) }
    fun removeHistoryListener(l: HistoryListener) { historyListeners.remove(l) }

    fun recordHistory(text: String, outgoing: Boolean) {
        history.add(0, HistoryItem(text, outgoing, System.currentTimeMillis()))
        while (history.size > MAX_HISTORY) history.removeAt(history.size - 1)
        historyListeners.forEach { try { it.onHistoryChanged() } catch (ignored: Exception) {} }
    }

    /** Creates the shared client and connects if this phone is already paired. */
    fun init(context: Context) {
        if (networkClient == null) {
            synchronized(this) {
                if (networkClient == null) {
                    val client = NetworkSyncClient(context.applicationContext)
                    networkClient = client
                    if (BridgePrefs.isPaired(context)) {
                        client.start(BridgePrefs.host(context), BridgePrefs.port(context), BridgePrefs.code(context))
                    }
                    Log.i(TAG, "ClipboardSyncManager initialized (paired=${BridgePrefs.isPaired(context)})")
                }
            }
        }
    }

    /** Attempts to pair with a Mac. Result is delivered via SyncListener.onPairingResult. */
    fun pair(context: Context, host: String?, port: Int, code: String) {
        init(context)
        BridgePrefs.saveCandidate(context, host, port, code)
        networkClient?.start(host, port, code)
    }

    fun unpair(context: Context) {
        networkClient?.sendUnpairAndStop()
        BridgePrefs.clear(context)
        history.clear()
        historyListeners.forEach { try { it.onHistoryChanged() } catch (ignored: Exception) {} }
    }

    fun dispatchTextToMac(context: Context, text: String, source: String) {
        if (text.isEmpty()) return

        val hash = ClipboardPayload.computeSHA256(text)
        Log.d(TAG, "[$source] dispatchTextToMac (${text.length} chars, hash: ${hash.take(8)})")

        // Loopback echo & deduplication check
        if (hash == lastReceivedHash || hash == lastSentHash) {
            Log.d(TAG, "Suppressed duplicate/echo: Matches last received or sent hash")
            return
        }

        lastSentHash = hash
        init(context)

        val client = networkClient
        if (client != null) {
            client.sendPayload(ClipboardPayload(type = "clip", hash = hash, text = text))
            recordHistory(text, outgoing = true)
        } else {
            Log.e(TAG, "NetworkSyncClient is null, cannot dispatch!")
        }
    }
}
