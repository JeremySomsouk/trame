import AppKit
import Foundation
import TrameSources

struct LibrarySourceInfo: Identifiable, Sendable {
  let id: URL
  let name: String
  let count: Int
  let validators: CatalogValidators?
}

struct LibraryActivity: Codable, Equatable, Sendable {
  var favorites: Set<String> = []
  var recent: [String] = []
}

private struct SourceRecord: Codable {
  let origin: URL?
  var films: [Film]
  var excluded: Set<URL>?
  var validators: CatalogValidators?
  var legacy: Bool?
  var hasMediaMetadata: Bool?
}

private struct CatalogFile: Codable {
  var sources: [SourceRecord] = []
}

// A legacy library contained only flattened imports and had no playlist addresses.
private struct LegacyLibrary: Decodable {
  var imports: [Film]
  var favorites: Set<String>
  var recent: [String]
}

struct LibraryIndex: Sendable {
  var all: [Film] = []
  var byKey: [String: Int] = [:]
  var sources: [LibrarySourceInfo] = []

  func favorites(for keys: Set<String>) async throws -> [Film] {
    var offsets: [Int] = []
    offsets.reserveCapacity(min(keys.count, all.count))
    for (index, key) in keys.enumerated() {
      if index.isMultiple(of: 256) { try Task.checkCancellation() }
      if let offset = byKey[key] { offsets.append(offset) }
    }
    // Match library order even when multiple playlists share titles.
    offsets.sort()
    try Task.checkCancellation()
    return offsets.map { all[$0] }
  }

  func migrateActivity(_ saved: LibraryActivity) -> LibraryActivity {
    func resolve(_ key: String) -> String? {
      if byKey[key] != nil { return key }
      // Earlier versions used the complete media URL as the activity key.
      let migrated = Film.mediaKey(for: key)
      return byKey[migrated] == nil ? nil : migrated
    }
    return LibraryActivity(
      favorites: Set(saved.favorites.compactMap(resolve)), recent: saved.recent.compactMap(resolve))
  }

  static let editions = LibraryIndex(
    all: Film.editions,
    byKey: Dictionary(
      uniqueKeysWithValues: Film.editions.enumerated().map { ($0.element.libraryKey, $0.offset) }))
}

struct SourceUpdate: Sendable {
  let films: [Film]?
  let validators: CatalogValidators?
}

struct CatalogChange: Sendable {
  var index: LibraryIndex?
  var error: String?
}

// The serial queue owns all mutable store state and orders disk writes, including at quit.
final class LibraryStore: NSObject, @unchecked Sendable {
  private let queue = DispatchQueue(label: "Trame.library-storage", qos: .userInitiated)
  private let directory: URL
  private var catalog = CatalogFile()
  private var pendingActivity: LibraryActivity?
  private var catalogDirty = false
  private var canSave = true

