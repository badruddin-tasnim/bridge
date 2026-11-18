package com.link.clipboardsync

import android.content.Context
import android.util.Log
import org.json.JSONObject

/**
 * Dispatches remote input commands received from Mac during Phone Mirroring
 * into [ClipboardSyncAccessibilityService].
 */
object PhoneMirrorInputController {
    private const val TAG = "PhoneMirrorInput"

    fun handleInputMessage(context: Context, jsonObj: JSONObject) {
        val cmd = PhoneMirrorProtocol.parseInputCommand(jsonObj) ?: run {
            Log.d(TAG, "Ignoring malformed mirror_input command: $jsonObj")
            return
        }
        val a11y = ClipboardSyncAccessibilityService.instance
        if (a11y == null) {
            Log.w(TAG, "Cannot inject mirror input ($cmd): Accessibility service is not active")
            return
        }

        when (cmd) {
            is MirrorInputCommand.Tap -> a11y.performMirrorTap(cmd.xNorm, cmd.yNorm)
            is MirrorInputCommand.LongPress -> a11y.performMirrorLongPress(cmd.xNorm, cmd.yNorm)
            is MirrorInputCommand.Swipe -> a11y.performMirrorSwipe(
                cmd.startXNorm,
                cmd.startYNorm,
                cmd.endXNorm,
                cmd.endYNorm,
                cmd.durationMs
            )
            is MirrorInputCommand.GlobalAction -> a11y.performMirrorGlobalAction(cmd.action)
            is MirrorInputCommand.TextInput -> a11y.performMirrorTextInput(cmd.text)
            is MirrorInputCommand.KeyAction -> a11y.performMirrorKeyAction(cmd.keyAction)
        }
    }
}
