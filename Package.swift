// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CoughButton",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CoughButton", targets: ["CoughButton"])
    ],
    targets: [
        // Thin executable shell — everything testable lives in the kit.
        .executableTarget(
            name: "CoughButton",
            dependencies: ["CoughButtonKit"],
            path: "Sources/CoughButton"
        ),
        .target(
            name: "CoughButtonKit",
            path: "Sources/CoughButtonKit"
        ),
        .testTarget(
            name: "CoughButtonKitTests",
            dependencies: ["CoughButtonKit"],
            path: "Tests/CoughButtonKitTests"
        )
    ]
)
