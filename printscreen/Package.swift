// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PrintScreen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PrintScreen", path: "Sources/PrintScreen")
    ]
)
