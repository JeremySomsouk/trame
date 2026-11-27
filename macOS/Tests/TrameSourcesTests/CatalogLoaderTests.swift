import Foundation
import Testing
import os

@testable import TrameSources

private final class CatalogProtocol: URLProtocol, @unchecked Sendable {
  static let requests = OSAllocatedUnfairLock(initialState: [URL: Int]())

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let action = items.first { $0.name == "action" }?.value
    var status = 200
    var headers: [String: String] = [:]
    var body: String
    switch (url.host, action) {
    case ("transport.test", _):
      let code = URLError.Code(rawValue: Int(url.lastPathComponent) ?? 0)
      client?.urlProtocol(self, didFailWithError: URLError(code ?? .unknown))
      return
    case ("sections.test", "get_vod_streams"), ("large.test", "get_vod_streams"):
      body = #"[{"stream_id":7,"name":"Film","container_extension":"mkv"}]"#
    case ("sections.test", "get_series"), ("large.test", "get_series"):
      body = #"[{"series_id":8,"name":"Series"}]"#
    case ("sections.test", _), ("large.test", _): body = "[]"
    case ("denied.test", _):
      status = 401
      body = "Unauthorized"
    case ("partial.test", _):
      status = 206
      body = "#EXTM3U\nstream.m3u8\n"
    case ("length.test", _):
      headers = ["Content-Length": "1000000"]
      body = ""
    case ("chunked.test", _):
      body = String(repeating: "a", count: 100)
    case ("cancel.test", _):
      return  // Wait for cancellation.
    case ("no-groups.test", "get_live_categories"):
      status = 404
      body = ""
    case (_, "get_live_categories"):
      body = #"[{"category_id":4,"category_name":"Cinéma"}]"#
    case (_, "get_live_streams"):
      body =
        #"[{"stream_id":21,"name":"Orbite","category_id":"4"},null,{},{"stream_id":"21"},{"stream_id":"../../elsewhere"},{"stream_id":"22"}]"#
    default:
      body = "#EXTM3U\n#EXTINF:-1,Canal\nstream.m3u8"
    }
    if url.host == "validated.test" {
      let tag = "\"" + (action ?? "playlist") + "\""
      headers["ETag"] = tag
      headers["Last-Modified"] = "Mon, 01 Jan 2024 00:00:00 GMT"
      if request.value(forHTTPHeaderField: "If-None-Match") == tag
        && request.value(forHTTPHeaderField: "If-Modified-Since") == headers["Last-Modified"]
      {
        status = 304
        body = ""
      }
    } else if url.host == "unsolicited.test" {
      status = 304
      body = ""
    }
    var origin = url
    if url.host == "changing.test" || url.host == "redirect.test" {
      let count = Self.requests.withLock { requests in
        requests[url, default: 0] += 1
        return requests[url, default: 0]
      }
      if count > 1 && action == "get_live_categories" {
        body = #"[{"category_id":4,"category_name":"Sports"}]"#
      }
      if url.host == "redirect.test" {
        origin = url.deletingLastPathComponent().appending(path: "cdn-\(count)/list.m3u")
      }
    }
    let response = HTTPURLResponse(
      url: origin, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if url.host == "large.test" && ["get_vod_streams", "get_series"].contains(action) {
      let padding = Data(repeating: 0x20, count: 1024 * 1024)
      for _ in 0..<64 { client?.urlProtocol(self, didLoad: padding) }
    }
    let bytes = Data(body.utf8)
    let split = bytes.count / 2
    client?.urlProtocol(self, didLoad: bytes.prefix(split))
    client?.urlProtocol(self, didLoad: bytes.suffix(from: split))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func fixtureSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [CatalogProtocol.self]
  return URLSession(configuration: config)
}

@Test func xtreamReadsBothListsAndEncodesCredentialsPerSegment() async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try XtreamSource.apiURL(
    server: #require(URL(string: "https://stream.test/proxy%20tv")), username: "a+b&é",
    password: "p/a?#"
  )
  #expect(url.absoluteString.contains("a%2Bb%26%C3%A9"))
  let catalog = try await CatalogLoader.refresh(url, name: "Direct", session: session, limit: 1024)
  #expect(catalog.catalog?.channels.map(\.name) == ["Orbite", "Chaîne 22"])
  #expect(catalog.catalog?.groups == ["Cinéma"])
  #expect(
    catalog.catalog?.channels[0].url.absoluteString
      == "https://stream.test/proxy%20tv/live/a%2Bb%26%C3%A9/p%2Fa%3F%23/21.m3u8")
}

