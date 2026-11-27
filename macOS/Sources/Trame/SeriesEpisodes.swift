import SwiftUI
import TrameSources

struct SeriesEpisodes: View {
  let series: Film
  let ready: @MainActor () -> Void
  let close: @MainActor () -> Void
  @ViewState private var episodes: [Episode]?
  @ViewState private var error: String?
  @ViewState private var attempt = 0
  @ViewState private var selected: Episode?

  var body: some View {
    if let selected {
      Cinema(
        film: Film(
          url: selected.url, title: selected.name, group: series.title, source: series.source),
        ready: ready, close: close)
    } else {
      VStack(alignment: .leading) {
        HStack {
          Text(series.title).font(.headline)
          Spacer()
          Button("Fermer", action: close).keyboardShortcut(.cancelAction)
        }
        if let error {
          Text(error)
          Button("Réessayer") { attempt += 1 }
        } else if let episodes {
          if episodes.isEmpty { Text("Aucun épisode disponible.") }
          List(episodes) { episode in
            Button {
              selected = episode
            } label: {
              Text(episode.season > 0 ? "Saison \(episode.season) · \(episode.name)" : episode.name)
            }
          }
        } else {
          LoadingSignal(label: "Chargement des épisodes…")
        }
      }.padding().frame(minWidth: 440, minHeight: 280)
        .task(id: attempt) {
          error = nil
          do { episodes = try await CatalogLoader.episodes(at: series.url) } catch {
            if !Task.isCancelled {
              self.error =
                (error as? ImportError)?.localizedDescription
                ?? "Impossible de charger les épisodes."
            }
          }
        }
    }
  }
}
