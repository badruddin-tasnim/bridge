package com.link.clipboardsync

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PathMeasure
import android.graphics.RectF
import android.provider.Settings
import android.util.AttributeSet
import android.view.View
import android.view.animation.AccelerateDecelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator

class BridgeLinkView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    enum class LinkMode {
        HERO_IDLE,
        HERO_CONNECTING,
        HERO_CONNECTED,
        PAIRING_IDLE,
        PAIRING_CONNECTING,
        PAIRING_CONNECTED
    }

    private var mode: LinkMode = LinkMode.HERO_IDLE

    // Design Tokens
    private val colorInk = Color.parseColor("#0E0F12")
    private val colorLime = Color.parseColor("#C8F135")
    private val colorCoral = Color.parseColor("#FF9A8A")
    private val colorMuted = Color.parseColor("#9BA3AD")
    private val colorLine2 = Color.parseColor("#3A3F47")
    private val colorHeroIdleNode = Color.parseColor("#262A31")
    private val colorPairingNode = Color.parseColor("#1C1F25")

    // Paints
    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2.4f
        strokeCap = Paint.Cap.ROUND
    }

    private val wirePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2.4f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    private val nodePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }

    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2.2f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    private val packetPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }

    private val midDotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }

    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.8f
    }

    // Geometry in 320 x 104 virtual coordinate space (generous margin so ripples never clip)
    private val nodeRadius = 28f
    private val leftCenterX = 48f
    private val rightCenterX = 272f
    private val nodeCenterY = 48f

    private val basePath = Path().apply {
        moveTo(76f, 52f)
        quadTo(160f, 98f, 244f, 52f)
    }
    private val pathMeasure = PathMeasure(basePath, false)
    private val totalLength = pathMeasure.length
    private val segmentPath = Path()
    private val pos = FloatArray(2)

    private val phoneRect = RectF(40.5f, 35f, 55.5f, 61f)
    private val macRect = RectF(259f, 39.5f, 285f, 55.5f)

    // Animation state
    private var travelProgress = 0f
    private var midDotScale = 0f
    private var rippleLeftScale = 1f
    private var rippleLeftAlpha = 0f
    private var rippleRightScale = 1f
    private var rippleRightAlpha = 0f

    private var travelAnimator: ValueAnimator? = null
    private var breatheAnimator: ValueAnimator? = null
    private var popAnimator: ValueAnimator? = null
    private var rippleLeftAnimator: ValueAnimator? = null
    private var rippleRightAnimator: ValueAnimator? = null

    init {
        updatePaintsForMode()
    }

    private fun isReducedMotion(): Boolean {
        return try {
            Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
        } catch (e: Exception) {
            false
        }
    }

    fun setMode(newMode: LinkMode) {
        if (mode == newMode) return
        mode = newMode
        stopAllAnimations()
        updatePaintsForMode()

        if (isReducedMotion()) {
            travelProgress = if (isConnecting()) 0.5f else 1f
            midDotScale = if (isConnected()) 1f else 0f
            invalidate()
            return
        }

        when (mode) {
            LinkMode.HERO_CONNECTING, LinkMode.PAIRING_CONNECTING -> {
                startConnectingAnimation()
            }
            LinkMode.HERO_CONNECTED, LinkMode.PAIRING_CONNECTED -> {
                travelProgress = 1f
                startConnectedAnimation()
            }
            LinkMode.HERO_IDLE, LinkMode.PAIRING_IDLE -> {
                travelProgress = 0f
                midDotScale = 0f
                invalidate()
            }
        }
    }

    private fun isConnecting() = mode == LinkMode.HERO_CONNECTING || mode == LinkMode.PAIRING_CONNECTING
    private fun isConnected() = mode == LinkMode.HERO_CONNECTED || mode == LinkMode.PAIRING_CONNECTED

    private fun updatePaintsForMode() {
        when (mode) {
            LinkMode.HERO_CONNECTED -> {
                trackPaint.color = colorInk
                trackPaint.alpha = (255 * 0.25f).toInt()
                trackPaint.pathEffect = DashPathEffect(floatArrayOf(2f, 7f), 0f)

                wirePaint.color = colorInk
                wirePaint.alpha = 255

                nodePaint.color = colorInk
                iconPaint.color = colorLime
                midDotPaint.color = colorInk
                packetPaint.color = colorInk
                ringPaint.color = colorInk
            }
            LinkMode.HERO_CONNECTING -> {
                trackPaint.color = Color.parseColor("#F4F5F2")
                trackPaint.alpha = (255 * 0.25f).toInt()
                trackPaint.pathEffect = DashPathEffect(floatArrayOf(2f, 7f), 0f)

                wirePaint.color = colorLime
                wirePaint.alpha = 255

                nodePaint.color = colorHeroIdleNode
                iconPaint.color = colorMuted
                midDotPaint.color = colorLime
                packetPaint.color = colorLime
                ringPaint.color = colorLime
            }
            LinkMode.HERO_IDLE -> {
                trackPaint.color = Color.parseColor("#F4F5F2")
                trackPaint.alpha = (255 * 0.25f).toInt()
                trackPaint.pathEffect = DashPathEffect(floatArrayOf(2f, 7f), 0f)

                nodePaint.color = colorHeroIdleNode
                iconPaint.color = colorMuted
                wirePaint.color = Color.TRANSPARENT
                packetPaint.color = Color.TRANSPARENT
            }
            LinkMode.PAIRING_IDLE -> {
                trackPaint.color = colorLine2
                trackPaint.alpha = 255
                trackPaint.pathEffect = DashPathEffect(floatArrayOf(2f, 7f), 0f)

                nodePaint.color = colorPairingNode
                iconPaint.color = colorMuted
                midDotPaint.color = colorCoral
                midDotScale = 1f
                wirePaint.color = Color.TRANSPARENT
                packetPaint.color = Color.TRANSPARENT
            }
            LinkMode.PAIRING_CONNECTING -> {
                trackPaint.color = colorLine2
                trackPaint.alpha = 255
                trackPaint.pathEffect = DashPathEffect(floatArrayOf(2f, 7f), 0f)

                wirePaint.color = colorLime
                wirePaint.alpha = 255

                nodePaint.color = colorPairingNode
                iconPaint.color = colorMuted
                packetPaint.color = colorLime
                midDotScale = 0f
            }
            LinkMode.PAIRING_CONNECTED -> {
                trackPaint.color = colorLine2
                trackPaint.alpha = (255 * 0.25f).toInt()
                trackPaint.pathEffect = DashPathEffect(floatArrayOf(2f, 7f), 0f)

                wirePaint.color = colorLime
                wirePaint.alpha = 255

                nodePaint.color = colorPairingNode
                iconPaint.color = colorLime
                midDotPaint.color = colorLime
                packetPaint.color = colorLime
                ringPaint.color = colorLime
            }
        }
    }

    private fun startConnectingAnimation() {
        travelAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1100
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.RESTART
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener { anim ->
                travelProgress = anim.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    private fun startConnectedAnimation() {
        // Pop in the mid dot with overshoot
        popAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 500
            interpolator = OvershootInterpolator(1.6f)
            addUpdateListener { anim ->
                midDotScale = anim.animatedValue as Float
                invalidate()
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    startBreathingAnimation()
                }
            })
            start()
        }

        // Ripple left node: grows to 1.55x (radius ~43.4, well inside 48px margin) and fades out smoothly
        rippleLeftAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1350
            repeatCount = 1
            interpolator = DecelerateInterpolator(1.5f)
            addUpdateListener { anim ->
                val f = anim.animatedValue as Float
                rippleLeftScale = 1.0f + 0.55f * f
                val rem = (1f - f).coerceIn(0f, 1f)
                rippleLeftAlpha = rem * rem * 0.55f
                invalidate()
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    rippleLeftAlpha = 0f
                    invalidate()
                }
            })
            start()
        }

        // Ripple right node (delayed by 180ms)
        rippleRightAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1350
            startDelay = 180
            repeatCount = 1
            interpolator = DecelerateInterpolator(1.5f)
            addUpdateListener { anim ->
                val f = anim.animatedValue as Float
                rippleRightScale = 1.0f + 0.55f * f
                val rem = (1f - f).coerceIn(0f, 1f)
                rippleRightAlpha = rem * rem * 0.55f
                invalidate()
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    rippleRightAlpha = 0f
                    invalidate()
                }
            })
            start()
        }
    }

    private fun startBreathingAnimation() {
        breatheAnimator = ValueAnimator.ofFloat(1f, 1.35f).apply {
            duration = 1300
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener { anim ->
                midDotScale = anim.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    private fun stopAllAnimations() {
        travelAnimator?.cancel()
        travelAnimator = null
        breatheAnimator?.cancel()
        breatheAnimator = null
        popAnimator?.cancel()
        popAnimator = null
        rippleLeftAnimator?.cancel()
        rippleLeftAnimator = null
        rippleRightAnimator?.cancel()
        rippleRightAnimator = null
        rippleLeftAlpha = 0f
        rippleRightAlpha = 0f
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        stopAllAnimations()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        // Aspect ratio: 320 x 104 -> height = width * (104 / 320)
        val desiredHeight = (width * 104f / 320f).toInt()
        val height = resolveSize(desiredHeight, heightMeasureSpec)
        setMeasuredDimension(width, height)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return

        canvas.save()
        val scale = w / 320f
        canvas.scale(scale, scale)

        // 1. Background dashed track
        canvas.drawPath(basePath, trackPaint)

        // 2. Wire stroke
        if (isConnecting() && travelProgress > 0f) {
            segmentPath.reset()
            pathMeasure.getSegment(0f, totalLength * travelProgress, segmentPath, true)
            canvas.drawPath(segmentPath, wirePaint)
        } else if (isConnected()) {
            canvas.drawPath(basePath, wirePaint)
        }

        // 3. Ripple rings (when connected) - stays well within 0..320 x 0..104 bounds and fades out
        if (rippleLeftAlpha > 0.005f) {
            ringPaint.alpha = (rippleLeftAlpha * 255).toInt()
            canvas.drawCircle(leftCenterX, nodeCenterY, nodeRadius * rippleLeftScale, ringPaint)
        }
        if (rippleRightAlpha > 0.005f) {
            ringPaint.alpha = (rippleRightAlpha * 255).toInt()
            canvas.drawCircle(rightCenterX, nodeCenterY, nodeRadius * rippleRightScale, ringPaint)
        }

        // 4. Left Node (Phone)
        canvas.drawCircle(leftCenterX, nodeCenterY, nodeRadius, nodePaint)
        canvas.drawRoundRect(phoneRect, 3.5f, 3.5f, iconPaint)

        // 5. Right Node (Mac)
        canvas.drawCircle(rightCenterX, nodeCenterY, nodeRadius, nodePaint)
        canvas.drawRoundRect(macRect, 2.5f, 2.5f, iconPaint)
        canvas.drawLine(255f, 60.5f, 289f, 60.5f, iconPaint)

        // 6. Traveling packet dot (when connecting)
        if (isConnecting()) {
            pathMeasure.getPosTan(totalLength * travelProgress, pos, null)
            canvas.drawCircle(pos[0], pos[1], 6f, packetPaint)
        }

        // 7. Midpoint dot (on curve midpoint: x=160, y=75)
        if (isConnected() && midDotScale > 0f) {
            canvas.drawCircle(160f, 75f, 6f * midDotScale, midDotPaint)
        } else if (mode == LinkMode.PAIRING_IDLE) {
            // Coral dot in the gap (r=5)
            canvas.drawCircle(160f, 75f, 5f, midDotPaint)
        }

        canvas.restore()
    }
}
