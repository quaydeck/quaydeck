// swift-tools-version: 5.9
import PackageDescription

// Renders Quaydeck's real menu from a fictional Mac into brand/screenshots and
// brand/social. Kept out of the app package so app builds never compile it.
//
//   swift run --package-path Tools/Screenshots
let package = Package(
    name: "Screenshots",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "Screenshots",
            dependencies: [
                .product(name: "QuaydeckCore", package: "quaydeck"),
                .product(name: "QuaydeckUI", package: "quaydeck"),
            ]
        ),
    ]
)
