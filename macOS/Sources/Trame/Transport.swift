import AVFoundation
import Combine

@MainActor
final class Transport: ObservableObject {
  enum Phase: Equatable {
    case idle, opening, buffering, available
    case failed(String)
  }

  @Published private(set) var player = AVPlayer()
  @Published private(set) var phase: Phase = .idle
  @Published private(set) var audioOnly = false

  private var observations: [NSKeyValueObservation] = []
  private var failureObserver: AnyCancellable?
  private var onFirstPlayback: (@MainActor () -> Void)?
  private var url: URL?
  private var resumeTime: CMTime?
  private var seekOnReady = false

  func start(_ url: URL, ready: @escaping @MainActor () -> Void) {
    stop()
    self.url = url
    onFirstPlayback = ready
    open(url)
  }

  func retry() {
    guard let url, let item = player.currentItem else { return }
    let position = item.currentTime()
    if position.isNumeric, position.seconds > 0, item.duration.isNumeric, position < item.duration {
      resumeTime = position
    }
    detach()
    open(url)
  }

  private func open(_ url: URL) {
    // A failed AVPlayer cannot accept another item. Keep the native view and
    // the user's audio settings when a retry requires a new playback engine.
    if player.status == .failed {
      let replacement = AVPlayer()
      replacement.volume = player.volume
      replacement.isMuted = player.isMuted
      player = replacement
    }
    phase = .opening
    let item = AVPlayerItem(asset: AVURLAsset(url: url), automaticallyLoadedAssetKeys: [])
    player.replaceCurrentItem(with: item)
    let refresh: @Sendable () -> Void = { [weak self] in
      Task { @MainActor in self?.refresh(item) }
    }
    observations = [
      item.observe(\.status, options: [.initial, .new]) { _, _ in refresh() },
      player.observe(\.timeControlStatus, options: [.new]) { _, _ in refresh() },
      player.observe(\.status, options: [.new]) { _, _ in refresh() },
      item.observe(\.tracks, options: [.initial, .new]) { [weak self] item, _ in
        Task { @MainActor in self?.updateTracks(item) }
      },
    ]
    failureObserver = NotificationCenter.default.publisher(
      for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item
    ).sink { @Sendable [weak self] notification in
      let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
      Task { @MainActor in self?.fail(item, error: error) }
    }
    // AVPlayer starts as soon as its native buffering policy permits. Do not
    // gate live streams on duration metadata or a round trip through SwiftUI.
    seekOnReady = resumeTime != nil
    if !seekOnReady { player.play() }
  }

  private func refresh(_ item: AVPlayerItem) {
    guard player.currentItem === item else { return }
    if case .failed = phase { return }
    if item.status == .failed || player.status == .failed {
      fail(item, error: (item.error ?? player.error) as NSError?)
      return
    }
    guard item.status == .readyToPlay else { return }
    if seekOnReady, let resumeTime {
      seekOnReady = false
      let tolerance = CMTime(value: 1, timescale: 2)
      player.seek(to: resumeTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
      player.play()
    }
    let next: Phase =
      player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? .buffering : .available
    if phase != next { phase = next }
    if player.timeControlStatus == .playing {
      resumeTime = nil
      let callback = onFirstPlayback
      onFirstPlayback = nil
      callback?()
    }
  }

  private func updateTracks(_ item: AVPlayerItem) {
    guard player.currentItem === item else { return }
    let tracks = item.tracks
    let onlyAudio =
      tracks.contains { $0.assetTrack?.mediaType == .audio }
      && !tracks.contains { $0.assetTrack?.mediaType == .video || $0.assetTrack == nil }
    if onlyAudio != audioOnly { audioOnly = onlyAudio }
  }

  private func fail(_ item: AVPlayerItem, error: NSError?) {
    guard player.currentItem === item else { return }
    if case .failed = phase { return }
    player.pause()
    if error?.domain == NSURLErrorDomain {
      phase = .failed("Vérifiez la connexion et la disponibilité de la source.")
    } else if url?.isFileURL == true {
      phase = .failed(
        "Vérifiez que le fichier est accessible et que son format est pris en charge.")
    } else {
      phase = .failed("Vérifiez la disponibilité du flux et son format.")
    }
  }

  func stop() {
    detach()
    url = nil
    resumeTime = nil
    onFirstPlayback = nil
    if audioOnly { audioOnly = false }
    if phase != .idle { phase = .idle }
  }

  private func detach() {
    observations.removeAll()
    failureObserver = nil
    if let item = player.currentItem {
      item.cancelPendingSeeks()
      player.pause()
      player.replaceCurrentItem(with: nil)
    }
  }
}
