import AVKit
import SwiftUI
import Testing
@preconcurrency import VLCKit

@testable import Trame

@MainActor
@Test func playbackWindowResizesTheNativeVideo() async throws {
  try await checkPlaybackWindow(film: #require(Film.editions.first), display: AVPlayerView.self)
}

@MainActor
@Test func playbackWindowResizesAfterAutomaticVLCFallback() async throws {
  // YUV4MPEG is readable by VLC and triggers the AVPlayer failure path offline.
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).y4m")
  defer { try? FileManager.default.removeItem(at: url) }
  var media = Data("YUV4MPEG2 W32 H18 F10:1 Ip A1:1 C420jpeg\n".utf8)
  for _ in 0..<100 {
    media.append(contentsOf: "FRAME\n".utf8)
    media.append(Data(repeating: 128, count: 32 * 18 * 3 / 2))
  }
  try media.write(to: url)
  let film = Film(url: url, title: "Test VLC", group: "", source: "Test")
  try await checkPlaybackWindow(film: film, display: VLCVideoView.self)
}

@MainActor
private func checkPlaybackWindow<Video: NSView>(film: Film, display: Video.Type) async throws {
  _ = NSApplication.shared
  var ready = false
  let playback = PlaybackWindow()
  playback.open(film) { ready = true }
  let window = try #require(playback.window)
  defer { playback.window?.close() }
  #expect(window.sheetParent == nil)
  #expect(window.isMovable && window.styleMask.contains([.titled, .resizable]))
  #expect(window.collectionBehavior.contains(.fullScreenPrimary))
  let content = try #require(window.contentView)
  let originalPosition = window.frame.origin
  let moved = CGPoint(x: originalPosition.x + 40, y: originalPosition.y - 30)
  window.setFrameOrigin(moved)
  func playerView(in view: NSView) -> Video? {
    if let video = view as? Video { return video }
    for child in view.subviews {
      if let video = playerView(in: child) { return video }
    }
    return nil
  }
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(8)
  var video: Video?
  repeat {
    try await Task.sleep(for: .milliseconds(20))
    video = playerView(in: content)
  } while (video == nil || !ready) && clock.now < deadline
  let surface = try #require(video)
  try #require(ready)
  #expect(surface.window === window)
  #expect(window.frame.origin == moved)
  #expect(window.contentMinSize.width <= 480 && window.contentMinSize.height <= 300)
  #expect(window.contentMaxSize.width >= 800 && window.contentMaxSize.height >= 480)
  var sizes: [CGSize] = []
  for size in [
    CGSize(width: 480, height: 300), CGSize(width: 800, height: 480),
    CGSize(width: 480, height: 300),
  ] {
    window.setContentSize(size)
    try await Task.sleep(for: .milliseconds(100))
    content.layoutSubtreeIfNeeded()
    sizes.append(surface.bounds.size)
  }
  #expect(sizes[1].width > sizes[0].width + 250)
  #expect(sizes[1].height > sizes[0].height + 120)
  #expect(sizes[2] == sizes[0])
  playback.open(film) { Issue.record("Selecting the playing title restarted playback") }
  #expect(playback.window === window && window.contentView === content)
  window.performClose(nil)
  #expect(playback.window == nil)
  #expect(surface.window == nil)
}
