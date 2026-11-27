import SwiftUI

@MainActor
final class PlaybackWindow: NSObject, ObservableObject, NSWindowDelegate {
  private(set) var window: NSWindow?
  private var filmID: Film.ID?

  func open(_ film: Film, ready: @escaping @MainActor () -> Void) {
    let playerWindow: NSWindow
    if let window {
      playerWindow = window
    } else {
      playerWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      playerWindow.isReleasedWhenClosed = false
      playerWindow.collectionBehavior.insert(.fullScreenPrimary)
      playerWindow.delegate = self
      playerWindow.center()
      window = playerWindow
    }

    if filmID != film.id {
      let close: @MainActor () -> Void = { [weak playerWindow] in playerWindow?.performClose(nil) }
      let content = Group {
        if film.opensEpisodes == true {
          SeriesEpisodes(series: film, ready: ready, close: close)
        } else {
          Cinema(film: film, ready: ready, close: close)
        }
      }.preferredColorScheme(.dark)
      playerWindow.contentView = NSHostingView(rootView: content)
      playerWindow.title = film.title
      filmID = film.id
    }
    playerWindow.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    window?.contentView = nil
    window = nil
    filmID = nil
  }
}
