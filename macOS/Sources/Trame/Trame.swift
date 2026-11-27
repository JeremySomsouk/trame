import SwiftUI
import TrameMedia
import TrameSources

typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct TrameApp: App {
  @StateObject private var library = Library()
  @StateObject private var playerWindow = PlaybackWindow()

  var body: some Scene {
    Window("Trame", id: "library") {
      Studio(library: library, playerWindow: playerWindow).preferredColorScheme(.dark)
    }
    .defaultSize(width: 1160, height: 760)
    .windowStyle(.hiddenTitleBar)
  }
}

enum Page: String, CaseIterable {
  case home = "À l’affiche"
  case library = "Bibliothèque"
  case favorites = "Favoris"
  case recent = "Historique"
  var icon: String {
    switch self {
    case .home: "rectangle.on.rectangle.angled"
    case .library: "rectangle.stack"
    case .favorites: "heart"
    case .recent: "clock.arrow.circlepath"
    }
  }
}

private struct NavigationBar: View {
  let selected: Page
  let select: (Page) -> Void
  @Namespace private var indicator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
        let active = selected == page
        Button {
          if !active { select(page) }
        } label: {
          VStack(spacing: 4) {
            Image(systemName: page.icon)
              .symbolVariant(active ? .fill : .none)
              .font(.system(size: 17, weight: active ? .semibold : .regular))
              .frame(height: 20)
            Text(page.rawValue).font(.system(size: 12, weight: .medium))
          }
          .frame(maxWidth: .infinity).frame(height: 48)
          .foregroundStyle(active ? coral : Color.secondary)
          .background {
            if active {
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.26, green: 0.19, blue: 0.17))
                .matchedGeometryEffect(id: "selection", in: indicator)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        .help("\(page.rawValue) (⌘\(index + 1))")
        .accessibilityAddTraits(active ? .isSelected : [])
      }
    }
    .padding(4).frame(width: 432)
    .background {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color(red: 0.14, green: 0.14, blue: 0.16))
        .strokeBorder(.white.opacity(0.13), lineWidth: 1)
        .shadow(color: .black.opacity(0.26), radius: 5, y: 2)
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: selected)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Navigation principale")
  }
}

let ink = Color(red: 0.062, green: 0.067, blue: 0.076)
let panel = Color(red: 0.092, green: 0.098, blue: 0.11)
let coral = Color(red: 1, green: 0.59, blue: 0.48)

struct Studio: View {
  @AppStorage("loadPosters") private var loadPosters = true
  @ObservedObject var library: Library
  let playerWindow: PlaybackWindow
  @ViewState private var page = Page.home
  @ViewState private var adding = false
  @ViewState private var search = ""
  @ViewState private var group = ""
  @ViewState private var choosingCategory = false
  @ViewState private var mediaKind: MediaKind?
  @ViewState private var featured = 0
  @FocusState private var searchFocus: Bool
  @ViewState private var sourceToRemove: LibrarySourceInfo?
  @ViewState private var collection: BrowserCollection?
  @ViewState private var collectionKey: CollectionKey?
  @ViewState private var matches: [Film] = []
  @ViewState private var displayedKey: CollectionKey?

  private struct CollectionKey: Hashable {
    let page: Page
    let kind: MediaKind?
    let catalog: Int
    let selection: Int
  }

  private struct Query: Equatable {
    let key: CollectionKey
    let text: String
    let group: String
  }

