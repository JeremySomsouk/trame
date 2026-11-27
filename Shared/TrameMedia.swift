import Foundation

extension Bundle {
  public static let cinemaResources =
    Bundle.main.url(forResource: "Trame_TrameMedia", withExtension: "bundle").flatMap(
      Bundle.init(url:)) ?? Bundle.module
}
