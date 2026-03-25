// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ears",
    platforms: [
        // Actual requirement is macOS 14.4+ (for Core Audio process taps).
        // SPM doesn't support .macOS(.v14_4) granularity, so we specify .v14
        // and check the minor version at runtime in Setup.swift.
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "ears",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Ears",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