  private var query: Query {
    Query(
      key: CollectionKey(
        page: page, kind: page == .library ? mediaKind : nil, catalog: library.catalogRevision,
        selection: page == .recent
          ? library.recentRevision : page == .favorites ? library.favoritesRevision : 0),
      text: search, group: group)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 16) {
        brand
        Divider().frame(height: 28)
        Text(page.rawValue).font(.system(size: 27, weight: .semibold))
        Spacer()
        if let status = library.committing
          ? "Enregistrement…" : library.syncing ? "Actualisation…" : library.syncStatus
        {
          Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        if library.hasRefreshableSources {
          syncControls
        }
        Button {
          library.notice = nil
          adding = true
        } label: {
          Label("Ajouter une source", systemImage: "plus")
        }
        .keyboardShortcut("o").disabled(!library.ready || library.importing || library.syncing)
      }.padding(.horizontal, 32).frame(height: 84)
      Divider()
      if !library.ready {
        ProgressView("Ouverture de la bibliothèque…").frame(
          maxWidth: .infinity, maxHeight: .infinity)
      } else if page == .home {
        home
      } else {
        browser
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      NavigationBar(selected: page, select: navigate)
        .frame(maxWidth: .infinity).padding(.vertical, 10)
    }
    .background(ink).tint(coral)
    .frame(minWidth: 760, minHeight: 540)
    .sheet(isPresented: $adding) {
      SourceSheet(library: library) {
        adding = false
        navigate(.library)
      }
    }
    .alert(
      "Bibliothèque",
      isPresented: Binding(
        get: { !adding && library.notice != nil }, set: { if !$0 { library.notice = nil } })
    ) {
      Button("Fermer") { library.notice = nil }
    } message: {
      Text(library.notice ?? "")
    }
    .confirmationDialog(
      "Retirer cette source ?",
      isPresented: Binding(
        get: { sourceToRemove != nil }, set: { if !$0 { sourceToRemove = nil } }
      ), presenting: sourceToRemove
    ) { source in
      Button("Retirer " + source.name, role: .destructive) { library.removeSource(source.id) }
      Button("Annuler", role: .cancel) {}
    } message: { _ in
      Text("Les titres fournis uniquement par cette source seront retirés de la bibliothèque.")
    }
    .background {
      Button("") {
        if page != .library { navigate(.library) }
        searchFocus = true
      }.keyboardShortcut("f").hidden()
    }
  }

  private func play(_ film: Film) {
    playerWindow.open(film) { [library] in library.played(film) }
  }

  private var syncControls: some View {
    HStack(spacing: 3) {
      if library.syncing {
        ProgressView().controlSize(.small).accessibilityLabel("Actualisation en cours")
        Button {
          library.cancelRefresh()
        } label: {
          Image(systemName: "xmark")
        }.disabled(library.committing).help("Annuler l’actualisation").accessibilityLabel(
          "Annuler l’actualisation")
      } else {
        Button {
          library.refreshSources()
        } label: {
          Image(systemName: "arrow.clockwise")
        }.keyboardShortcut("r").help("Actualiser les sources (⌘R)").accessibilityLabel(
          "Actualiser les sources"
        )
        .disabled(library.importing)
      }
      Menu {
        Section("Retirer une source") {
          ForEach(library.sources) { source in
            Button(source.name + " · " + String(source.count)) { sourceToRemove = source }
          }
        }
      } label: {
        Image(systemName: "ellipsis").frame(minWidth: 24)
      }.menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().help("Gérer les sources")
        .accessibilityLabel("Gérer les sources").disabled(library.syncing || library.importing)
    }
  }

  private func navigate(_ destination: Page) {
    if destination == .home {
      collection = nil
      collectionKey = nil
      displayedKey = nil
      matches = []
    }
    page = destination
    group = ""
    search = ""
  }

  private static let mark = Bundle.cinemaResources.url(forResource: "Marque", withExtension: "png")
    .flatMap(NSImage.init(contentsOf:))

  private var brand: some View {
    HStack(spacing: 9) {
      if let mark = Self.mark {
        Image(nsImage: mark).resizable().frame(width: 32, height: 32)
          .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
      }
      Text("Trame").font(.system(size: 19, weight: .bold))
    }.accessibilityElement(children: .combine)
  }