@Test func pastedXtreamLoginUsesFormQueryEncoding() async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(
    URL(string: "https://stream.test/player_api.php?username=a+b&password=c%2Bd"))
  let result = try await CatalogLoader.refresh(url, name: "", session: session, limit: 1024)
  #expect(
    result.catalog?.channels.first?.url.absoluteString
      == "https://stream.test/live/a%20b/c%2Bd/21.m3u8")
}

@Test func partialHTTPResponseCannotReplaceCompleteCatalog() async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(URL(string: "https://partial.test/list.m3u"))
  await #expect(throws: ImportError.httpStatus(206)) {
    try await CatalogLoader.refresh(url, name: "", session: session, limit: 1024)
  }
}

@Test func missingOptionalCategoryEndpointKeepsChannels() async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(URL(string: "https://no-groups.test/player_api.php?username=u&password=p"))
  let catalog = try await CatalogLoader.refresh(url, name: "Direct", session: session, limit: 1024)
  #expect(catalog.catalog?.channels.count == 2)
  #expect(catalog.catalog?.groups.isEmpty == true)
}

@Test(arguments: ["chunked.test", "length.test"]) func responseSizeIsBounded(host: String)
  async throws
{
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(URL(string: "https://" + host))
  await #expect(throws: ImportError.tooLarge) {
    try await CatalogLoader.refresh(url, name: "", session: session, limit: 60)
  }
}

@Test func httpErrorsSurviveTransportCancellation() async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(URL(string: "https://denied.test"))
  await #expect(throws: ImportError.httpStatus(401)) {
    try await CatalogLoader.refresh(url, name: "", session: session, limit: 100)
  }
}

@Test(arguments: [
  URLError.Code.appTransportSecurityRequiresSecureConnection, .cannotFindHost,
  .cannotConnectToHost, .timedOut, .serverCertificateUntrusted, .notConnectedToInternet,
])
func catalogReportsTransportFailureWithoutEchoingAddress(code: URLError.Code) async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(URL(string: "https://transport.test"))
    .appending(path: String(code.rawValue))
    .appending(queryItems: [URLQueryItem(name: "ticket", value: "fixture-marker")])
  let expected = ImportError.transport(code)
  await #expect(throws: expected) {
    try await CatalogLoader.refresh(url, name: "", session: session, limit: 100)
  }
  #expect(expected.localizedDescription != ImportError.network.localizedDescription)
  #expect(!expected.localizedDescription.contains("fixture-marker"))
}

@Test func cancellingAnUnresponsiveTransferReturnsPromptly() async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(URL(string: "https://cancel.test"))
  let task = Task { try await CatalogLoader.refresh(url, name: "", session: session, limit: 100) }
  try await Task.sleep(for: .milliseconds(20))
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
}

@Test(arguments: ["list.m3u", "player_api.php?username=u&password=p"])
func conditionalRefreshSkipsAnUnchangedCatalog(path: String) async throws {
  let url = try #require(URL(string: "https://validated.test/" + path))
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let initial = try await CatalogLoader.refresh(url, name: "", session: session, limit: 1024)
  #expect(initial.catalog != nil)
  let validators = try #require(initial.validators)
  let next = try await CatalogLoader.refresh(
    url, name: "", validators: validators, session: session, limit: 1024)
  #expect(next.catalog == nil)
  #expect(next.validators == initial.validators)
}

@Test func partialXtreamChangeRejoinsBothLists() async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(URL(string: "https://validated.test/player_api.php?username=u&password=p"))
  let initial = try await CatalogLoader.refresh(url, name: "", session: session, limit: 1024)
  let validators = try #require(initial.validators)
  for partial in [
    CatalogValidators(list: validators.list),
    CatalogValidators(list: nil, categories: validators.categories),
  ] {
    let next = try await CatalogLoader.refresh(
      url, name: "", validators: partial, session: session, limit: 1024)
    #expect(next.catalog?.groups == ["Cinéma"])
    #expect(next.catalog?.channels.count == 2)
    #expect(next.validators == validators)
  }
}

@Test func unsolicitedNotModifiedIsRejected() async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(URL(string: "https://unsolicited.test/list.m3u"))
  await #expect(throws: ImportError.httpStatus(304)) {
    try await CatalogLoader.refresh(url, name: "", session: session, limit: 1024)
  }
}

