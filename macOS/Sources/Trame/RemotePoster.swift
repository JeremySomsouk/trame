import ImageIO
import SwiftUI
import TrameSources

private actor PosterCache {
  static let shared = PosterCache()
  private let images = NSCache<NSURL, CGImage>()

  init() { images.totalCostLimit = 8 * 1024 * 1024 }

  func thumbnail(at url: URL) async throws -> CGImage? {
    if let image = images.object(forKey: url as NSURL) { return image }
    let data = try await CatalogLoader.posterData(at: url)
    try Task.checkCancellation()
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
          kCGImageSourceThumbnailMaxPixelSize: 192,
        ] as CFDictionary)
    else { return nil }
    images.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
    return image
  }
}

struct RemotePoster: View {
  let url: URL
  @ViewState private var image: CGImage?

  var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFill()
      } else {
        Color.clear
      }
    }
    .accessibilityHidden(true)
    .task(id: url) {
      image = nil
      let thumbnail = try? await PosterCache.shared.thumbnail(at: url)
      if !Task.isCancelled { image = thumbnail }
    }
  }
}
