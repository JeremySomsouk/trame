// swift-tools-version: 6.0
import Foundation
import PackageDescription

#if arch(arm64)
  let hostTarget = "aarch64-apple-darwin"
#else
  let hostTarget = "x86_64-apple-darwin"
#endif
let rustLibrary =
  ProcessInfo.processInfo.environment["TRAME_CORE_LIB_DIR"]
  ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent(".build/rust/\(hostTarget)/release").path

let package = Package(
  name: "Trame",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "Trame", targets: ["Trame"])],
  targets: [
    .binaryTarget(name: "VLCKit", path: ".build/vlc/macos-3.7.3/VLCKit.xcframework"),
    .systemLibrary(name: "CTrameCore", path: "Core/include"),
    .target(
      name: "TrameSources", dependencies: ["CTrameCore"], path: "macOS/Sources/TrameSources",
      linkerSettings: [.unsafeFlags([rustLibrary + "/libtrame_core.a"])]),
    .target(
      name: "TrameMedia", path: "Shared", exclude: ["Licenses"], resources: [.process("Resources")]),
    .executableTarget(
      name: "Trame", dependencies: ["TrameSources", "TrameMedia", "VLCKit"],
      path: "macOS/Sources/Trame",
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]),
    .testTarget(
      name: "TrameSourcesTests", dependencies: ["TrameSources"],
      path: "macOS/Tests/TrameSourcesTests"),
    .testTarget(name: "TrameTests", dependencies: ["Trame"], path: "macOS/Tests/TrameTests"),
  ]
)
