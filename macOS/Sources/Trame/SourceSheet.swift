import SwiftUI
import TrameSources
import UniformTypeIdentifiers

private enum SourceKind: String, CaseIterable {
  case playlist = "Playlist"
  case xtream = "Xtream"
  case media = "Vidéo / audio"
}

struct SourceSheet: View {
  @ObservedObject var library: Library
  let imported: @MainActor () -> Void
  @Environment(\.dismiss) private var dismiss
  @ViewState private var address = ""
  @ViewState private var server = ""
  @ViewState private var username = ""
  @ViewState private var password = ""
  @ViewState private var kind = SourceKind.playlist

  @ViewState private var section: XtreamSection?

  private func webURL(_ text: String) -> URL? {
    guard
      let value = URL(
        string: text.trimmingCharacters(in: .whitespacesAndNewlines),
        encodingInvalidCharacters: false),
      ["http", "https"].contains(value.scheme?.lowercased()), value.host?.isEmpty == false
    else { return nil }
    return value
  }

  private var sourceURLs: [URL]? {
    if kind == .xtream {
      guard let serverURL = webURL(server), !username.isEmpty, !password.isEmpty else { return nil }
      let sections = section.map { [$0] } ?? XtreamSection.allCases
      return try? sections.map {
        try XtreamSource.apiURL(
          server: serverURL, username: username, password: password, section: $0)
      }
    }
    return webURL(address).map { [$0] }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Ajouter une source").font(.title.weight(.semibold))
      Picker("Type de source", selection: $kind) {
        ForEach(SourceKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).labelsHidden().disabled(library.importing)
      VStack(alignment: .leading, spacing: 8) {
        if kind == .xtream {
          Picker("Catalogue", selection: $section) {
            Text("Tout le catalogue").tag(nil as XtreamSection?)
            Text("Toutes les chaînes en direct").tag(XtreamSection.live as XtreamSection?)
            Text("Films").tag(XtreamSection.movies as XtreamSection?)
            Text("Séries").tag(XtreamSection.series as XtreamSection?)
          }
          Text("Serveur Xtream (HTTP ou HTTPS)").font(.headline)
          TextField(
            "Adresse du serveur", text: $server,
            prompt: Text(verbatim: "https://example.invalid:8080"))
          TextField("Identifiant", text: $username)
          SecureField("Mot de passe", text: $password)
          Text(
            "Les identifiants sont enregistrés en clair dans la bibliothèque de ce Mac."
          )
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
          Text("Adresse réseau (HTTP ou HTTPS)").font(.headline)
          TextField(
            "Adresse réseau", text: $address,
            prompt: Text(
              verbatim: kind == .playlist
                ? "https://example.invalid/chaines.m3u" : "https://example.invalid/video.mp4")
          )
        }
        if webURL(kind == .xtream ? server : address)?.scheme?.lowercased() == "http" {
          Text(
            "HTTP transmet les données en clair. Utilisez l’adresse HTTPS du fournisseur si elle est disponible."
          )
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }.textFieldStyle(.roundedBorder).disabled(library.importing)
      if kind != .xtream {
        Divider()
        Button {
          chooseFile()
        } label: {
          Label("Choisir un fichier local…", systemImage: "folder")
        }.disabled(library.importing)
      }
      if let message = library.notice { Text(message).foregroundStyle(coral) }
      HStack {
        if let status = library.importStatus {
          LoadingSignal(label: status)
        }
        Spacer()
        Button("Annuler") {
          library.cancelImport()
          library.notice = nil
          dismiss()
        }.keyboardShortcut(.cancelAction).disabled(library.committing)
        Button("Ajouter") {
          if let sourceURLs {
            library.add(sourceURLs, playlist: kind != .media, completion: imported)
          }
        }
        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        .disabled(sourceURLs == nil || library.importing)
      }
    }.padding(28).frame(width: 440).background(panel)
      .interactiveDismissDisabled(library.importing)
      .onChange(of: kind) { library.notice = nil }
  }

  private func chooseFile() {
    guard !library.importing else { return }
    let picker = NSOpenPanel()
    picker.allowedContentTypes =
      kind == .playlist
      ? ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) } : [.movie, .video, .audio]
    if picker.runModal() == .OK, let file = picker.url {
      library.add([file], playlist: kind == .playlist, completion: imported)
    }
  }
}