  private var home: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if let last = library.recent.first, last.artwork == nil {
          Text("Dernière lecture").font(.headline)
          row(last)
        }
        if Film.editions.indices.contains(featured) {
          let film = Film.editions[featured]
          ZStack(alignment: .bottomLeading) {
            Color(red: 0.073, green: 0.075, blue: 0.087)
            GeometryReader { proxy in
              Poster(film: film).aspectRatio(contentMode: .fit)
                .frame(width: proxy.size.width * 0.78, height: proxy.size.height)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            LinearGradient(
              stops: [
                .init(color: .black.opacity(0.84), location: 0),
                .init(color: .black.opacity(0.58), location: 0.36),
                .init(color: .clear, location: 0.72),
              ], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 12) {
              Text("ÉDITIONS TRAME").tracking(2.2).font(.caption.weight(.bold)).foregroundStyle(
                coral)
              Text(film.title).font(.system(size: 43, weight: .medium, design: .serif))
              Text("Étude de mouvement  /  10 s").font(.callout).foregroundStyle(.secondary)
              HStack(spacing: 10) {
                Button {
                  play(film)
                } label: {
                  Label("Regarder", systemImage: "play.fill")
                    .font(.headline).foregroundStyle(.black)
                    .padding(.horizontal, 16).frame(height: 34)
                    .background(coral, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                heart(film)
              }.padding(.top, 4)
            }.padding(25)
          }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 9))
          HStack {
            Text("Les études de mouvement").font(.title3.weight(.semibold))
            Spacer()
            Text("\(Film.editions.count) films").foregroundStyle(.secondary)
          }
          HStack(alignment: .top, spacing: 14) {
            ForEach(Array(Film.editions.enumerated()), id: \.element.id) { index, item in
              Button {
                featured = index
                play(item)
              } label: {
                VStack(alignment: .leading, spacing: 8) {
                  Poster(film: item).aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                  Text(item.title).font(.headline)
                  Text("Film court · 10 s").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityLabel("Lire " + item.title)
            }
          }
        }

      }.padding(32)
    }
  }

  private func updateBrowser(_ input: Query) async {
    do {
      let snapshot: BrowserCollection
      if collectionKey == input.key, let collection {
        snapshot = collection
      } else {
        let films: [Film]
        switch input.key.page {
        case .favorites: films = try await library.favoriteFilms()
        case .recent: films = library.recent
        case .home, .library: films = library.all
        }
        snapshot = try await BrowserCollection.build(films: films, kind: input.key.kind)
        try Task.checkCancellation()
        guard query == input else { return }
        collection = snapshot
        collectionKey = input.key
      }
      if !input.group.isEmpty && snapshot.children[input.group] == nil
        && !snapshot.groups.contains(input.group)
      {
        group = ""
        return
      }
      let result = try await snapshot.matches(text: input.text, group: input.group)
      try Task.checkCancellation()
      guard query == input else { return }
      matches = result
      displayedKey = input.key
    } catch {
      // A new query or navigation cancelled the work.
    }
  }

