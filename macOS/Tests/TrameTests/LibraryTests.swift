import Foundation
import Testing

@testable import Trame

@MainActor
struct LibraryTests {
  private func waitFor(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while !condition() && clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition())
  }

  private func add(_ url: URL, to library: Library) async throws {
    library.add([url], playlist: true) {}
    try await waitFor { !library.importing }
    #expect(library.notice == nil)
  }

  private func playlist(_ items: [(String, String)], at url: URL) throws {
    let content = ["#EXTM3U"] + items.map { "#EXTINF:-1," + $0.0 + "\nhttps://stream.test/" + $0.1 }
    try content.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  @Test func oldPlaylistRecoversTypesAndPostersEvenWhenItsContentHasNotChanged() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "catalog.m3u")
    try """
    #EXTM3U
    #EXTINF:-1 type="series" group-title="Drama" tvg-logo="https://images.test/show.jpg",Show
    https://stream.test/watch/1
    #EXTINF:-1 group-title="News",Channel
    https://stream.test/live/1
    """.write(to: source, atomically: true, encoding: .utf8)
    let library = Library(directory: directory)
    try await waitFor { library.ready }
    try await add(source, to: library)

    let file = directory.appending(path: "library.json")
    var saved = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [[String: Any]]])
    var record = try #require(saved["sources"]?.first)
    record.removeValue(forKey: "hasMediaMetadata")
    var films = try #require(record["films"] as? [[String: Any]])
    for i in films.indices {
      films[i].removeValue(forKey: "kind")
      films[i].removeValue(forKey: "posterURL")
    }
    record["films"] = films
    saved["sources"] = [record]
    try JSONSerialization.data(withJSONObject: saved).write(to: file)
    let reopened = Library(directory: directory)
    try await waitFor { reopened.ready }
    #expect(reopened.sources.first?.validators == nil)
    reopened.refreshSources()
    try await waitFor { !reopened.syncing }
    let series = try await BrowserCollection.build(films: reopened.all, kind: .series)
    #expect(series.groups == ["Drama"])
    #expect(series.films.map(\.title) == ["Show"])
    #expect(series.films.first?.opensEpisodes != true)
    #expect(series.films.first?.posterURL?.host == "images.test")
    let direct = try await BrowserCollection.build(films: reopened.all, kind: .live)
    #expect(direct.films.map(\.title) == ["Channel"])
    let movies = try await BrowserCollection.build(films: reopened.all, kind: .movies)
    #expect(movies.films == Film.editions)
  }

  @Test func bulkImportKeepsAvailableSectionsAndCanRetryWithoutDuplicates() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let live = directory.appending(path: "direct.m3u")
    let movies = directory.appending(path: "films.m3u")
    let series = directory.appending(path: "series.m3u")
    try playlist([("One", "1"), ("Two", "2")], at: live)
    try playlist([("Movie", "movie")], at: movies)

    let library = Library(directory: directory)
    try await waitFor { library.ready }
    library.add([live, movies, series], playlist: true) {}
    try await waitFor { !library.importing }
    #expect(library.sources.map(\.id) == [live, movies])
    #expect(library.sources.map(\.count) == [2, 1])
    #expect(library.notice?.contains("series") == true)

    try playlist([("Series", "series")], at: series)
    library.add([live, movies, series], playlist: true) {}
    try await waitFor { !library.importing }
    #expect(library.notice == nil)
    let reopened = Library(directory: directory)
    try await waitFor { reopened.ready }
    #expect(Set(reopened.sources.map(\.id)) == [live, movies, series])
    #expect(reopened.sources.count == 3)
    #expect(reopened.all.count == Film.editions.count + 4)
  }

  @Test func refreshPreservesOfflineSourcesSharedChannelsAndExplicitRemovals() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = directory.appending(path: "a.m3u")
    let b = directory.appending(path: "b.m3u")
    try playlist([("Shared A", "shared"), ("Removed", "removed")], at: a)
    try playlist([("Shared B", "shared"), ("Offline", "offline")], at: b)
    let library = Library(directory: directory)
    try await waitFor { library.ready }
    try await add(a, to: library)
    try await add(b, to: library)
    #expect(library.sources.count == 2)
    let shared = try #require(library.all.first { $0.title == "Shared B" })
    library.toggle(shared)
    library.played(shared)
    library.remove(try #require(library.all.first { $0.title == "Removed" }))
    try await waitFor { !library.all.contains { $0.title == "Removed" } }
    try playlist([("New A", "shared"), ("Removed", "removed"), ("New", "new")], at: a)
    try FileManager.default.removeItem(at: b)
    library.refreshSources()
    try await waitFor { !library.syncing }
    #expect(library.notice?.contains("b.m3u") == true)
    #expect(library.all.contains { $0.title == "New" })
    #expect(library.all.contains { $0.title == "Offline" })
    #expect(!library.all.contains { $0.title == "Removed" })
    library.removeSource(b)
    try await waitFor { library.sources.count == 1 }
    #expect(library.recent.first?.title == "New A")
    #expect(library.favorite(shared))
    #expect(!library.all.contains { $0.title == "Offline" })
    let restored = Library(directory: directory)
    try await waitFor { restored.ready }
    #expect(restored.sources.map(\.id) == [a])
    #expect(restored.favorite(shared))
    #expect(restored.recent.first?.title == "New A")
    let rev = restored.catalogRevision
    restored.refreshSources()
    try await waitFor { !restored.syncing }
    #expect(restored.catalogRevision == rev)
    #expect(restored.syncStatus == "Sources à jour")
  }

  @Test func legacyLibraryMigratesWithoutRewritingCatalogForActivity() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "library.json")
    let key = "https://stream.test/legacy"
    let bytes = Data(
      """
      {"imports":[{"url":"\(key)","title":"Legacy","group":"","source":"my"}],"favorites":["\(key)"],"recent":["\(key)"]}
      """.utf8)
    try bytes.write(to: file)
    let library = Library(directory: directory)
    try await waitFor { library.ready }
    #expect(!library.hasRefreshableSources)
    let film = try #require(library.recent.first)
    #expect(library.favorite(film))
    let migratedCatalog = try Data(contentsOf: file)
    #expect(migratedCatalog != bytes)
    let activityFile = directory.appending(path: "activity.json")
    let saved = try JSONDecoder().decode(LibraryActivity.self, from: Data(contentsOf: activityFile))
    #expect(saved.favorites == [film.libraryKey])
    #expect(saved.recent == [film.libraryKey])
    #expect(!film.libraryKey.contains(key))
    library.toggle(film)
    try await waitFor {
      (try? JSONDecoder().decode(LibraryActivity.self, from: Data(contentsOf: activityFile)))?
        .favorites.isEmpty == true
    }
    #expect(try Data(contentsOf: file) == migratedCatalog)
    let source = directory.appending(path: "my.m3u")
    try playlist([("New title", "legacy")], at: source)
    try await add(source, to: library)
    #expect(library.recent.first?.title == "New title")
    let restored = Library(directory: directory)
    try await waitFor { restored.ready }
    #expect(!restored.favorite(film))
    #expect(restored.recent.first?.title == "New title")
    restored.removeSource(source)
    try await waitFor { restored.sources.isEmpty }
    #expect(!restored.all.contains { $0.url == film.url })
  }

  @Test func rotatedURLsAndLegacyOrphansAreRemovedFromActivity() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "list.m3u")
    let file = directory.appending(path: "activity.json")
    func savedActivity() throws -> LibraryActivity {
      try JSONDecoder().decode(LibraryActivity.self, from: Data(contentsOf: file))
    }

    try playlist([("Channel", "channel?ticket=old-fixture")], at: source)
    let library = Library(directory: directory)
    try await waitFor { library.ready }
    try await add(source, to: library)
    let film = try #require(library.all.first { $0.title == "Channel" })
    let orphan = "https://stream.test/expired"
    let legacyKeys = [film.url.absoluteString, orphan]
    try JSONEncoder().encode(LibraryActivity(favorites: Set(legacyKeys), recent: legacyKeys))
      .write(to: file, options: .atomic)

    let restored = Library(directory: directory)
    try await waitFor { restored.ready }
    #expect(restored.favorite(film))
    #expect(restored.recent == [film])
    let saved = try savedActivity()
    #expect(saved.favorites == [film.libraryKey])
    #expect(saved.recent == [film.libraryKey])
    #expect(!film.libraryKey.contains("old-fixture"))

    try playlist([("Channel", "channel?ticket=new-fixture")], at: source)
    restored.refreshSources()
    try await waitFor { !restored.syncing }
    // A player opened before refresh can still report its first frame afterward.
    restored.played(film)
    restored.toggle(film)
    #expect(!restored.favorite(film))
    #expect(restored.recent.isEmpty)
    try await waitFor { (try? savedActivity()) == LibraryActivity() }
    let replacement = try #require(restored.all.first { $0.title == "Channel" })
    restored.played(replacement)
    restored.toggle(replacement)
    try await waitFor { (try? savedActivity().favorites) == [replacement.libraryKey] }
    restored.removeSource(source)
    try await waitFor { restored.sources.isEmpty && (try? savedActivity()) == LibraryActivity() }
    let reopened = Library(directory: directory)
    try await waitFor { reopened.ready }
    #expect(reopened.recent.isEmpty)
    #expect(try await reopened.favoriteFilms().isEmpty)
  }

  @Test func hidingLastChannelAndCancellingRefreshKeepSubscription() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "live.m3u")
    try playlist([("Hidden", "hidden")], at: source)
    let library = Library(directory: directory)
    try await waitFor { library.ready }
    try await add(source, to: library)
    library.remove(try #require(library.all.first { $0.title == "Hidden" }))
    try await waitFor { library.sources.first?.count == 0 }
    try playlist([("Hidden", "hidden"), ("New", "new")], at: source)
    let revision = library.catalogRevision
    library.refreshSources()
    library.cancelRefresh()
    try await waitFor { !library.syncing }
    #expect(library.catalogRevision == revision)
    #expect(library.syncStatus == "Actualisation annulée")
    library.refreshSources()
    try await waitFor { !library.syncing }
    #expect(library.sources.first?.count == 1)
    #expect(library.all.contains { $0.title == "New" })
    #expect(!library.all.contains { $0.title == "Hidden" })
  }

  @Test func favoriteDoesNotRewriteLargeCatalog() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "large.m3u")
    try playlist((0..<10_000).map { ("Station " + String($0), String($0)) }, at: source)
    let library = Library(directory: directory)
    try await waitFor { library.ready }
    try await add(source, to: library)
    let catalog = directory.appending(path: "library.json")
    let before = try FileManager.default.attributesOfItem(atPath: catalog.path)
    let film = try #require(library.all.first)
    library.toggle(film)
    let activity = directory.appending(path: "activity.json")
    try await waitFor { FileManager.default.fileExists(atPath: activity.path) }
    let after = try FileManager.default.attributesOfItem(atPath: catalog.path)
    #expect(before[.systemFileNumber] as? UInt64 == after[.systemFileNumber] as? UInt64)
    #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    let size = try Data(contentsOf: activity).count
    #expect(size < 1024)
    print(
      "Storage fixture: 10,000 channels, catalogue \(before[.size] ?? 0) bytes; favorite update \(size) bytes."
    )
  }

  @Test func corruptCatalogIsProtectedFromOverwrites() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "library.json")
    let bad = Data("truncated".utf8)
    try bad.write(to: file)
    let library = Library(directory: directory)
    try await waitFor { library.ready }
    #expect(library.notice != nil)
    library.notice = nil
    let source = directory.appending(path: "local.m3u")
    try playlist([("Session only", "session")], at: source)
    try await add(source, to: library)
    #expect(library.hasRefreshableSources)
    #expect(try Data(contentsOf: file) == bad)
  }
}
