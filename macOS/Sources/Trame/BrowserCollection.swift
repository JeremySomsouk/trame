import Foundation
import TrameSources

/// A snapshot shared by successive searches until the displayed catalog changes.
struct BrowserCollection: Sendable {
  let films: [Film]
  let groups: [String]
  let children: [String: [String]]
  private let sources: Set<String>

  static func build(films: [Film], kind: MediaKind? = nil) async throws -> Self {
    var selected: [Film] = []
    var groups = Set<String>()
    var sources = Set<String>()
    for (offset, film) in films.enumerated() {
      if offset.isMultiple(of: 256) { try Task.checkCancellation() }
      if let kind {
        guard film.kind == kind else { continue }
        selected.append(film)
      }
      if !film.group.isEmpty { groups.insert(film.group) }
      sources.insert(film.source)
    }
    var tree: [String: Set<String>] = [:]
    for path in groups {
      try Task.checkCancellation()
      var parent = ""
      for part in path.components(separatedBy: " › ") where !part.isEmpty {
        let node = parent.isEmpty ? part : parent + " › " + part
        tree[parent, default: []].insert(node)
        parent = node
      }
    }
    return Self(
      films: kind == nil ? films : selected,
      groups: groups.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
      children: tree.mapValues {
        $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      },
      sources: sources)
  }

  func matchingCategories(_ query: String) async throws -> [String] {
    let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var pending = Array((children[""] ?? []).reversed())
    var result: [String] = []
    while let path = pending.popLast() {
      try Task.checkCancellation()
      if terms.allSatisfy({ path.localizedStandardContains($0) }) { result.append(path) }
      if let descendants = children[path] { pending.append(contentsOf: descendants.reversed()) }
    }
    return result
  }

  func matches(text: String, group: String) async throws -> [Film] {
    let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if term.isEmpty && group.isEmpty { return films }
    let matchingGroups =
      term.isEmpty ? [] : Set(groups.filter { $0.localizedStandardContains(term) })
    let matchingSources =
      term.isEmpty ? [] : Set(sources.filter { $0.localizedStandardContains(term) })
    let prefix = group + " › "
    var result: [Film] = []
    for (offset, film) in films.enumerated() {
      if offset.isMultiple(of: 128) { try Task.checkCancellation() }
      if (group.isEmpty || group == film.group || film.group.hasPrefix(prefix))
        && (term.isEmpty || matchingSources.contains(film.source)
          || matchingGroups.contains(film.group)
          || film.title.localizedStandardContains(term))
      {
        result.append(film)
      }
    }
    return result
  }
}
