package com.link.clipboardsync

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import kotlin.math.min

/**
 * Compact circular battery ring indicator matching the macOS Bridge BatteryRingView aesthetic.
 */
class MacBatteryRingView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private var percent: Int = 0
    private var isCharging: Boolean = false

    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        color = 0xFF2B2F36.toInt()
    }

    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        color = 0xFFC8F135.toInt()
    }

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        color = 0xFFF4F5F2.toInt()
        isFakeBoldText = true
    }

    private val rect = RectF()

    fun setBattery(percent: Int, charging: Boolean) {
        val clamped = percent.coerceIn(0, 100)
        if (this.percent == clamped && this.isCharging == charging) return
        this.percent = clamped
        this.isCharging = charging
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val size = min(width, height).toFloat()
        if (size <= 0f) return
        val stroke = (size * 0.135f).coerceAtLeast(4f)
        trackPaint.strokeWidth = stroke
        ringPaint.strokeWidth = stroke

        val ringColor = when {
            isCharging -> 0xFFF5A623.toInt()
            percent <= 20 -> 0xFFFF9A8A.toInt()
            else -> 0xFFC8F135.toInt()
        }
        ringPaint.color = ringColor

        val pad = stroke / 2f + 1.5f
        rect.set(pad, pad, size - pad, size - pad)
        canvas.drawArc(rect, 0f, 360f, false, trackPaint)
        val sweep = (percent / 100f) * 360f
        if (sweep > 0f) {
            canvas.drawArc(rect, -90f, sweep, false, ringPaint)
        }

        textPaint.textSize = size * 0.31f
        val fm = textPaint.fontMetrics
        val baseline = (size / 2f) - ((fm.ascent + fm.descent) / 2f)
        canvas.drawText(percent.toString(), size / 2f, baseline, textPaint)
    }
}
