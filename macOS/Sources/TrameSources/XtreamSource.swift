import CTrameCore
import Foundation

public typealias XtreamSection = MediaKind

public struct Episode: Identifiable, Decodable, Sendable {
  public var id: URL { url }
  public let name: String
  public let season: UInt
  public let url: URL
}

public struct XtreamSource: Sendable {
  private struct Endpoints: Decodable, Sendable {
    let streams, categories: URL
    let section: XtreamSection
  }
  private let login: URL
  private let endpoints: Endpoints

  public static func apiURL(
    server: URL, username: String, password: String,
    section: XtreamSection = .live
  ) throws -> URL {
    guard !username.utf8.contains(0), !password.utf8.contains(0) else {
      throw ImportError.invalidAddress
    }
    return try decodeCoreResponse(
      trame_xtream_login(server.absoluteString, username, password, section.rawValue))
  }
  public var section: XtreamSection { endpoints.section }

  public init(_ url: URL) throws {
    login = url
    endpoints = try decodeCoreResponse(trame_xtream_endpoints(url.absoluteString))
  }
  private func fetch(_ url: URL, validator: HTTPValidator?, session: URLSession, limit: Int)
    async throws -> CatalogBody
  {
    do {
      return try await CatalogLoader.fetch(
        url, validator: validator, session: session, limit: limit)
    } catch ImportError.httpStatus(let status)
      where url == endpoints.categories && [404, 405].contains(status)
    {
      return .content(Data("[]".utf8), origin: url)
    }
  }
  func refresh(name: String, validators: CatalogValidators?, session: URLSession, limit: Int)
    async throws -> CatalogUpdate
  {
    async let groupsRequest = fetch(
      endpoints.categories, validator: validators?.categories, session: session, limit: limit)
    var streams = try await fetch(
      endpoints.streams, validator: validators?.list, session: session, limit: limit)
    var groups = try await groupsRequest
    if streams.isUnchanged(since: validators?.list)
      && groups.isUnchanged(since: validators?.categories)
    {
      return (nil, CatalogValidators(list: streams.validator, categories: groups.validator))
    }
    // A changed group can affect every channel. Rebuild the pair from fresh or validated
    // responses without retaining a second copy of a potentially very large provider list.
    if streams.data == nil {
      streams = try await fetch(endpoints.streams, validator: nil, session: session, limit: limit)
    }
    if groups.data == nil {
      groups = try await fetch(
        endpoints.categories, validator: nil, session: session, limit: limit)
    }
    guard let streamData = streams.data, let groupData = groups.data else {
      throw ImportError.invalidResponse
    }
    let catalog: Catalog = try streamData.withUnsafeBytes { streams in
      try groupData.withUnsafeBytes { groups in
        try decodeCoreResponse(
          trame_xtream_catalog(
            login.absoluteString,
            streams.bindMemory(to: UInt8.self).baseAddress, streams.count,
            groups.bindMemory(to: UInt8.self).baseAddress, groups.count))
      }
    }
    return (
      Catalog(name: name, channels: catalog.channels),
      CatalogValidators(list: streams.validator, categories: groups.validator)
    )
  }

  static func episodes(_ data: Data, at url: URL) throws -> [Episode] {
    try data.withUnsafeBytes { bytes in
      try decodeCoreResponse(
        trame_xtream_episodes(
          url.absoluteString, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count))
    }
  }
}
