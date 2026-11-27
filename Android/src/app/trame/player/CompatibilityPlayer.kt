package app.trame.player

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.PopupMenu
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.util.VLCVideoLayout

internal class CompatibilityPlayer(
    context: Context,
    private val screen: FrameLayout
) : MediaController.MediaPlayerControl {
    private val engine = LibVLC(context, arrayListOf("--quiet", "--no-video-title-show", "--no-metadata-network-access"))
    private val player = MediaPlayer(engine)
    private val surface = VLCVideoLayout(context)
    private val controls = MediaController(context)
    private var descriptor: AssetFileDescriptor? = null
    private var closed = false
    private var ended = false
    private var buffering = 0
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private var resumeOnGain = false
    private val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
        .setOnAudioFocusChangeListener { change ->
            if (!closed) when (change) {
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                    resumeOnGain = player.isPlaying
                    if (resumeOnGain) player.pause()
                }
                AudioManager.AUDIOFOCUS_LOSS -> pause()
                AudioManager.AUDIOFOCUS_GAIN -> if (resumeOnGain) {
                    resumeOnGain = false
                    player.play()
                }
            }
        }.build()

    fun open(uri: Uri, position: Int, events: (MediaPlayer.Event) -> Unit) {
        screen.addView(surface, 0, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        player.attachViews(surface, null, true, false)
        controls.setAnchorView(surface)
        controls.setMediaPlayer(this)
        surface.setOnClickListener { if (controls.isShowing) controls.hide() else controls.show() }
        player.setEventListener { event ->
            if (closed) return@setEventListener
            when (event.type) {
                MediaPlayer.Event.Buffering -> buffering = event.buffering.toInt()
                MediaPlayer.Event.Playing -> ended = false
                MediaPlayer.Event.EndReached -> ended = true
            }
            events(event)
        }
        val media = when (uri.scheme) {
            "content", "android.resource" -> {
                val file = requireNotNull(screen.context.contentResolver.openAssetFileDescriptor(uri, "r"))
                descriptor = file
                if (file.declaredLength < 0) Media(engine, file.fileDescriptor) else Media(engine, file)
            }
            "file", "http", "https" -> Media(engine, uri)
            else -> throw IllegalArgumentException("Adresse média non prise en charge")
        }
        try {
            if (position > 0) media.addOption(":start-time=" + position / 1000.0)
            player.media = media
        } finally {
            media.release()
        }
        start()
    }

    fun tracks(anchor: View) {
        val menu = PopupMenu(anchor.context, anchor)
        for (audio in listOf(true, false)) {
            val sub = menu.menu.addSubMenu(if (audio) "Audio" else "Sous-titres")
            val tracks = (if (audio) player.audioTracks else player.spuTracks).orEmpty()
            if (tracks.isEmpty()) sub.add("Aucune piste disponible").isEnabled = false
            val selected = if (audio) player.audioTrack else player.spuTrack
            for (track in tracks) {
                sub.add(if (track.id == -1) "Désactivé" else track.name).apply {
                    isCheckable = true
                    isChecked = selected == track.id
                    setOnMenuItemClickListener {
                        if (!closed) {
                            if (audio) player.setAudioTrack(track.id) else player.setSpuTrack(track.id)
                        }
                        true
                    }
                }
            }
        }
        menu.show()
    }

    fun showControls() = controls.show()
    override fun start() {
        if (audioManager.requestAudioFocus(focus) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            controls.show(0)
            return
        }
        if (ended) player.stop()
        player.play()
    }
    override fun pause() {
        resumeOnGain = false
        player.pause()
    }
    override fun isPlaying(): Boolean = player.isPlaying
    override fun seekTo(pos: Int) { player.setTime(pos.toLong()) }
    override fun getDuration(): Int = player.length.coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
    override fun getCurrentPosition(): Int = player.time.coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
    override fun getBufferPercentage(): Int = buffering
    override fun canPause(): Boolean = true
    override fun canSeekBackward(): Boolean = player.isSeekable
    override fun canSeekForward(): Boolean = player.isSeekable
    override fun getAudioSessionId(): Int = 0

    fun close() {
        if (closed) return
        closed = true
        controls.hide()
        audioManager.abandonAudioFocusRequest(focus)
        player.setEventListener(null)
        player.stop()
        player.detachViews()
        screen.removeView(surface)
        player.release()
        engine.release()
        descriptor?.close()
    }
}
