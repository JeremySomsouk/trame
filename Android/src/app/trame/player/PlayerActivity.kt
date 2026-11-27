package app.trame.player

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Bundle
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.*
import org.videolan.libvlc.MediaPlayer.Event

// Some Xtream panels accept surrounding whitespace in API logins but reject it in stream paths.
internal fun xtreamPlaybackFallback(uri: Uri): Uri? {
    if (!Catalog.web(uri)) return null
    val parts = uri.encodedPath?.split('/')?.toMutableList() ?: return null
    val route = parts.lastIndex - 3
    if (route < 0 || parts[route] !in listOf("live", "movie", "series")) return null
    var changed = false
    for (index in route + 1..route + 2) {
        val value = Uri.decode(parts[index])
        val trimmed = value.trim()
        if (trimmed.isEmpty() || trimmed == "." || trimmed == "..") return null
        if (value != trimmed) {
            parts[index] = Uri.encode(trimmed)
            changed = true
        }
    }
    return if (changed) uri.buildUpon().encodedPath(parts.joinToString("/")).build() else null
}

class PlayerActivity : Activity() {
    private lateinit var screen: FrameLayout
    private lateinit var switchPlayer: View
    private lateinit var vlcTracks: View
    private var compatibility: CompatibilityPlayer? = null
    private var useVLC = false
    private var errorDialog: AlertDialog? = null
    private lateinit var video: VideoView
    private lateinit var tracks: PlaybackTracks
    private lateinit var progress: LoadingSignal
    private lateinit var uri: Uri
    private lateinit var playbackUri: Uri
    private var ready = false
    private var active = false
    private var playing = true
    private var recorded = false
    private var position = 0

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        uri = intent.getStringExtra("uri")?.let(Uri::parse) ?: run { finish(); return }
        playbackUri = state?.getString("playbackUri")?.let(Uri::parse) ?: uri
        useVLC = state?.getBoolean("useVLC") == true
        position = state?.getInt("position") ?: 0
        playing = state?.getBoolean("playing", true) ?: true
        recorded = state?.getBoolean("recorded") ?: false
        volumeControlStream = AudioManager.STREAM_MUSIC
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
            setBackgroundColor(Color.BLACK)
        }
        val bar = row().apply {
            setBackgroundColor(panel)
            pad(12, 4)
        }
        bar.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_play)
            setColorFilter(coral)
        }, dp(20), dp(20))
        val details = column().apply { pad(10, 0) }
        val title = label(intent.getStringExtra("title").orEmpty(), 16f, bold = true)
        val source = label(intent.getStringExtra("source").orEmpty(), 12f, muted)
        for (line in listOf(title, source)) {
            if (line.text.isEmpty()) continue
            line.isSingleLine = true
            line.ellipsize = TextUtils.TruncateAt.END
            details.addView(line)
        }
        bar.addView(details, weight())
        tracks = PlaybackTracks(this, state)
        bar.addView(tracks.button, dp(48), dp(48))
        switchPlayer = action("VLC") { switchToVLC() }.apply { contentDescription = "Ouvrir avec le lecteur VLC" }
        bar.addView(switchPlayer)
        vlcTracks = iconButton(R.drawable.ic_tracks, "Audio et sous-titres") { compatibility?.tracks(vlcTracks) }
        vlcTracks.visibility = View.GONE
        bar.addView(vlcTracks, dp(48), dp(48))
        bar.addView(action("Fermer") { finish() }.apply { setTextColor(coral) })
        root.addView(bar)
        screen = FrameLayout(this)
        root.addView(screen, LinearLayout.LayoutParams(-1, 0, 1f))
        video = VideoView(this)
        screen.addView(video, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        screen.addView(tracks.caption, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
            setMargins(dp(8), 0, dp(8), dp(32))
        })
        val controls = MediaController(this)
        video.setMediaController(controls)
        progress = LoadingSignal(this, "Ouverture…").apply {
            pad(14, 9)
            background = shape(panel, 6)
        }
        screen.addView(progress, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))
        setContentView(root)

        video.setOnPreparedListener { player ->
            if (useVLC) return@setOnPreparedListener
            tracks.attach(player)
            ready = true
            progress.visibility = View.GONE
            if (position > 0) video.seekTo(position)
            if (playing && active) video.start()
            recordPlayback()
            controls.show(2500)
        }
        video.setOnInfoListener { _, what, _ ->
            if (useVLC) return@setOnInfoListener false
            if (ready && what == MediaPlayer.MEDIA_INFO_BUFFERING_START) {
                progress.message = "Mise en mémoire tampon…"
                progress.visibility = View.VISIBLE
            } else if (ready && what == MediaPlayer.MEDIA_INFO_BUFFERING_END) {
                progress.visibility = View.GONE
            }
            false
        }
        video.setOnCompletionListener {
            if (useVLC) return@setOnCompletionListener
            progress.visibility = View.GONE
            playing = false
            position = 0
            video.seekTo(0)
            controls.show(0)
        }
        video.setOnErrorListener { _, _, extra ->
            if (useVLC || isFinishing) return@setOnErrorListener true
            if (!ready && playbackUri == uri && extra == MediaPlayer.MEDIA_ERROR_IO &&
                intent.getBooleanExtra("xtream", false)) {
                xtreamPlaybackFallback(uri)?.let {
                    playbackUri = it
                    open()
                    return@setOnErrorListener true
                }
            }
            switchToVLC()
            true
        }
    }

    private fun switchToVLC() {
        if (useVLC) return
        if (ready) position = video.currentPosition.coerceAtLeast(0)
        useVLC = true
        video.stopPlayback()
        open()
    }

    private fun recordPlayback() {
        if (recorded) return
        recorded = true
        val key = intent.getStringExtra("history") ?: uri.toString()
        Library.writes.execute { Library.open(applicationContext).played(key) }
    }

    private fun failed() {
        ready = false
        progress.visibility = View.GONE
        compatibility?.close()
        compatibility = null
        if (isFinishing || errorDialog?.isShowing == true) return
        errorDialog = AlertDialog.Builder(this).setTitle("Lecture indisponible")
            .setMessage("Le lecteur VLC n’a pas pu ouvrir ce média.")
            .setPositiveButton("Réessayer") { _, _ -> open() }
            .setNegativeButton("Fermer") { _, _ -> finish() }
            .setOnCancelListener { finish() }.show()
    }

    private fun open() {
        ready = false
        tracks.attach(null)
        progress.message = "Ouverture…"
        progress.visibility = View.VISIBLE
        if (!useVLC) {
            video.setVideoURI(playbackUri)
            return
        }
        switchPlayer.visibility = View.GONE
        video.visibility = View.GONE
        tracks.button.visibility = View.GONE
        vlcTracks.visibility = View.VISIBLE
        vlcTracks.isEnabled = false
        progress.message = "Chargement avec VLC…"
        try {
            val next = CompatibilityPlayer(this, screen)
            compatibility = next
            next.open(playbackUri, position) eventListener@{ event ->
                if (compatibility !== next) return@eventListener
                when (event.type) {
                    Event.Playing -> {
                        val first = !ready
                        ready = true
                        if (first && (!active || !playing)) next.pause()
                        progress.visibility = View.GONE
                        vlcTracks.isEnabled = true
                        recordPlayback()
                        if (first) next.showControls()
                    }
                    Event.Buffering -> {
                        progress.visibility = if (event.buffering < 100) View.VISIBLE else View.GONE
                    }
                    Event.EndReached -> {
                        position = 0
                        progress.visibility = View.GONE
                        next.showControls()
                    }
                    Event.EncounteredError -> failed()
                }
            }
        } catch (_: Exception) { failed() }
    }

    override fun onStart() { super.onStart(); open() }
    override fun onResume() {
        super.onResume()
        if (active) return
        active = true
        if (ready && playing) compatibility?.start() ?: video.start()
    }
    override fun onPause() {
        if (!isInMultiWindowMode) pausePlayback()
        super.onPause()
    }
    private fun pausePlayback() {
        active = false
        compatibility?.let { player ->
            if (ready) {
                position = player.currentPosition
                playing = player.isPlaying
                if (playing) player.pause()
            }
            return
        }
        if (ready) {
            position = video.currentPosition.coerceAtLeast(0)
            playing = video.isPlaying
        }
        video.pause()
    }
    override fun onStop() {
        if (active) pausePlayback()
        ready = false
        tracks.attach(null)
        errorDialog?.dismiss()
        errorDialog = null
        compatibility?.close()
        compatibility = null
        video.stopPlayback()
        super.onStop()
    }
    override fun onSaveInstanceState(state: Bundle) {
        super.onSaveInstanceState(state)
        state.putBoolean("useVLC", useVLC)
        state.putString("playbackUri", playbackUri.toString())
        tracks.save(state)
        state.putInt("position", position)
        state.putBoolean("playing", playing)
        state.putBoolean("recorded", recorded)
    }
}
