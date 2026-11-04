// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmniFS",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "OmniFSCore", targets: ["OmniFSCore"]),
        .library(name: "OmniFSPrefPane", type: .dynamic, targets: ["OmniFSPrefPane"]),
        .executable(name: "omnifs", targets: ["OmniFSCLI"]),
        .executable(name: "OmniFSSettings", targets: ["OmniFSSettings"]),
        .executable(name: "omnifs-vmd", targets: ["OmniFSVMHelper"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "OmniFSCore",
            dependencies: [],
            path: "Sources/OmniFSCore"
        ),
        .target(
            name: "OmniFSPrefPane",
            dependencies: ["OmniFSCore"],
            path: "Sources/OmniFSPrefPane",
            linkerSettings: [
                .linkedFramework("PreferencePanes"),
                .linkedFramework("Cocoa")
            ]
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
        .executableTarget(
            name: "OmniFSVMHelper",
            dependencies: ["OmniFSCore"],
            path: "Sources/OmniFSVMHelper",
            linkerSettings: [
                .linkedFramework("Virtualization")
            ]
        ),
        .testTarget(
            name: "OmniFSTests",
            dependencies: ["OmniFSCore"],
            path: "Tests/OmniFSTests"
        ),
    ]
)
