// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nudge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "nudge",
            path: "Sources"
        )
    ]
)
