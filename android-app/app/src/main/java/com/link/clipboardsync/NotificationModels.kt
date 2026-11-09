package com.link.clipboardsync

import org.json.JSONArray
import org.json.JSONObject

data class BridgeNotificationAction(
    val id: Int,
    val title: String,
    val hasInput: Boolean = false,
    val placeholder: String? = null
) {
    fun toJson(): JSONObject {
        val json = JSONObject()
        json.put("id", id)
        json.put("title", title)
        json.put("hasInput", hasInput)
        placeholder?.let { json.put("placeholder", it) }
        return json
    }

    companion object {
        fun fromJson(json: JSONObject): BridgeNotificationAction {
            return BridgeNotificationAction(
                id = json.optInt("id", 0),
                title = json.optString("title", ""),
                hasInput = json.optBoolean("hasInput", false),
                placeholder = json.optString("placeholder").ifEmpty { null }
            )
        }
    }
}

data class BridgeMessageItem(
    val text: String,
    val timestamp: Long = System.currentTimeMillis(),
    val sender: String? = null
) {
    fun toJson(): JSONObject {
        val json = JSONObject()
        json.put("text", text)
        json.put("timestamp", timestamp)
        sender?.let { json.put("sender", it) }
        return json
    }

    companion object {
        fun fromJson(json: JSONObject): BridgeMessageItem {
            return BridgeMessageItem(
                text = json.optString("text", ""),
                timestamp = json.optLong("timestamp", System.currentTimeMillis()),
                sender = json.optString("sender").ifEmpty { null }
            )
        }
    }
}

data class BridgeNotification(
    val id: String,
    val source: String = "android", // "android" or "mac"
    val pkg: String = "",
    val app: String = "",
    val title: String = "",
    val text: String = "",
    val icon: String? = null, // Base64 encoded PNG
    val timestamp: Long = System.currentTimeMillis(),
    val actions: List<BridgeNotificationAction> = emptyList(),
    val isSilent: Boolean = false,
    val messages: List<BridgeMessageItem>? = null
) {
    fun toPostJsonString(): String {
        val json = JSONObject()
        json.put("type", "notif_post")
        json.put("id", id)
        json.put("source", source)
        json.put("pkg", pkg)
        json.put("app", app)
        json.put("title", title)
        json.put("text", text)
        json.put("timestamp", timestamp)
        json.put("isSilent", isSilent)
        icon?.let { json.put("icon", it) }

        if (actions.isNotEmpty()) {
            val arr = JSONArray()
            actions.forEach { arr.put(it.toJson()) }
            json.put("actions", arr)
        }

        if (messages != null && messages.isNotEmpty()) {
            val arr = JSONArray()
            messages.forEach { arr.put(it.toJson()) }
            json.put("messages", arr)
        }

        return json.toString()
    }

    companion object {
        fun fromJson(json: JSONObject): BridgeNotification? {
            val id = json.optString("id").ifEmpty { return null }
            val actionsList = ArrayList<BridgeNotificationAction>()
            val arr = json.optJSONArray("actions")
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    val aObj = arr.optJSONObject(i) ?: continue
                    actionsList.add(BridgeNotificationAction.fromJson(aObj))
                }
            }

            val messagesList = ArrayList<BridgeMessageItem>()
            val msgArr = json.optJSONArray("messages")
            if (msgArr != null) {
                for (i in 0 until msgArr.length()) {
                    val mObj = msgArr.optJSONObject(i) ?: continue
                    messagesList.add(BridgeMessageItem.fromJson(mObj))
                }
            }

            return BridgeNotification(
                id = id,
                source = json.optString("source", "android"),
                pkg = json.optString("pkg", ""),
                app = json.optString("app", ""),
                title = json.optString("title", ""),
                text = json.optString("text", ""),
                icon = json.optString("icon").ifEmpty { null },
                timestamp = json.optLong("timestamp", System.currentTimeMillis()),
                actions = actionsList,
                isSilent = json.optBoolean("isSilent", false),
                messages = if (messagesList.isNotEmpty()) messagesList else null
            )
        }
    }
}

data class NotificationActionRequest(
    val id: String,
    val actionId: Int,
    val replyText: String? = null
) {
    fun toJsonString(): String {
        val json = JSONObject()
        json.put("type", "notif_action")
        json.put("id", id)
        json.put("actionId", actionId)
        replyText?.let { json.put("replyText", it) }
        return json.toString()
    }

    companion object {
        fun fromJson(json: JSONObject): NotificationActionRequest? {
            val id = json.optString("id").ifEmpty { return null }
            val actionId = json.optInt("actionId", -1)
            if (actionId < 0) return null
            val replyText = json.optString("replyText").ifEmpty { null }
            return NotificationActionRequest(id, actionId, replyText)
        }
    }
}

data class NotificationDismissRequest(
    val id: String,
    val target: String = "android" // "android" (dismiss on phone) or "mac" (dismiss on Mac)
) {
    fun toJsonString(): String {
        val json = JSONObject()
        json.put("type", "notif_dismiss")
        json.put("id", id)
        json.put("target", target)
        return json.toString()
    }

    companion object {
        fun fromJson(json: JSONObject): NotificationDismissRequest? {
            val id = json.optString("id").ifEmpty { return null }
            val target = json.optString("target", "android")
            return NotificationDismissRequest(id, target)
        }
    }
}
