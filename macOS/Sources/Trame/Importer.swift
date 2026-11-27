import Foundation
import TrameSources

enum Importer {
  static func standaloneKind(_ url: URL) -> MediaKind? {
    let kind = MediaKind.inferred(from: url)
    if kind == .live
      && (url.isFileURL
        || ["aac", "mp3", "m4a", "aiff", "caf", "wav", "flac", "alac"].contains(
          url.pathExtension.lowercased()))
    {
      return nil
    }
    return kind
  }

  static func sourceName(_ url: URL) -> String {
    if url.isFileURL { return url.deletingPathExtension().lastPathComponent }
    let host = url.host ?? "Flux"
    guard url.lastPathComponent.lowercased() == "player_api.php",
      let source = try? XtreamSource(url)
    else { return host }
    switch source.section {
    case .live: return host
    case .movies: return host + " · Films"
    case .series: return host + " · Séries"
    }
  }

  static func refresh(_ url: URL, playlist: Bool, validators: CatalogValidators?) async throws -> (
    films: [Film]?, validators: CatalogValidators?
  ) {
    let name = sourceName(url)
    guard playlist else {
      return (
        [
          Film(
            url: url, title: name, group: "",
            source: url.isFileURL ? "Fichier multimédia" : "Flux réseau", kind: standaloneKind(url))
        ], nil
      )
    }
    let update = try await CatalogLoader.refresh(url, name: name, validators: validators)
    let films = try update.catalog?.channels.map {
      try Task.checkCancellation()
      return Film(
        url: $0.url, title: $0.name, group: $0.group, source: name,
        opensEpisodes: $0.opensEpisodes ? true : nil, kind: $0.kind, posterURL: $0.posterUrl)
    }
    return (films, update.validators)
  }
}
