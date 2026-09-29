// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "airhop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "airhop",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
