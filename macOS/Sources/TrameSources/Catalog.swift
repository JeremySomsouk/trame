import CTrameCore
import Foundation

public enum MediaKind: String, CaseIterable, Codable, Sendable {
  case live, movies, series

  public static func inferred(from url: URL) -> Self? {
    switch trame_media_kind(url.absoluteString) {
    case 1: .live
    case 2: .movies
    case 3: .series
    default: nil
    }
  }
}

public struct Channel: Identifiable, Sendable {
  public let id: Int
  public let posterUrl: URL?
  public let kind: MediaKind
  public let opensEpisodes: Bool
  public let name: String
  public let group: String
  public let url: URL
}

public struct Catalog: Sendable, Decodable {
  private struct Item: Decodable {
    let name: String
    let group: String
    let url: URL
    let posterUrl: URL?
    let kind: MediaKind
    let opensEpisodes: Bool
  }
  private enum CodingKeys: String, CodingKey { case name, items }

  init(name: String, channels: [Channel]) {
    self.name = name
    self.channels = channels
  }

  public init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    name = try fields.decode(String.self, forKey: .name)
    var items = try fields.nestedUnkeyedContainer(forKey: .items)
    var result: [Channel] = []
    result.reserveCapacity(items.count ?? 0)
    while !items.isAtEnd {
      if result.count.isMultiple(of: 256) { try Task.checkCancellation() }
      let item = try items.decode(Item.self)
      result.append(
        Channel(
          id: result.count, posterUrl: item.posterUrl, kind: item.kind,
          opensEpisodes: item.opensEpisodes,
          name: item.name, group: item.group, url: item.url))
    }
    channels = result
  }

  public let name: String
  public let channels: [Channel]

  public var groups: [String] {
    Set(channels.lazy.map(\.group)).filter { !$0.isEmpty }.sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
  }
}

public enum ImportError: LocalizedError, Equatable {
  case invalidAddress, invalidPlaylist, emptyPlaylist, tooLarge, temporaryStorage, invalidResponse,
    network
  case transport(URLError.Code)
  case httpStatus(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidAddress: "Saisissez une adresse HTTP ou HTTPS valide."
    case .invalidPlaylist: "Le fichier reçu ne ressemble pas à une liste M3U."
    case .emptyPlaylist: "Cette source ne contient aucune chaîne lisible."
    case .tooLarge: "La liste dépasse 2 Go. Importez une liste plus petite."
    case .temporaryStorage:
      "Impossible de lire le catalogue temporaire. Vérifiez l’espace disque disponible."
    case .invalidResponse: "Réponse Xtream inattendue. Vérifiez le serveur et les identifiants."
    case .transport(.appTransportSecurityRequiresSecureConnection):
      "macOS a bloqué la connexion HTTP à cette source ou à une adresse de redirection."
    case .transport(.cannotFindHost), .transport(.dnsLookupFailed):
      "Le nom du serveur est introuvable. Vérifiez son adresse."
    case .transport(.cannotConnectToHost):
      "Connexion au serveur impossible. Vérifiez le port et la disponibilité du service."
    case .transport(.timedOut): "Le serveur n’a pas répondu à temps. Réessayez plus tard."
    case .transport(.notConnectedToInternet): "Le Mac est hors ligne. Vérifiez la connexion réseau."
    case .transport(.secureConnectionFailed), .transport(.serverCertificateHasBadDate),
      .transport(.serverCertificateUntrusted), .transport(.serverCertificateHasUnknownRoot),
      .transport(.serverCertificateNotYetValid):
      "La connexion sécurisée a échoué. Vérifiez l’adresse HTTPS et le certificat du serveur."
    case .transport, .network:
      "Impossible de joindre la source. Vérifiez l’adresse et la connexion."
    case .httpStatus(let status) where status == 401 || status == 403:
      "Le serveur a refusé l’accès (HTTP \(status)). Vérifiez les droits du compte ou de la source."
    case .httpStatus(let status): "Le serveur a répondu avec le code HTTP \(status)."
    }
  }
}

public enum PlaylistParser {
  public static func parse(_ data: Data, origin: URL, name: String) throws -> Catalog {
    try Task.checkCancellation()
    let catalog: Catalog = try data.withUnsafeBytes { bytes in
      try decodeCoreResponse(
        trame_parse_playlist(
          bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
          origin.absoluteString, name)
      )
    }
    try Task.checkCancellation()
    return catalog
  }
}

func decodeCoreResponse<Value: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?) throws -> Value {
  guard let pointer else { throw ImportError.invalidResponse }
  let data = Data(
    bytesNoCopy: pointer, count: strlen(pointer),
    deallocator: .custom { memory, _ in
      trame_free(memory.assumingMemoryBound(to: CChar.self))
    })
  let response = try JSONDecoder().decode(CoreResponse<Value>.self, from: data)
  if let value = response.value { return value }
  switch response.error {
  case .invalidAddress: throw ImportError.invalidAddress
  case .invalidPlaylist: throw ImportError.invalidPlaylist
  case .emptyPlaylist: throw ImportError.emptyPlaylist
  case .invalidResponse: throw ImportError.invalidResponse
  case .localHls: throw ImportError.invalidPlaylist
  case nil: throw ImportError.invalidResponse
  }
}

private struct CoreResponse<Value: Decodable>: Decodable {
  enum Code: String, Decodable {
    case invalidAddress, invalidPlaylist, emptyPlaylist, invalidResponse, localHls
  }

  enum CodingKeys: String, CodingKey {
    case value = "Ok"
    case error = "Err"
  }

  let value: Value?
  let error: Code?
}

func webAddress(_ url: URL) -> Bool {
  guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
    return false
  }
  return url.host?.isEmpty == false
}
