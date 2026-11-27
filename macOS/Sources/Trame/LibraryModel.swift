import Combine
import Foundation
import TrameSources

@MainActor
final class Library: ObservableObject {
  @Published var notice: String?
  @Published private(set) var ready = false
  @Published private(set) var importStatus: String?
  var importing: Bool { importStatus != nil }
  @Published private(set) var committing = false
  @Published private(set) var syncing = false
  @Published private(set) var syncStatus: String?
  @Published private(set) var catalogRevision = 0
  @Published private(set) var favoritesRevision = 0
  @Published private(set) var recentRevision = 0
  private let store: LibraryStore
  private var index = LibraryIndex.editions
  private var activity = LibraryActivity()
  private var importTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?

  init(directory: URL = URL.applicationSupportDirectory.appending(path: "Trame")) {
    store = LibraryStore(directory: directory)
    store.load { [weak self] index, activity, warning in
      guard let self else { return }
      self.index = index
      self.activity = activity
      catalogRevision += 1
      ready = true
      notice = warning
    }
  }

  var all: [Film] { index.all }
  func favoriteFilms() async throws -> [Film] {
    try await index.favorites(for: activity.favorites)
  }

  var recent: [Film] { activity.recent.compactMap { index.byKey[$0].map { index.all[$0] } } }
  var sources: [LibrarySourceInfo] { index.sources }
  var hasRefreshableSources: Bool { !sources.isEmpty }

  func favorite(_ film: Film) -> Bool { activity.favorites.contains(film.libraryKey) }

  func toggle(_ film: Film) {
    let key = film.libraryKey
    guard ready, index.byKey[key] != nil else { return }
    if !activity.favorites.insert(key).inserted {
      activity.favorites.remove(key)
    }
    favoritesRevision += 1
    saveActivity()
  }

  func played(_ film: Film) {
    let key = film.libraryKey
    guard ready, index.byKey[key] != nil, activity.recent.first != key else { return }
    activity.recent = [key] + activity.recent.filter { $0 != key }.prefix(39)
    recentRevision += 1
    saveActivity()
  }

  func clearHistory() {
    guard ready, !activity.recent.isEmpty else { return }
    activity.recent.removeAll()
    recentRevision += 1
    saveActivity()
  }

  private func saveActivity() {
    store.saveActivity(activity) { [weak self] error in self?.notice = error }
  }

  private func apply(_ change: CatalogChange) {
    if let index = change.index {
      self.index = index
      catalogRevision += 1
      let favoriteCount = activity.favorites.count
      let recentCount = activity.recent.count
      activity.favorites = activity.favorites.filter { index.byKey[$0] != nil }
      activity.recent.removeAll { index.byKey[$0] == nil }
      if favoriteCount != activity.favorites.count { favoritesRevision += 1 }
      if recentCount != activity.recent.count { recentRevision += 1 }
      if favoriteCount != activity.favorites.count || recentCount != activity.recent.count {
        saveActivity()
      }
    }
    if let error = change.error { notice = error }
  }

  func remove(_ film: Film) {
    guard ready else { return }
    store.remove(film) { [weak self] change in self?.apply(change) }
  }

  func removeSource(_ id: URL) {
    guard ready else { return }
    store.removeSource(id) { [weak self] change in self?.apply(change) }
  }

  func cancelImport() { if !committing { importTask?.cancel() } }

