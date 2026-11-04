// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GrowthBookOpenFeature",
    // OpenFeature Swift requires these minimums; the GrowthBook SDK itself supports older versions.
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "GrowthBookOpenFeature",
            targets: ["GrowthBookOpenFeature"])
    ],
    dependencies: [
        .package(url: "https://github.com/growthbook/growthbook-swift.git", .upToNextMajor(from: "2.0.0")),
        .package(url: "https://github.com/open-feature/swift-sdk.git", .upToNextMinor(from: "0.7.0"))
    ],
    targets: [
        .target(
            name: "GrowthBookOpenFeature",
            dependencies: [
                .product(name: "GrowthBook-IOS", package: "growthbook-swift"),
                .product(name: "OpenFeature", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "GrowthBookOpenFeatureTests",
            dependencies: [
                "GrowthBookOpenFeature",
                .product(name: "GrowthBook-IOS", package: "growthbook-swift"),
                .product(name: "OpenFeature", package: "swift-sdk")
            ]
        )
    ]
)
