package app.trame.player

import android.content.Context
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.*

internal class FeaturePage(
    context: Context,
    initial: Int,
    private val watch: (Edition) -> Unit,
    private val favorite: (Edition) -> Unit
) : ScrollView(context) {
    var featured = initial.coerceIn(editions.indices)
        private set
    private val poster = ImageView(context)
    private val title = context.label("", 37f).apply { typeface = Typeface.SERIF }
    private val heart = context.iconButton(R.drawable.ic_heart, "Favori") { favorite(editions[featured]) }
    private val recent = context.action("") {}
    private var favorites = emptySet<String>()

    init {
        isFillViewport = true
        val body = context.column().apply { pad(16, 12) }
        addView(body)
        body.addView(context.label("À l’affiche", 27f, bold = true).apply { setPadding(0, 0, 0, context.dp(14)) })

        val hero = RelativeLayout(context).apply {
            background = context.shape(panel, 8)
            clipToOutline = true
        }
        body.addView(hero, -1, -2)
        val captionId = View.generateViewId()
        fun backdrop() = RelativeLayout.LayoutParams(-1, -1).apply {
            addRule(RelativeLayout.ALIGN_TOP, captionId)
            addRule(RelativeLayout.ALIGN_BOTTOM, captionId)
        }
        poster.scaleType = ImageView.ScaleType.CENTER_CROP
        hero.addView(poster, backdrop())
        hero.addView(View(context).apply {
            background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(0x08000000, 0x22000000, 0xef09090b.toInt()))
        }, backdrop())
        val caption = context.column().apply {
            id = captionId
            gravity = Gravity.BOTTOM
            minimumHeight = context.dp(316)
            setPadding(context.dp(18), context.dp(96), context.dp(18), context.dp(18))
        }
        hero.addView(caption, RelativeLayout.LayoutParams(-1, -2))
        caption.addView(context.label("ÉDITIONS TRAME", 11f, coral, true).apply { letterSpacing = 0.18f })
        title.addOnLayoutChangeListener { _, left, _, right, _, oldLeft, _, oldRight, _ ->
            if (right - left != oldRight - oldLeft) fitTitle()
        }
        caption.addView(title)
        caption.addView(context.label("Étude de mouvement  /  10 s", 14f).apply { setPadding(0, 0, 0, context.dp(12)) })
        val controls = context.row()
        val play = context.action("Regarder") { watch(editions[featured]) }.apply {
            surface(coral, 6)
            setTextColor(ink)
            pad(15, 0)
            val icon = context.getDrawable(R.drawable.ic_play)!!.mutate().apply {
                setTint(ink)
                setBounds(0, 0, context.dp(15), context.dp(15))
            }
            setCompoundDrawables(icon, null, null, null)
            compoundDrawablePadding = context.dp(8)
        }
        controls.addView(play)
        controls.addView(heart, LinearLayout.LayoutParams(context.dp(48), context.dp(48)).apply {
            marginStart = context.dp(8)
        })
        caption.addView(controls)

        val heading = context.row().apply { setPadding(0, context.dp(24), 0, context.dp(10)) }
        heading.addView(context.label("Les études de mouvement", 18f, bold = true), weight())
        heading.addView(context.label("${editions.size} films", 13f, muted))
        body.addView(heading)
        val rail = HorizontalScrollView(context).apply { isHorizontalScrollBarEnabled = false }
        val cards = context.row()
        for ((index, item) in editions.withIndex()) {
            val card = context.column().apply {
                surface(ink, 5)
                isFocusable = true
                contentDescription = "Lire ${item.title}, film court, 10 secondes"
                setOnClickListener { featured = index; update(); watch(item) }
            }
            val image = ImageView(context).apply {
                setImageResource(item.poster)
                scaleType = ImageView.ScaleType.CENTER_CROP
                background = context.shape(panel, 5)
                clipToOutline = true
            }
            card.addView(image, -1, context.dp(87))
            card.addView(context.label(item.title, 15f, bold = true).apply { setPadding(0, context.dp(6), 0, 0) })
            card.addView(context.label("Film court · 10 s", 12f, muted))
            cards.addView(card, LinearLayout.LayoutParams(context.dp(154), -2).apply {
                if (index < editions.lastIndex) marginEnd = context.dp(12)
            })
        }
        rail.addView(cards)
        body.addView(rail)
        recent.gravity = Gravity.START or Gravity.CENTER_VERTICAL
        recent.visibility = GONE
        body.addView(recent, LinearLayout.LayoutParams(-1, -2).apply { topMargin = context.dp(20) })
        update()
    }

    fun activity(favoriteUrls: Set<String>, last: String?, resume: () -> Unit) {
        favorites = favoriteUrls
        recent.visibility = if (last == null) GONE else VISIBLE
        recent.text = "Dernière lecture  ·  ${last.orEmpty()}"
        recent.setOnClickListener { resume() }
        update()
    }

    private fun fitTitle() {
        if (title.width <= 0) return
        fun sp(size: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, size, resources.displayMetrics)
        val maximum = sp(37f)
        val measure = Paint(title.paint).apply { textSize = maximum }
        val longest = editions[featured].title.split(' ').maxOf { measure.measureText(it) }
        val size = (maximum * title.width * 0.95f / longest).coerceIn(sp(26f), maximum)
        if (title.textSize != size) title.setTextSize(TypedValue.COMPLEX_UNIT_PX, size)
    }

    private fun update() {
        val item = editions[featured]
        poster.setImageResource(item.poster)
        title.text = item.title
        fitTitle()
        val saved = item.url in favorites
        heart.setImageResource(if (saved) R.drawable.ic_heart_on else R.drawable.ic_heart)
        heart.contentDescription = if (saved) "Retirer ${item.title} des favoris" else "Ajouter ${item.title} aux favoris"
        heart.tooltipText = heart.contentDescription
    }
}
