// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CodeCoverageKitOfflineMerge",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "CodeCoverageKitOfflineMerge", targets: ["CodeCoverageKitOfflineMerge"])],
    dependencies: [.package(name: "CodeCoverageKit", path: "..")],
    targets: [
        .binaryTarget(name: "CCKProfileMerge", path: "Artifacts/CCKProfileMerge.xcframework"),
        .target(name: "CodeCoverageKitOfflineMerge", dependencies: [
            .product(name: "CodeCoverageKit", package: "CodeCoverageKit"), "CCKProfileMerge"
        ], path: "Sources", swiftSettings: [.define("CODE_COVERAGE_KIT_ENABLED", .when(configuration: .debug))], linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("z")]),
        .testTarget(name: "CodeCoverageKitOfflineMergeTests", dependencies: ["CodeCoverageKitOfflineMerge", .product(name: "CodeCoverageKit", package: "CodeCoverageKit")], path: "Tests")
    ])
