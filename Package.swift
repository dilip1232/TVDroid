// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TVDroid",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CShm", path: "Sources/CShm"),
        .executableTarget(name: "TVDroid", dependencies: ["CShm"], path: "Sources/TVDroid"),
    ]
)
