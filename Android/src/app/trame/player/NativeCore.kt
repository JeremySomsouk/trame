package app.trame.player

internal interface MediaSink {
    fun reset()
    fun item(url: String, title: String, group: String, category: Int, opensEpisodes: Boolean, poster: String?)
}

internal object NativeCore {
    init { System.loadLibrary("trame_core") }

    external fun legacyCategory(address: String): Int
    external fun login(server: String, user: String, password: String, section: String): String
    external fun endpoints(login: String): String
    external fun playlist(origin: String, name: String, input: Int, sink: MediaSink)
    external fun catalog(login: String, streams: Int, groups: Int, sink: MediaSink)
    external fun episodes(endpoint: String, input: Int): String
}