  init(directory: URL) {
    self.directory = directory
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(willTerminate(_:)), name: NSApplication.willTerminateNotification,
      object: nil)
  }

  @objc private func willTerminate(_ notification: Notification) { queue.sync {} }

  func load(
    _ completion: @escaping @MainActor @Sendable (LibraryIndex, LibraryActivity, String?) -> Void
  ) {
    queue.async { [self] in
      var activity = LibraryActivity()
      var warning: String?
      do {
        if let data = try read("library.json") {
          let decoder = JSONDecoder()
          if let file = try? decoder.decode(CatalogFile.self, from: data) {
            catalog = file
          } else {
            let legacy = try decoder.decode(LegacyLibrary.self, from: data)
            catalog.sources = [SourceRecord(origin: nil, films: legacy.imports, legacy: true)]
            activity = LibraryActivity(favorites: legacy.favorites, recent: legacy.recent)
            catalogDirty = true
          }
        }
        if let data = try read("activity.json") {
          activity = try JSONDecoder().decode(LibraryActivity.self, from: data)
        }
      } catch {
        canSave = false
        warning =
          "La bibliothèque enregistrée est illisible. Vos modifications seront limitées à cette session."
      }
      let index = makeIndex()
      let migrated = index.migrateActivity(activity)
      if canSave && (catalogDirty || migrated != activity) {
        pendingActivity = migrated
        do { try writePendingChanges() } catch { warning = writeError }
      }
      activity = migrated
      DispatchQueue.main.async { [activity, warning] in completion(index, activity, warning) }
    }
  }

  private func read(_ name: String) throws -> Data? {
    do {
      return try Data(contentsOf: directory.appending(path: name), options: .mappedIfSafe)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
  }

  private func write(_ value: some Encodable, to name: String) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(value).write(to: directory.appending(path: name), options: .atomic)
  }

  private func writePendingChanges() throws {
    // On migration, persist activity before replacing the only combined copy.
    if let pendingActivity {
      try write(pendingActivity, to: "activity.json")
      self.pendingActivity = nil
    }
    if catalogDirty {
      try write(catalog, to: "library.json")
      catalogDirty = false
    }
  }

  private var writeError: String {
    "L’enregistrement a échoué. Vérifiez l’espace disque et les permissions."
  }

  func saveActivity(
    _ activity: LibraryActivity, onError: @escaping @MainActor @Sendable (String) -> Void
  ) {
    queue.async { [self] in
      guard canSave else { return }
      pendingActivity = activity
      do { try writePendingChanges() } catch {
        DispatchQueue.main.async { onError(self.writeError) }
      }
    }
  }

  private func makeIndex() -> LibraryIndex {
    var index = LibraryIndex()
    let capacity = catalog.sources.reduce(Film.editions.count) { $0 + $1.films.count }
    index.all.reserveCapacity(capacity)
    index.byKey.reserveCapacity(capacity)
    let editionURLs = Set(Film.editions.map(\.url))
    for record in catalog.sources {
      let section = record.origin.flatMap { url in
        url.lastPathComponent.lowercased() == "player_api.php"
          ? (try? XtreamSource(url))?.section : nil
      }
      for var film in record.films {
        if record.hasMediaMetadata != true && !film.group.isEmpty {
          film.group = film.group.replacingOccurrences(of: " | ", with: " › ")
            .replacingOccurrences(of: " / ", with: " › ").replacingOccurrences(
              of: " > ", with: " › ")
        }
        if film.kind == nil {
          if let section {
            film.kind = section
          } else if film.opensEpisodes == true {
            film.kind = .series
          } else if record.origin != nil || record.legacy == true {
            film.kind = MediaKind.inferred(from: film.url)
          } else {
            film.kind = Importer.standaloneKind(film.url)
          }
        }
        let key = film.libraryKey
        guard index.byKey[key] == nil, !editionURLs.contains(film.url) else { continue }
        index.byKey[key] = index.all.count
        index.all.append(film)
      }
      if let url = record.origin {
        // Older imports discarded types and poster URLs. Reparse on their next refresh.
        index.sources.append(
          LibrarySourceInfo(
            id: url, name: url.isFileURL ? url.lastPathComponent : Importer.sourceName(url),
            count: record.films.count,
            validators: record.hasMediaMetadata == true ? record.validators : nil))
      }
    }
    for film in Film.editions {
      index.byKey[film.libraryKey] = index.all.count
      index.all.append(film)
    }
    return index
  }

  private typealias Mutation = @Sendable (inout CatalogFile) -> Bool
  typealias Completion = @MainActor @Sendable (CatalogChange) -> Void

  private func change(_ mutate: @escaping Mutation, then completion: @escaping Completion) {
    queue.async { [self] in
      let changed = mutate(&catalog)
      if changed { catalogDirty = true }
      guard changed || ((catalogDirty || pendingActivity != nil) && canSave) else {
        DispatchQueue.main.async { completion(CatalogChange()) }
        return
      }
      let index = changed ? makeIndex() : nil
      var warning: String?
      if canSave {
        do {
          try writePendingChanges()
        } catch {
          warning = writeError
        }
      }
      DispatchQueue.main.async { [warning] in
        completion(CatalogChange(index: index, error: warning))
      }
    }
  }

  struct Import: Sendable {
    let films: [Film]
    let origin: URL?
    let validators: CatalogValidators?
  }

  func add(_ imports: [Import], then completion: @escaping Completion) {
    change(
      { catalog in
        var changed = false
        for source in imports.reversed() {
          if Self.add(source, to: &catalog) { changed = true }
        }
        return changed
      }, then: completion)
  }

  private static func add(_ source: Import, to catalog: inout CatalogFile) -> Bool {
    let (films, origin, validators) = (source.films, source.origin, source.validators)
    if let origin, let index = catalog.sources.firstIndex(where: { $0.origin == origin }) {
      return Self.replace(
        &catalog.sources[index], update: SourceUpdate(films: films, validators: validators))
    }
    if origin == nil, let film = films.first,
      catalog.sources.contains(where: { $0.films.contains(where: { $0.id == film.id }) })
    {
      return false
    }
    if origin != nil, let i = catalog.sources.firstIndex(where: { $0.legacy == true }) {
      // Old versions saved only the display source. Adopt matching channels only
      // when the user adds their playlist again.
      let channelSources = Dictionary(
        films.lazy.map { ($0.url, $0.source) }, uniquingKeysWith: { a, _ in a })
      catalog.sources[i].films.removeAll { channelSources[$0.url] == $0.source }
      if catalog.sources[i].films.isEmpty { catalog.sources.remove(at: i) }
    }
    catalog.sources.insert(
      SourceRecord(origin: origin, films: films, validators: validators, hasMediaMetadata: true),
      at: 0)
    return true
  }

  private static func replace(_ record: inout SourceRecord, update: SourceUpdate) -> Bool {
    let headersChanged = update.validators != record.validators
    record.validators = update.validators
    guard let films = update.films else { return headersChanged }
    let metadataChanged = record.hasMediaMetadata != true
    record.hasMediaMetadata = true
    let visible =
      record.excluded.map { excluded in films.filter { !excluded.contains($0.url) } } ?? films
    guard visible != record.films else { return headersChanged || metadataChanged }
    record.films = visible
    return true
  }

  func refresh(_ updates: [URL: SourceUpdate], then completion: @escaping Completion) {
    change(
      { catalog in
        var changed = false
        for i in catalog.sources.indices {
          guard let origin = catalog.sources[i].origin, let update = updates[origin] else {
            continue
          }
          if Self.replace(&catalog.sources[i], update: update) { changed = true }
        }
        return changed
      }, then: completion)
  }

  func remove(_ film: Film, then completion: @escaping Completion) {
    change(
      { catalog in
        var changed = false
        for i in catalog.sources.indices {
          guard let match = catalog.sources[i].films.firstIndex(where: { $0.id == film.id }) else {
            continue
          }
          catalog.sources[i].films.remove(at: match)
          if catalog.sources[i].origin != nil {
            if catalog.sources[i].excluded == nil { catalog.sources[i].excluded = [] }
            catalog.sources[i].excluded?.insert(film.url)
          }
          changed = true
        }
        if changed { catalog.sources.removeAll { $0.origin == nil && $0.films.isEmpty } }
        return changed
      }, then: completion)
  }

  func removeSource(_ origin: URL, then completion: @escaping Completion) {
    change(
      { catalog in
        guard let i = catalog.sources.firstIndex(where: { $0.origin == origin }) else {
          return false
        }
        catalog.sources.remove(at: i)
        return true
      }, then: completion)
  }
}
