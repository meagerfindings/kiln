// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Kiln",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "Kiln", targets: ["Kiln"])],
  targets: [
    .executableTarget(name: "Kiln", resources: [.process("Resources")]),
    .testTarget(name: "KilnTests", dependencies: ["Kiln"]),
  ]
)
