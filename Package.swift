// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Quaydeck",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Quaydeck", targets: ["Quaydeck"]),
        .library(name: "QuaydeckCore", targets: ["QuaydeckCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure logic: scanning, classification, advice. No AppKit, no SwiftUI.
        // Every call out to the system goes through CommandRunner, so the whole
        // pipeline can be driven from recorded fixtures in tests.
        .target(name: "QuaydeckCore"),

        // Everything that touches AppKit/SwiftUI.
        .target(name: "QuaydeckUI", dependencies: ["QuaydeckCore"]),

        .executableTarget(
            name: "Quaydeck",
            dependencies: [
                "QuaydeckCore",
                "QuaydeckUI",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),

        .testTarget(
            name: "QuaydeckCoreTests",
            dependencies: ["QuaydeckCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
