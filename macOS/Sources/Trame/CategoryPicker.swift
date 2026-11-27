import SwiftUI

struct CategoryPicker: View {
  let collection: BrowserCollection
  let selected: String
  let select: (String) -> Void
  @ViewState private var parent = ""
  @ViewState private var query = ""
  @ViewState private var completedQuery = ""
  @ViewState private var results: [String] = []
  @FocusState private var searchFocused: Bool

  private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Rechercher une catégorie…", text: $query)
          .textFieldStyle(.plain).focused($searchFocused)
          .onSubmit {
            if !term.isEmpty, completedQuery == term, let first = results.first { select(first) }
          }
        if !query.isEmpty {
          Button {
            query = ""
            searchFocused = true
          } label: {
            Image(systemName: "xmark.circle.fill")
          }.buttonStyle(.borderless).accessibilityLabel("Effacer la recherche")
        }
      }.padding(8).background(panel, in: RoundedRectangle(cornerRadius: 6))
      if term.isEmpty {
        if !parent.isEmpty {
          Button {
            parent = parent.components(separatedBy: " › ").dropLast().joined(separator: " › ")
          } label: {
            Label(parent, systemImage: "chevron.left").lineLimit(2)
          }.buttonStyle(.borderless).help("Revenir à la catégorie parente")
        }
        Button(parent.isEmpty ? "Toutes les catégories" : "Tous les titres de cette catégorie") {
          select(parent)
        }.buttonStyle(.borderless)
      }
      Divider()
      if !term.isEmpty && completedQuery != term {
        ProgressView().controlSize(.small)
      } else if !term.isEmpty && results.isEmpty {
        Text("Aucune catégorie trouvée").foregroundStyle(.secondary)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(term.isEmpty ? collection.children[parent] ?? [] : results, id: \.self) {
              path in
              let opensChildren = term.isEmpty && collection.children[path] != nil
              Button {
                if opensChildren { parent = path } else { select(path) }
              } label: {
                HStack {
                  Text(term.isEmpty ? path.components(separatedBy: " › ").last ?? path : path)
                    .multilineTextAlignment(.leading)
                  Spacer()
                  if selected == path { Image(systemName: "checkmark").foregroundStyle(coral) }
                  if opensChildren {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                  }
                }.padding(.vertical, 6).contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityAddTraits(selected == path ? .isSelected : [])
            }
          }
        }.id(term.isEmpty ? parent : term)
      }
      Spacer(minLength: 0)
    }
    .padding(12).frame(width: 360, height: 310)
    .onAppear { searchFocused = true }
    .task(id: term) {
      let input = term
      guard !input.isEmpty else { return }
      if let matches = try? await collection.matchingCategories(input), !Task.isCancelled {
        results = matches
        completedQuery = input
      }
    }
  }
}
