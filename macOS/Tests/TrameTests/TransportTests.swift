import AVFoundation
import Testing

@testable import Trame

@MainActor
private func waitForPlaybackState(_ predicate: () -> Bool) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(8))
  while !predicate(), clock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(predicate())
}

@MainActor
@Test func localVideoStartsAndRecoversAtItsPosition() async throws {
  let url = try #require(Film.editions.first?.url)
  let transport = Transport()
  defer { transport.stop() }
  var starts = 0
  transport.start(url) { starts += 1 }
  try await waitForPlaybackState { starts == 1 }
  let oldItem = try #require(transport.player.currentItem)
  #expect(!transport.audioOnly)
  #expect(oldItem.automaticallyLoadedAssetKeys.isEmpty)
  // AVKit's native scrubber can still seek with duration removed from the startup gate.
  let moved = await transport.player.seek(to: CMTime(seconds: 4, preferredTimescale: 600))
  #expect(moved)
  NotificationCenter.default.post(
    name: AVPlayerItem.failedToPlayToEndTimeNotification, object: oldItem)
  try await waitForPlaybackState { if case .failed = transport.phase { true } else { false } }
  transport.retry()
  NotificationCenter.default.post(
    name: AVPlayerItem.failedToPlayToEndTimeNotification, object: oldItem)
  try await waitForPlaybackState {
    transport.player.timeControlStatus == .playing && transport.player.currentTime().seconds >= 3
  }
  #expect(transport.player.currentItem !== oldItem)
  #expect(transport.phase == .available)
  #expect(starts == 1)
  transport.stop()
  #expect(transport.player.currentItem == nil)
  #expect(transport.phase == .idle)
}

@MainActor
@Test func audioOnlyFileUsesTheSameTransport() async throws {
  let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
  defer { try? FileManager.default.removeItem(at: url) }
  let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
  do {
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let samples = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
    samples.frameLength = samples.frameCapacity
    samples.floatChannelData?[0].update(repeating: 0, count: Int(samples.frameLength))
    try file.write(from: samples)
  }
  let transport = Transport()
  defer { transport.stop() }
  var started = false
  transport.start(url) { started = true }
  try await waitForPlaybackState { transport.audioOnly && started }
  #expect(transport.phase == .available)
  transport.stop()
  #expect(!transport.audioOnly)
}

@MainActor
@Test func playbackOfMissingFileCanBeClosedDuringRetry() async throws {
  let transport = Transport()
  let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
  var started = false
  transport.start(url) { started = true }
  try await waitForPlaybackState { if case .failed = transport.phase { true } else { false } }
  transport.retry()
  transport.stop()
  await Task.yield()
  #expect(transport.player.currentItem == nil)
  #expect(transport.phase == .idle)
  #expect(!started)
}
