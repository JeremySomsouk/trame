import AppKit
import CryptoKit
import Foundation
import TrameMedia
import TrameSources

struct Film: Identifiable, Codable, Hashable, Sendable {
  let url: URL
  let title: String
  var group: String
  let source: String
  var artwork: String?
  var opensEpisodes: Bool?
  var kind: MediaKind?
  var posterURL: URL?
  var id: URL { url }

  var symbol: String {
    switch kind {
    case .movies: return "film"
    case .series: return "tv"
    case .live: return "antenna.radiowaves.left.and.right"
    case nil: break
    }
    return switch url.pathExtension.lowercased() {
    case "aac", "mp3", "m4a", "aiff", "caf", "wav", "flac", "alac": "waveform"
    default: url.isFileURL ? "film" : "antenna.radiowaves.left.and.right"
    }
  }

  static let editions = [
    ("corail", "Interférences"), ("maree", "Marée bleue"), ("orbite", "Orbite solaire"),
  ].compactMap { key, title -> Film? in
    guard let url = Bundle.cinemaResources.url(forResource: key, withExtension: "mp4") else {
      return nil
    }
    return Film(
      url: url, title: title, group: "Études de mouvement", source: "Éditions Trame", artwork: key,
      kind: .movies)
  }

  // A resource name stays stable when the application moves.
  var libraryKey: String {
    artwork.map { "edition/" + $0 } ?? Self.mediaKey(for: url.absoluteString)
  }

  static func mediaKey(for address: String) -> String {
    "media/" + Data(SHA256.hash(data: Data(address.utf8))).base64EncodedString()
  }
}
