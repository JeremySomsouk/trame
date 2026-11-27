package app.trame.player

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.view.Gravity
import android.view.View
import android.widget.*
import kotlin.math.roundToInt

internal enum class Page(val label: String, val compactLabel: String, val icon: Int) {
    HOME("À l’affiche", "Affiche", R.drawable.ic_feature), LIBRARY("Bibliothèque", "Titres", R.drawable.ic_library),
    FAVORITES("Favoris", "Favoris", R.drawable.ic_heart), RECENT("Historique", "Récents", R.drawable.ic_history)
}

internal enum class Category(val code: Int, val label: String, val icon: Int) {
    ALL(0, "Tous", R.drawable.ic_play), LIVE(1, "Direct", R.drawable.ic_live),
    MOVIES(2, "Films", R.drawable.ic_feature), SERIES(3, "Séries", R.drawable.ic_series)
}

internal data class Edition(val key: String, val title: String, val poster: Int) {
    val url get() = "android.resource://app.trame.player/raw/$key"
}

internal val editions = listOf(
    Edition("corail", "Interférences", R.drawable.corail),
    Edition("maree", "Marée bleue", R.drawable.maree),
    Edition("orbite", "Orbite solaire", R.drawable.orbite)
)

internal val ink = Color.rgb(16, 17, 19)
internal val panel = Color.rgb(26, 27, 31)
internal val coral = Color.rgb(255, 150, 122)
internal val muted = Color.rgb(184, 183, 190)
internal val paper = Color.rgb(246, 243, 240)
internal fun Context.dp(n: Int) = (resources.displayMetrics.density * n).roundToInt()
internal fun Context.shape(color: Int, radius: Int = 0) = GradientDrawable().apply {
    setColor(color)
    cornerRadius = dp(radius).toFloat()
}
internal fun View.surface(color: Int, radius: Int = 0) {
    background = RippleDrawable(ColorStateList.valueOf(0x30ffffff), context.shape(color, radius), null)
}
internal fun Context.label(value: String, size: Float, color: Int = paper, bold: Boolean = false) =
    TextView(this).apply {
        text = value
        textSize = size
        setTextColor(color)
        if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }

internal fun Context.column() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
internal fun Context.row() = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
internal fun weight() = LinearLayout.LayoutParams(0, -2, 1f)
internal fun View.pad(x: Int, y: Int) = setPadding(context.dp(x), context.dp(y), context.dp(x), context.dp(y))

internal fun Context.iconButton(icon: Int, description: String, action: () -> Unit) =
    ImageButton(this).apply {
        setImageResource(icon)
        contentDescription = description
        tooltipText = description
        imageTintList = ColorStateList.valueOf(coral)
        scaleType = ImageView.ScaleType.CENTER
        minimumWidth = dp(48)
        minimumHeight = dp(48)
        surface(panel, 6)
        setOnClickListener { action() }
    }

internal fun Context.action(label: String, action: () -> Unit) =
    Button(this, null, android.R.attr.borderlessButtonStyle).apply {
        text = label
        textSize = 14f
        isAllCaps = false
        letterSpacing = 0f
        minWidth = 0
        minimumWidth = 0
        minHeight = dp(48)
        minimumHeight = dp(48)
        pad(10, 0)
        setTextColor(paper)
        surface(panel, 6)
        setOnClickListener { action() }
    }
