package app.trame.player

import android.content.Context
import android.media.MediaPlayer
import android.media.MediaPlayer.TrackInfo
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.PopupMenu
import android.widget.Toast
import java.util.Locale

internal class PlaybackTracks(private val context: Context, state: Bundle?) {
    private var player: MediaPlayer? = null
    private var audioChoice = state?.getString("audioChoice")
    private var subtitleChoice = state?.getString("subtitleChoice")
    val button = context.iconButton(R.drawable.ic_tracks, "Audio et sous-titres") { showMenu() }
    val caption = context.label("", 16f).apply {
        gravity = Gravity.CENTER
        setTextColor(android.graphics.Color.WHITE)
        setBackgroundColor(0xc0000000.toInt())
        pad(8, 3)
        visibility = View.GONE
    }

    init { button.isEnabled = false }

    fun attach(next: MediaPlayer?) {
        player = next
        button.isEnabled = next != null
        caption.visibility = View.GONE
        if (next == null) return
        next.setOnTimedTextListener { sender, cue ->
            if (sender === player) {
                caption.text = cue?.text
                caption.visibility = if (caption.text.isNullOrBlank()) View.GONE else View.VISIBLE
            }
        }
        if (audioChoice == null && subtitleChoice == null) return
        runCatching {
            val tracks = next.trackInfo
            tracks.forEachIndexed { i, info ->
                if (key(i, info) == audioChoice || key(i, info) == subtitleChoice) next.selectTrack(i)
            }
            if (subtitleChoice == "off") disableSubtitles(next)
        }
    }

    fun save(state: Bundle) {
        state.putString("audioChoice", audioChoice)
        state.putString("subtitleChoice", subtitleChoice)
    }

    private fun key(index: Int, info: TrackInfo) = "${info.trackType}/${info.language}/$index"
    private fun isSubtitle(type: Int) = type == TrackInfo.MEDIA_TRACK_TYPE_SUBTITLE || type == TrackInfo.MEDIA_TRACK_TYPE_TIMEDTEXT

    private fun disableSubtitles(current: MediaPlayer, exceptType: Int? = null) {
        for (type in listOf(TrackInfo.MEDIA_TRACK_TYPE_SUBTITLE, TrackInfo.MEDIA_TRACK_TYPE_TIMEDTEXT)) {
            if (type == exceptType) continue
            val index = current.getSelectedTrack(type)
            if (index >= 0) current.deselectTrack(index)
        }
        caption.visibility = View.GONE
    }

    private fun showMenu() {
        val current = player ?: return
        try {
            val tracks = current.trackInfo
            val menu = PopupMenu(context, button)
            for (audio in listOf(true, false)) {
                val submenu = menu.menu.addSubMenu(if (audio) "Audio" else "Sous-titres")
                val indices = tracks.indices.filter {
                    if (audio) tracks[it].trackType == TrackInfo.MEDIA_TRACK_TYPE_AUDIO else isSubtitle(tracks[it].trackType)
                }
                if (indices.isEmpty()) {
                    submenu.add(if (audio) "Aucune piste audio détectée" else "Aucune piste de sous-titres détectée").isEnabled = false
                    continue
                }
                val names = indices.map { i ->
                    val lang = tracks[i].language
                    if (lang.isNullOrBlank() || lang == "und") "" else Locale.forLanguageTag(lang).getDisplayLanguage(Locale.FRENCH)
                }
                val selected = indices.filter { current.getSelectedTrack(tracks[it].trackType) == it }
                if (!audio) {
                    submenu.add("Désactivés").apply {
                        isCheckable = true
                        isChecked = selected.isEmpty()
                        setOnMenuItemClickListener { applyChoice(current) { disableSubtitles(current); subtitleChoice = "off" } }
                    }
                }
                indices.forEachIndexed { pos, index ->
                    val info = tracks[index]
                    val name = names[pos]
                    val label = when {
                        name.isBlank() -> "Piste ${pos + 1}"
                        names.count { it == name } > 1 -> "$name · ${pos + 1}"
                        else -> name.replaceFirstChar { it.titlecase(Locale.FRENCH) }
                    }
                    submenu.add(label).apply {
                        isCheckable = true
                        isChecked = index in selected
                        setOnMenuItemClickListener {
                            applyChoice(current) {
                                current.selectTrack(index)
                                if (audio) audioChoice = key(index, info) else {
                                    disableSubtitles(current, exceptType = info.trackType)
                                    subtitleChoice = key(index, info)
                                }
                            }
                        }
                    }
                }
            }
            menu.show()
        } catch (_: RuntimeException) { unavailable() }
    }

    private fun applyChoice(current: MediaPlayer, action: () -> Unit): Boolean {
        if (player === current) try { action() } catch (_: RuntimeException) { unavailable() }
        return true
    }

    private fun unavailable() {
        Toast.makeText(context, "Cette piste n’est pas disponible dans le lecteur.", Toast.LENGTH_SHORT).show()
    }
}
