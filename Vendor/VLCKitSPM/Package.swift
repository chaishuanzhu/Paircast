// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VLCKitSPM",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "VLCKitSPM", targets: ["VLCKitSPM"]),
    ],
    targets: [
        .binaryTarget(
            name: "VLCKit-all",
            path: "VLCKit-all.xcframework"
        ),
        .target(
            name: "VLCKitSPM",
            dependencies: ["VLCKit-all"],
            path: "Sources/VLCKitSPM",
            linkerSettings: [
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("OpenGLES"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedLibrary("c++"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
            ]
        ),
    ]
)
