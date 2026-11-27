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
        .binaryTarget(name: "CCKProfileMerge", path: "Vendor/LLVMProfileMerge/CCKProfileMerge.xcframework"),
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
            dependencies: ["CodeCoverageRuntimeBridge", "CCKProfileMerge"],
            path: "Sources/CodeCoverageKit",
            swiftSettings: [
                .define("CODE_COVERAGE_KIT_ENABLED", .when(configuration: .debug))
            ],
            linkerSettings: [.linkedLibrary("z"), .linkedLibrary("c++")]
        ),
        .testTarget(
            name: "CodeCoverageKitTests",
            dependencies: ["CodeCoverageKit", "CodeCoverageRuntimeBridge"],
            path: "Tests/CodeCoverageKitTests"
        )
    ]
)
