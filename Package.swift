// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EPaperNFCSwift",
    platforms: [
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "EPaperNFCSwift",
            targets: [
                "EPaperNFCSwift"
            ]
        )
    ],
    targets: [
        .target(
            name: "EPaperNFCSwift"
        )
    ]
)

for target in package.targets {
    var swiftSettings = target.swiftSettings ?? []
    swiftSettings.append(contentsOf: [
        // Enable approachable concurrency flags for Swift 6
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances")
    ])
    target.swiftSettings = swiftSettings
}
