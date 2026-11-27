package app.trame.player

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import android.widget.ImageView
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Future
import java.util.concurrent.Executors

internal class Posters {
    private val cache = object : LruCache<String, Bitmap>(8 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }
    private val workers = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())
    private class Request(val url: String) { var future: Future<*>? = null }
    private val pending = mutableMapOf<ImageView, Request>()

    fun cancel(view: ImageView) { pending.remove(view)?.future?.cancel(true) }

    fun cancelAll() {
        pending.values.forEach { it.future?.cancel(true) }
        pending.clear()
    }

    fun close() { cancelAll(); workers.shutdownNow() }

    fun bind(view: ImageView, url: String?) {
        if (url != null && pending[view]?.url == url) return
        cancel(view)
        if (url == null) return
        cache.get(url)?.let { show(view, it); return }
        val request = Request(url)
        pending[view] = request
        request.future = workers.submit {
            val bitmap = try { cache.get(url) ?: download(url) } catch (_: Exception) { null }
            if (Thread.currentThread().isInterrupted) return@submit
            main.post {
                if (pending[view] !== request) return@post
                pending.remove(view)
                if (bitmap != null) { cache.put(url, bitmap); show(view, bitmap) }
            }
        }
    }

    private fun show(view: ImageView, bitmap: Bitmap) {
        view.imageTintList = null
        view.scaleType = ImageView.ScaleType.CENTER_CROP
        view.setImageBitmap(bitmap)
    }

    private fun download(address: String): Bitmap? {
        val url = URL(address)
        if (url.protocol != "http" && url.protocol != "https") return null
        val connection = url.openConnection() as HttpURLConnection
        val limit = 4 * 1024 * 1024
        try {
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            if (connection.responseCode != 200 || connection.contentLengthLong > limit) return null
            val bytes = connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val chunk = ByteArray(16 * 1024)
                while (!Thread.currentThread().isInterrupted) {
                    val count = input.read(chunk)
                    if (count < 0) break
                    if (count > limit - output.size()) return null
                    output.write(chunk, 0, count)
                }
                if (Thread.currentThread().isInterrupted) return null
                output.toByteArray()
            }
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            if (options.outWidth <= 0 || options.outHeight <= 0) return null
            while (maxOf(options.outWidth, options.outHeight) / options.inSampleSize.coerceAtLeast(1) > 384) {
                options.inSampleSize = options.inSampleSize.coerceAtLeast(1) * 2
            }
            options.inJustDecodeBounds = false
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        } finally { connection.disconnect() }
    }
}
