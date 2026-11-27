import CryptoKit
import Darwin
import Foundation

public struct CatalogValidators: Codable, Equatable, Sendable {
  let list: HTTPValidator?
  let categories: HTTPValidator?

  init?(list: HTTPValidator?, categories: HTTPValidator? = nil) {
    guard list != nil || categories != nil else { return nil }
    self.list = list
    self.categories = categories
  }
}

struct HTTPValidator: Codable, Equatable, Sendable {
  let etag: String?
  let modified: String?
  let digest: Data?

  init(headers: HTTPURLResponse?, digest: Data?, previous: HTTPValidator? = nil) {
    etag = headers?.value(forHTTPHeaderField: "ETag") ?? previous?.etag
    modified = headers?.value(forHTTPHeaderField: "Last-Modified") ?? previous?.modified
    self.digest = digest
  }

}

struct CatalogBody: Sendable {
  // Keep a downloaded body available even when identical: the other Xtream endpoint may change.
  let data: Data?
  let origin: URL
  let validator: HTTPValidator

  static func content(_ data: Data, origin: URL, headers: HTTPURLResponse? = nil) -> Self {
    var hash = SHA256()
    // Relative channel addresses depend on the final URL after redirects.
    hash.update(data: Data(origin.absoluteString.utf8))
    hash.update(data: [UInt8(0)])
    hash.update(data: data)
    let validator = HTTPValidator(headers: headers, digest: Data(hash.finalize()))
    return Self(data: data, origin: origin, validator: validator)
  }

  func isUnchanged(since previous: HTTPValidator?) -> Bool {
    data == nil || (validator.digest != nil && validator.digest == previous?.digest)
  }
}

private typealias CatalogTransfer = (data: Data, response: HTTPURLResponse)

public typealias CatalogUpdate = (catalog: Catalog?, validators: CatalogValidators?)

public enum CatalogLoader {
  static let byteLimit = 2 * 1024 * 1024 * 1024
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 30
    return URLSession(configuration: configuration)
  }()

  public static func refresh(_ url: URL, name: String, validators: CatalogValidators?) async throws
    -> CatalogUpdate
  {
    try await refresh(url, name: name, validators: validators, session: session, limit: byteLimit)
  }

  public static func posterData(at url: URL) async throws -> Data {
    guard webAddress(url) else { throw ImportError.invalidAddress }
    let body = try await fetch(url, validator: nil, session: session, limit: 4 * 1024 * 1024)
    guard let data = body.data else { throw ImportError.invalidResponse }
    return data
  }

  public static func episodes(at url: URL) async throws -> [Episode] {
    guard webAddress(url) else { throw ImportError.invalidAddress }
    let body = try await fetch(url, validator: nil, session: session, limit: byteLimit)
    guard let data = body.data else { throw ImportError.invalidResponse }
    return try XtreamSource.episodes(data, at: url)
  }

  static func refresh(
    _ url: URL, name: String, validators: CatalogValidators? = nil, session: URLSession, limit: Int
  ) async throws -> CatalogUpdate {
    try Task.checkCancellation()
    let result: CatalogBody
    if url.isFileURL {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      guard try handle.seekToEnd() <= UInt64(limit) else { throw ImportError.tooLarge }
      try handle.seek(toOffset: 0)
      var buffer = CatalogBuffer(limit: limit)
      while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
        try Task.checkCancellation()
        try buffer.append(chunk)
      }
      result = try .content(buffer.contents(), origin: url)
    } else {
      guard webAddress(url) else { throw ImportError.invalidAddress }
      if url.lastPathComponent.lowercased() == "player_api.php" {
        return try await XtreamSource(url).refresh(
          name: name, validators: validators, session: session, limit: limit)
      }
      result = try await fetch(url, validator: validators?.list, session: session, limit: limit)
    }
    if result.isUnchanged(since: validators?.list) {
      return (nil, CatalogValidators(list: result.validator))
    }
    let catalog = try result.data.map {
      try PlaylistParser.parse($0, origin: result.origin, name: name)
    }
    return (catalog, CatalogValidators(list: result.validator))
  }

  static func fetch(_ url: URL, validator: HTTPValidator?, session: URLSession, limit: Int)
    async throws -> CatalogBody
  {
    let (results, continuation) = AsyncThrowingStream<CatalogTransfer, Error>.makeStream()
    let receiver = CatalogResponse(limit: limit, result: continuation)
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.setValue(validator?.etag, forHTTPHeaderField: "If-None-Match")
    request.setValue(validator?.modified, forHTTPHeaderField: "If-Modified-Since")
    let task = session.dataTask(with: request)
    task.delegate = receiver
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      task.resume()
      defer { withExtendedLifetime(receiver) {} }
      do {
        for try await result in results {
          try Task.checkCancellation()
          let http = result.response
          guard let origin = http.url else { throw ImportError.network }
          if http.statusCode == 304 {
            let current = task.currentRequest
            let sentCondition =
              current?.value(forHTTPHeaderField: "If-None-Match")?.isEmpty == false
              || current?.value(forHTTPHeaderField: "If-Modified-Since")?.isEmpty == false
            guard let validator, sentCondition, origin == url else {
              throw ImportError.httpStatus(304)
            }
            return CatalogBody(
              data: nil, origin: origin,
              validator: HTTPValidator(headers: http, digest: validator.digest, previous: validator)
            )
          }
          // A redirect target must supply its own validators on each refresh.
          return .content(result.data, origin: origin, headers: origin == url ? http : nil)
        }
        throw ImportError.network
      } catch {
        // A cancelled URLSession task may finish before the stream observes task cancellation.
        try Task.checkCancellation()
        throw error
      }
    } onCancel: {
      task.cancel()
    }
  }
}

