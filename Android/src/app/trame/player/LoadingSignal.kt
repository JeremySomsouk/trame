package app.trame.player

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import kotlin.math.PI
import kotlin.math.cos

internal class LoadingSignal(context: Context, message: String) : LinearLayout(context) {
    private val caption = context.label(message, 14f)
    var message: CharSequence
        get() = caption.text
        set(value) { caption.text = value }

    init {
        gravity = Gravity.CENTER_VERTICAL
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        val bars = object : View(context) {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = coral }
            override fun onDraw(canvas: Canvas) {
                val moving = ValueAnimator.areAnimatorsEnabled()
                val phase = if (moving) (SystemClock.uptimeMillis() % 2000) * PI / 1000 else 0.0
                val unit = width / 34f
                for (index in 0 until 9) {
                    val wave = ((1 + cos(index * 0.64 - phase)) / 2).toFloat()
                    val h = 4 * unit + (height - 4 * unit) * wave
                    val x = index * 4 * unit
                    canvas.drawRoundRect(x, (height - h) / 2, x + 2 * unit, (height + h) / 2, unit, unit, paint)
                }
                if (moving && isShown) postInvalidateDelayed(42)
            }
        }
        addView(bars, context.dp(34), context.dp(18))
        addView(caption, LayoutParams(-2, -2).apply { marginStart = context.dp(9) })
    }
}
