import AVKit
import SwiftUI

private struct Screen: NSViewRepresentable {
  let player: AVPlayer
  let audioOnly: Bool

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.showsFullScreenToggleButton = true
    view.allowsPictureInPicturePlayback = true
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
    let style: AVPlayerViewControlsStyle = audioOnly ? .inline : .floating
    if view.controlsStyle != style { view.controlsStyle = style }
  }

  static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
    view.player = nil
  }
}

private struct WaitingIndicator: View {
  let opening: Bool
  let retry: () -> Void
  @ViewState private var visible = false
  @ViewState private var showRetry = false

  var body: some View {
    ZStack {
      if visible {
        HStack(spacing: 9) {
          LoadingSignal(label: opening ? "Ouverture…" : "Mise en mémoire tampon…")
          if showRetry {
            Button("Réessayer", action: retry)
          }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(ink.opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
      }
    }
    .task {
      do {
        try await Task.sleep(for: .milliseconds(400))
        visible = true
        try await Task.sleep(for: .seconds(12))
        showRetry = true
      } catch {}
    }
  }
}

struct Cinema: View {
  let film: Film
  let ready: @MainActor () -> Void
  let close: @MainActor () -> Void
  @ViewState private var fallbackOffset: Double?
  @ViewState private var recorded = false
  @ViewState private var choosingTracks = false
  @StateObject private var transport = Transport()
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: transport.audioOnly ? "waveform" : "play.rectangle")
          .foregroundStyle(coral).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(film.title).font(.headline).lineLimit(1)
          Text(film.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        if fallbackOffset == nil {
          if canUseVLC {
            Button("VLC", action: switchToVLC).help("Ouvrir avec le lecteur VLC")
          }
          Button {
            choosingTracks.toggle()
          } label: {
            Label("Audio et sous-titres", systemImage: "captions.bubble").labelStyle(.iconOnly)
          }
          .help("Audio et sous-titres")
          .disabled(transport.phase != .available && transport.phase != .buffering)
          .popover(isPresented: $choosingTracks) {
            if let item = transport.player.currentItem { PlaybackTracks(item: item).id(item) }
          }
        }
        Button("Fermer", action: close).keyboardShortcut(.cancelAction)
      }.padding(.horizontal, 18).padding(.vertical, 12)
      Divider()
      ZStack(alignment: .bottom) {
        if let offset = fallbackOffset {
          CompatibilityPlayer(url: film.url, offset: offset, ready: recordPlayback)
        } else {
          if transport.audioOnly {
            VStack {
              Image(systemName: "hifispeaker.2")
                .font(.system(size: 44, weight: .light)).foregroundStyle(coral).accessibilityHidden(
                  true)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
              .padding(.bottom, 48)
          }
          Screen(player: transport.player, audioOnly: transport.audioOnly)
            .frame(height: transport.audioOnly ? 48 : nil)
          if case .failed(let detail) = transport.phase {
            VStack(spacing: 10) {
              Text("Lecture indisponible").font(.headline)
              Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(
                .center)
              Button("Réessayer", action: transport.retry)
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(ink)
          } else if transport.phase == .opening || transport.phase == .buffering {
            WaitingIndicator(opening: transport.phase == .opening, retry: transport.retry)
              .id(transport.player.currentItem)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }.frame(
        minHeight: 140, idealHeight: transport.audioOnly ? 168 : 394, maxHeight: .infinity
      )
      .background(transport.audioOnly ? ink : .black)
    }.frame(minWidth: 360, idealWidth: 700, maxWidth: .infinity).background(panel)
      .onAppear { transport.start(film.url, ready: recordPlayback) }
      .onChange(of: transport.phase) {
        if case .failed = transport.phase { switchToVLC() }
      }
      .onDisappear { transport.stop() }
  }

  private var canUseVLC: Bool {
    if film.url.isFileURL { return true }
    guard ["http", "https"].contains(film.url.scheme?.lowercased()) else { return false }
    // The optional host-restricted build relies on ATS, including on redirects.
    let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
    return ats?["NSExceptionDomains"] == nil
  }

  private func switchToVLC() {
    guard canUseVLC, fallbackOffset == nil else { return }
    let seconds = transport.player.currentTime().seconds
    fallbackOffset = seconds.isFinite ? max(0, seconds) : 0
    choosingTracks = false
    transport.stop()
  }

  private func recordPlayback() {
    guard !recorded else { return }
    recorded = true
    ready()
  }
}
