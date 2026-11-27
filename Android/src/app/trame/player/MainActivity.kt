package app.trame.player

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.database.Cursor
import android.graphics.Rect
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.text.Editable
import android.text.InputType
import android.text.TextUtils
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import android.view.inputmethod.InputMethodManager
import android.widget.*
import java.util.concurrent.Executors

class MainActivity : Activity() {
    private val db by lazy { Library.open(this) }
    private val posters = Posters()
    private val preferences by lazy { getSharedPreferences("display", MODE_PRIVATE) }
    private var loadPosters = true
    private val reads = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private val delayed = Runnable { refresh() }
    private lateinit var films: FilmAdapter
    private lateinit var search: EditText
    private lateinit var resultCount: TextView
    private lateinit var loadingSignal: LoadingSignal
    private lateinit var sourceButton: Button
    private lateinit var playlist: Button
    private lateinit var sync: ImageButton
    private lateinit var groupButton: Button
    private lateinit var clearHistory: Button
    private lateinit var categoryRow: LinearLayout
    private lateinit var selector: LinearLayout
    private lateinit var heading: TextView
    private lateinit var home: FeaturePage
    private lateinit var list: ListView
    private lateinit var navigation: NavigationBar
    private lateinit var categories: List<Button>
    private var page = Page.HOME
    private var category = Category.ALL
    private var sourceId: Long? = null
    private var group = ""
    private var sources = emptyList<Source>()
    private val selected get() = sources.find { it.id == sourceId }
    private var typing = false
    private var landscape = false
    private var busy = false
    private var syncing: Long? = null
    private var backCallback: OnBackInvokedCallback? = null
    private var generation = 0
    private val available get() = !isFinishing && !isDestroyed

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        page = Page.entries.find { it.name == state?.getString("destination") } ?: Page.HOME
        category = Category.entries.find { it.code == state?.getInt("category") } ?: Category.ALL
        sourceId = state?.getLong("source")?.takeIf { it > 0 }
        group = state?.getString("group").orEmpty()

        loadPosters = preferences.getBoolean("loadPosters", true)
        val root = column().apply {
            fitsSystemWindows = true
            isFocusableInTouchMode = true
            setBackgroundColor(ink)
        }
        val header = row().apply { pad(16, 4) }
        header.addView(ImageView(this).apply { setImageResource(R.drawable.trame) }, dp(32), dp(32))
        header.addView(label("Trame", 25f, bold = true).apply {
            letterSpacing = -0.055f
            setPadding(dp(8), 0, 0, 0)
        }, weight())
        sourceButton = action("+ Source") { sourceMenu() }.apply { setTextColor(coral) }
        header.addView(sourceButton)
        root.addView(header)
        loadingSignal = LoadingSignal(this, "Import en cours…").apply {
            pad(16, 6)
            visibility = View.GONE
        }
        root.addView(loadingSignal)
        val body = FrameLayout(this)
        root.addView(body, LinearLayout.LayoutParams(-1, 0, 1f))
        home = FeaturePage(this, state?.getInt("featured") ?: 0,
            { play(it.url, it.title, it.url, false, "Éditions Trame") }, { mutate { db.toggle(it.url) } })
        body.addView(home)
        list = ListView(this).apply {
            divider = null
            itemsCanFocus = true
            isVerticalScrollBarEnabled = false
        }
        list.addHeaderView(browserHeader(state?.getString("search").orEmpty()), null, false)
        films = FilmAdapter()
        list.adapter = films
        list.setRecyclerListener { view -> (view as? FilmRow)?.let { posters.cancel(it.poster) } }
        body.addView(list)

