// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HerdrMenubar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "HerdrMenubar", path: "Sources/HerdrMenubar")
    ]
)
