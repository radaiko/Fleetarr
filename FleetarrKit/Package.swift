// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FleetarrKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FleetarrKit", targets: ["FleetarrKit"]),
    ],
    targets: [
        .target(
            name: "FleetarrKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "FleetarrKitTests",
            dependencies: ["FleetarrKit"],
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
