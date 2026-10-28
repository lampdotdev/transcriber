// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Transcriber", path: "Sources")]
)
