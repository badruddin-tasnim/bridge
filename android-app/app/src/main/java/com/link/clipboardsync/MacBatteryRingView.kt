package com.link.clipboardsync

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.util.AttributeSet
import android.view.View
import androidx.core.content.res.ResourcesCompat
import kotlin.math.min

/**
 * Circular battery ring with numeric percentage and a top charging bolt badge when plugged in.
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
        color = 0xFF3A3F47.toInt()
    }

    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        color = 0xFFC8F135.toInt()
    }

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        color = 0xFFF4F5F2.toInt()
        typeface = ResourcesCompat.getFont(context, R.font.plus_jakarta_sans_bold)
            ?: Typeface.DEFAULT_BOLD
    }

    private val badgeBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = 0xFFF5A623.toInt()
    }

    private val badgeBoltPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = 0xFFFFFFFF.toInt()
    }

    private val rect = RectF()
    private val boltPath = Path()

    fun setBattery(percent: Int, charging: Boolean) {
        val clamped = percent.coerceIn(0, 100)
        if (this.percent == clamped && this.isCharging == charging) return
        this.percent = clamped
        this.isCharging = charging
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return

        val ringDiameter = min(w * 0.86f, h * 0.80f)
        val stroke = (ringDiameter * 0.115f).coerceAtLeast(3.5f)
        trackPaint.strokeWidth = stroke
        ringPaint.strokeWidth = stroke

        val badgeRadius = ringDiameter * 0.195f
        val topOffset = (h - ringDiameter) * 0.65f
        val cx = w / 2f
        val cy = topOffset + ringDiameter / 2f
        val r = ringDiameter / 2f - stroke / 2f

        val ringColor = when {
            isCharging -> 0xFFF5A623.toInt()
            percent <= 20 -> 0xFFFF9A8A.toInt()
            else -> 0xFFC8F135.toInt()
        }
        ringPaint.color = ringColor

        rect.set(cx - r, cy - r, cx + r, cy + r)
        canvas.drawArc(rect, 0f, 360f, false, trackPaint)
        val sweep = (percent / 100f) * 360f
        if (sweep > 0f) {
            canvas.drawArc(rect, -90f, sweep, false, ringPaint)
        }

        textPaint.textSize = if (percent == 100) ringDiameter * 0.30f else ringDiameter * 0.34f
        val fm = textPaint.fontMetrics
        val textCenterY = if (isCharging) cy + (ringDiameter * 0.06f) else cy
        val baseline = textCenterY - ((fm.ascent + fm.descent) / 2f)
        canvas.drawText(percent.toString(), cx, baseline, textPaint)

        if (isCharging) {
            val badgeCy = (cy - r).coerceAtLeast(badgeRadius + 1f)
            canvas.drawCircle(cx, badgeCy, badgeRadius, badgeBgPaint)

            val bw = badgeRadius * 0.92f
            val bh = badgeRadius * 1.18f
            val bx = cx - bw / 2f
            val by = badgeCy - bh / 2f
            boltPath.reset()
            boltPath.moveTo(bx + bw * 0.58f, by)
            boltPath.lineTo(bx + bw * 0.06f, by + bh * 0.56f)
            boltPath.lineTo(bx + bw * 0.46f, by + bh * 0.56f)
            boltPath.lineTo(bx + bw * 0.34f, by + bh)
            boltPath.lineTo(bx + bw * 0.94f, by + bh * 0.44f)
            boltPath.lineTo(bx + bw * 0.52f, by + bh * 0.44f)
            boltPath.close()
            canvas.drawPath(boltPath, badgeBoltPaint)
        }
    }
}
