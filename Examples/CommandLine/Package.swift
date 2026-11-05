// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CommandLineExample",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        // Uses the provider from this repo; apps depend on the released package instead.
        .package(path: "../.."),
        .package(url: "https://github.com/growthbook/growthbook-swift.git", .upToNextMajor(from: "2.0.0")),
        .package(url: "https://github.com/open-feature/swift-sdk.git", .upToNextMinor(from: "0.7.0"))
    ],
    targets: [
        .executableTarget(
            name: "CommandLineExample",
            dependencies: [
                .product(name: "GrowthBookOpenFeature", package: "growthbook-openfeature-provider-swift"),
                .product(name: "GrowthBook-IOS", package: "growthbook-swift"),
                .product(name: "OpenFeature", package: "swift-sdk")
            ]
        )
    ]
)
