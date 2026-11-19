// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenSourceHub",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "OpenSourceHubCore", targets: ["OpenSourceHubCore"]),
    ],
    targets: [
        .target(
            name: "OpenSourceHubCore",
            path: "Sources/OpenSourceHubCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "OpenSourceHubCoreTests",
            dependencies: ["OpenSourceHubCore"],
            path: "Tests/OpenSourceHubCoreTests"
        ),
    ]
)