  private var browser: some View {
    let input = query
    return VStack(alignment: .leading, spacing: 16) {
      if page == .recent {
        HStack {
          Spacer()
          Button("Effacer tout l’historique", role: .destructive) { library.clearHistory() }
            .disabled(library.recent.isEmpty)
        }
      }
      if page == .library {
        HStack {
          Picker("Type de contenu", selection: $mediaKind) {
            Text("Tous").tag(nil as MediaKind?)
            Text("TV en direct").tag(MediaKind.live as MediaKind?)
            Text("Films").tag(MediaKind.movies as MediaKind?)
            Text("Séries").tag(MediaKind.series as MediaKind?)
          }.pickerStyle(.segmented).labelsHidden().controlSize(.large)
            .frame(maxWidth: 460).onChange(of: mediaKind) { group = "" }
          Spacer()
          Toggle("Charger les affiches", isOn: $loadPosters).toggleStyle(.switch).controlSize(
            .small)
        }
      }
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Rechercher un titre, une chaîne…", text: $search).textFieldStyle(.plain).focused(
          $searchFocus)
        if !search.isEmpty {
          Button {
            search = ""
            searchFocus = true
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }.buttonStyle(.plain).accessibilityLabel("Effacer la recherche").help(
            "Effacer la recherche")
        }
        if collectionKey == input.key, let collection, !collection.children.isEmpty {
          Button {
            choosingCategory.toggle()
          } label: {
            Label(group.isEmpty ? "Catégories" : group, systemImage: "folder").lineLimit(1)
              .frame(maxWidth: 220, alignment: .leading).fixedSize(
                horizontal: true, vertical: false)
          }
          .help(group.isEmpty ? "Choisir une catégorie ou une sous-catégorie" : group)
          .popover(isPresented: $choosingCategory) {
            CategoryPicker(collection: collection, selected: group) { path in
              group = path
              choosingCategory = false
            }.id(input.key)
          }
        }
      }.padding(12).background(panel, in: RoundedRectangle(cornerRadius: 6))
      if displayedKey != input.key {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if matches.isEmpty {
        ContentUnavailableView {
          Label(
            search.isEmpty && group.isEmpty && input.key.kind == nil
              ? page.rawValue : "Aucun résultat",
            systemImage: page.icon)
        } description: {
          Text(
            !search.isEmpty || !group.isEmpty
              ? "Essayez un autre titre ou groupe."
              : page == .favorites
                ? "Utilisez le cœur d’un film ou d’une chaîne pour le retrouver ici."
                : page == .library
                  ? "Ajoutez une source ou choisissez un autre type de contenu."
                  : "Vos dernières lectures apparaîtront ici.")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Text(matches.count.formatted() + (matches.count == 1 ? " titre" : " titres"))
          .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(matches) { film in
              row(film).overlay(alignment: .bottom) { Divider() }
            }
          }
        }
      }
    }.padding(24).task(id: input) { await updateBrowser(input) }
  }

  private func row(_ film: Film) -> some View {
    HStack {
      Button {
        play(film)
      } label: {
        HStack(spacing: 14) {
          if film.artwork != nil {
            Poster(film: film).aspectRatio(contentMode: .fill).frame(width: 64, height: 36)
              .clipShape(RoundedRectangle(cornerRadius: 4))
          } else {
            Image(systemName: film.symbol)
              .foregroundStyle(coral).frame(width: 64, height: 36)
              .background(panel)
              .overlay {
                if loadPosters, let url = film.posterURL { RemotePoster(url: url).id(url) }
              }
              .clipShape(RoundedRectangle(cornerRadius: 4))
          }
          VStack(alignment: .leading, spacing: 4) {
            Text(film.title).font(.headline).lineLimit(1)
            Text(film.group.isEmpty ? film.source : film.group + " · " + film.source).font(
              .caption
            ).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          Image(systemName: "play.fill").font(.caption).foregroundStyle(.secondary)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("Lire " + film.title)
      heart(film)
    }.padding(.vertical, 7).contextMenu {
      if film.artwork == nil {
        Button("Retirer de la bibliothèque") {
          library.remove(film)
        }
      }
    }
  }

  private func heart(_ film: Film) -> some View {
    let selected = library.favorite(film)
    return Button {
      library.toggle(film)
    } label: {
      Image(systemName: selected ? "heart.fill" : "heart").frame(width: 27, height: 26)
    }.buttonStyle(.borderless).foregroundStyle(selected ? coral : .secondary).help(
      selected ? "Retirer des favoris" : "Ajouter aux favoris"
    )
    .accessibilityLabel((selected ? "Retirer des favoris, " : "Ajouter aux favoris, ") + film.title)
  }
}

struct Poster: View {
  let film: Film
  private static let artwork = Dictionary(
    uniqueKeysWithValues: Film.editions.compactMap { film -> (String, NSImage)? in
      guard let key = film.artwork,
        let url = Bundle.cinemaResources.url(forResource: key, withExtension: "jpg"),
        let image = NSImage(contentsOf: url)
      else { return nil }
      return (key, image)
    })
  var body: some View {
    if let key = film.artwork, let image = Self.artwork[key] {
      Image(nsImage: image).resizable().accessibilityHidden(true)
    }
  }
}
