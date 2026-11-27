import SwiftUI
@preconcurrency import VLCKit

@MainActor
private final class VLCSession: NSObject, ObservableObject, @preconcurrency VLCMediaPlayerDelegate {
  let player = VLCMediaPlayer(options: [
    "--quiet", "--no-video-title-show", "--no-metadata-network-access",
  ])
  @Published var state = VLCMediaPlayerState.opening
  @Published var position = 0.0
  private var ready: (() -> Void)?

  func open(_ url: URL, offset: Double, ready: @escaping () -> Void) {
    self.ready = ready
    state = .opening
    let media = VLCMedia(url: url)
    if offset.isFinite && offset > 0 { media.addOption(":start-time=\(offset)") }
    player.delegate = self
    player.media = media
    player.play()
  }

  func close() {
    ready = nil
    player.delegate = nil
    player.stop()
    player.drawable = nil
  }

  func mediaPlayerStateChanged(_ notification: Notification) {
    let next = player.state
    if next != .esAdded && !(next == .stopped && state == .error) { state = next }
    if next == .playing { started() }
  }

  func mediaPlayerTimeChanged(_ notification: Notification) {
    let value = Double(player.position)
    position = value.isFinite ? min(1, max(0, value)) : 0
    if player.isPlaying {
      if state != .playing { state = .playing }
      started()
    }
  }

  private func started() {
    let callback = ready
    ready = nil
    callback?()
  }
}

private struct VLCDisplay: NSViewRepresentable {
  let session: VLCSession
  func makeNSView(context: Context) -> VLCVideoView {
    let view = VLCVideoView()
    session.player.drawable = view
    return view
  }
  func updateNSView(_ view: VLCVideoView, context: Context) {}
}

struct CompatibilityPlayer: View {
  let url: URL
  let offset: Double
  let ready: () -> Void
  @StateObject private var session = VLCSession()
  @ViewState private var seek: Double?

  private var player: VLCMediaPlayer { session.player }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        VLCDisplay(session: session)
        if session.state == .error {
          VStack {
            Text("Le lecteur VLC n’a pas pu ouvrir ce média.")
            Button("Réessayer") { restart(at: offset) }
          }.padding().background(panel)
        } else if session.state == .opening || session.state == .buffering {
          LoadingSignal(label: "Chargement avec VLC…").padding(8).background(panel)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      HStack(spacing: 12) {
        Button {
          if session.state == .ended || session.state == .stopped {
            restart(at: 0)
          } else if player.isPlaying {
            player.pause()
          } else {
            player.play()
          }
        } label: {
          let playing = session.state == .playing
          Image(systemName: playing ? "pause.fill" : "play.fill")
            .accessibilityLabel(playing ? "Pause" : "Lecture")
        }.disabled(session.state == .error)
        Slider(value: Binding(get: { seek ?? session.position }, set: { seek = $0 }), in: 0...1) {
          editing in
          if !editing, let target = seek {
            player.position = Float(target)
            seek = nil
          }
        }.disabled(!player.isSeekable).accessibilityLabel("Position")
        Menu {
          trackMenu(
            "Audio", ids: player.audioTrackIndexes, names: player.audioTrackNames,
            selected: player.currentAudioTrackIndex
          ) { player.currentAudioTrackIndex = $0 }
          trackMenu(
            "Sous-titres", ids: player.videoSubTitlesIndexes, names: player.videoSubTitlesNames,
            selected: player.currentVideoSubTitleIndex
          ) { player.currentVideoSubTitleIndex = $0 }
        } label: {
          Image(systemName: "captions.bubble")
        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Audio et sous-titres")
        Text("VLC").font(.caption).foregroundStyle(.secondary)
      }.padding(10).background(panel)
    }
    .onAppear { session.open(url, offset: offset, ready: ready) }
    .onDisappear { session.close() }
  }

  private func restart(at seconds: Double) {
    player.stop()
    session.open(url, offset: seconds, ready: ready)
  }

  private func trackMenu(
    _ title: String, ids: [Any], names: [Any], selected: Int32,
    choose: @escaping (Int32) -> Void
  ) -> some View {
    Menu(title) {
      if ids.isEmpty { Text("Aucune piste disponible") }
      ForEach(Array(ids.indices), id: \.self) { i in
        if let id = (ids[i] as? NSNumber)?.int32Value {
          let name =
            id == -1
            ? "Désactivé"
            : (names.indices.contains(i) ? names[i] as? String : nil) ?? "Piste \(i + 1)"
          Button {
            choose(id)
          } label: {
            if id == selected { Label(name, systemImage: "checkmark") } else { Text(name) }
          }
        }
      }
    }
  }
}