// Small lists stay in memory. Spill larger ones to an anonymous file so Rust can
// borrow a contiguous mapping without requiring a second multi-gigabyte buffer.
private struct CatalogBuffer {
  let limit: Int
  private var memory = Data()
  private var count = 0
  private var file: FileHandle?

  init(limit: Int) { self.limit = limit }

  mutating func append(_ chunk: Data) throws {
    guard chunk.count <= limit - count else { throw ImportError.tooLarge }
    let nextCount = count + chunk.count
    if file == nil, nextCount > 4 * 1024 * 1024 {
      guard let temporary = tmpfile() else { throw ImportError.temporaryStorage }
      let descriptor = dup(fileno(temporary))
      fclose(temporary)
      guard descriptor >= 0 else { throw ImportError.temporaryStorage }
      let temporaryFile = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      do { try temporaryFile.write(contentsOf: memory) } catch {
        throw ImportError.temporaryStorage
      }
      file = temporaryFile
      memory = Data()
    }
    if let file {
      do { try file.write(contentsOf: chunk) } catch { throw ImportError.temporaryStorage }
    } else {
      memory.append(chunk)
    }
    count = nextCount
  }

  func contents() throws -> Data {
    guard let file else { return memory }
    guard let bytes = mmap(nil, count, PROT_READ, MAP_PRIVATE, file.fileDescriptor, 0),
      bytes != MAP_FAILED
    else { throw ImportError.temporaryStorage }
    return Data(bytesNoCopy: bytes, count: count, deallocator: .unmap)
  }
}

// URLSession serializes delegate callbacks. Each transfer owns its buffer, and enforces the
// limit on decoded chunks as well as the advertised size (which can be missing or compressed).
private final class CatalogResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let limit: Int
  let result: AsyncThrowingStream<CatalogTransfer, Error>.Continuation
  private var buffer: CatalogBuffer

  init(
    limit: Int,
    result: AsyncThrowingStream<CatalogTransfer, Error>.Continuation
  ) {
    self.limit = limit
    self.result = result
    buffer = CatalogBuffer(limit: limit)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    var redirected = request
    redirected.setValue(nil, forHTTPHeaderField: "If-None-Match")
    redirected.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
    completionHandler(redirected)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    if let http = response as? HTTPURLResponse, http.statusCode == 304 {
      result.yield((Data(), http))
      result.finish()
      completionHandler(.cancel)
    } else if let http = response as? HTTPURLResponse,
      http.statusCode == 206 || !(200..<300).contains(http.statusCode)
    {
      result.finish(throwing: ImportError.httpStatus(http.statusCode))
      completionHandler(.cancel)
    } else if response.expectedContentLength > Int64(limit) {
      result.finish(throwing: ImportError.tooLarge)
      completionHandler(.cancel)
    } else {
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    do {
      try buffer.append(chunk)
    } catch {
      result.finish(throwing: error)
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    if let error = error as? URLError {
      result.finish(throwing: ImportError.transport(error.code))
    } else if error != nil {
      result.finish(throwing: ImportError.network)
    } else if let http = task.response as? HTTPURLResponse {
      do {
        result.yield((try buffer.contents(), http))
      } catch {
        result.finish(throwing: error)
        return
      }
      result.finish()
    } else {
      result.finish(throwing: ImportError.network)
    }
  }
}
