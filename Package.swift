// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "pnow",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "pnow",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
