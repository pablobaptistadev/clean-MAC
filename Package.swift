// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Limpo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Limpo", path: "Sources/Limpo")
    ]
)
