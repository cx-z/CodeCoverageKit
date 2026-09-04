// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodeCoverageKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "CodeCoverageKit", targets: ["CodeCoverageKit"])
    ],
    targets: [
        .target(
            name: "CodeCoverageRuntimeBridge",
            path: "Sources/CodeCoverageRuntimeBridge",
            publicHeadersPath: "include",
            cSettings: [
                .define("CODE_COVERAGE_KIT_ENABLED", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "CodeCoverageKit",
            dependencies: ["CodeCoverageRuntimeBridge"],
            path: "Sources/CodeCoverageKit",
            swiftSettings: [
                .define("CODE_COVERAGE_KIT_ENABLED", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "CodeCoverageKitTests",
            dependencies: ["CodeCoverageKit", "CodeCoverageRuntimeBridge"],
            path: "Tests/CodeCoverageKitTests"
        )
    ]
)
