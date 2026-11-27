import Foundation
import Testing

@testable import Trame

@Test func catalogSearchMatchesTitlesSourcesAndGroups() async throws {
  let news = Film(url: URL(filePath: "/a"), title: "Été à Paris", group: "Régions", source: "Télé")
  let music = Film(url: URL(filePath: "/b"), title: "Jazz", group: "Musique", source: "Radio")
  let index = try await BrowserCollection.build(films: [news, music])
  #expect(index.groups == ["Musique", "Régions"])
  #expect(try await index.matches(text: "ete", group: "") == [news])
  #expect(try await index.matches(text: "TELE", group: "") == [news])
  #expect(try await index.matches(text: "regi", group: "Régions") == [news])
  #expect(try await index.matches(text: "PARIS", group: "Musique").isEmpty)
  var catalog = LibraryIndex()
  catalog.all = [news, music]
  catalog.byKey = [news.libraryKey: 0, music.libraryKey: 1]
  #expect(try await catalog.favorites(for: [music.libraryKey, "unknown"]) == [music])
  #expect(try await catalog.favorites(for: [music.libraryKey, news.libraryKey]) == [news, music])
}
