// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OmniFS",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "OmniFSCore", targets: ["OmniFSCore"]),
        .executable(name: "omnifs", targets: ["OmniFSCLI"]),
        .executable(name: "OmniFSSettings", targets: ["OmniFSSettings"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "OmniFSCore",
            dependencies: [],
            path: "Sources/OmniFSCore"
        ),
        .executableTarget(
            name: "OmniFSCLI",
            dependencies: ["OmniFSCore"],
            path: "Sources/OmniFSCLI"
        ),
        .executableTarget(
            name: "OmniFSSettings",
            dependencies: ["OmniFSCore"],
            path: "Sources/OmniFSSettings"
        ),
        .testTarget(
            name: "OmniFSTests",
            dependencies: ["OmniFSCore"],
            path: "Tests/OmniFSTests"
        ),
    ]
)
