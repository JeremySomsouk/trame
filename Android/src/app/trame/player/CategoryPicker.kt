package app.trame.player

import android.app.AlertDialog
import android.content.Context
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.ArrayAdapter
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.SearchView
import android.widget.TextView
import java.text.Normalizer
import java.util.Locale

private val marks = Regex("\\p{M}+")
private val spaces = Regex("\\s+")

private fun searchable(text: String): String =
    Normalizer.normalize(text, Normalizer.Form.NFD).replace(marks, "").lowercase(Locale.ROOT)

internal class CategoryIndex(groups: List<String>) {
    val children = mutableMapOf<String, MutableSet<String>>()
    private val searchKeys = linkedMapOf<String, String>()

    init {
        for (path in groups) {
            var parent = ""
            for (part in path.split(" › ")) {
                if (part.isEmpty()) continue
                val node = if (parent.isEmpty()) part else "$parent › $part"
                if (children.getOrPut(parent) { linkedSetOf() }.add(node)) searchKeys[node] = searchable(node)
                parent = node
            }
        }
    }

    fun matches(query: String): List<String> {
        val terms = searchable(query).split(spaces)
        return searchKeys.mapNotNull { (path, key) -> path.takeIf { terms.all(key::contains) } }
    }
}

internal fun Context.showCategoryPicker(index: CategoryIndex, selected: String, select: (String) -> Unit) {
    val body = column().apply { isFocusableInTouchMode = true }
    val search = SearchView(this).apply {
        setIconifiedByDefault(false)
        queryHint = "Rechercher une catégorie…"
    }
    body.addView(search)
    val list = ListView(this)
    val empty = label("Aucune catégorie trouvée", 14f, muted).apply { gravity = Gravity.CENTER }
    val results = FrameLayout(this).apply { addView(list); addView(empty) }
    list.emptyView = empty
    body.addView(results, LinearLayout.LayoutParams(-1, dp(320), 1f))
    val dialog = AlertDialog.Builder(this).setTitle("Catégories").setView(body)
        .setNeutralButton("Retour", null).setNegativeButton("Fermer", null).create()
    var parent = ""
    var term = ""
    fun choose(path: String) {
        dialog.dismiss()
        select(path)
    }
    fun render() {
        val browsing = term.isEmpty()
        val paths = if (browsing) listOf(parent) + index.children[parent].orEmpty() else index.matches(term)
        dialog.setTitle(if (browsing && parent.isNotEmpty()) parent else "Catégories")
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL).visibility = if (browsing && parent.isNotEmpty()) View.VISIBLE else View.GONE
        list.adapter = object : ArrayAdapter<String>(this, android.R.layout.simple_list_item_1, paths) {
            override fun getView(position: Int, convertView: View?, container: ViewGroup): View {
                val row = super.getView(position, convertView, container) as TextView
                val path = paths[position]
                row.text = when {
                    !browsing -> path
                    position == 0 -> if (parent.isEmpty()) "Toutes les catégories" else "Tous les titres de cette catégorie"
                    path in index.children -> path.substringAfterLast(" › ") + "  ›"
                    else -> path.substringAfterLast(" › ")
                }
                row.isSelected = path == selected
                row.setTextColor(if (row.isSelected) coral else paper)
                row.isSingleLine = false
                row.layoutParams.height = ViewGroup.LayoutParams.WRAP_CONTENT
                row.minimumHeight = dp(48)
                return row
            }
        }
    }
    list.setOnItemClickListener { _, _, position, _ ->
        val path = list.getItemAtPosition(position) as String
        if (term.isEmpty() && position > 0 && path in index.children) {
            parent = path
            render()
        } else choose(path)
    }
    dialog.show()
    dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
    dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener {
        parent = parent.substringBeforeLast(" › ", "")
        render()
    }
    search.setOnQueryTextListener(object : SearchView.OnQueryTextListener {
        override fun onQueryTextChange(text: String): Boolean {
            val value = text.trim()
            if (term != value) { term = value; render() }
            return true
        }
        override fun onQueryTextSubmit(text: String): Boolean {
            if (term.isNotEmpty() && list.count > 0) choose(list.getItemAtPosition(0) as String)
            return true
        }
    })
    render()
}
