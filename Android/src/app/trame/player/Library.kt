package app.trame.player

import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.net.Uri
import java.util.concurrent.Executors

internal data class Source(val uri: Uri, val name: String, val kind: String, val id: Long = 0) {
    val refreshable get() = kind == "playlist" || kind == "xtream"
}

internal class Library private constructor(private val app: Context) :
    SQLiteOpenHelper(app, "library.db", null, 5) {
    companion object {
        val writes = Executors.newSingleThreadExecutor()
        private var instance: Library? = null
        @Synchronized fun open(context: Context): Library =
            instance ?: Library(context.applicationContext).also { instance = it }
    }

    init { setWriteAheadLoggingEnabled(true) }
    override fun onConfigure(db: SQLiteDatabase) = db.setForeignKeyConstraintsEnabled(true)
    override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) {
        if (old < 5) db.execSQL("""UPDATE film SET genre = replace(replace(replace(genre, ' | ', ' › '), ' / ', ' › '), ' > ', ' › ')
            WHERE instr(genre, ' | ') > 0 OR instr(genre, ' / ') > 0 OR instr(genre, ' > ') > 0""")
        if (old < 4) db.execSQL("ALTER TABLE film ADD COLUMN poster TEXT")
        if (old < 2) db.execSQL("ALTER TABLE film ADD COLUMN episodes INTEGER NOT NULL DEFAULT 0")
        if (old < 3) {
            db.execSQL("ALTER TABLE film ADD COLUMN category INTEGER NOT NULL DEFAULT 0")
            // Earlier imports kept the episode flag and URL, but discarded explicit M3U types.
            db.rawQuery("""SELECT f._id,f.url,f.episodes,s.kind FROM film f
                JOIN source s ON s.id=f.source ORDER BY f._id""", null).use { rows ->
                db.compileStatement("UPDATE film SET category=? WHERE _id=?").use { update ->
                    while (rows.moveToNext()) {
                        val category = when {
                            rows.getInt(2) != 0 -> Category.SERIES.code
                            rows.getString(3) == "edition" -> Category.MOVIES.code
                            rows.getString(3) == "media" -> mediaCategory(Uri.parse(rows.getString(1)))
                            else -> NativeCore.legacyCategory(rows.getString(1))
                        }
                        update.bindLong(1, category.toLong())
                        update.bindLong(2, rows.getLong(0))
                        update.executeUpdateDelete()
                    }
                }
            }
        }
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE source (id INTEGER PRIMARY KEY, uri TEXT UNIQUE, name TEXT NOT NULL, kind TEXT NOT NULL)")
        db.execSQL("""CREATE TABLE film (_id INTEGER PRIMARY KEY, source INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
            url TEXT NOT NULL, title TEXT NOT NULL, genre TEXT NOT NULL, episodes INTEGER NOT NULL DEFAULT 0, category INTEGER NOT NULL DEFAULT 0, poster TEXT, UNIQUE(source,url))""")
        db.execSQL("CREATE INDEX film_url ON film(url)")
        db.execSQL("CREATE TABLE activity (url TEXT PRIMARY KEY, favorite INTEGER DEFAULT 0, played INTEGER DEFAULT 0)")
        db.execSQL("INSERT INTO source VALUES(1,'editions','Éditions Trame','edition')")
        for (edition in editions) {
            db.execSQL("INSERT INTO film(source,url,title,genre,category) VALUES(1,?,?,'Études de mouvement',?)",
                arrayOf<Any>(edition.url, edition.title, Category.MOVIES.code))
        }
    }

    private fun mediaCategory(uri: Uri): Int {
        if (uri.scheme == "content") {
            val type = try { app.contentResolver.getType(uri) } catch (_: RuntimeException) { null }
            if (type?.startsWith("video/") == true) return Category.MOVIES.code
        }
        // A standalone audio file or an untyped address remains available under Tous.
        return NativeCore.legacyCategory(uri.toString()).takeIf { it == Category.MOVIES.code } ?: 0
    }

    private fun <T> transaction(block: (SQLiteDatabase) -> T): T {
        val db = writableDatabase
        db.beginTransactionNonExclusive()
        return try { block(db).also { db.setTransactionSuccessful() } } finally { db.endTransaction() }
    }

    fun load(source: Source) = transaction { db ->
        val origin = arrayOf(source.uri.toString())
        db.execSQL("INSERT OR IGNORE INTO source(uri,name,kind) VALUES(?,?,?)",
            arrayOf(source.uri.toString(), source.name, source.kind))
        val id = db.rawQuery("SELECT id FROM source WHERE uri=?", origin).use { it.moveToFirst(); it.getLong(0) }
        db.execSQL("DELETE FROM film WHERE source=?", arrayOf(id))
        db.compileStatement("INSERT OR IGNORE INTO film(source,url,title,genre,episodes,category,poster) VALUES(?,?,?,?,?,?,?)").use { insert ->
            insert.bindLong(1, id)
            var any = false
            val add = object : MediaSink {
                override fun reset() {
                    db.execSQL("DELETE FROM film WHERE source=?", arrayOf(id))
                    any = false
                }
                override fun item(url: String, title: String, group: String, category: Int, opensEpisodes: Boolean, poster: String?) {
                    insert.bindString(2, url)
                    insert.bindString(3, title)
                    insert.bindString(4, group)
                    insert.bindLong(5, if (opensEpisodes) 1 else 0)
                    insert.bindLong(6, category.toLong())
                    if (poster == null) insert.bindNull(7) else insert.bindString(7, poster)
                    insert.executeInsert()
                    any = true
                }
            }
            if (source.kind == "media") add.item(origin[0], source.name, "", mediaCategory(source.uri), false, null) else Catalog.read(app, source, add)
            if (!any) throw SourceError("Aucun titre lisible dans cette source.")
        }
        db.execSQL("DELETE FROM activity WHERE NOT EXISTS (SELECT 1 FROM film WHERE film.url=activity.url)")
        db.execSQL("UPDATE source SET kind=?,name=? WHERE id=?", arrayOf<Any>(source.kind, source.name, id))
        id
    }

    fun list(page: Page, text: String = "", sourceId: Long? = null, category: Category = Category.ALL,
             group: String = "", limit: Int? = null): Cursor {
        val conditions = mutableListOf<String>()
        val args = mutableListOf<String>()
        when (page) {
            Page.FAVORITES -> conditions.add("a.favorite=1")
            Page.RECENT -> conditions.add("a.played>0")
            else -> Unit
        }
        if (sourceId != null) {
            conditions.add("f.source=?")
            args.add(sourceId.toString())
        }
        if (category != Category.ALL) {
            conditions.add("f.category=?")
            args.add(category.code.toString())
        }
        if (group.isNotEmpty()) {
            conditions.add("(f.genre=? OR instr(f.genre,?)=1)")
            args.add(group)
            args.add("$group › ")
        }
        if (text.isNotBlank()) {
            val pattern = "%" + text.trim().replace("!", "!!").replace("%", "!%").replace("_", "!_") + "%"
            conditions.add("(f.title LIKE ? ESCAPE '!' OR f.genre LIKE ? ESCAPE '!' OR s.name LIKE ? ESCAPE '!')")
            args.addAll(listOf(pattern, pattern, pattern))
        }
        val where = if (conditions.isEmpty()) "" else "WHERE " + conditions.joinToString(" AND ")
        val sort = if (page == Page.RECENT) "a.played DESC" else "s.id DESC, _id"
        val sql = """SELECT min(f._id) AS _id, f.url, f.title, f.genre, s.name, coalesce(a.favorite,0),
            max(f.episodes), max(s.kind='xtream'), f.category, f.poster
            FROM film f JOIN source s ON s.id=f.source LEFT JOIN activity a ON a.url=f.url
            $where GROUP BY f.url ORDER BY $sort"""
        return readableDatabase.rawQuery(sql + (limit?.let { " LIMIT $it" } ?: ""), args.toTypedArray())
    }

    fun groups(sourceId: Long?, category: Category): List<String> {
        val filter = buildString {
            if (sourceId != null) append(" AND source=?")
            if (category != Category.ALL) append(" AND category=?")
        }
        val args = listOfNotNull(sourceId?.toString(), category.code.toString().takeIf { category != Category.ALL })
        return readableDatabase.rawQuery(
            "SELECT DISTINCT genre FROM film WHERE genre<>'' $filter ORDER BY genre COLLATE NOCASE", args.toTypedArray()
        ).use { rows -> buildList { while (rows.moveToNext()) add(rows.getString(0)) } }
    }

    fun sources(): List<Source> = readableDatabase.rawQuery(
        "SELECT uri,name,kind,id FROM source WHERE kind<>'edition' ORDER BY id DESC", null
    ).use { c -> buildList { while (c.moveToNext()) add(Source(Uri.parse(c.getString(0)), c.getString(1), c.getString(2), c.getLong(3))) } }

    fun remove(source: Source) = transaction { db ->
        db.delete("source", "uri=? AND kind<>'edition'", arrayOf(source.uri.toString()))
        db.execSQL("DELETE FROM activity WHERE NOT EXISTS (SELECT 1 FROM film WHERE film.url=activity.url)")
    }

    fun toggle(url: String) = transaction { db ->
        db.execSQL("INSERT OR IGNORE INTO activity(url) SELECT url FROM film WHERE url=? LIMIT 1", arrayOf(url))
        db.execSQL("UPDATE activity SET favorite=1-favorite WHERE url=?", arrayOf(url))
    }

    fun clearHistory() = transaction { db ->
        db.execSQL("DELETE FROM activity WHERE played>0 AND favorite=0")
        db.execSQL("UPDATE activity SET played=0 WHERE played>0")
    }

    fun played(url: String) = transaction { db ->
        db.execSQL("INSERT OR IGNORE INTO activity(url) SELECT url FROM film WHERE url=? LIMIT 1", arrayOf(url))
        db.execSQL("UPDATE activity SET played=? WHERE url=?", arrayOf<Any>(System.currentTimeMillis(), url))
        db.execSQL("""UPDATE activity SET played=0 WHERE played>0 AND url NOT IN
            (SELECT url FROM activity ORDER BY played DESC LIMIT 40)""")
    }
}