        navigation = NavigationBar(this, ::navigate)
        val nav = row().apply {
            setPadding(dp(10), dp(6), dp(10), dp(10))
            clipToPadding = false
            clipChildren = false
        }
        val holder = FrameLayout(this).apply {
            clipChildren = false
            clipToPadding = false
            addView(navigation, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER))
        }
        nav.addView(holder, weight())
        body.addView(nav, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM))
        home.clipToPadding = false
        list.clipToPadding = false
        fun updateScrollInsets() {
            val bottom = if (nav.visibility == View.VISIBLE) nav.height else 0
            if (home.paddingBottom != bottom) home.setPadding(0, 0, 0, bottom)
            if (list.paddingBottom != bottom) list.setPadding(0, 0, 0, bottom)
        }
        nav.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> updateScrollInsets() }
        val visible = Rect()
        root.viewTreeObserver.addOnGlobalLayoutListener {
            root.getWindowVisibleDisplayFrame(visible)
            val ime = (Build.VERSION.SDK_INT >= 30 && root.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) == true)
                || root.rootView.height - visible.bottom > dp(100)
            val editing = search.hasFocus() && ime
            val wide = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
            if (typing != editing || landscape != wide) {
                if (landscape != wide) {
                    (sourceButton.parent as ViewGroup).removeView(sourceButton)
                    (if (wide) nav else header).addView(sourceButton)
                }
                typing = editing
                landscape = wide
                header.visibility = if (editing || wide) View.GONE else View.VISIBLE
                nav.visibility = if (editing) View.GONE else View.VISIBLE
                updateScrollInsets()
                showPage()
            }
        }
        setContentView(root)
        showPage()
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                generation++
                handler.removeCallbacks(delayed)
                handler.postDelayed(delayed, 150)
            }
            override fun afterTextChanged(s: Editable?) {}
        })
    }

    private fun browserHeader(term: String): View {
        val header = column().apply { pad(16, 8) }
        heading = label("", 27f, bold = true)
        header.addView(heading)
        selector = row().apply { setPadding(0, dp(8), 0, 0) }
        playlist = action("Toutes les sources") { chooseSource() }.apply {
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            isSingleLine = true
            ellipsize = TextUtils.TruncateAt.END
            setCompoundDrawablesWithIntrinsicBounds(0, 0, R.drawable.ic_chevron, 0)
        }
        selector.addView(playlist, weight())
        sync = iconButton(R.drawable.ic_refresh, "Actualiser la playlist") { selected?.let(::syncSource) }
        selector.addView(sync, LinearLayout.LayoutParams(dp(48), dp(48)).apply { marginStart = dp(6) })
        header.addView(selector)
        val searchBar = row().apply { background = shape(panel, 6) }
        val glass = ImageView(this).apply { setImageResource(R.drawable.ic_search); setColorFilter(muted); pad(8, 0) }
        searchBar.addView(glass, dp(36), dp(48))
        search = EditText(this).apply {
            hint = "Rechercher…"
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT
            imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH or android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI
            textSize = 15f
            setTextColor(paper)
            setHintTextColor(muted)
            background = null
            pad(2, 0)
            minHeight = dp(48)
            setText(term)
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        searchBar.addView(search, weight())
        header.addView(searchBar, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
        categoryRow = row()
        categories = Category.entries.map { item ->
            action(item.label) {
                if (category != item) {
                    category = item
                    group = ""
                    showPage()
                    refresh()
                }
            }.apply { pad(2, 0); categoryRow.addView(this, weight()) }
        }
        header.addView(categoryRow, header.indexOfChild(searchBar), LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
        groupButton = action("Catégories") { chooseGroup() }.apply {
            setCompoundDrawablesWithIntrinsicBounds(R.drawable.ic_filter, 0, R.drawable.ic_chevron, 0)
            compoundDrawablePadding = dp(8)
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            isSingleLine = true
            ellipsize = TextUtils.TruncateAt.END
        }
        header.addView(groupButton, -1, -2)
        clearHistory = action("Effacer tout l’historique") { mutate { db.clearHistory() } }.apply { setTextColor(coral) }
        header.addView(clearHistory, LinearLayout.LayoutParams(-2, -2).apply { gravity = Gravity.END })
        val info = row()
        resultCount = label("", 13f, muted).apply { accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }
        info.addView(resultCount)
        info.addView(View(this), weight())
        val posterSwitch = Switch(this).apply {
            text = "Affiches"
            textSize = 13f
            contentDescription = "Charger les affiches"
            minHeight = dp(48)
            switchPadding = dp(6)
            isChecked = loadPosters
            setOnCheckedChangeListener { _, enabled ->
                loadPosters = enabled
                preferences.edit().putBoolean("loadPosters", enabled).apply()
                if (!enabled) posters.cancelAll()
                films.notifyDataSetChanged()
            }
        }
        info.addView(posterSwitch)
        header.addView(info)
        return header
    }

    private fun openLibrary(id: Long?) {
        sourceId = id
        category = Category.ALL
        group = ""
        navigate(Page.LIBRARY)
    }

    private fun navigate(destination: Page) {
        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(search.windowToken, 0)
        search.clearFocus()
        page = destination
        search.setText("")
        handler.removeCallbacks(delayed)
        films.changeCursor(null)
        list.setSelection(0)
        showPage()
        refresh()
    }

    private fun stepBack() {
        if (page == Page.LIBRARY && group.isNotEmpty()) selectGroup(group.substringBeforeLast(" › ", ""))
        else if (page == Page.LIBRARY && sourceId != null) openLibrary(null) else navigate(Page.HOME)
    }

    @Suppress("DEPRECATION")
    @Deprecated("Legacy Android back navigation")
    override fun onBackPressed() {
        if (page == Page.HOME) super.onBackPressed() else stepBack()
    }

    private fun showPage() {
        if (Build.VERSION.SDK_INT >= 33) {
            if (page != Page.HOME && backCallback == null) {
                backCallback = OnBackInvokedCallback { stepBack() }.also {
                    onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, it)
                }
            } else if (page == Page.HOME) {
                backCallback?.let(onBackInvokedDispatcher::unregisterOnBackInvokedCallback)
                backCallback = null
            }
        }
        home.visibility = if (page == Page.HOME) View.VISIBLE else View.GONE
        list.visibility = if (page == Page.HOME) View.GONE else View.VISIBLE
        heading.text = page.label
        heading.visibility = if (typing || landscape) View.GONE else View.VISIBLE
        val library = page == Page.LIBRARY
        selector.visibility = if (library && !typing && sources.isNotEmpty()) View.VISIBLE else View.GONE
        groupButton.visibility = if (library && !typing) View.VISIBLE else View.GONE
        groupButton.text = group.ifEmpty { "Catégories" }
        clearHistory.visibility = if (page == Page.RECENT && !typing) View.VISIBLE else View.GONE
        playlist.text = selected?.name ?: "Toutes les sources"
        sync.visibility = if (library && selected?.refreshable == true) View.VISIBLE else View.GONE
        sync.isEnabled = !busy
        sync.alpha = if (busy) 0.5f else 1f
        val updating = syncing != null && syncing == sourceId
        if (updating) playlist.text = "Actualisation…"
        sync.contentDescription = if (updating) "Actualisation en cours" else "Actualiser ${playlist.text}"
        sync.tooltipText = sync.contentDescription
        categoryRow.visibility = if (library && !typing) View.VISIBLE else View.GONE
        categories.forEachIndexed { i, tab ->
            tab.isSelected = Category.entries[i] == category
            tab.setTextColor(if (tab.isSelected) coral else muted)
            tab.surface(if (tab.isSelected) 0xff372825.toInt() else ink, 5)
            tab.setTypeface(null, if (tab.isSelected) Typeface.BOLD else Typeface.NORMAL)
        }
        navigation.select(page)
    }

    private fun chooseSource() {
        val choices = sources
        val options = listOf("Toutes les sources") + choices.map { it.name }
        AlertDialog.Builder(this).setTitle("Source").setSingleChoiceItems(options.toTypedArray(),
            choices.indexOfFirst { it.id == sourceId } + 1) { dialog, i ->
            dialog.dismiss()
            openLibrary(choices.getOrNull(i - 1)?.id)
        }.setNegativeButton("Annuler", null).show()
    }

    private fun selectGroup(path: String) {
        group = path
        showPage()
        list.setSelection(0)
        refresh()
    }

    private fun chooseGroup() {
        val id = sourceId
        val type = category
        reads.execute {
            val index = runCatching { CategoryIndex(db.groups(id, type)) }.getOrNull()
            runOnUiThread {
                if (!available || page != Page.LIBRARY || id != sourceId || type != category) return@runOnUiThread
                if (index == null) showError("Impossible de lire les catégories.")
                else showCategoryPicker(index, group, ::selectGroup)
            }
        }
    }

    override fun onResume() { super.onResume(); reloadSources() }

    private fun reloadSources() {
        val previousSource = sourceId
        val previousCategory = category
        val previousGroup = group
        reads.execute {
            val loaded = runCatching { db.sources() }.getOrNull()
            val groupMissing = previousGroup.isNotEmpty() && runCatching {
                db.groups(previousSource, previousCategory).none { it == previousGroup || it.startsWith("$previousGroup › ") }
            }.getOrDefault(false)
            runOnUiThread {
                if (!available) return@runOnUiThread
                if (loaded != null) {
                    sources = loaded
                    if (groupMissing && sourceId == previousSource && category == previousCategory && group == previousGroup) group = ""
                    if (sourceId != null && selected == null) { sourceId = null; group = "" }
                }
                showPage()
                refresh()
            }
        }
    }

    override fun onDestroy() {
        generation++
        handler.removeCallbacks(delayed)
        posters.close()
        reads.shutdown()
        films.changeCursor(null)
        super.onDestroy()
    }
    override fun onSaveInstanceState(state: Bundle) {
        state.putString("destination", page.name)
        state.putInt("category", category.code)
        state.putLong("source", sourceId ?: 0)
        state.putString("group", group)
        state.putString("search", search.text.toString())
        state.putInt("featured", home.featured)
        super.onSaveInstanceState(state)
    }

    private data class Title(val url: String, val name: String, val episodes: Boolean, val xtream: Boolean, val source: String) {
        companion object {
            fun read(c: Cursor) = Title(c.getString(1), c.getString(2), c.getInt(6) != 0, c.getInt(7) != 0, c.getString(4))
        }
    }

    private fun open(item: Title) {
        if (item.episodes) chooseEpisode(Uri.parse(item.url), item.name)
        else play(item.url, item.name, item.url, item.xtream, item.source)
    }

    private fun refresh() {
        val token = ++generation
        val section = page
        val term = search.text.toString()
        val library = section == Page.LIBRARY
        val type = if (library) category else Category.ALL
        val id = if (library) sourceId else null
        val genre = if (library) group else ""
        reads.execute {
            if (section == Page.HOME) {
                val result = runCatching {
                    val favorites = db.list(Page.FAVORITES, sourceId = 1L).use { c ->
                        buildSet { while (c.moveToNext()) add(c.getString(1)) }
                    }
                    val last = db.list(Page.RECENT, limit = 1).use { c -> if (c.moveToFirst()) Title.read(c) else null }
                    favorites to last?.takeUnless { item -> editions.any { it.url == item.url } }
                }
                runOnUiThread {
                    if (available && token == generation) result.onSuccess { (favorites, last) ->
                        home.activity(favorites, last?.name) { last?.let(::open) }
                    }
                }
                return@execute
            }
            val cursor = try {
                db.list(section, term, id, type, genre).also { c ->
                    try { c.count } catch (e: Exception) { c.close(); throw e }
                }
            } catch (_: Exception) { null }
            runOnUiThread {
                if (!available || token != generation) { cursor?.close(); return@runOnUiThread }
                val count = cursor?.count ?: 0
                resultCount.text = when {
                    cursor == null -> "Impossible de lire la bibliothèque."
                    count > 0 -> "$count " + if (count == 1) "titre" else "titres"
                    term.isNotBlank() || genre.isNotEmpty() || type != Category.ALL -> "Aucun résultat"
                    section == Page.FAVORITES -> "Aucun favori"
                    section == Page.RECENT -> "Aucune lecture récente"
                    else -> "Aucun titre"
                }
                films.changeCursor(cursor)
            }
        }
    }

    private inner class FilmRow : LinearLayout(this@MainActivity) {
        val poster = ImageView(context)
        val title = context.label("", 16f, bold = true)
        val subtitle = context.label("", 13f, muted)
        val heart = iconButton(R.drawable.ic_heart, "Favori") {}
        init {
            gravity = Gravity.CENTER_VERTICAL
            pad(16, 6)
            minimumHeight = dp(68)
            isFocusable = true
            surface(ink)
            poster.background = shape(panel, 4)
            poster.clipToOutline = true
            addView(poster, dp(64), dp(40))
            val words = context.column().apply { pad(10, 0) }
            for (label in listOf(title, subtitle)) {
                label.isSingleLine = true
                label.ellipsize = TextUtils.TruncateAt.END
                words.addView(label)
            }
            addView(words, weight())
            heart.surface(ink, 5)
            addView(heart, dp(48), dp(48))
        }
    }

    private inner class FilmAdapter : CursorAdapter(this@MainActivity, null, 0) {
        override fun newView(context: Context, cursor: Cursor, parent: ViewGroup): View = FilmRow()
        override fun bindView(view: View, context: Context, c: Cursor) = with(view as FilmRow) {
            val item = Title.read(c)
            val genre = c.getString(3)
            val source = item.source
            val favorite = c.getInt(5) != 0
            title.text = item.name
            subtitle.text = if (genre.isBlank()) source else "$genre · $source"
            val edition = editions.find { it.url == item.url }
            poster.scaleType = if (edition == null) ImageView.ScaleType.CENTER else ImageView.ScaleType.CENTER_CROP
            poster.imageTintList = if (edition == null) ColorStateList.valueOf(coral) else null
            val type = Category.entries.find { it.code == c.getInt(8) } ?: Category.ALL
            poster.setImageResource(edition?.poster ?: type.icon)
            posters.bind(poster, if (loadPosters && edition == null) c.getString(9) else null)
            heart.setImageResource(if (favorite) R.drawable.ic_heart_on else R.drawable.ic_heart)
            heart.imageTintList = ColorStateList.valueOf(if (favorite) coral else muted)
            heart.contentDescription = if (favorite) "Retirer ${item.name} des favoris" else "Ajouter ${item.name} aux favoris"
            heart.tooltipText = heart.contentDescription
            heart.setOnClickListener { mutate { db.toggle(item.url) } }
            setOnClickListener { open(item) }
        }
    }

    private fun play(url: String, title: String, history: String, xtream: Boolean, source: String) {
        startActivity(Intent(this, PlayerActivity::class.java)
            .putExtra("uri", url).putExtra("title", title).putExtra("source", source).putExtra("history", history).putExtra("xtream", xtream))
    }

    private fun chooseEpisode(uri: Uri, title: String) {
        val loading = AlertDialog.Builder(this).setTitle(title)
            .setView(LoadingSignal(this, "Chargement des épisodes…").apply { pad(24, 14) })
            .setNegativeButton("Fermer", null).show()
        reads.execute {
            val result = runCatching { Catalog.episodes(applicationContext, uri) }
            runOnUiThread {
                if (!available || !loading.isShowing) return@runOnUiThread
                loading.dismiss()
                val dialog = AlertDialog.Builder(this).setTitle(title).setNegativeButton("Fermer", null)
                val episodes = result.getOrNull()
                if (episodes == null) dialog.setMessage((result.exceptionOrNull() as? SourceError)?.message
                    ?: "Impossible de charger les épisodes.")
                else if (episodes.isEmpty()) dialog.setMessage("Aucun épisode disponible.")
                else dialog.setItems(episodes.map { if (it.season > 0) "Saison ${it.season} · ${it.title}" else it.title }
                    .toTypedArray()) { _, index ->
                    val episode = episodes[index]
                    play(episode.url, episode.title, uri.toString(), xtream = true, source = title)
                }
                dialog.show()
            }
        }
    }

    private fun syncSource(source: Source) {
        if (busy) return
        syncing = source.id
        mutate(true, done = {
            Toast.makeText(this, "« ${source.name} » actualisée", Toast.LENGTH_SHORT).show()
        }) { db.load(source) }
    }

    private fun importSources(resolve: () -> List<Source>) {
        val imported = mutableListOf<Long>()
        val failures = mutableListOf<String>()
        mutate(true, done = {
            openLibrary(imported.singleOrNull())
            if (failures.isNotEmpty()) showError("Certaines rubriques n’ont pas pu être importées.\n" + failures.joinToString("\n"))
        }) {
            val pending = resolve()
            for ((index, source) in pending.withIndex()) {
                runOnUiThread {
                    if (available) loadingSignal.message = if (pending.size > 1)
                        "${source.name} · ${index + 1} sur ${pending.size}" else "Import en cours…"
                }
                try {
                    imported.add(db.load(source))
                } catch (e: Exception) {
                    val detail = (e as? SourceError)?.message ?: "Vérifiez le fichier, la connexion et l’espace disponible."
                    failures.add(if (pending.size > 1) "${source.name} — $detail" else detail)
                }
            }
            if (imported.isEmpty()) throw SourceError(failures.joinToString("\n"))
        }
    }

    private fun mutate(sourceChange: Boolean = false, done: () -> Unit = {}, action: () -> Unit) {
        if (sourceChange) {
            if (busy) return
            busy = true
            sourceButton.isEnabled = false
            loadingSignal.message = if (syncing == null) "Mise à jour…" else "Actualisation…"
            loadingSignal.visibility = View.VISIBLE
            showPage()
        }
        Library.writes.execute {
            val error = try { action(); null } catch (e: SourceError) { e.message }
            catch (_: Exception) { "Vérifiez le fichier, la connexion ou les identifiants." }
            runOnUiThread {
                if (!available) return@runOnUiThread
                if (sourceChange) {
                    val wasSyncing = syncing != null
                    busy = false
                    syncing = null
                    sourceButton.isEnabled = true
                    loadingSignal.visibility = View.GONE
                    if (error != null && wasSyncing) {
                        AlertDialog.Builder(this).setTitle("Actualisation impossible")
                            .setMessage("$error\nLe dernier catalogue a été conservé.")
                            .setPositiveButton("Fermer", null).show()
                    } else if (error != null) showError(error)
                    if (error == null) done()
                    reloadSources()
                } else {
                    if (error != null) showError(error)
                    refresh()
                }
            }
        }
    }

    private fun showError(message: String) {
        AlertDialog.Builder(this).setMessage(message).setPositiveButton("Fermer", null).show()
    }

    private fun sourceMenu() {
        val choices = arrayOf("Vidéo ou audio · fichier", "Vidéo ou audio · adresse", "Playlist M3U · fichier",
            "Playlist M3U · adresse", "Compte Xtream", "Gérer les sources")
        AlertDialog.Builder(this).setTitle("Sources").setItems(choices) { _, which ->
            when (which) {
                0, 2 -> {
                    val picker = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
                    if (which == 0) picker.putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("video/*", "audio/*"))
                    startActivityForResult(picker, if (which == 0) 10 else 11)
                }
                1 -> address("media")
                3 -> address("playlist")
                4 -> address("xtream")
                5 -> manage()
            }
        }.show()
    }

    private fun address(kind: String) {
        val form = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), 0, dp(20), 0) }
        fun field(label: String, type: Int) = EditText(this).apply {
            hint = label
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or type
            form.addView(this)
        }
        val url = field("https://…", InputType.TYPE_TEXT_VARIATION_URI)
        val playlistName = if (kind == "playlist") field("Nom de la playlist (facultatif)", InputType.TYPE_TEXT_FLAG_CAP_SENTENCES) else null
        val user = if (kind == "xtream") field("Identifiant", InputType.TYPE_TEXT_VARIATION_NORMAL) else null
        val pass = if (kind == "xtream") field("Mot de passe", InputType.TYPE_TEXT_VARIATION_PASSWORD) else null
        val sections = listOf("live", "movies", "series")
        val labels = listOf("Direct", "Films", "Séries")
        val picker = if (kind == "xtream") Spinner(this).also {
            it.contentDescription = "Catalogue"
            it.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, listOf("Tout le catalogue") + labels)
            form.addView(it)
        } else null
        form.addView(TextView(this).apply {
            text = "Les adresses et identifiants sont conservés dans la bibliothèque de cet appareil. En HTTP, ils circulent en clair."
            setTextColor(muted)
            setPadding(0, dp(8), 0, 0)
        })
        val dialog = AlertDialog.Builder(this).setTitle(when (kind) {
            "xtream" -> "Serveur Xtream"; "playlist" -> "Adresse de la playlist"; else -> "Adresse du média"
        }).setView(ScrollView(this).apply { addView(form) }).setNegativeButton("Annuler", null).setPositiveButton("Ajouter", null).create()
        dialog.show()
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            val base = Uri.parse(url.text.toString().trim())
            if (!Catalog.web(base)) { url.error = "Adresse HTTP ou HTTPS requise"; return@setOnClickListener }
            if (user != null && user.text.isBlank()) { user.error = "Identifiant requis"; return@setOnClickListener }
            if (pass != null && pass.text.isEmpty()) { pass.error = "Mot de passe requis"; return@setOnClickListener }
            val pending = if (user != null && pass != null && picker != null) try {
                val selection = picker.selectedItemPosition
                val indices = if (selection == 0) sections.indices else (selection - 1)..(selection - 1)
                indices.map { i ->
                    val uri = NativeCore.login(base.toString(), user.text.toString(), pass.text.toString(), sections[i])
                    Source(Uri.parse(uri), "${base.host} · ${labels[i]}", kind)
                }
            } catch (e: SourceError) {
                url.error = e.message
                return@setOnClickListener
            } else {
                val name = if (kind == "media") base.lastPathSegment?.takeIf { it.isNotBlank() } else playlistName?.text?.toString()?.trim()?.takeIf { it.isNotEmpty() }
                listOf(Source(base, name ?: base.host.orEmpty(), kind))
            }
            dialog.dismiss()
            importSources { pending }
        }
    }

    @Deprecated("Document picker callback")
    override fun onActivityResult(request: Int, result: Int, data: Intent?) {
        super.onActivityResult(request, result, data)
        val uri = data?.data ?: return
        if (result != RESULT_OK || request !in 10..11) return
        importSources {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: "Fichier"
            listOf(Source(uri, name, if (request == 10) "media" else "playlist"))
        }
    }

    private fun manage() {
        reads.execute {
            val sources = db.sources()
            runOnUiThread {
                if (!available) return@runOnUiThread
                val dialog = AlertDialog.Builder(this).setTitle("Mes sources").setNegativeButton("Fermer", null)
                if (sources.isEmpty()) dialog.setMessage("Aucune source ajoutée.")
                else dialog.setItems(sources.map { it.name }.toTypedArray()) { _, i ->
                    val source = sources[i]
                    val actions = if (source.kind == "media") arrayOf("Retirer") else arrayOf("Actualiser", "Retirer")
                    AlertDialog.Builder(this).setTitle(source.name).setItems(actions) { _, j ->
                        if (actions[j] == "Actualiser") syncSource(source) else {
                            AlertDialog.Builder(this).setMessage("Retirer « ${source.name} » de la bibliothèque ?")
                                .setNegativeButton("Annuler", null).setPositiveButton("Retirer") { _, _ ->
                                    mutate(true) {
                                        db.remove(source)
                                        if (source.uri.scheme == "content") contentResolver.releasePersistableUriPermission(
                                            source.uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                }.show()
                        }
                    }.show()
                }
                dialog.show()
            }
        }
    }
}
