import AVFoundation
import SwiftUI

struct PlaybackTracks: View {
  let item: AVPlayerItem
  @ViewState private var audio: AVMediaSelectionGroup?
  @ViewState private var subtitles: AVMediaSelectionGroup?
  @ViewState private var selection: AVMediaSelection?
  @ViewState private var loaded = false
  @ViewState private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if failed {
        Text("Impossible de lire les pistes du média.")
      } else if loaded {
        trackPicker("Audio", group: audio, canDisable: false)
        Divider()
        trackPicker("Sous-titres", group: subtitles, canDisable: true)
      } else {
        LoadingSignal(label: "Recherche des pistes…")
      }
    }
    .padding(16).frame(width: 290)
    .task(id: item) {
      do {
        let audioGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let subtitleGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
        try Task.checkCancellation()
        audio = audioGroup
        subtitles = subtitleGroup
        selection = item.currentMediaSelection
        loaded = true
      } catch {
        if !Task.isCancelled { failed = true }
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVPlayerItem.mediaSelectionDidChangeNotification, object: item)
    ) { _ in
      selection = item.currentMediaSelection
    }
  }

  @ViewBuilder
  private func trackPicker(_ title: String, group: AVMediaSelectionGroup?, canDisable: Bool)
    -> some View
  {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.headline)
      if let group, !group.options.isEmpty {
        Picker(
          title,
          selection: Binding(
            get: { selection?.selectedMediaOption(in: group) },
            set: { option in
              item.select(option, in: group)
              selection = item.currentMediaSelection
            }
          )
        ) {
          if canDisable && group.allowsEmptySelection {
            Text("Désactivés").tag(nil as AVMediaSelectionOption?)
          }
          ForEach(Array(group.options.enumerated()), id: \.offset) { index, option in
            let name = option.displayName(with: Locale(identifier: "fr"))
            Text(name.isEmpty ? "Piste \(index + 1)" : name)
              .tag(option as AVMediaSelectionOption?)
          }
        }.labelsHidden().frame(maxWidth: .infinity)
      } else {
        Text(
          canDisable
            ? "Aucune piste de sous-titres détectée." : "Aucune piste audio sélectionnable."
        )
        .font(.callout).foregroundStyle(.secondary)
      }
    }
  }
}
