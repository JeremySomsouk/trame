package app.trame.player

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.RandomAccessFile
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONArray
import org.json.JSONObject

internal open class SourceError(message: String) : IOException(message)
private class HttpError(val status: Int) : SourceError("Le serveur a répondu avec le code HTTP $status.")
internal data class Episode(val url: String, val title: String, val season: Long)

internal object Catalog {
    private const val byteLimit = 2L * 1024 * 1024 * 1024
    private fun tooLarge(): Nothing = throw SourceError("La liste dépasse 2 Go. Importez une liste plus petite.")

    fun web(uri: Uri) = (uri.scheme.equals("https", true) || uri.scheme.equals("http", true)) && !uri.host.isNullOrBlank()

    private class Body(val origin: Uri, val input: InputStream, val connection: HttpURLConnection? = null) : Closeable {
        override fun close() { try { input.close() } finally { connection?.disconnect() } }
    }

    private fun open(context: Context, uri: Uri): Body {
        if (uri.scheme == "content") {
            return Body(uri, context.contentResolver.openInputStream(uri) ?: throw SourceError("Fichier inaccessible."))
        }
        if (!web(uri)) throw SourceError("Saisissez une adresse HTTP ou HTTPS.")
        val connection = URL(uri.toString()).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 15000
            connection.readTimeout = 30000
            val status = connection.responseCode
            if (status !in 200..299 || status == 206) throw HttpError(status)
            if (connection.contentLengthLong > byteLimit) tooLarge()
            return Body(Uri.parse(connection.url.toString()), connection.inputStream, connection)
        } catch (e: Exception) {
            connection.disconnect()
            throw e
        }
    }

    // An unlinked cache file bounds the heap on 32-bit phones and disappears even
    // if the process exits. The core reads it sequentially and emits rows to SQLite.
    private fun <T> Body.withFile(context: Context, consume: (Int) -> T): T {
        val path = File.createTempFile("catalog-", null, context.cacheDir)
        try {
            RandomAccessFile(path, "rw").use { file ->
                if (!path.delete()) throw SourceError("Impossible de préparer le catalogue temporaire.")
                val buffer = ByteArray(64 * 1024)
                var size = 0L
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    size += n
                    if (size > byteLimit) tooLarge()
                    try { file.write(buffer, 0, n) } catch (_: IOException) {
                        throw SourceError("Impossible d’enregistrer le catalogue temporaire. Vérifiez l’espace disponible.")
                    }
                }
                file.seek(0)
                return ParcelFileDescriptor.dup(file.fd).use { consume(it.fd) }
            }
        } finally {
            if (path.exists()) path.delete()
        }
    }

    fun read(context: Context, source: Source, sink: MediaSink) {
        if (source.kind != "xtream" && !source.uri.lastPathSegment.equals("player_api.php", true)) {
            open(context, source.uri).use { body ->
                body.withFile(context) { NativeCore.playlist(body.origin.toString(), source.name, it, sink) }
            }
            return
        }
        val login = source.uri.toString()
        val plan = JSONObject(NativeCore.endpoints(login))
        val groups = Uri.parse(plan.getString("categories"))
        val categories = try { open(context, groups) } catch (e: HttpError) {
            if (e.status != 404 && e.status != 405) throw e
            Body(groups, "[]".byteInputStream())
        }
        categories.use { body ->
            body.withFile(context) { groupFile ->
                open(context, Uri.parse(plan.getString("streams"))).use { streams ->
                    streams.withFile(context) { NativeCore.catalog(login, it, groupFile, sink) }
                }
            }
        }
    }

    fun episodes(context: Context, endpoint: Uri): List<Episode> = open(context, endpoint).use { body ->
        val rows = JSONArray(body.withFile(context) { NativeCore.episodes(endpoint.toString(), it) })
        List(rows.length()) { i ->
            val row = rows.getJSONObject(i)
            Episode(row.getString("url"), row.getString("name"), row.getLong("season"))
        }
    }
}
