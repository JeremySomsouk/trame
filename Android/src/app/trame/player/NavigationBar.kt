package app.trame.player

import android.animation.ValueAnimator
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.graphics.drawable.RippleDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.animation.DecelerateInterpolator
import android.widget.Button

internal class NavigationBar(context: Context, onSelect: (Page) -> Unit) : ViewGroup(context) {
    private val inset = context.dp(4)
    private val indicator = View(context).apply {
        background = context.shape(0xff42302b.toInt(), 18)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val tabs = Page.entries.map { page ->
        Button(context, null, android.R.attr.borderlessButtonStyle).apply {
            isAllCaps = false
            letterSpacing = 0f
            textSize = 12f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            isSingleLine = true
            minWidth = 0
            minimumWidth = 0
            minHeight = 0
            minimumHeight = 0
            gravity = Gravity.CENTER
            contentDescription = page.label
            tooltipText = page.label
            setPadding(context.dp(2), context.dp(5), context.dp(2), context.dp(5))
            compoundDrawablePadding = context.dp(3)
            setCompoundDrawablesWithIntrinsicBounds(0, page.icon, 0, 0)
            background = RippleDrawable(ColorStateList.valueOf(0x28ffffff), null, context.shape(paper, 18))
            setOnClickListener { if (!isSelected) onSelect(page) }
        }
    }
    private var selected: Page? = null
    private var columns = tabs.size

    init {
        background = context.shape(0xff242429.toInt(), 23).apply {
            setStroke(context.dp(1), 0xff454247.toInt())
        }
        elevation = context.dp(6).toFloat()
        addView(indicator)
        tabs.forEach { addView(it) }
    }

    fun select(page: Page) {
        if (selected == page) return
        selected = page
        tabs.forEachIndexed { index, tab ->
            val active = index == page.ordinal
            tab.isSelected = active
            val color = if (active) coral else muted
            if (index == Page.FAVORITES.ordinal) {
                tab.setCompoundDrawablesWithIntrinsicBounds(0, if (active) R.drawable.ic_heart_on else R.drawable.ic_heart, 0, 0)
            }
            tab.compoundDrawableTintList = ColorStateList.valueOf(color)
            tab.setTextColor(color)
        }
        placeIndicator(isLaidOut && isShown && ValueAnimator.areAnimatorsEnabled())
    }

    private fun placeIndicator(animate: Boolean) {
        val target = tabs[(selected ?: Page.HOME).ordinal]
        indicator.animate().cancel()
        val x = target.left.toFloat()
        val y = target.top.toFloat()
        if (animate) {
            indicator.animate().translationX(x).translationY(y).setDuration(220)
                .setInterpolator(DecelerateInterpolator(1.5f)).start()
        } else {
            indicator.translationX = x
            indicator.translationY = y
        }
    }

    override fun onMeasure(widthSpec: Int, heightSpec: Int) {
        val width = minOf(MeasureSpec.getSize(widthSpec), context.dp(448))
        val track = (width - 2 * inset).coerceAtLeast(0)
        val shortest = tabs.indices.maxOf { i ->
            val tab = tabs[i]
            tab.paint.measureText(Page.entries[i].compactLabel) + tab.paddingLeft + tab.paddingRight
        }
        columns = if (track / tabs.size < maxOf(shortest, context.dp(48).toFloat())) 2 else tabs.size
        val cell = track / columns
        var height = context.dp(56)
        tabs.forEachIndexed { index, tab ->
            val page = Page.entries[index]
            val caption = if (tab.paint.measureText(page.label) + tab.paddingLeft + tab.paddingRight <= cell)
                page.label else page.compactLabel
            if (tab.text != caption) tab.text = caption
            tab.measure(MeasureSpec.makeMeasureSpec(cell, MeasureSpec.EXACTLY), MeasureSpec.UNSPECIFIED)
            height = maxOf(height, tab.measuredHeight)
        }
        val exactHeight = MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY)
        val exactWidth = MeasureSpec.makeMeasureSpec(cell, MeasureSpec.EXACTLY)
        tabs.forEach { it.measure(exactWidth, exactHeight) }
        indicator.measure(exactWidth, exactHeight)
        setMeasuredDimension(width, height * (tabs.size / columns) + 2 * inset)
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val w = indicator.measuredWidth
        val h = indicator.measuredHeight
        val target = tabs[(selected ?: Page.HOME).ordinal]
        val oldLeft = target.left
        val oldTop = target.top
        indicator.layout(0, 0, w, h)
        tabs.forEachIndexed { i, tab ->
            val column = if (layoutDirection == LAYOUT_DIRECTION_RTL) columns - 1 - i % columns else i % columns
            val x = inset + column * w
            val y = inset + (i / columns) * h
            tab.layout(x, y, x + w, y + h)
        }
        if (changed || target.left != oldLeft || target.top != oldTop) placeIndicator(false)
    }
}