@Test(arguments: [
  "https://plain.test/list.m3u",
  "https://plain.test/player_api.php?username=u&password=p",
  "https://no-groups.test/player_api.php?username=u&password=p",
])
func unversionedSourcesSkipUnchangedBodies(address: String) async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(URL(string: address))
  let first = try await CatalogLoader.refresh(url, name: "", session: session, limit: 1024)
  let saved = try JSONEncoder().encode(#require(first.validators))
  let validators = try JSONDecoder().decode(CatalogValidators.self, from: saved)
  #expect(validators.list?.etag == nil && validators.list?.modified == nil)
  #expect(validators.list?.digest?.count == 32)
  let next = try await CatalogLoader.refresh(
    url, name: "", validators: validators, session: session, limit: 1024)
  #expect(next.catalog == nil)
  #expect(next.validators == first.validators)
}

@Test func changedUnversionedGroupsUseDownloadedChannelsWithoutAnotherRequest() async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(URL(string: "https://changing.test/player_api.php?username=u&password=p"))
  let first = try await CatalogLoader.refresh(url, name: "", session: session, limit: 1024)
  #expect(first.catalog?.groups == ["Cinéma"])
  let next = try await CatalogLoader.refresh(
    url, name: "", validators: first.validators, session: session, limit: 1024)
  #expect(next.catalog?.groups == ["Sports"])
  #expect(next.catalog?.channels.count == 2)
  let counts = CatalogProtocol.requests.withLock { requests in
    requests.filter { $0.key.host == "changing.test" }.values.sorted()
  }
  #expect(counts == [2, 2])
}

@Test func aNewResolvedOriginChangesRelativeStreamsEvenWithIdenticalBytes() async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(URL(string: "https://redirect.test/list.m3u"))
  let first = try await CatalogLoader.refresh(url, name: "", session: session, limit: 1024)
  let next = try await CatalogLoader.refresh(
    url, name: "", validators: first.validators, session: session, limit: 1024)
  #expect(first.catalog?.channels.first?.url.path == "/cdn-1/stream.m3u8")
  #expect(next.catalog?.channels.first?.url.path == "/cdn-2/stream.m3u8")
}

@Test func bodyFingerprintDoesNotAuthorizeAnUnsolicited304() async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let url = try #require(URL(string: "https://unsolicited.test/list.m3u"))
  let validator = CatalogBody.content(Data("old body".utf8), origin: url).validator
  await #expect(throws: ImportError.httpStatus(304)) {
    try await CatalogLoader.refresh(
      url, name: "", validators: CatalogValidators(list: validator), session: session, limit: 1024)
  }
}

@Test func oldETagsRemainUsableWithoutStoredFingerprints() throws {
  let saved = Data(#"{"list":{"etag":"old"}}"#.utf8)
  let validators = try JSONDecoder().decode(CatalogValidators.self, from: saved)
  #expect(validators.list?.etag == "old")
  #expect(validators.list?.digest == nil)
}

@Test(arguments: [XtreamSection.movies, .series])
func storedSectionLoadsTypedMedia(section: XtreamSection) async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let server = try #require(URL(string: "https://sections.test/panel"))
  let login = try XtreamSource.apiURL(
    server: server, username: "fixture", password: "fixture", section: section)
  let result = try await CatalogLoader.refresh(login, name: "", session: session, limit: 2048)
  let item = try #require(result.catalog?.channels.first)
  #expect(item.opensEpisodes == (section == .series))
  if item.opensEpisodes {
    let rows = try XtreamSource.episodes(
      Data(#"{"episodes":{"1":[{"id":"18","title":"Pilot"}]}}"#.utf8), at: item.url)
    #expect(rows.map(\.name) == ["Pilot"])
    #expect(rows.first?.url.lastPathComponent == "18.mp4")
  } else {
    #expect(item.url.lastPathComponent == "7.mkv")
  }
}

@Test(arguments: [XtreamSection.movies, .series])
func importsXtreamListsBeyond64MiB(section: XtreamSection) async throws {
  let session = fixtureSession()
  defer { session.invalidateAndCancel() }
  let server = try #require(URL(string: "https://large.test"))
  let url = try XtreamSource.apiURL(server: server, username: "u", password: "p", section: section)
  let result = try await CatalogLoader.refresh(
    url, name: "", session: session, limit: CatalogLoader.byteLimit)
  #expect(result.catalog?.channels.map(\.name) == [section == .movies ? "Film" : "Series"])
}

@Test func localPlaylistEnforcesTwoGiBLimitBeforeReading() async throws {
  let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".m3u")
  try Data().write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  let file = try FileHandle(forWritingTo: url)
  try file.truncate(atOffset: 2 * 1024 * 1024 * 1024 + 1)
  try file.close()
  #expect(CatalogLoader.byteLimit == 2 * 1024 * 1024 * 1024)
  await #expect(throws: ImportError.tooLarge) {
    try await CatalogLoader.refresh(url, name: "", validators: nil)
  }
}