  func add(_ urls: [URL], playlist: Bool, completion: @escaping @MainActor () -> Void) {
    guard ready, !importing, !syncing, !urls.isEmpty else { return }
    notice = nil
    importStatus = "Import en cours…"
    importTask = Task {
      var imports: [LibraryStore.Import] = []
      var failures: [String] = []
      for (index, url) in urls.enumerated() {
        if Task.isCancelled { break }
        if url.lastPathComponent.lowercased() == "player_api.php",
          let source = try? XtreamSource(url)
        {
          let section =
            switch source.section {
            case .live: "Chaînes en direct"
            case .movies: "Films"
            case .series: "Séries"
            }
          importStatus =
            urls.count == 1 ? "Import · " + section : "\(section) · \(index + 1) sur \(urls.count)"
        }
        do {
          let response = try await Importer.refresh(url, playlist: playlist, validators: nil)
          guard let films = response.films else { throw ImportError.invalidResponse }
          imports.append(
            .init(films: films, origin: playlist ? url : nil, validators: response.validators))
        } catch {
          let detail =
            (error as? ImportError)?.localizedDescription
            ?? "Impossible d’ouvrir la source. Vérifiez le fichier ou la connexion."
          failures.append(urls.count == 1 ? detail : Importer.sourceName(url) + " — " + detail)
        }
      }
      guard !Task.isCancelled, !imports.isEmpty else {
        if !Task.isCancelled { notice = failures.joined(separator: "\n") }
        importStatus = nil
        importTask = nil
        return
      }
      committing = true
      importStatus = "Enregistrement…"
      store.add(imports) { [self, failures] change in
        apply(change)
        if !failures.isEmpty {
          notice =
            (["Certaines rubriques n’ont pas pu être importées."] + failures
            + [change.error].compactMap { $0 }).joined(separator: "\n")
        } else if change.index == nil && change.error == nil {
          notice =
            urls.count == 1
            ? "Cette source figure déjà dans votre bibliothèque."
            : "Ces sources figurent déjà dans votre bibliothèque."
        }
        committing = false
        importStatus = nil
        importTask = nil
        completion()
      }
    }
  }

  func cancelRefresh() { if !committing { refreshTask?.cancel() } }

  func refreshSources() {
    guard ready, !importing, !syncing, hasRefreshableSources else { return }
    let pending = sources
    syncing = true
    syncStatus = nil
    refreshTask = Task {
      let results = await Self.fetch(pending)
      guard !Task.isCancelled else {
        syncStatus = "Actualisation annulée"
        syncing = false
        refreshTask = nil
        return
      }
      committing = true
      store.refresh(results.updates) { [self] change in
        apply(change)
        if !results.failed.isEmpty {
          let errors = results.failed.prefix(3).joined(separator: "\n")
          let suffix = results.failed.count > 3 ? "\n…" : ""
          notice = [
            change.error,
            "Le dernier catalogue des sources indisponibles a été conservé.\n\(errors)\(suffix)",
          ].compactMap { $0 }.joined(separator: "\n")
        }
        committing = false
        syncStatus =
          results.failed.isEmpty
          ? (change.index == nil ? "Sources à jour" : "Catalogue actualisé")
          : "\(results.updates.count) sur \(pending.count) actualisées"
        syncing = false
        refreshTask = nil
      }
    }
  }

  private struct RefreshResults: Sendable {
    var updates: [URL: SourceUpdate] = [:]
    var failed: [String] = []
  }

  private enum SourceResponse: Sendable {
    case loaded(SourceUpdate)
    case failed(String)
  }

  private nonisolated static func fetch(_ sources: [LibrarySourceInfo]) async -> RefreshResults {
    await withTaskGroup(of: (LibrarySourceInfo, SourceResponse).self) { group in
      var pending = sources.makeIterator()
      var result = RefreshResults()
      func enqueue(_ source: LibrarySourceInfo) {
        group.addTask {
          do {
            let response = try await Importer.refresh(
              source.id, playlist: true, validators: source.validators)
            return (
              source, .loaded(SourceUpdate(films: response.films, validators: response.validators))
            )
          } catch {
            let detail =
              (error as? ImportError)?.localizedDescription
              ?? "Vérifiez le fichier ou la connexion."
            return (source, .failed(detail))
          }
        }
      }
      // Bound simultaneous response buffers and provider connections.
      for _ in 0..<min(2, sources.count) {
        if let source = pending.next() { enqueue(source) }
      }
      for await (source, update) in group {
        guard !Task.isCancelled else {
          group.cancelAll()
          break
        }
        switch update {
        case .loaded(let snapshot):
          result.updates[source.id] = snapshot
        case .failed(let detail):
          result.failed.append(source.name + " — " + detail)
        }
        if let next = pending.next() { enqueue(next) }
      }
      return result
    }
  }
}
